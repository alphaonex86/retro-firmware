/* NBMON payload: the suspected USB-DMA memory corruption of the A90's VT6212, without Linux. The stick (STICK_FN/
   STICK_PORT first, else the first device found) is reset and configured; then "arg" & 1FFFFFFFh iterations of a
   bulk-only READ(10) of 64 KB at LBA into A, while the CPU writes and verifies a rotating address pattern over B. Own
   schedule. Returns the error count (FFFFFFFF: no test; E00000vv: CPU exception vv). Load at 00100000. Arg bits:
   31 injects one A and one B fault at iteration 2, and with bit 30 one checksum fault (self-test);
   30 interrupts: own IDT, 8259s at 20h/28h, PIT channel 0 at 1 kHz on IRQ0 (it checksums a 4 KB region), the USB IOC
      interrupt on the IRQ of the controller's 3Ch, waits in hlt; every handler checks a stack pattern; counted per
      iteration: IRQ0, USB, spurious IRQ7/15, and the errors wrong vector, stack and checksum mismatch;
   29 EHCI high speed (CONFIGFLAG 1, async QHs and qTDs); clear: the EHCI is halted, the UHCIs own the ports. */
#include "nbmon_api.h"

#define VT6212_EHCI 0x31041106u   /* function 2; the UHCIs are functions 0 and 1 */
#define STICK_FN    1             /* EHCI port 3 = UHCI 0c.1 port 1 on the real board */
#define STICK_PORT  1
#define LBA         0
#define BLOCKS      128

#define RAM_DMA     0x00110000u   /* frame list, QHs, control/BOT buffers, TDs, checksum region, IDT */
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
#define EQH(q)      ((volatile uint32_t *)(RAM_DMA + 0x1400 + 0x40 * (q)))   /* EHCI: control, bulk out, bulk in */
#define TDS         ((volatile struct td *)(RAM_DMA + 0x2000))
#define QTDS        ((volatile struct qtd *)(RAM_DMA + 0x2000))
#define CHECKED     (RAM_DMA + 0xe000)                                       /* 4 KB, summed by IRQ0 */
#define IDT         ((volatile uint32_t *)(RAM_DMA + 0xf000))

enum { CMD_RS = 1, CMD_HCRESET = 2, CMD_CF = 0x40, CMD_MAXP = 0x80, STS_HALTED = 0x20 };
enum { PORT_CCS = 1, PORT_CSC = 2, PORT_PE = 4, PORT_PEC = 8, PORT_LSDA = 0x100, PORT_PR = 0x200 };
enum { TD_ACTIVE = 1u << 23, TD_ERRORS = 0x760000, PID_SETUP = 0x2d, PID_IN = 0x69, PID_OUT = 0xe1 };
enum { E_CMD = 0, E_STS = 4, E_INTR = 8, E_ASYNC = 0x18, E_CONFIGFLAG = 0x40, E_PORTSC = 0x44 };
enum { E_RS = 1, E_HCRESET = 2, E_ASE = 0x20, E_HALTED = 0x1000, E_ASS = 0x8000 };
enum { EP_CCS = 1, EP_PE = 4, EP_PR = 0x100, EP_LS = 0xc00, EP_LS_K = 0x400, EP_PP = 0x1000 };
enum { Q_ACTIVE = 0x80, Q_HALTED = 0x40, Q_IOC = 0x8000, Q_CHUNK = 0x4000 };
enum { C_IRQ0, C_USB, C_SPUR, C_VEC, C_STACK, C_SUM, NCOUNTS };   /* C_VEC and after: errors */

struct td { uint32_t link, status, token, buffer; };
struct qtd { uint32_t next, alt, token, buffer[5]; };
struct diff { uint32_t n, first, xor; };
struct frame { uint32_t edi, esi, ebp, esp, ebx, edx, ecx, eax, vector, error, eip, cs, eflags; };
struct idtr { uint16_t limit; uint32_t base; } __attribute__((packed));

static const struct nbmon_api *Api;
static uint16_t UhciIo[2], Io, PortReg;
static uint32_t EhciOp, EhciPort, Tag, ChecksumRef;
static int CardDev, UsbFn, UsbIrq, Ehci, Irq, IrqActive, ExceptionVector;
static int Addr, Mps0, EpIn, EpOut, MpsBulk, ToggleIn, ToggleOut, NTd, First[3], Last[3];
static volatile uint32_t Count[NCOUNTS];
static uint32_t CountPrinted[NCOUNTS];
static void *Recover[5];
static struct idtr SavedIdtr;
static uint8_t SavedMask[2];

