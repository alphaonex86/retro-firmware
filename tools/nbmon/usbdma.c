/* NBMON payload: the suspected USB-DMA memory corruption of the A90's VT6212, without Linux. The stick (STICK_FN/
   STICK_PORT first, else the first device found) is reset and configured; then "arg" & FFFFh iterations of a
   bulk-only READ(10) of 64 KB at LBA into A, while the CPU writes and verifies a rotating address pattern over B: the
   free RAM [FREE_LO, FREE_HI) less A, the schedule (64 KB after A) and the first read (after the schedule). Own
   schedule. Returns the error count (FFFFFFFF: no test; E00000vv: CPU exception vv). Load at 00100000. Arg bits:
   31 injects one A and one B fault at iteration 2, and with bit 30 one checksum fault (self-test);
   30 interrupts: own IDT, 8259s at 20h/28h, PIT channel 0 at 1 kHz on IRQ0 (it checksums a 4 KB region), the USB IOC
      interrupt on the IRQ of the controller's 3Ch, waits in hlt; every handler checks a stack pattern; counted per
      iteration: IRQ0, USB, spurious IRQ7/15, and the errors wrong vector, stack and checksum mismatch; IRQ0 is the
      clock (the BIOS one reads PIT channel 0); the interrupt state is printed 100 ms after the setup and on a USB
      failure;
   29 EHCI high speed (CONFIGFLAG 1, async QHs and qTDs); clear: the EHCI is halted, the UHCIs own the ports;
   28 each iteration reads into another of 16 A slots, 384 KB apart from the base, wrapping in the free RAM;
   27 shared lines: the read (127 blocks) starts at A + 24h, mid 32-byte line, and every UHCI TD has a line of its own;
      the CPU keeps rewriting the rest of those lines (guards: around the read, after each TD and the UHCI QH, the
      EHCI QHs' spare dwords 12-15, after the CSW) with a counter, before each start, while it waits and between
      the 64 KB parts of B; after each transfer the guards must hold the last value (G: the mismatches);
   26 write+readback: the CPU fills A with a new pattern, WRITE(10) to LBA_W = 37800h + n * 80h (in the
      stick's swap partition; A stays at 00120000), READ(10) back into the poisoned first-read area (A2), compared
      with A (W: the mismatches, @ the offset); A must still hold the pattern;
   25 wbinvd after the CPU fill, before the transfer;
   24 EHCI qTD/QH overrun guards: qTDs 128 bytes apart, bytes 32-127 guards, QHs 256 apart, bytes 48-175 guards, set
      before each transfer, checked after it: "O n" and a line per changed place (its qTD stage or QH, offset,
      old -> new, count);
   23 Linux-style unlink (EHCI): the async schedule keeps running on a permanent head QH; each transfer gets the next
      of 16 slots (3 QHs, its qTDs), linked after the head, unlinked after the transfer with the IAA doorbell (its
      interrupt with bit 30), then filled with a guard pattern at once; every freed slot is checked after each
      transfer and 5 ms after the last: "F n" and a line per changed place (slot, offset, old -> new, count);
      Knobs in RAM (wl before call): 0010FFF0 ms of delay after IAA before freeing (0-1000), 0010FFF4 IAA doorbells
      (0: 1, up to 16), 0010FFF8 nonzero: wait until ASYNCLISTADDR (the HC's current QH) is off the slot, 0010FFFC
      the freed slot polled every 0.1 ms for that many 0.1 ms ("+t ms" after IAA of the first change; "late": found
      later; FFFFFFFF: 10 ms). Freed slots are also checked while the next transfer runs, a change noted with what
      ran then (unlink, watch, between transfers, the active qTD's stage of the slot in use, end);
      0010FFEC (with bit 29): bit 0, 1: UHCI function 0, 1 runs Linux's empty skeleton beside the EHCI (4 KB frame
      list, 11 QHs, inactive TDs, RS, MAXP, its interrupts), checked during and after each transfer: unchanged, no
      HSE, process error or halt, the frame number advancing ("U n", lines "U fn ...");
      0010FFE8: the IAA timeout in ms (0: 20, up to 1000). The IAA latency (doorbell to USBSTS IAA, PIT polled,
      no hlt) ends the run: min/avg/max, a histogram, the waits over 10 ms;
   22 no B: the CPU leaves B alone (an idle CPU during the transfers);
   20 unlink while busy (with bit 23): 4 empty dummy QHs follow the transfer's QHs in the ring; during each
      READ/WRITE, once its CBW is out, the first dummy is unlinked (the bulk-in QH before it skips it), IAA awaited
      ("IAA busy" statistics, with how often the data stage was still active), the dummy poisoned at once and watched
      ("F dummy"); a fresh one of 16 is linked at the end after the transfer;
   16-19 n: A's base n * 512 KB (3-14; 0: 00120000); with bit 26, LBA_W. */
#include "nbmon_api.h"

#define VT6212_EHCI 0x31041106u   /* function 2; the UHCIs are functions 0 and 1 */
#define STICK_FN    1             /* EHCI port 3 = UHCI 0c.1 port 1 on the real board */
#define STICK_PORT  1
#define LBA         0
#define BLOCKS      128

#define FREE_LO     0x00110000u   /* after the payload */
#define FREE_HI     0x00770000u   /* free RAM ends at 0077f1e0 */
#define CHUNK       0x10000u      /* A, the schedule, the first read and the parts of B */
#define NCHUNKS     ((FREE_HI - FREE_LO) / CHUNK)
#define READ_LEN    (BLOCKS * 512)
#define RAM_DMA     Dma           /* frame list, QHs, control/BOT buffers, TDs, checksum region, IDT */

#define FRAME_LIST  ((volatile uint32_t *)RAM_DMA)
#define QH          ((volatile uint32_t *)(RAM_DMA + 0x1000))
#define SETUP       (RAM_DMA + 0x1100)
#define CBW         (RAM_DMA + 0x1120)
#define CSW         (RAM_DMA + 0x1160)
#define CTL         (RAM_DMA + 0x1200)
/* EHCI QHs: control, bulk out, bulk in */
#define EQH(q)      ((volatile uint32_t *)(Unlink ? SLOT(CurSlot) + 0x40 * (q) \
                                          : RAM_DMA + 0x1400 + (Overrun ? 0x100 : 0x40) * (q)))
#define SLOT(n)     (RAM_DMA + 0xa000 + 0x200 * (n))   /* bit 23: 3 QHs, then the qTDs from C0h */
#define HEAD_QH     ((volatile uint32_t *)(RAM_DMA + 0xc000))
#define NSLOTS      16
#define DSLOT(n)    ((volatile uint32_t *)(RAM_DMA + 0xc400 + 0x40 * (n)))   /* bit 20: 16 dummy QHs */
#define CHECKED     (RAM_DMA + 0xe000)                                       /* 4 KB, summed by IRQ0 */
#define IDT         ((volatile uint32_t *)(RAM_DMA + 0xf000))

