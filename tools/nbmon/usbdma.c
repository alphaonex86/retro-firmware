/* NBMON payload: the suspected USB-DMA memory corruption of the A90's VT6212, without Linux. The EHCI is halted and
   gives every port to its UHCIs (CONFIGFLAG 0); the stick (STICK_FN/STICK_PORT first, else the first full-speed
   device) is reset and configured; then "arg" iterations of a bulk-only READ(10) of 64 KB at LBA into A, while the CPU
   writes and verifies a rotating address pattern over B. Polled, own frame list, QH and TDs. Returns the error count
   (FFFFFFFF: no test); bit 31 of arg injects one A and one B fault at iteration 2 (self-test). Load at 00100000. */
#include "nbmon_api.h"

#define VT6212_EHCI 0x31041106u   /* function 2; the UHCIs are functions 0 and 1 */
#define STICK_FN    1             /* EHCI port 3 = UHCI 0c.1 port 1 on the real board */
#define STICK_PORT  1
#define LBA         0
#define BLOCKS      128

#define RAM_DMA     0x00110000u   /* frame list, QH, control/BOT buffers, TDs */
#define RAM_A       0x00120000u
#define RAM_REF     0x00130000u   /* the first read */
#define RAM_B_LO    0x00140000u
#define RAM_B_HI    0x00770000u   /* free RAM ends at 0077f1e0 */
#define READ_LEN    (BLOCKS * 512)

#define FRAME_LIST  ((volatile uint32_t *)RAM_DMA)
#define QH          ((volatile uint32_t *)(RAM_DMA + 0x1000))
#define SETUP       (RAM_DMA + 0x1100)
#define CBW         (RAM_DMA + 0x1120)
#define CSW         (RAM_DMA + 0x1160)
#define CTL         (RAM_DMA + 0x1200)
#define TDS         ((volatile struct td *)(RAM_DMA + 0x2000))

enum { CMD_RS = 1, CMD_HCRESET = 2, CMD_CF = 0x40, CMD_MAXP = 0x80, STS_HALTED = 0x20 };
enum { PORT_CCS = 1, PORT_CSC = 2, PORT_PE = 4, PORT_PEC = 8, PORT_LSDA = 0x100, PORT_PR = 0x200 };
enum { TD_ACTIVE = 1u << 23, TD_ERRORS = 0x760000, PID_SETUP = 0x2d, PID_IN = 0x69, PID_OUT = 0xe1 };

struct td { uint32_t link, status, token, buffer; };
struct diff { uint32_t n, first, xor; };

static const struct nbmon_api *Api;
static uint16_t UhciIo[2], Io, PortReg;
static uint32_t EhciOp, Tag;
static int Addr, Mps0, EpIn, EpOut, MpsBulk, ToggleIn, ToggleOut, NTd;