static void outb(uint16_t port, uint8_t v) { __asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port)); }
static void outw(uint16_t port, uint16_t v) { __asm__ volatile("outw %0, %1" : : "a"(v), "Nd"(port)); }
static void outl(uint16_t port, uint32_t v) { __asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(port)); }
static uint8_t inb(uint16_t port) { uint8_t v; __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static uint16_t inw(uint16_t port) { uint16_t v; __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static uint32_t inl(uint16_t port) { uint32_t v; __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port)); return v; }
static volatile uint32_t *mmio(uint32_t addr) { return (volatile uint32_t *)addr; }
static volatile uint8_t *bytes(uint32_t addr) { return (volatile uint8_t *)addr; }
static volatile uint32_t *ereg(uint32_t reg) { return mmio(EhciOp + reg); }

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

static int
wait_ereg(uint32_t reg, uint32_t mask, uint32_t want)
{
    for (int ms = 0; ms < 20; ms++, Api->mdelay(1))
        if ((*ereg(reg) & mask) == want)
            return 0;
    return fail("EHCI timeout, register value", *ereg(reg));
}

/****************************************************************
 * Interrupts (arg bit 30)
 ****************************************************************/

/* Vectors 0-2Fh: a stub each, 16 bytes apart (a dummy error code where the CPU pushes none, the vector); any other
   vector: stub 30h, vector 30h. */
__asm__(".text\n"
        "isr_stubs:\n"
        ".set vec, 0\n"
        ".rept 0x31\n"
        ".balign 16\n"
        ".if vec != 8 && (vec < 10 || vec > 14) && vec != 17\n"
        "pushl $0\n"
        ".endif\n"
        "pushl $vec\n"
        "jmp isr_common\n"
        ".set vec, vec + 1\n"
        ".endr\n"
        "isr_common:\n"
        "pushal\n"
        "cld\n"
        "pushl %esp\n"
        "call isr\n"
        "addl $4, %esp\n"
        "popal\n"
        "addl $8, %esp\n"
        "iret\n");
extern const char isr_stubs[];

static int
stack_pattern_bad(void)
{
    volatile uint32_t pattern[16];
    for (int i = 0; i < 16; i++)
        pattern[i] = (uint32_t)&pattern[i] ^ 0xa5c3e1f0u;
    for (int i = 0; i < 16; i++)
        if (pattern[i] != ((uint32_t)&pattern[i] ^ 0xa5c3e1f0u))
            return 1;
    return 0;
}

static uint32_t
checksum(void)
{
    uint32_t sum = 0;
    for (uint32_t off = 0; off < 4096; off += 4)
        sum = (sum << 1 | sum >> 31) + *mmio(CHECKED + off);
    return sum;
}

static int
pic_in_service(int irq)
{
    uint16_t cmd = irq < 8 ? 0x20 : 0xa0;
    outb(cmd, 0x0b);
    return inb(cmd) >> (irq & 7) & 1;
}

static void
usb_ack(void)
{
    if (Ehci)
        *ereg(E_STS) = *ereg(E_STS) & 0x3f;
    else
        outw(Io + 2, inw(Io + 2) & 0x1f);
}

__attribute__((used, regparm(0))) void
isr(struct frame *f)
{
    int vector = f->vector, irq = vector - 0x20;
    if (vector < 0x20) {
        put_str("usbdma: exception ");
        put_hex(vector, 2);
        put_str(" at eip ");
        put_hex(f->eip, 8);
        put_str(" error ");
        put_hex(f->error, 8);
        put_str(" esp ");
        put_hex(f->esp + 20, 8);
        put_str("\r\n");
        ExceptionVector = vector;
        __builtin_longjmp(Recover, 1);
    }
    Count[C_STACK] += stack_pattern_bad();
    if ((irq == 7 || irq == 15) && !pic_in_service(irq)) {
        Count[C_SPUR]++;
        if (irq == 15)
            outb(0x20, 0x20);
        return;
    }
    if (irq == 0) {
        Count[C_IRQ0]++;
        Count[C_SUM] += checksum() != ChecksumRef;
    } else if (irq == UsbIrq) {
        Count[C_USB]++;
        usb_ack();   /* level-triggered: the source off before the EOI */
    } else {
        Count[C_VEC]++;
        if (irq > 15)
            return;
    }
    if (irq >= 8)
        outb(0xa0, 0x20);
    outb(0x20, 0x20);
}