enum { CMD_RS = 1, CMD_HCRESET = 2, CMD_CF = 0x40, CMD_MAXP = 0x80, STS_HALTED = 0x20 };
enum { PORT_CCS = 1, PORT_CSC = 2, PORT_PE = 4, PORT_PEC = 8, PORT_LSDA = 0x100, PORT_PR = 0x200 };
enum { TD_ACTIVE = 1u << 23, TD_ERRORS = 0x760000, PID_SETUP = 0x2d, PID_IN = 0x69, PID_OUT = 0xe1 };
enum { E_CMD = 0, E_STS = 4, E_INTR = 8, E_ASYNC = 0x18, E_CONFIGFLAG = 0x40, E_PORTSC = 0x44 };
enum { E_RS = 1, E_HCRESET = 2, E_ASE = 0x20, E_IAAD = 0x40, E_IAA = 0x20, E_HALTED = 0x1000, E_ASS = 0x8000 };
enum { EP_CCS = 1, EP_PE = 4, EP_PR = 0x100, EP_LS = 0xc00, EP_LS_K = 0x400, EP_PP = 0x1000 };
enum { Q_ACTIVE = 0x80, Q_HALTED = 0x40, Q_IOC = 0x8000, Q_CHUNK = 0x4000 };
enum { C_IRQ0, C_USB, C_SPUR, C_VEC, C_STACK, C_SUM, NCOUNTS };   /* C_VEC and after: errors */

struct td { uint32_t link, status, token, buffer; };
struct qtd { uint32_t next, alt, token, buffer[5]; };
struct diff { uint32_t n, first, xor; };
static struct diff Guard;
struct frame { uint32_t edi, esi, ebp, esp, ebx, edx, ecx, eax, vector, error, eip, cs, eflags; };
struct idtr { uint16_t limit; uint32_t base; } __attribute__((packed));

static const struct nbmon_api *Api;
static uint32_t Base, RamA, Dma, Ref, Legsup[2], Buf, Len, GuardValue;
static int Shared, GuardInject, Write, Wbinvd, Overrun, OverrunInject, NOverruns, Unlink, FreedInject, CurSlot;
static int Freed[NSLOTS];
static uint32_t KnobDelay, KnobCycles, KnobAsync, KnobWatch, KnobIaaTimeout, FirstStray = ~0u;
static struct iaa { uint32_t waits, min, max, sum, hist[8]; } Iaa[2];   /* transfer, busy unlinks: PIT ticks; bins
                                                                       <0.125 <1 <2 <5 <10 <20 >=20 ms, never */
static int NoB, Busy, Ring[4], NRing, DNext, DFreed[NSLOTS], BusyData, Bg;
static uint32_t BgChanged, BgFrnum[2];
static int BgInject;
static volatile uint16_t BgSts[2];
static volatile int IaaSeen;
static const char *StageName, *Label[16];
static uint32_t OverrunChanged, FreedChanged;
static struct overrun { const char *where; int slot, during; uint32_t offset, old, now, count; } Overruns[16];
static const char *Phase;   /* bit 23: what runs while freed slots are checked (0: the transfer's active qTD) */
static uint32_t LbaW;
static uint16_t UhciIo[2], Io, PortReg;
static uint32_t EhciOp, EhciPort, Tag, ChecksumRef;
static int CardDev, UsbFn, UsbIrq, Ehci, Irq, IrqActive, ExceptionVector;
static int Addr, Mps0, EpIn, EpOut, MpsBulk, ToggleIn, ToggleOut, NTd, First[3], Last[3];
static volatile uint32_t Count[NCOUNTS];
static uint32_t CountPrinted[NCOUNTS];
static const char *const CountName[NCOUNTS] = { " irq0 ", " usb ", " spur ", " vec ", " stack ", " sum " };
static void *Recover[5];
static struct idtr SavedIdtr;
static uint8_t SavedMask[2], Mask[2];

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

/* The BIOS clock reads PIT channel 0: while it runs at 1 kHz for us, IRQ0 is the clock (in hlt). */
static uint32_t
now_ms(void)
{
    return IrqActive ? Count[C_IRQ0] : Api->ticks();
}

static void
delay_ms(uint32_t ms)
{
    if (!IrqActive)
        Api->mdelay(ms);
    for (uint32_t start = Count[C_IRQ0]; IrqActive && Count[C_IRQ0] - start <= ms;)
        __asm__ volatile("hlt");
}

static int
wait_bits(uint16_t port, uint16_t mask, uint16_t want)
{
    for (int ms = 0; ms < 20; ms++, delay_ms(1))
        if ((inw(port) & mask) == want)
            return 0;
    return -1;
}