static void outb(uint16_t port, uint8_t v) { __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port)); }
static void outw(uint16_t port, uint16_t v) { __asm__ volatile("outw %0, %1" : : "a"(v), "Nd"(port)); }
static void outl(uint16_t port, uint32_t v) { __asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(port)); }
static uint16_t inw(uint16_t port) { uint16_t v; __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static uint32_t inl(uint16_t port) { uint32_t v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static volatile uint32_t *mmio(uint32_t addr) { return (volatile uint32_t *)addr; }
static volatile uint8_t *bytes(uint32_t addr) { return (volatile uint8_t *)addr; }

static uint32_t
pci_read(int dev, int fn, int reg)
{
    outl(0xcf8, 0x80000000u | dev << 11 | fn << 8 | reg);
    return inl(0xcfc);
}

static void
pci_write(int dev, int fn, int reg, uint32_t v)
{
    outl(0xcf8, 0x80000000u | dev << 11 | fn << 8 | reg);
    outl(0xcfc, v);
}

static void
put_str(const char *s)
{
    while (*s)
        Api->putc(*s++);
}

static void
put_hex(uint32_t v, int digits)
{
    while (digits--)
        Api->putc("0123456789abcdef"[(v >> (4 * digits)) & 15]);
}

static void
put_dec(uint32_t v)
{
    if (v >= 10)
        put_dec(v / 10);
    Api->putc('0' + v % 10);
}

static int
fail(const char *what, uint32_t v)
{
    put_str("usbdma: ");
    put_str(what);
    put_str(" ");
    put_hex(v, 8);
    put_str("\r\n");
    return -1;
}

static int
wait_bits(uint16_t port, uint16_t mask, uint16_t want)
{
    for (int ms = 0; ms < 20; ms++, Api->mdelay(1))
        if ((inw(port) & mask) == want)
            return 0;
    return -1;
}

static void
td_add(int pid, int ep, int toggle, uint32_t buf, int len)
{
    volatile struct td *t = &TDS[NTd];
    t->link = 1;
    t->status = 3u << 27 | TD_ACTIVE;
    t->token = (uint32_t)((len - 1) & 0x7ff) << 21 | toggle << 19 | ep << 15 | Addr << 8 | pid;
    t->buffer = buf;
    if (NTd)
        TDS[NTd - 1].link = (uint32_t)t | 4;   /* depth first */
    NTd++;
}

static void
bulk_add(int in, uint32_t buf, uint32_t len)
{
    for (uint32_t off = 0; off < len; off += MpsBulk) {
        int n = len - off < (uint32_t)MpsBulk ? (int)(len - off) : MpsBulk;
        if (in)
            td_add(PID_IN, EpIn, ToggleIn, buf + off, n), ToggleIn ^= 1;
        else
            td_add(PID_OUT, EpOut, ToggleOut, buf + off, n), ToggleOut ^= 1;
    }
}

static void
queue_start(void)
{
    QH[1] = (uint32_t)TDS;
}

/* The queue to its end; then every TD moved its full length. */
static int
queue_wait(uint32_t timeout_ms)
{
    uint32_t start = Api->ticks(), element;
    while (!((element = QH[1]) & 1)) {
        uint32_t status = ((volatile struct td *)(element & ~0xfu))->status;
        if (!(status & TD_ACTIVE) && (status & TD_ERRORS))
            return QH[1] = 1, fail("TD error, status", status);
        if (Api->ticks() - start > timeout_ms)
            return QH[1] = 1, fail("timeout at TD", element);
    }
    for (int i = 0; i < NTd; i++)
        if ((TDS[i].status ^ TDS[i].token >> 21) & 0x7ff)
            return fail("short packet, status", TDS[i].status);
    return 0;
}

static int
control(int type, int request, int value, int len)
{
    volatile uint8_t *s = bytes(SETUP);
    int in = type & 0x80, toggle = 1;
    s[0] = type, s[1] = request, s[2] = value, s[3] = value >> 8, s[4] = s[5] = 0, s[6] = len, s[7] = len >> 8;
    NTd = 0;
    td_add(PID_SETUP, 0, 0, SETUP, 8);
    for (int off = 0; off < len; off += Mps0, toggle ^= 1)
        td_add(in ? PID_IN : PID_OUT, 0, toggle, CTL + off, len - off < Mps0 ? len - off : Mps0);
    td_add(in && len ? PID_OUT : PID_IN, 0, 1, 0, 0);
    queue_start();
    return queue_wait(500);
}

static void
scsi_start(const uint8_t *cdb, int cdb_len, uint32_t buf, uint32_t len)
{
    volatile uint8_t *c = bytes(CBW);
    for (int i = 0; i < 31; i++)
        c[i] = 0;
    *mmio(CBW) = 0x43425355;
    *mmio(CBW + 4) = ++Tag;
    *mmio(CBW + 8) = len;
    c[12] = 0x80, c[14] = cdb_len;
    for (int i = 0; i < cdb_len; i++)
        c[15 + i] = cdb[i];
    NTd = 0;
    bulk_add(0, CBW, 31);
    bulk_add(1, buf, len);
    bulk_add(1, CSW, 13);
    queue_start();
}

/* -1: transport failure, else the CSW status */
static int
scsi_wait(void)
{
    if (queue_wait(3000))
        return -1;
    if (*mmio(CSW) != 0x53425355 || *mmio(CSW + 4) != Tag)
        return fail("bad CSW", *mmio(CSW));
    return bytes(CSW)[12];
}

static int
scsi(const uint8_t *cdb, int cdb_len, uint32_t len)
{
    scsi_start(cdb, cdb_len, CTL, len);
    return scsi_wait();
}

static int
find_card(void)
{
    for (int dev = 0; dev < 32; dev++)
        if (pci_read(dev, 2, 0) == VT6212_EHCI) {
            for (int fn = 0; fn < 2; fn++) {
                UhciIo[fn] = pci_read(dev, fn, 0x20) & 0xffe0;
                pci_write(dev, fn, 4, pci_read(dev, fn, 4) | 5);   /* I/O, bus master */
            }
            uint32_t bar = pci_read(dev, 2, 0x10) & ~0xffu;
            EhciOp = bar + bytes(bar)[0];
            put_str("usbdma: VT6212 at 00:");
            put_hex(dev, 2);
            put_str(", UHCI io ");
            put_hex(UhciIo[0], 4);
            put_str(" ");
            put_hex(UhciIo[1], 4);
            put_str(", EHCI ");
            put_hex(bar, 8);
            put_str("\r\n");
            return 0;
        }
    return fail("no VT6212 EHCI", VT6212_EHCI);
}

static void
uhci_stop(uint16_t io)
{
    outw(io, 0);
    if (wait_bits(io + 2, STS_HALTED, STS_HALTED))
        fail("UHCI does not halt, io", io);
}

static int
pick_port(int fn, int port)
{
    uint16_t sc = inw(UhciIo[fn] + 0x10 + 2 * port);
    if (!(sc & PORT_CCS) || (sc & PORT_LSDA))
        return 0;
    Io = UhciIo[fn], PortReg = Io + 0x10 + 2 * port;
    put_str("usbdma: stick on UHCI function ");
    put_dec(fn);
    put_str(" port ");
    put_dec(port);
    put_str("\r\n");
    return 1;
}

static int
setup_controllers(void)
{
    for (int fn = 0; fn < 2; fn++) {
        uhci_stop(UhciIo[fn]);
        outw(UhciIo[fn], CMD_HCRESET);
        if (wait_bits(UhciIo[fn], CMD_HCRESET, 0))
            return fail("UHCI reset, io", UhciIo[fn]);
    }
    *mmio(EhciOp) &= ~1u;
    for (int ms = 0; ms < 20 && !(*mmio(EhciOp + 4) & 0x1000); ms++)
        Api->mdelay(1);
    if (!(*mmio(EhciOp + 4) & 0x1000))
        return fail("EHCI does not halt, USBSTS", *mmio(EhciOp + 4));
    *mmio(EhciOp + 0x40) = 0;
    Api->mdelay(100);
    if (!pick_port(STICK_FN, STICK_PORT) && !pick_port(0, 0) && !pick_port(0, 1) && !pick_port(1, 0)
        && !pick_port(1, 1))
        return fail("no full-speed device on the UHCI ports", 0);
    for (int i = 0; i < 1024; i++)
        FRAME_LIST[i] = (uint32_t)QH | 2;
    QH[0] = QH[1] = 1;
    outl(Io + 8, RAM_DMA);
    outw(Io + 6, 0);
    outb(Io + 0xc, 0x40);
    outw(Io + 4, 0);
    outw(Io + 2, 0x3f);
    outw(Io, CMD_RS | CMD_CF | CMD_MAXP);
    outw(PortReg, PORT_PR);
    Api->mdelay(50);
    outw(PortReg, 0);
    Api->mdelay(1);
    outw(PortReg, PORT_PE | PORT_CSC | PORT_PEC);
    Api->mdelay(10);
    if (!(inw(PortReg) & PORT_PE))
        return fail("port not enabled, PORTSC", inw(PortReg));
    return 0;
}

static int
setup_stick(void)
{
    volatile uint8_t *d = bytes(CTL);
    Addr = 0, Mps0 = 8;
    if (control(0x80, 6, 0x100, 8))
        return -1;
    Mps0 = d[7];
    if (Mps0 != 8 && Mps0 != 16 && Mps0 != 32 && Mps0 != 64)
        return fail("bMaxPacketSize0", Mps0);
    if (control(0, 5, 1, 0))
        return -1;
    Addr = 1;
    Api->mdelay(10);
    if (control(0x80, 6, 0x200, 9))
        return -1;
    int total = d[2] | d[3] << 8, msc = 0;
    if (total > 255)
        total = 255;
    if (control(0x80, 6, 0x200, total))
        return -1;
    EpIn = EpOut = MpsBulk = 0;
    for (int i = 0; i + 7 <= total && d[i] >= 2; i += d[i]) {
        if (d[i + 1] == 4)
            msc = d[i + 5] == 8 && d[i + 7] == 0x50;
        if (d[i + 1] == 5 && (d[i + 3] & 3) == 2) {
            if (d[i + 2] & 0x80)
                EpIn = d[i + 2] & 15;
            else
                EpOut = d[i + 2] & 15;
            MpsBulk = (d[i + 4] | d[i + 5] << 8) & 0x7ff;
        }
    }
    if (!msc || !EpIn || !EpOut || MpsBulk < 8 || MpsBulk > 64)
        return fail("not a bulk-only stick, bulk max packet", MpsBulk);
    if (control(0, 9, d[5], 0))
        return -1;
    ToggleIn = ToggleOut = 0;

    static const uint8_t inquiry[6] = { 0x12, 0, 0, 0, 36, 0 }, sense[6] = { 0x03, 0, 0, 0, 18, 0 }, tur[6] = { 0 };
    if (scsi(inquiry, 6, 36))
        return fail("INQUIRY", 0);
    put_str("usbdma: ");
    for (int i = 8; i < 36; i++)
        Api->putc(d[i] >= ' ' && d[i] < 127 ? d[i] : '.');
    put_str("\r\n");
    for (int try = 0;; try++) {
        int status = scsi(tur, 6, 0);
        if (status == 0)
            return 0;
        if (status < 0 || try == 20 || scsi(sense, 6, 18) < 0)
            return fail("not ready, sense key", d[2]);
        Api->mdelay(100);
    }
}

static void
teardown(void)
{
    QH[1] = 1;
    for (int fn = 0; fn < 2; fn++)
        uhci_stop(UhciIo[fn]);
    *mmio(EhciOp + 0x40) = 1;
}

static uint32_t
crc32(uint32_t addr, uint32_t len)
{
    uint32_t c = ~0u;
    for (volatile uint8_t *p = bytes(addr); len--; p++) {
        c ^= *p;
        for (int k = 0; k < 8; k++)
            c = c >> 1 ^ (0xedb88320u & -(c & 1));
    }
    return ~c;
}

static void
fill(uint32_t lo, uint32_t hi, uint32_t seed)
{
    for (volatile uint32_t *p = mmio(lo); (uint32_t)p < hi; p++)
        *p = (uint32_t)p ^ seed;
}

/* Words of [lo, hi) unlike ref (0: the fill pattern of seed); the first 4 printed. */
static void
compare(const char *name, uint32_t lo, uint32_t hi, uint32_t ref, uint32_t seed, struct diff *d)
{
    d->n = 0;
    for (volatile uint32_t *p = mmio(lo); (uint32_t)p < hi; p++) {
        uint32_t want = ref ? *mmio(ref + ((uint32_t)p - lo)) : (uint32_t)p ^ seed, got = *p;
        if (got == want)
            continue;
        if (!d->n)
            d->first = (uint32_t)p, d->xor = got ^ want;
        if (d->n++ < 4) {
            put_str("  ");
            put_str(name);
            put_str(" ");
            put_hex((uint32_t)p, 8);
            put_str(" got ");
            put_hex(got, 8);
            put_str(" want ");
            put_hex(want, 8);
            put_str("\r\n");
        }
    }
}

static void
put_diff(const char *name, const struct diff *d)
{
    put_str(name);
    put_dec(d->n);
    if (d->n) {
        put_str(" @");
        put_hex(d->first, 8);
        put_str(" x");
        put_hex(d->xor, 8);
    }
}

static uint32_t
run_test(uint32_t iterations, int inject)
{
    static const uint32_t seeds[4] = { 0, 0xffffffff, 0xa5a5a5a5, 0x5a5a5a5a };
    static const uint8_t read10[10] = { 0x28, 0, LBA >> 24, LBA >> 16 & 255, LBA >> 8 & 255, LBA & 255, 0,
                                        BLOCKS >> 8, BLOCKS & 255, 0 };
    uint32_t errors = 0, ref = 0;
    struct diff a, b;
    for (uint32_t it = 0; it < iterations; it++) {
        fill(RAM_A, RAM_A + READ_LEN, 0xdeadbeef ^ it);   /* the read must replace what the CPU wrote */
        scsi_start(read10, 10, RAM_A, READ_LEN);
        fill(RAM_B_LO, RAM_B_HI, seeds[it & 3]);
        if (inject && it == 1)
            *mmio(RAM_B_LO + 0x323450) ^= 0x10000;
        compare("B", RAM_B_LO, RAM_B_HI, 0, seeds[it & 3], &b);
        int status = scsi_wait();
        if (status) {
            put_str("it ");
            put_dec(it + 1);
            put_str(status < 0 ? " USB transport failure\r\n" : " READ(10) failed\r\n");
            return errors + 1;
        }
        if (inject && it == 1)
            bytes(RAM_A + 0x1234)[0] ^= 0x40;
        uint32_t crc = crc32(RAM_A, READ_LEN);
        if (!it) {
            ref = crc;
            for (uint32_t off = 0; off < READ_LEN; off += 4)
                *mmio(RAM_REF + off) = *mmio(RAM_A + off);
        }
        compare("A", RAM_A, RAM_A + READ_LEN, RAM_REF, 0, &a);
        errors += a.n + b.n + (!a.n && crc != ref);
        put_str("it ");
        put_dec(it + 1);
        put_str(" crc ");
        put_hex(crc, 8);
        put_str(crc == ref ? " OK" : " BAD");
        put_diff(" A ", &a);
        put_diff(" B ", &b);
        put_str("\r\n");
    }
    return errors;
}

NBMON_ENTRY uint32_t
usbdma(uint32_t arg, const struct nbmon_api *api)
{
    Api = api;
    if ((uint32_t)usbdma < 0x100000 || (uint32_t)usbdma + 0x10000 > RAM_DMA)
        return fail("load at 00100000, not", (uint32_t)usbdma), ~0u;
    if (find_card())
        return ~0u;
    uint32_t errors = setup_controllers() || setup_stick() ? ~0u : run_test(arg & 0x7fffffff, arg >> 31);
    teardown();
    put_str("usbdma: errors ");
    put_dec(errors);
    put_str("\r\n");
    return errors;
}