static void
pic_init(uint8_t base1, uint8_t base2)
{
    outb(0x20, 0x11), outb(0xa0, 0x11);
    outb(0x21, base1), outb(0xa1, base2);
    outb(0x21, 4), outb(0xa1, 2);
    outb(0x21, 1), outb(0xa1, 1);
}

static void
pit0(uint16_t divisor)
{
    outb(0x43, 0x34);   /* mode 2, as SeaBIOS */
    outb(0x40, divisor), outb(0x40, divisor >> 8);
}

static void
irq_on(void)
{
    uint16_t cs;
    __asm__ volatile("mov %%cs, %0" : "=r"(cs));
    for (int v = 0; v < 256; v++) {
        uint32_t stub = (uint32_t)isr_stubs + 16 * (v < 0x30 ? v : 0x30);
        IDT[2 * v] = (stub & 0xffff) | (uint32_t)cs << 16;
        IDT[2 * v + 1] = (stub & 0xffff0000u) | 0x8e00;
    }
    struct idtr idtr = { 256 * 8 - 1, (uint32_t)IDT };
    __asm__ volatile("sidt %0" : "=m"(SavedIdtr));
    __asm__ volatile("lidt %0" : : "m"(idtr));
    for (uint32_t off = 0; off < 4096; off += 4)
        *mmio(CHECKED + off) = (CHECKED + off) * 0x9e3779b1u;
    ChecksumRef = checksum();
    SavedMask[0] = inb(0x21), SavedMask[1] = inb(0xa1);
    pic_init(0x20, 0x28);
    outb(0x21, ~(1 | (UsbIrq < 8 ? 1 << UsbIrq : 4)));
    outb(0xa1, UsbIrq < 8 ? 0xff : ~(1 << (UsbIrq - 8)));
    pit0(1193);
    IrqActive = 1;
    __asm__ volatile("sti");
}

static void
irq_off(void)
{
    __asm__ volatile("cli");
    if (!IrqActive)
        return;
    IrqActive = 0;
    pit0(0);
    pic_init(0x08, 0x70);
    outb(0x21, SavedMask[0]), outb(0xa1, SavedMask[1]);
    __asm__ volatile("lidt %0" : : "m"(SavedIdtr));
}

/****************************************************************
 * Transfers: UHCI TDs on one QH, or EHCI qTDs on three QHs; IOC on the last of each stage
 ****************************************************************/

static void
td_add(int pid, int ep, int toggle, uint32_t buf, int len, int ioc)
{
    volatile struct td *t = &TDS[NTd];
    t->link = 1;
    t->status = 3u << 27 | TD_ACTIVE | ioc << 24;
    t->token = (uint32_t)((len - 1) & 0x7ff) << 21 | toggle << 19 | ep << 15 | Addr << 8 | pid;
    t->buffer = buf;
    if (NTd)
        TDS[NTd - 1].link = (uint32_t)t | 4;   /* depth first */
    NTd++;
}

static void
qtd_add(int q, int pid, int toggle, uint32_t buf, uint32_t len, int ioc)
{
    volatile struct qtd *t = &QTDS[NTd];
    t->next = t->alt = 1;
    t->token = (uint32_t)toggle << 31 | len << 16 | (ioc ? Q_IOC : 0) | 3 << 10
               | (pid == PID_OUT ? 0 : pid == PID_IN ? 1 : 2) << 8 | Q_ACTIVE;
    for (int i = 0; i < 5; i++)
        t->buffer[i] = i ? (buf & ~0xfffu) + 0x1000 * i : buf;
    if (First[q] < 0)
        First[q] = NTd;
    else
        QTDS[Last[q]].next = (uint32_t)t;
    Last[q] = NTd++;
}

static void
queue_reset(void)
{
    NTd = 0;
    for (int q = 0; q < 3; q++)
        First[q] = Last[q] = -1;
}

/* One stage of a transfer: packets (UHCI) or 16 KB qTDs (EHCI), at least one */
static void
stage(int pid, int ep, int *toggle, uint32_t buf, uint32_t len)
{
    uint32_t max = Ehci ? Q_CHUNK : ep ? MpsBulk : Mps0, off = 0;
    do {
        uint32_t n = len - off < max ? len - off : max;
        if (Ehci)
            qtd_add(!ep ? 0 : pid == PID_OUT ? 1 : 2, pid, *toggle, buf + off, n, off + n == len);
        else {
            td_add(pid, ep, *toggle, buf + off, n, off + n == len);
            *toggle ^= 1;
        }
        off += n;
    } while (off < len);
}