static int
wait_ereg(uint32_t reg, uint32_t mask, uint32_t want)
{
    for (int ms = 0; ms < 20; ms++, delay_ms(1))
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
    uint32_t sts = Ehci ? *ereg(E_STS) & 0x3f : 0;
    IaaSeen |= sts & E_IAA;
    if (Ehci)
        *ereg(E_STS) = sts;
    else
        outw(Io + 2, inw(Io + 2) & 0x1f);
    for (int fn = 0; fn < 2; fn++)
        if (Bg >> fn & 1) {
            uint16_t bg = inw(UhciIo[fn] + 2) & 0x1f;
            BgSts[fn] |= bg;   /* for bg_check */
            outw(UhciIo[fn] + 2, bg);
        }
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
    Mask[0] = ~(1 | (UsbIrq < 8 ? 1 << UsbIrq : 4)), Mask[1] = UsbIrq < 8 ? 0xff : ~(1 << (UsbIrq - 8));
    outb(0x21, Mask[0]), outb(0xa1, Mask[1]);
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

static void
put_reg(const char *name, uint32_t v, int digits)
{
    put_str(name);
    put_hex(v, digits);
}

static void
put_pic(uint16_t cmd)
{
    outb(cmd, 0x0a);
    put_reg(" IRR ", inb(cmd), 2);
    outb(cmd, 0x0b);
    put_reg(" ISR ", inb(cmd), 2);
    put_reg(" IMR ", inb(cmd + 1), 2);
}

/* The interrupt state: counts, 8259s (and the 82C558M's shadows of what they were written, 80h-8Eh by 22h/24h),
   EFLAGS.IF, the controller, the 82C558M's PCI routing (40h-43h, 50h-53h). */
static void
irq_diag(void)
{
    uint32_t eflags;
    __asm__ volatile("pushfl; popl %0" : "=r"(eflags));
    put_str("usbdma: counts");
    for (int c = 0; c < NCOUNTS; c++) {
        put_str(CountName[c]);
        put_dec(Count[c]);
    }
    put_str("\r\nusbdma: 8259 master");
    put_pic(0x20);
    put_str(", slave");
    put_pic(0xa0);
    put_reg(", IF ", eflags >> 9 & 1, 1);
    put_str("\r\nusbdma: wrote ICW1 11/11 ICW2 20/28 ICW3 04/02 ICW4 01/01");
    put_reg(" OCW1 ", Mask[0], 2);
    put_reg("/", Mask[1], 2);
    put_str(", PIT 34 04a9; shadows 80h-8Eh");
    for (int i = 0x80; i < 0x8f; i++) {
        outb(0x22, i);
        put_reg(" ", inb(0x24), 2);
    }
    if (Ehci) {
        put_reg("\r\nusbdma: EHCI USBCMD ", *ereg(E_CMD), 8);
        put_reg(" USBSTS ", *ereg(E_STS), 8);
        put_reg(" USBINTR ", *ereg(E_INTR), 8);
        put_reg(" FRINDEX ", *ereg(0xc), 8);
        put_reg(" PORTSC ", *ereg(EhciPort), 8);
    } else {
        put_reg("\r\nusbdma: UHCI USBCMD ", inw(Io), 4);
        put_reg(" USBSTS ", inw(Io + 2), 4);
        put_reg(" USBINTR ", inw(Io + 4), 4);
        put_reg(" FRNUM ", inw(Io + 6), 4);
        put_reg(" PORTSC ", inw(PortReg), 4);
    }
    put_reg("\r\nusbdma: 82C558M 40h ", pci_read(1, 0, 0x40), 8);
    put_reg(" 50h ", pci_read(1, 0, 0x50), 8);
    put_str("\r\n");
}

/* Interrupts on, then 100 ms counted by polling PIT channel 0 (its reloads): IRQ0 must have come about 100 times,
   else there is no clock for the waits. */
static int
irq_start(void)
{
    irq_on();
    uint16_t last = 0;
    for (int reloads = 0; reloads < 100;) {
        outb(0x43, 0);
        uint16_t now = inb(0x40);
        now |= inb(0x40) << 8;
        reloads += now > last;
        last = now;
    }
    put_str("usbdma: 100 ms after the IDT/PIC setup\r\n");
    irq_diag();
    return Count[C_IRQ0] < 50 ? fail("IRQ0 not delivered, count", Count[C_IRQ0]) : 0;
}

/****************************************************************
 * Shared lines (arg bit 27)
 ****************************************************************/

static volatile struct td *
td_at(int i)
{
    return (volatile struct td *)(RAM_DMA + 0x2000 + i * (Shared ? 32 : 16));
}

/* What follows the transfer's QHs in the ring (bit 23): the first dummy (bit 20), else the head */
static uint32_t
after_qhs(void)
{
    return (NRing ? (uint32_t)DSLOT(Ring[0]) : (uint32_t)HEAD_QH) | 2;
}

static volatile struct qtd *
qtd_at(int i)
{
    if (Unlink)
        return (volatile struct qtd *)(SLOT(CurSlot) + 0xc0 + 32 * i);
    return (volatile struct qtd *)(RAM_DMA + 0x2000 + i * (Overrun ? 128 : 32));
}

/* A word unlike want, added to d; the first 4 printed. */
static void
note(const char *name, uint32_t addr, uint32_t got, uint32_t want, struct diff *d)
{
    if (!d->n)
        d->first = addr, d->xor = got ^ want;
    if (d->n++ < 4) {
        put_str("  ");
        put_str(name);
        put_str(" ");
        put_hex(addr, 8);
        put_str(" got ");
        put_hex(got, 8);
        put_str(" want ");
        put_hex(want, 8);
        put_str("\r\n");
    }
}

static void
guard_range(uint32_t addr, int dwords, int check)
{
    for (; dwords--; addr += 4)
        if (!check)
            *mmio(addr) = GuardValue;
        else if (*mmio(addr) != GuardValue)
            note("G", addr, *mmio(addr), GuardValue, &Guard);
}

/* Write the guards with a new counter value, or check them against the last one */
static void
guards(int check)
{
    if (!Shared)
        return;
    if (!check)
        GuardValue++;
    if (check && GuardInject)
        *mmio(Buf - 4) ^= 0x100, GuardInject = 0;
    guard_range(Buf - 4, 1, check);
    guard_range(Buf + Len, (32 - (Buf + Len) % 32) / 4, check);
    guard_range(CSW + 16, 4, check);
    for (int q = 0; Ehci && !Overrun && !Unlink && q < 3; q++)
        guard_range((uint32_t)EQH(q) + 48, 4, check);
    if (Ehci)
        return;
    guard_range((uint32_t)QH + 8, 6, check);
    for (int i = 0; i < NTd; i++)
        guard_range((uint32_t)td_at(i) + 16, 4, check);
}

/****************************************************************
 * qTD/QH overrun guards (arg bit 24, EHCI)
 ****************************************************************/

/* A changed guard: an overrun (slot -1) or a write into a freed slot; counted once per place */
static void
note_change(const char *where, int slot, uint32_t off, uint32_t old, uint32_t now)
{
    int i = 0;
    if (slot == -1)
        OverrunChanged++;
    else if (slot < 0)
        BgChanged++;
    else
        FreedChanged++;
    while (i < NOverruns && (Overruns[i].where != where || Overruns[i].slot != slot || Overruns[i].offset != off
                             || Overruns[i].during != CurSlot))
        i++;
    if (i == NOverruns && NOverruns < 16)
        Overruns[NOverruns++] = (struct overrun){ where, slot, CurSlot, off, old, now, 0 };
    if (i < 16)
        Overruns[i].count++;
}

static void
overrun_range(uint32_t base, uint32_t from, uint32_t to, const char *where, int check)
{
    for (uint32_t off = from; off < to; off += 4) {
        uint32_t old = 0x6a6a0000 | off, now = *mmio(base + off);
        if (!check)
            *mmio(base + off) = old;
        else if (now != old)
            note_change(where, -1, off, old, now);
    }
}

/* Set the guards after the QHs' 48 bytes and the qTDs' 32 bytes, or check them */
static void
overrun_guards(int check)
{
    static const char *const qh_names[3] = { "QH control", "QH bulk out", "QH bulk in" };
    if (!Overrun)
        return;
    if (check && OverrunInject)
        *mmio((uint32_t)qtd_at(0) + 0x40) ^= 0x10000, OverrunInject = 0;
    for (int q = 0; q < 3; q++)
        overrun_range((uint32_t)EQH(q), 48, 176, qh_names[q], check);
    for (int i = 0; i < NTd; i++)
        overrun_range((uint32_t)qtd_at(i), 32, 128, Label[i], check);
}

/* Freed memory: transfer slots 0-15 (512 bytes), dummy QHs 16-31 (64 bytes), each with its own guard pattern */
static uint32_t
slot_base(int slot)
{
    return slot < NSLOTS ? SLOT(slot) : (uint32_t)DSLOT(slot - NSLOTS);
}

static uint32_t
slot_pattern(int slot, uint32_t off)
{
    return (slot < NSLOTS ? 0xf4e00000 : 0xd4e00000) | (slot % NSLOTS) << 12 | off;
}

/* A freed slot (bit 23) filled with its guard pattern, or checked: a change is noted with what was running then
   (Phase, else the first active qTD of the transfer in CurSlot) */
static void
freed_slot(int slot, int check)
{
    for (uint32_t off = 0; off < (slot < NSLOTS ? 0x200u : 0x40u); off += 4) {
        uint32_t old = slot_pattern(slot, off), now = *mmio(slot_base(slot) + off);
        if (!check)
            *mmio(slot_base(slot) + off) = old;
        else if (now != old) {
            const char *where = Phase;
            for (int i = 0; !where && i < NTd; i++)
                if (qtd_at(i)->token & Q_ACTIVE)
                    where = Label[i];
            note_change(where ? where : "transfer done", slot, off, old, now);
            *mmio(slot_base(slot) + off) = old;   /* each write counted once */
        }
    }
}

static void
freed_check(void)
{
    for (int slot = 0; Unlink && slot < NSLOTS; slot++) {
        if (Freed[slot])
            freed_slot(slot, 1);
        if (DFreed[slot])
            freed_slot(NSLOTS + slot, 1);
    }
}

/* The changes since the last report, one line per place: overruns (slot -1, returned), background UHCIs (slot -2 -
   fn, *bg), freed slots (*freed) */
static uint32_t
overrun_report(uint32_t *freed, uint32_t *bg)
{
    uint32_t changed = OverrunChanged;
    *freed = FreedChanged, *bg = BgChanged;
    for (int i = 0; i < NOverruns; i++) {
        put_str(Overruns[i].slot == -1 ? "  O " : Overruns[i].slot < 0 ? "  U fn" : Overruns[i].slot < NSLOTS
                ? "  F slot " : "  F dummy ");
        if (Overruns[i].slot < -1) {
            put_dec(-2 - Overruns[i].slot);
            put_str(" ");
        }
        if (Overruns[i].slot < 0)
            put_str(Overruns[i].where);
        else
            put_dec(Overruns[i].slot % NSLOTS);
        put_str("+");
        put_hex(Overruns[i].offset, Overruns[i].offset > 0xff ? 4 : 2);
        put_str(" ");
        put_hex(Overruns[i].old, 8);
        put_str(" -> ");
        put_hex(Overruns[i].now, 8);
        put_str(" x");
        put_dec(Overruns[i].count);
        if (Overruns[i].slot >= 0) {
            put_str(" at ");
            put_str(Overruns[i].where);
            put_str(" of slot ");
            put_dec(Overruns[i].during);
        }
        put_str("\r\n");
    }
    NOverruns = OverrunChanged = FreedChanged = BgChanged = 0;
    return changed;
}

/****************************************************************
 * Transfers: UHCI TDs on one QH, or EHCI qTDs on three QHs; IOC on the last of each stage
 ****************************************************************/

static void
td_add(int pid, int ep, int toggle, uint32_t buf, int len, int ioc)
{
    volatile struct td *t = td_at(NTd);
    t->link = 1;
    t->status = 3u << 27 | TD_ACTIVE | ioc << 24;
    t->token = (uint32_t)((len - 1) & 0x7ff) << 21 | toggle << 19 | ep << 15 | Addr << 8 | pid;
    t->buffer = buf;
    if (NTd)
        td_at(NTd - 1)->link = (uint32_t)t | 4;   /* depth first */
    NTd++;
}

static void
qtd_add(int q, int pid, int toggle, uint32_t buf, uint32_t len, int ioc)
{
    volatile struct qtd *t = qtd_at(NTd);
    Label[NTd] = StageName;
    t->next = t->alt = 1;
    t->token = (uint32_t)toggle << 31 | len << 16 | (ioc ? Q_IOC : 0) | 3 << 10
               | (pid == PID_OUT ? 0 : pid == PID_IN ? 1 : 2) << 8 | Q_ACTIVE;
    for (int i = 0; i < 5; i++)
        t->buffer[i] = i ? (buf & ~0xfffu) + 0x1000 * i : buf;
    if (First[q] < 0)
        First[q] = NTd;
    else
        qtd_at(Last[q])->next = (uint32_t)t;
    Last[q] = NTd++;
}

static void
queue_reset(void)
{
    NTd = 0;
    for (int q = 0; q < 3; q++)
        First[q] = Last[q] = -1;
    if (Unlink)
        CurSlot = (CurSlot + 1) % NSLOTS, Freed[CurSlot] = 0;
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
    qh[0] = Unlink && q == 2 ? after_qhs() : (uint32_t)EQH((q + 1) % 3) | 2;
    qh[1] = (q ? 0 : (Unlink ? 0 : 1u << 15) | 1u << 14) | (uint32_t)(q ? MpsBulk : Mps0) << 16 | 2 << 12 | ep << 8 | Addr;
    qh[2] = 1u << 30;
    qh[3] = 0;
    qh[4] = First[q] < 0 ? 1 : (uint32_t)qtd_at(First[q]);
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

/****************************************************************
 * Background UHCIs (knob 0010FFEC, with bit 29): Linux's empty skeleton running beside the EHCI
 ****************************************************************/

#define BG_FRAMES(fn) (RAM_DMA + 0x6000 + 0x1000 * (fn))
#define BG_SKEL(fn)   (RAM_DMA + 0x8000 + 0x400 * (fn))   /* 11 QHs 16 bytes apart, then 8 TDs from 100h */

/* The value Linux 3.16 puts at off: frame list entries (0-FFFh) to the interrupt skeleton QHs by ffs(frame), QHs 2-8
   (int128-int2) linked to 9 (async, its link T), 10 the terminating QH linked to itself; 9 and 10 hold the
   inactive terminating TD (address 7Fh, IN), the interrupt QHs one inactive TD each */
static uint32_t
bg_value(int fn, uint32_t off)
{
    uint32_t skel = BG_SKEL(fn), td = skel + 0x100;
    if (off < 0x1000) {
        int frame = off / 4, skelnum = 8 - __builtin_ctz(frame | 1024);
        return (skel + 16 * (skelnum <= 1 ? 9 : skelnum)) | 2;
    }
    off -= 0x1000;
    if (off < 0x100) {
        int qh = off / 16, td_of_qh = qh >= 9 ? 0 : qh >= 2 ? qh - 1 : -1;
        if (off % 16 >= 8)
            return 0;
        if (off % 16 == 0)
            return qh >= 2 && qh <= 8 ? (skel + 16 * 9) | 2 : qh == 10 ? (skel + 16 * 10) | 2 : 1;
        return td_of_qh < 0 ? 1 : td + 16 * td_of_qh;
    }
    switch (off % 16) {
    case 0: return 1;
    case 8: return 0x7ffu << 21 | 0x7f << 8 | PID_IN;
    default: return 0;
    }
}

/* Write the skeleton, or check it: a changed dword is noted and restored */
static void
bg_skeleton(int fn, int check)
{
    for (uint32_t off = 0; off < 0x1000 + 0x180; off += 4) {
        uint32_t addr = off < 0x1000 ? BG_FRAMES(fn) + off : BG_SKEL(fn) + off - 0x1000, want = bg_value(fn, off);
        if (check && *mmio(addr) != want)
            note_change("mem", -2 - fn, off, want, *mmio(addr));
        if (!check || *mmio(addr) != want)
            *mmio(addr) = want;
    }
}

static void
bg_start(void)
{
    for (int fn = 0; fn < 2; fn++)
        if (Bg >> fn & 1) {
            uint16_t io = UhciIo[fn];
            bg_skeleton(fn, 0);
            outl(io + 8, BG_FRAMES(fn));
            outw(io + 6, 0);
            outb(io + 0xc, 0x40);
            outw(io + 4, Irq ? 0x0f : 0);
            outw(io + 2, 0x3f);
            outw(io, CMD_RS | CMD_CF | CMD_MAXP);
            BgFrnum[fn] = 0;
            put_str("usbdma: background UHCI function ");
            put_dec(fn);
            put_str(", IRQ ");
            put_dec(pci_read(CardDev, fn, 0x3c) & 0xff);
            put_str("\r\n");
        }
}

/* The skeleton unchanged, no HSE, process error or halt; after a transfer also the frame number advanced */
static void
bg_check(int after)
{
    for (int fn = 0; fn < 2; fn++)
        if (Bg >> fn & 1) {
            uint16_t io = UhciIo[fn], sts = inw(io + 2) | BgSts[fn], frnum = inw(io + 6) & 0x3ff;
            BgSts[fn] = 0;
            if (BgInject && after)
                *mmio(BG_FRAMES(fn) + 0x10) ^= 0x10000, BgInject = 0;
            bg_skeleton(fn, 1);
            if (sts & 0x38)
                note_change("USBSTS", -2 - fn, 0, 0, sts), outw(io + 2, sts & 0x18);
            if (after && frnum == BgFrnum[fn])
                note_change("FRNUM stuck", -2 - fn, 0, frnum, frnum);
            BgFrnum[fn] = after ? frnum : BgFrnum[fn];
        }
}

static void
idle(void)
{
    guards(0);
    freed_check();
    bg_check(0);
    if (Irq)
        __asm__ volatile("hlt");
}

static int
queue_start(void)
{
    guards(0);
    if (!Ehci)
        return QH[1] = (uint32_t)td_at(0), 0;
    for (int q = 0; q < 3; q++)
        ehci_qh_init(q);
    overrun_guards(0);
    if (!Unlink)
        return ehci_async(1);
    Phase = 0;
    HEAD_QH[0] = (uint32_t)EQH(0) | 2;   /* linked into the running schedule */
    return 0;
}

static uint16_t
pit_count(void)
{
    outb(0x43, 0);
    uint16_t count = inb(0x40);
    return count | inb(0x40) << 8;
}

static int
slot_intact(int slot)
{
    for (uint32_t off = 0; off < 0x200; off += 4)
        if (*mmio(SLOT(slot) + off) != slot_pattern(slot, off))
            return 0;
    return 1;
}

/* The freed slot watched for KnobWatch * 0.1 ms (PIT channel 0 polled): the 0.1 ms after IAA of its first change */
static void
watch_slot(uint32_t since_iaa_ms)
{
    uint32_t period = IrqActive ? 1193 : 65536, last = pit_count(), ticks = 0, next = 0;
    while (ticks < KnobWatch * 1193 / 10) {
        uint32_t now = pit_count();
        ticks += (last - now + period) % period, last = now;
        if (ticks < next)
            continue;
        next += 119;
        if (!slot_intact(CurSlot)) {
            uint32_t at = since_iaa_ms * 10 + ticks / 119;
            FirstStray = at < FirstStray ? at : FirstStray;
            return;
        }
    }
}

/* The doorbell, then IAA polled (or its interrupt) with its latency measured on PIT channel 0, no hlt */
static int
wait_iaa(int busy)
{
    struct iaa *st = &Iaa[busy];
    static const uint32_t bins[6] = { 149, 1193, 2386, 5966, 11932, 23864 };
    uint32_t period = IrqActive ? 1193 : 65536, last = pit_count(), ticks = 0;
    IaaSeen = 0;
    *ereg(E_CMD) |= E_IAAD;
    while (!IaaSeen) {
        uint32_t now = pit_count();
        ticks += (last - now + period) % period, last = now;
        if (*ereg(E_STS) & E_IAA)
            *ereg(E_STS) = E_IAA, IaaSeen = 1;
        else if (ticks > KnobIaaTimeout * 1193) {
            st->hist[7]++;
            return fail("no IAA, USBSTS", *ereg(E_STS));
        }
    }
    int bin = 0;
    while (bin < 6 && ticks >= bins[bin])
        bin++;
    st->hist[bin]++;
    st->min = !st->waits || ticks < st->min ? ticks : st->min;
    st->max = ticks > st->max ? ticks : st->max;
    st->sum += ticks, st->waits++;
    return 0;
}

static void
put_ms(const char *name, uint32_t ticks)
{
    uint32_t hundredths = ticks * 100 / 1193;
    put_str(name);
    put_dec(hundredths / 100);
    put_str(".");
    put_dec(hundredths / 10 % 10);
    put_dec(hundredths % 10);
}

static void
put_iaa_stats(int busy)
{
    static const char *const names[8] = { "; <0.125 ", ", <1 ", ", <2 ", ", <5 ", ", <10 ", ", <20 ", ", >=20 ",
                                          ", never " };
    const struct iaa *st = &Iaa[busy];
    put_str(busy ? "usbdma: IAA busy " : "usbdma: IAA ");
    put_dec(st->waits);
    put_str(" waits");
    if (st->waits) {
        put_ms(", min ", st->min);
        put_ms(" avg ", st->sum / st->waits);
        put_ms(" max ", st->max);
        put_str(" ms");
    }
    for (int i = 0; i < 8; i++) {
        put_str(names[i]);
        put_dec(st->hist[i]);
    }
    put_str("; over 10 ms ");
    put_dec(st->hist[5] + st->hist[6] + st->hist[7]);
    if (busy) {
        put_str("; data stage active at ");
        put_dec(BusyData);
    }
    put_str("\r\n");
}

/* Bit 20: empty dummy QHs in the ring after the transfer's QHs, as Linux's idle endpoints */
static void
dummy_init(int n)
{
    volatile uint32_t *qh = DSLOT(n);
    for (int i = 0; i < 12; i++)
        qh[i] = 0;
    qh[0] = (uint32_t)HEAD_QH | 2;
    qh[1] = 512u << 16 | 2 << 12 | 15 << 8 | Addr;
    qh[2] = 1u << 30;
    qh[4] = qh[5] = 1;
}

static int
in_ring(int n)
{
    for (int i = 0; i < NRing; i++)
        if (Ring[i] == n)
            return 1;
    return 0;
}

/* A fresh dummy at the end of the ring */
static void
dummy_relink(void)
{
    while (in_ring(DNext))
        DNext = (DNext + 1) % NSLOTS;
    int fresh = DNext;
    DNext = (DNext + 1) % NSLOTS;
    DFreed[fresh] = 0;
    dummy_init(fresh);
    if (NRing)
        DSLOT(Ring[NRing - 1])[0] = (uint32_t)DSLOT(fresh) | 2;
    else
        HEAD_QH[0] = (uint32_t)DSLOT(fresh) | 2;
    Ring[NRing++] = fresh;
}

/* During a READ/WRITE: once the CBW is out, the first dummy is unlinked (the bulk QH before it skips it), IAA
   awaited, the dummy poisoned at once */
static int
busy_unlink(void)
{
    for (uint32_t start = now_ms(); (qtd_at(0)->token & Q_ACTIVE) && now_ms() - start < 5;)
        ;
    int victim = Ring[0];
    BusyData += (qtd_at(1)->token & Q_ACTIVE) != 0;
    EQH(2)[0] = NRing > 1 ? (uint32_t)DSLOT(Ring[1]) | 2 : (uint32_t)HEAD_QH | 2;
    for (int i = 0; i + 1 < NRing; i++)
        Ring[i] = Ring[i + 1];
    NRing--;
    if (wait_iaa(1))
        return -1;
    freed_slot(NSLOTS + victim, 0);
    DFreed[victim] = 1;
    if (FreedInject)
        *mmio((uint32_t)DSLOT(victim) + 0x18) ^= 0x10000, FreedInject = 0;
    return 0;
}

/* Bit 23, as Linux: the transfer's QHs out of the running ring, the IAA doorbell, then the slot is free memory. The
   knobs (0010FFF0-0010FFFB): more doorbells, waiting for ASYNCLISTADDR off the slot, a delay before freeing. */
static int
ehci_unlink(void)
{
    HEAD_QH[0] = after_qhs();
    Phase = "unlink";
    for (uint32_t i = 0; i < KnobCycles; i++)
        if (wait_iaa(0))
            return -1;
    for (uint32_t start = now_ms(); KnobAsync && (*ereg(E_ASYNC) & ~0x1ffu) == SLOT(CurSlot);)
        if (now_ms() - start > 20)
            return fail("ASYNCLISTADDR stays on the freed QHs:", *ereg(E_ASYNC));
    delay_ms(KnobDelay);
    freed_slot(CurSlot, 0);
    Freed[CurSlot] = 1;
    if (FreedInject)
        *mmio(SLOT(CurSlot) + 0x18) ^= 0x10000, FreedInject = 0;
    Phase = "watch";
    watch_slot(KnobDelay);
    freed_check();
    Phase = "between transfers";
    return 0;
}

static int
uhci_wait(uint32_t timeout_ms)
{
    uint32_t start = now_ms(), element;
    while (!((element = QH[1]) & 1)) {
        uint32_t status = ((volatile struct td *)(element & ~0xfu))->status;
        if (!(status & TD_ACTIVE) && (status & TD_ERRORS))
            return QH[1] = 1, fail("TD error, status", status);
        if (now_ms() - start > timeout_ms)
            return QH[1] = 1, fail("timeout at TD", element), fail("its status", status);
        idle();
    }
    for (int i = 0; i < NTd; i++)
        if ((td_at(i)->status ^ td_at(i)->token >> 21) & 0x7ff)
            return fail("short packet, status", td_at(i)->status);
    return 0;
}

static int
ehci_wait(uint32_t timeout_ms)
{
    uint32_t start = now_ms();
    for (int i = 0; i < NTd;) {
        uint32_t token = qtd_at(i)->token;
        if (token & Q_HALTED)
            return fail("qTD error, token", token);
        if (!(token & Q_ACTIVE) && (token >> 16 & 0x7fff))
            return fail("short packet, token", token);
        if (!(token & Q_ACTIVE))
            i++;
        else if (now_ms() - start > timeout_ms)
            return fail("timeout at qTD", (uint32_t)qtd_at(i)), fail("its token", token);
        else
            idle();
    }
    return 0;
}

/* The queue to its end; then every descriptor moved its full length. */
static int
queue_wait(uint32_t timeout_ms)
{
    int r = Ehci ? ehci_wait(timeout_ms) : uhci_wait(timeout_ms);
    if (r && Irq)
        irq_diag();
    if (!r)
        guards(1);
    if (!Ehci)
        return r;
    bg_check(1);
    if (Unlink) {
        ToggleOut = EQH(1)[6] >> 31, ToggleIn = EQH(2)[6] >> 31;
        if (ehci_unlink())
            return -1;
        if (Busy && NRing < 4)
            dummy_relink();
        return r;
    }
    int stopped = ehci_async(0);
    overrun_guards(1);
    if (stopped)
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
    StageName = "qTD setup";
    stage(PID_SETUP, 0, &toggle, SETUP, 8);
    toggle = 1;
    StageName = "qTD control data";
    if (len)
        stage(in ? PID_IN : PID_OUT, 0, &toggle, CTL, len);
    toggle = 1;
    StageName = "qTD status";
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
    c[12] = cdb[0] == 0x2a ? 0 : 0x80, c[14] = cdb_len;
    for (int i = 0; i < cdb_len; i++)
        c[15 + i] = cdb[i];
    queue_reset();
    StageName = "qTD CBW out";
    stage(PID_OUT, EpOut, &ToggleOut, CBW, 31);
    StageName = c[12] ? "qTD data in" : "qTD data out";
    if (len && !c[12])
        stage(PID_OUT, EpOut, &ToggleOut, buf, len);
    else if (len)
        stage(PID_IN, EpIn, &ToggleIn, buf, len);
    StageName = "qTD CSW in";
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
                Legsup[fn] = pci_read(dev, fn, 0xc0) & 0xffff;
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
            put_str(", UHCI C0h ");
            put_hex(Legsup[0], 4);
            put_str(" ");
            put_hex(Legsup[1], 4);
            put_str("\r\n");
            return 0;
        }
    return fail("no VT6212 EHCI", VT6212_EHCI);
}

/* UHCI LEGSUP (C0h): 2000h, the PIRQ enable alone, as Linux sets it */
static void
legsup_write(int fn, uint32_t v)
{
    pci_write(CardDev, fn, 0xc0, (pci_read(CardDev, fn, 0xc0) & 0xffff0000u) | v);
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
    delay_ms(50);
    outw(PortReg, 0);
    delay_ms(1);
    outw(PortReg, PORT_PE | PORT_CSC | PORT_PEC);
    delay_ms(10);
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
    *ereg(E_INTR) = Irq ? (Unlink ? 0x23 : 3) : 0;
    for (int i = 0; i < 12; i++)
        HEAD_QH[i] = 0;
    HEAD_QH[0] = (uint32_t)HEAD_QH | 2;
    HEAD_QH[1] = 1u << 15 | 2 << 12;   /* H, high speed, no qTD: the reclamation head */
    HEAD_QH[4] = HEAD_QH[5] = 1;
    HEAD_QH[6] = Q_HALTED;
    for (NRing = 0; Busy && NRing < 4;)
        dummy_relink();
    *ereg(E_ASYNC) = Unlink ? (uint32_t)HEAD_QH : (uint32_t)EQH(0);
    *ereg(E_CMD) = 8 << 16 | E_RS;
    if (wait_ereg(E_STS, E_HALTED, 0) || (Unlink && ehci_async(1)))
        return -1;
    *ereg(E_CONFIGFLAG) = 1;
    for (int p = 0; p < 4; p++)
        *ereg(E_PORTSC + 4 * p) = EP_PP;
    delay_ms(100);
    if (!pick_ehci_port(2 * STICK_FN + STICK_PORT) && !pick_ehci_port(0) && !pick_ehci_port(1)
        && !pick_ehci_port(2) && !pick_ehci_port(3))
        return fail("no device on the EHCI ports", 0);
    *ereg(EhciPort) = EP_PP | EP_PR;
    delay_ms(50);
    *ereg(EhciPort) = EP_PP;
    if (wait_ereg(EhciPort, EP_PR, 0))
        return -1;
    delay_ms(10);
    if (!(*ereg(EhciPort) & EP_PE))
        return fail("not high speed, PORTSC", *ereg(EhciPort));
    return 0;
}

static int
setup_controllers(void)
{
    for (int fn = 0; fn < 2; fn++) {
        uhci_stop(UhciIo[fn]);
        legsup_write(fn, 0x2000);
        outw(UhciIo[fn], CMD_HCRESET);
        if (wait_bits(UhciIo[fn], CMD_HCRESET, 0))
            return fail("UHCI reset, io", UhciIo[fn]);
    }
    *ereg(E_INTR) = 0;
    *ereg(E_CMD) &= ~E_RS;
    if (wait_ereg(E_STS, E_HALTED, E_HALTED))
        return -1;
    *ereg(E_CONFIGFLAG) = 0;
    delay_ms(100);
    if (Ehci ? ehci_setup() : uhci_setup())
        return -1;
    bg_start();
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
    delay_ms(10);
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
        delay_ms(100);
    }
}