static void
ehci_qh_init(int q)
{
    volatile uint32_t *qh = EQH(q);
    int ep = q == 0 ? 0 : q == 1 ? EpOut : EpIn;
    qh[0] = (uint32_t)EQH((q + 1) % 3) | 2;
    qh[1] = (q ? 0 : 1u << 15 | 1u << 14) | (uint32_t)(q ? MpsBulk : Mps0) << 16 | 2 << 12 | ep << 8 | Addr;
    qh[2] = 1u << 30;
    qh[3] = 0;
    qh[4] = First[q] < 0 ? 1 : (uint32_t)&QTDS[First[q]];
    qh[5] = 1;
    qh[6] = (uint32_t)(q == 1 ? ToggleOut : q == 2 ? ToggleIn : 0) << 31;
    for (int i = 7; i < 12; i++)
        qh[i] = 0;
}

static int
ehci_async(int on)
{
    *ereg(E_CMD) = (*ereg(E_CMD) & ~E_ASE) | (on ? E_ASE : 0);
    return wait_ereg(E_STS, E_ASS, on ? E_ASS : 0);
}

static int
queue_start(void)
{
    if (!Ehci)
        return QH[1] = (uint32_t)TDS, 0;
    for (int q = 0; q < 3; q++)
        ehci_qh_init(q);
    return ehci_async(1);
}

static void
idle(void)
{
    if (Irq)
        __asm__ volatile("hlt");
}

static int
uhci_wait(uint32_t timeout_ms)
{
    uint32_t start = Api->ticks(), element;
    while (!((element = QH[1]) & 1)) {
        uint32_t status = ((volatile struct td *)(element & ~0xfu))->status;
        if (!(status & TD_ACTIVE) && (status & TD_ERRORS))
            return QH[1] = 1, fail("TD error, status", status);
        if (Api->ticks() - start > timeout_ms)
            return QH[1] = 1, fail("timeout at TD", element);
        idle();
    }
    for (int i = 0; i < NTd; i++)
        if ((TDS[i].status ^ TDS[i].token >> 21) & 0x7ff)
            return fail("short packet, status", TDS[i].status);
    return 0;
}

static int
ehci_wait(uint32_t timeout_ms)
{
    uint32_t start = Api->ticks();
    for (int i = 0; i < NTd;) {
        uint32_t token = QTDS[i].token;
        if (token & Q_HALTED)
            return fail("qTD error, token", token);
        if (!(token & Q_ACTIVE) && (token >> 16 & 0x7fff))
            return fail("short packet, token", token);
        if (!(token & Q_ACTIVE))
            i++;
        else if (Api->ticks() - start > timeout_ms)
            return fail("timeout at qTD", (uint32_t)&QTDS[i]);
        else
            idle();
    }
    return 0;
}

/* The queue to its end; then every descriptor moved its full length. */
static int
queue_wait(uint32_t timeout_ms)
{
    if (!Ehci)
        return uhci_wait(timeout_ms);
    int r = ehci_wait(timeout_ms);
    if (ehci_async(0))
        return -1;
    ToggleOut = EQH(1)[6] >> 31, ToggleIn = EQH(2)[6] >> 31;
    return r;
}

static int
control(int type, int request, int value, int len)
{
    volatile uint8_t *s = bytes(SETUP);
    int in = type & 0x80, toggle = 0;
    s[0] = type, s[1] = request, s[2] = value, s[3] = value >> 8, s[4] = s[5] = 0, s[6] = len, s[7] = len >> 8;
    queue_reset();
    stage(PID_SETUP, 0, &toggle, SETUP, 8);
    toggle = 1;
    if (len)
        stage(in ? PID_IN : PID_OUT, 0, &toggle, CTL, len);
    toggle = 1;
    stage(in && len ? PID_OUT : PID_IN, 0, &toggle, 0, 0);
    return queue_start() || queue_wait(500);
}

/****************************************************************
 * Bulk-only SCSI
 ****************************************************************/

static int
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
    queue_reset();
    stage(PID_OUT, EpOut, &ToggleOut, CBW, 31);
    if (len)
        stage(PID_IN, EpIn, &ToggleIn, buf, len);
    stage(PID_IN, EpIn, &ToggleIn, CSW, 13);
    return queue_start();
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
    return scsi_start(cdb, cdb_len, CTL, len) ? -1 : scsi_wait();
}