static void
teardown(void)
{
    QH[1] = 1;
    for (int fn = 0; fn < 2; fn++) {
        uhci_stop(UhciIo[fn]);
        legsup_write(fn, Legsup[fn]);
    }
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

/* Words of [lo, hi) unlike ref (0: the fill pattern of seed), added to d */
static void
compare(const char *name, uint32_t lo, uint32_t hi, uint32_t ref, uint32_t seed, struct diff *d)
{
    for (volatile uint32_t *p = mmio(lo); (uint32_t)p < hi; p++) {
        uint32_t want = ref ? *mmio(ref + ((uint32_t)p - lo)) : (uint32_t)p ^ seed, got = *p;
        if (got != want)
            note(name, (uint32_t)p, got, want, d);
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

static int
in_b(uint32_t addr)
{
    addr &= ~(CHUNK - 1);
    return addr != RamA && addr != Dma && addr != Ref;
}

static void
fill_b(uint32_t seed)
{
    for (uint32_t c = FREE_LO; !NoB && c < FREE_HI; c += CHUNK)
        if (in_b(c))
            fill(c, c + CHUNK, seed), guards(0), freed_check(), bg_check(0);
}

static void
compare_b(uint32_t seed, struct diff *d)
{
    for (uint32_t c = FREE_LO; !NoB && c < FREE_HI; c += CHUNK)
        if (in_b(c))
            compare("B", c, c + CHUNK, 0, seed, d), guards(0), freed_check(), bg_check(0);
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
    uint32_t errors = 0;
    for (int c = 0; c < NCOUNTS; c++) {
        uint32_t now = Count[c], n = now - CountPrinted[c];
        CountPrinted[c] = now;
        put_str(CountName[c]);
        put_dec(n);
        if (c >= C_VEC)
            errors += n;
    }
    return errors;
}

/* One READ(10) (or WRITE(10)) of Len bytes at Buf, B filled and checked meanwhile (with the self-test's faults) */
static int
transfer(int write, uint32_t lba, int fault, struct diff *b, uint32_t seed)
{
    uint8_t cdb[10] = { write ? 0x2a : 0x28, 0, lba >> 24, lba >> 16 & 255, lba >> 8 & 255, lba & 255, 0, 0,
                        Len / 512, 0 };
    int status = scsi_start(cdb, 10, Buf, Len) || (Busy && NRing && busy_unlink()) ? -1 : 0;
    fill_b(seed);
    uint32_t bad = 0x463450;
    while (!in_b(bad))
        bad += CHUNK;
    if (fault && !NoB)
        *mmio(bad) ^= 0x10000;
    if (fault && Irq)
        checksum_fault();
    compare_b(seed, b);
    return status ? status : scsi_wait();
}

static uint32_t
run_test(uint32_t iterations, int inject, int slots)
{
    static const uint32_t seeds[4] = { 0, 0xffffffff, 0xa5a5a5a5, 0x5a5a5a5a };
    uint32_t errors = 0, ref = 0;
    struct diff a, b, w;
    if (Irq) {
        put_str("usbdma: setup");
        errors += put_counts();
        put_str("\r\n");
    }
    for (uint32_t it = 0; it < iterations; it++) {
        if (slots)
            RamA = FREE_LO + ((Base - FREE_LO) / CHUNK + 6 * (it % 16)) % NCHUNKS * CHUNK;   /* never the schedule */
        uint32_t off = Shared ? 0x24 : 0, a_buf = RamA + off, pattern = 0xdeadbeef ^ it * 0x9e3779b9u;
        Buf = a_buf;
        a.n = b.n = w.n = 0;
        GuardInject = OverrunInject = FreedInject = BgInject = inject && it == 1;
        fill(RamA, RamA + READ_LEN, pattern);   /* a read must replace it; a write sends it, Modified in L1 */
        if (Wbinvd)
            __asm__ volatile("wbinvd" : : : "memory");
        int status = transfer(Write, Write ? LbaW : LBA, inject && it == 1, &b, seeds[it & 3]);
        if (Write && !status) {
            Buf = Ref + off;
            fill(Ref, Ref + CHUNK, ~pattern);
            status = transfer(0, LbaW, 0, &b, seeds[it & 3]);
        }
        if (status) {
            put_str("it ");
            put_dec(it + 1);
            put_str(status < 0 ? " USB transport failure\r\n" : " READ(10)/WRITE(10) failed\r\n");
            return errors + 1;
        }
        if (inject && it == 1)
            bytes((Buf & ~(CHUNK - 1)) + 0x1234)[0] ^= 0x40;
        uint32_t crc = crc32(Buf, Len);
        if (Write) {
            compare("A", a_buf, a_buf + Len, 0, pattern, &a);
            compare("W", Buf, Buf + Len, a_buf, 0, &w);
            w.first -= Buf;
        } else if (!it) {
            ref = crc;
            for (uint32_t i = 0; i < Len; i += 4)
                *mmio(Ref + i) = *mmio(Buf + i);
        }
        if (!Write)
            compare("A", Buf, Buf + Len, Ref, 0, &a);
        int bad = Write ? a.n || w.n : crc != ref;
        uint32_t freed, bg, overruns = overrun_report(&freed, &bg);   /* the first one has those of the setup */
        errors += a.n + b.n + w.n + (!Write && !a.n && bad) + Guard.n + overruns + freed + bg;
        put_str("it ");
        put_dec(it + 1);
        put_str(" crc ");
        put_hex(crc, 8);
        put_str(bad ? " BAD" : " OK");
        put_diff(" A ", &a);
        put_diff(" B ", &b);
        if (Write)
            put_diff(" W ", &w);
        if (Shared)
            put_diff(" G ", &Guard), Guard.n = 0;   /* the first one has those of the setup */
        if (Overrun) {
            put_str(" O ");
            put_dec(overruns);
        }
        if (Bg) {
            put_str(" U ");
            put_dec(bg);
        }
        if (Unlink) {
            put_str(" F ");
            put_dec(freed);
            if (freed && FirstStray == ~0u)
                put_str(" late");
            else if (freed) {
                put_str(" +");
                put_dec(FirstStray / 10);
                put_str(".");
                put_dec(FirstStray % 10);
                put_str(" ms");
            }
            FirstStray = ~0u;
        }
        if (slots) {
            put_str(" slot ");
            put_hex(RamA, 8);
        }
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
    if ((uint32_t)usbdma < 0x100000 || (uint32_t)usbdma + 0x10000 > FREE_LO)
        return fail("load at 00100000, not", (uint32_t)usbdma), ~0u;
    Irq = arg >> 30 & 1, Ehci = arg >> 29 & 1, Shared = arg >> 27 & 1, Write = arg >> 26 & 1, Wbinvd = arg >> 25 & 1;
    Unlink = Ehci && arg >> 23 & 1, Overrun = Ehci && !Unlink && arg >> 24 & 1;
    NOverruns = OverrunChanged = FreedChanged = CurSlot = 0;
    for (int slot = 0; slot < NSLOTS; slot++)
        Freed[slot] = 0;
    NoB = arg >> 22 & 1, Busy = Unlink && arg >> 20 & 1;
    LbaW = 0x37800 + (arg >> 16 & 15) * 0x80;
    Base = RamA = arg & 0xf0000 && !Write ? (arg >> 16 & 15) * 0x80000 : 0x120000;
    Iaa[0] = Iaa[1] = (struct iaa){ 0 };
    NRing = DNext = BusyData = 0;
    for (int slot = 0; slot < NSLOTS; slot++)
        DFreed[slot] = 0;
    Dma = Base + CHUNK, Ref = Base + 2 * CHUNK;
    Buf = RamA + (Shared ? 0x24 : 0), Len = READ_LEN - (Shared ? 512 : 0);
    if (Base < FREE_LO || Ref + CHUNK > FREE_HI)
        return fail("A base not in 00110000-00740000:", Base), ~0u;
    put_str("usbdma: A ");
    put_hex(Base, 8);
    put_str(arg >> 28 & 1 ? " (16 slots)" : "");
    put_str(Shared ? " + 24h, 127 blocks, shared lines" : "");
    if (Write) {
        put_str(", write+readback at LBA ");
        put_hex(LbaW, 8);
        put_str(Wbinvd ? " (wbinvd after the fill)" : "");
    }
    put_str(Overrun ? ", qTD/QH overrun guards" : "");
    FirstStray = ~0u;
    KnobDelay = *mmio(0x10fff0), KnobCycles = *mmio(0x10fff4), KnobAsync = *mmio(0x10fff8), KnobWatch = *mmio(0x10fffc);
    KnobWatch = KnobWatch > 10000 ? 100 : KnobWatch;
    Bg = Ehci ? *mmio(0x10ffec) & 3 : 0, BgChanged = 0;
    KnobIaaTimeout = *mmio(0x10ffe8), KnobIaaTimeout = KnobIaaTimeout - 1 >= 1000 ? 20 : KnobIaaTimeout;
    KnobDelay = KnobDelay > 1000 ? 1000 : KnobDelay, KnobCycles = KnobCycles - 1 > 15 ? 1 : KnobCycles;
    if (Unlink) {
        put_str(Busy ? ", Linux-style unlink, also while busy: IAA x" : ", Linux-style unlink: IAA x");
        put_dec(KnobCycles);
        put_str(KnobAsync ? ", ASYNCLISTADDR off the slot" : "");
        put_str(", then ");
        put_dec(KnobDelay);
        put_str(" ms, watch ");
        put_dec(KnobWatch);
        put_str(" x0.1 ms, IAA timeout ");
        put_dec(KnobIaaTimeout);
        put_str(" ms");
    }
    put_str(", schedule ");
    put_hex(Dma, 8);
    put_str(", first read ");
    put_hex(Ref, 8);
    put_str(NoB ? ", no B\r\n" : ", B the rest of 00110000-0076ffff\r\n");
    for (int c = 0; c < NCOUNTS; c++)
        Count[c] = CountPrinted[c] = 0;
    Guard.n = 0;
    if (find_card())
        return ~0u;
    uint32_t errors = ~0u;
    if (__builtin_setjmp(Recover))
        errors = 0xe0000000u | ExceptionVector;
    else if (!setup_controllers() && (!Irq || !irq_start())) {
        errors = setup_stick() ? ~0u : run_test(arg & 0xffff, arg >> 31, arg >> 28 & 1);
        if (Unlink)
            Phase = "end", delay_ms(5), freed_check();   /* late writes into the freed slots */
    }
    irq_off();
    teardown();
    uint32_t freed, bg, overruns = overrun_report(&freed, &bg);   /* those of a failed transfer, and late ones */
    if (errors != ~0u)
        errors += overruns + freed + bg;
    if (Unlink)
        put_iaa_stats(0);
    if (Busy)
        put_iaa_stats(1);
    put_str("usbdma: errors ");
    put_dec(errors);
    put_str("\r\n");
    return errors;
}