/****************************************************************
 * Controllers and stick
 ****************************************************************/

static int
find_card(void)
{
    for (int dev = 0; dev < 32; dev++)
        if (pci_read(dev, 2, 0) == VT6212_EHCI) {
            for (int fn = 0; fn < 2; fn++) {
                UhciIo[fn] = pci_read(dev, fn, 0x20) & 0xffe0;
                pci_write(dev, fn, 4, pci_read(dev, fn, 4) | 5);   /* I/O, bus master */
            }
            pci_write(dev, 2, 4, pci_read(dev, 2, 4) | 6);         /* memory, bus master */
            uint32_t bar = pci_read(dev, 2, 0x10) & ~0xffu;
            EhciOp = bar + bytes(bar)[0];
            CardDev = dev;
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
    outw(io + 4, 0);
    outw(io, 0);
    if (wait_bits(io + 2, STS_HALTED, STS_HALTED))
        fail("UHCI does not halt, io", io);
    outw(io + 2, 0x1f);
}

static int
pick_uhci_port(int fn, int port)
{
    uint16_t sc = inw(UhciIo[fn] + 0x10 + 2 * port);
    if (!(sc & PORT_CCS) || (sc & PORT_LSDA))
        return 0;
    Io = UhciIo[fn], PortReg = Io + 0x10 + 2 * port, UsbFn = fn;
    put_str("usbdma: stick on UHCI function ");
    put_dec(fn);
    put_str(" port ");
    put_dec(port);
    put_str("\r\n");
    return 1;
}

static int
pick_ehci_port(int port)
{
    uint32_t sc = *ereg(E_PORTSC + 4 * port);
    if (!(sc & EP_CCS) || (sc & EP_LS) == EP_LS_K)
        return 0;
    EhciPort = E_PORTSC + 4 * port, UsbFn = 2;
    put_str("usbdma: stick on EHCI port ");
    put_dec(port);
    put_str("\r\n");
    return 1;
}

static int
uhci_setup(void)
{
    if (!pick_uhci_port(STICK_FN, STICK_PORT) && !pick_uhci_port(0, 0) && !pick_uhci_port(0, 1)
        && !pick_uhci_port(1, 0) && !pick_uhci_port(1, 1))
        return fail("no full-speed device on the UHCI ports", 0);
    for (int i = 0; i < 1024; i++)
        FRAME_LIST[i] = (uint32_t)QH | 2;
    QH[0] = QH[1] = 1;
    outl(Io + 8, RAM_DMA);
    outw(Io + 6, 0);
    outb(Io + 0xc, 0x40);
    outw(Io + 4, Irq ? 0x0f : 0);
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
ehci_setup(void)
{
    *ereg(E_CMD) = E_HCRESET;
    if (wait_ereg(E_CMD, E_HCRESET, 0))
        return -1;
    *ereg(0x10) = 0;   /* CTRLDSSEGMENT */
    *ereg(E_INTR) = Irq ? 3 : 0;
    *ereg(E_ASYNC) = (uint32_t)EQH(0);
    *ereg(E_CMD) = 8 << 16 | E_RS;
    if (wait_ereg(E_STS, E_HALTED, 0))
        return -1;
    *ereg(E_CONFIGFLAG) = 1;
    for (int p = 0; p < 4; p++)
        *ereg(E_PORTSC + 4 * p) = EP_PP;
    Api->mdelay(100);
    if (!pick_ehci_port(2 * STICK_FN + STICK_PORT) && !pick_ehci_port(0) && !pick_ehci_port(1)
        && !pick_ehci_port(2) && !pick_ehci_port(3))
        return fail("no device on the EHCI ports", 0);
    *ereg(EhciPort) = EP_PP | EP_PR;
    Api->mdelay(50);
    *ereg(EhciPort) = EP_PP;
    if (wait_ereg(EhciPort, EP_PR, 0))
        return -1;
    Api->mdelay(10);
    if (!(*ereg(EhciPort) & EP_PE))
        return fail("not high speed, PORTSC", *ereg(EhciPort));
    return 0;
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
    *ereg(E_INTR) = 0;
    *ereg(E_CMD) &= ~E_RS;
    if (wait_ereg(E_STS, E_HALTED, E_HALTED))
        return -1;
    *ereg(E_CONFIGFLAG) = 0;
    Api->mdelay(100);
    if (Ehci ? ehci_setup() : uhci_setup())
        return -1;
    UsbIrq = pci_read(CardDev, UsbFn, 0x3c) & 0xff;
    if (!Irq)
        return 0;
    if (UsbIrq < 3 || UsbIrq > 15)
        return fail("no PCI IRQ in 3Ch", UsbIrq);
    put_str("usbdma: IRQ ");
    put_dec(UsbIrq);
    put_str(", 82C558M 42h ");
    put_hex(pci_read(1, 0, 0x40) >> 16 & 0xff, 2);
    put_str("\r\n");
    return 0;
}

static int
setup_stick(void)
{
    volatile uint8_t *d = bytes(CTL);
    Addr = 0, Mps0 = Ehci ? 64 : 8;
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
    if (!msc || !EpIn || !EpOut || MpsBulk < 8 || MpsBulk > (Ehci ? 512 : 64))
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
    *ereg(E_INTR) = 0;
    *ereg(E_CMD) &= ~(E_RS | E_ASE);
    wait_ereg(E_STS, E_HALTED, E_HALTED);
    *ereg(E_STS) = 0x3f;
    *ereg(E_CONFIGFLAG) = 1;
}

/****************************************************************
 * The test
 ****************************************************************/

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

/* Self-test: one IRQ0 sees a word of the checksummed region changed */
static void
checksum_fault(void)
{
    __asm__ volatile("cli");
    *mmio(CHECKED + 0x100) ^= 1;
    for (uint32_t ticks = Count[C_IRQ0]; Count[C_IRQ0] == ticks;)
        __asm__ volatile("sti; hlt; cli");
    *mmio(CHECKED + 0x100) ^= 1;
    __asm__ volatile("sti");
}

/* The interrupt counts since the last call; returns the handler errors among them. */
static uint32_t
put_counts(void)
{
    static const char *const names[NCOUNTS] = { " irq0 ", " usb ", " spur ", " vec ", " stack ", " sum " };
    uint32_t errors = 0;
    for (int c = 0; c < NCOUNTS; c++) {
        uint32_t now = Count[c], n = now - CountPrinted[c];
        CountPrinted[c] = now;
        put_str(names[c]);
        put_dec(n);
        if (c >= C_VEC)
            errors += n;
    }
    return errors;
}

static uint32_t
run_test(uint32_t iterations, int inject)
{
    static const uint32_t seeds[4] = { 0, 0xffffffff, 0xa5a5a5a5, 0x5a5a5a5a };
    static const uint8_t read10[10] = { 0x28, 0, LBA >> 24, LBA >> 16 & 255, LBA >> 8 & 255, LBA & 255, 0,
                                        BLOCKS >> 8, BLOCKS & 255, 0 };
    uint32_t errors = 0, ref = 0;
    struct diff a, b;
    if (Irq) {
        put_str("usbdma: setup");
        errors += put_counts();
        put_str("\r\n");
    }
    for (uint32_t it = 0; it < iterations; it++) {
        fill(RAM_A, RAM_A + READ_LEN, 0xdeadbeef ^ it);   /* the read must replace what the CPU wrote */
        int status = scsi_start(read10, 10, RAM_A, READ_LEN) ? -1 : 0;
        fill(RAM_B_LO, RAM_B_HI, seeds[it & 3]);
        if (inject && it == 1)
            *mmio(RAM_B_LO + 0x323450) ^= 0x10000;
        if (inject && it == 1 && Irq)
            checksum_fault();
        compare("B", RAM_B_LO, RAM_B_HI, 0, seeds[it & 3], &b);
        if (!status)
            status = scsi_wait();
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
        if (Irq)
            errors += put_counts();
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
    Irq = arg >> 30 & 1, Ehci = arg >> 29 & 1;
    for (int c = 0; c < NCOUNTS; c++)
        Count[c] = CountPrinted[c] = 0;
    if (find_card())
        return ~0u;
    uint32_t errors = ~0u;
    if (__builtin_setjmp(Recover))
        errors = 0xe0000000u | ExceptionVector;
    else if (!setup_controllers()) {
        if (Irq)
            irq_on();
        errors = setup_stick() ? ~0u : run_test(arg & 0x1fffffff, arg >> 31);
    }
    teardown();
    irq_off();
    put_str("usbdma: errors ");
    put_dec(errors);
    put_str("\r\n");
    return errors;
}
