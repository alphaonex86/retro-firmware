# IBM Aptiva A90 (machine type 2168, Type I-2 system board)

The second board of this repository. Status: emulated in the 86Box fork with the original IBM BIOS; the coreboot and
SeaBIOS port is at step 6 of its plan (below; the bring-up ROM is ready for the board, `BRINGUP.md`): our ROM, with SeaBIOS's board code, boots DOS and Linux in the
emulator, from USB without a PS/2 keyboard as the operator's board needs. The board's photos, IBM manuals, datasheets, the BIOS analysis and the
port plan are in the Aptiva project (`/mnt/data/perso/retro/Aptiva A90/docs`, `docs/bios-extract/README.md`,
`docs/port/PORT_PLAN.md`).

## Hardware

| Part | Real board | 86Box fork (`86box` submodule) |
|---|---|---|
| Chipset | OPTi Viper-M 82C556M/557M/558M, MIDE IDE | `opti55x` (upstream 86Box) |
| DRAM | 4 x 72-pin SIMM in two pairs, J23/J24 (RAS0#/RAS1#, inferred) and J27/J28 (RAS2#/RAS3#) | flat RAM; with a pair set in `[OPTi 82C55x (Viper)]` `pair0`/`pair1`, the 82C557M decode (13h/14h/19h, MA map, aliases, absent banks, `stuck_addr`/`stuck_bit`) |
| CPU | Pentium P54C 166 (66 MHz x 2.5), Socket 7; P54C 75-166 on 50/60/66 MHz | `pentium_p54c`; P5 DIV/IDIV r32 41/46 clocks; with a SIMM pair set, its L1 data cache as RAM (CR0.CD/NW, `src/cpu/cache_l1.c`: 8 KB 2-way 32-byte lines, LRU, KEN# and WB/WT# from the 82C557M) |
| Bus-speed jumper JP2 | on the FDC37C933 GPIO GP21/GP20, read at EAh (index 2) / EBh: 00 66, 10 60, 11 50 MHz | Super I/O GPIO input, follows the configured bus |
| Video | Trident TGUI9680XGi on board, PCI 00:02.0, 1 MB, VGA BIOS inside the system BIOS | `tgui9680_onboard_pci`, PCI class VGA (030000, the class in its BIOS's PCI data) |
| PCI slots | riser, devices 07h/0Bh/0Ch; INTA: 0Bh -> PIRQ0, 07h/0Ch -> PIRQ1 (as the IBM BIOS routes) | same |
| Super I/O | SMC FDC37C933 at 370h | FDC37C93x (ID 02h), 256-byte RTC |
| Flash | MX28F1000 128 KiB, IBM BIOS BG2US0J 03/06/96 | AMD 28F010 model; `BOX86_FLASH=tn28f010`: Intel TN28F010 |
| Sound/modem | Mwave "Dolphin" ISA card | Sound Blaster Pro 2 (Mwave not emulated) |

## Try it, test it

- `boards/aptiva2168/run_86box.sh [rom]`: the A90 with the IBM BIOS (`boards/aptiva2168/BIOSORIGINAL.bin`, a
  symlink to the dump, not in git), or ours (`out/aptiva2168.rom`).
- `boards/aptiva2168/test/boot.sh` (also in `test/run_all.sh`): from an empty CMOS, each P54C setting gives exactly
  its POST errors (161/163 from a new CMOS; 127 where the IBM CPU speed check rejects the CPU: P75, P90, P100).
- `boards/aptiva2168/test/flashlinux.sh`: the BIOS update from Linux below, on the emulated TN28F010.
- `boards/aptiva2168/test/skeleton.sh`: our ROM sends exactly the POST codes of the skeleton below, up to 30h, and 30h
  on COM1, on the DRAM model: its CAR self-test holds only in the L1 model.
- `boards/aptiva2168/test/car.sh`: the probe ROM `car.asm` checks the L1 model: CAR with CD/NW, a write outside the CAR
  lines lost, more than 8 KiB evicting the least recently used way, code fetches apart, INVD losing Modified lines,
  WBINVD writing them back, no fill outside KEN#; on flat RAM (no model) it must fail.
- `boards/aptiva2168/test/ramoracle.sh`: the IBM BIOS on the 14 SIMM configurations of `test/simm_configs.txt` (the
  DRAM model): the memory its Setup shows and its 13h/14h/19h, the oracle for our raminit. SIMMs it cannot size: 2 x 32 MB 8Mx32 (MA11 is RAS4#)
  gives 32 MB; 2 x 16 MB double-sided (2Mx32 sides) hangs its memory test at 16 MB (POST A7, an alias overwrites low
  memory; inferred for the real board).
- `boards/aptiva2168/test/ram.sh`: our ROM on the same configurations: the memory SeaBIOS counts and 13h/14h/19h are
  the IBM BIOS's, or the line's `ours=` where the IBM BIOS fails; the warning POST codes below where expected.
- `boards/aptiva2168/test/dramfuzz.sh`: native, no emulator: `raminit.c` against a C port of the DRAM model
  (`test/native/`), all 1089 pairs of SIMM geometries (empty or 9-12 row/column bits, 1-2 sides), each also with a
  floating bus and a faulty bit at every dword the sizing reads and at random addresses (1.36 million cases, about
  12 s on 16 cores): the best top the chipset can address, one-to-one decode, same registers with a faulty bit,
  no access to the cache-as-RAM lines, the POST codes; then `simm_configs.txt`.
- `boards/aptiva2168/test/dramprobe.sh`: native, `tools/dramprobe.c` (the Linux probe of J27/J28 on the real board:
  bank placement per code, the IBM count, our probe, aliasing address lines and failing data bits per SIMM, a full
  test; only 14h, interrupts off) on the DRAM model: the operator's SIMMs, then a faulty bit.
- `boards/aptiva2168/test/post.sh`: our ROM to SeaBIOS's text screen (Trident VGA BIOS from CBFS, POST memory test,
  summary, boot attempts), then the same POST codes after Ctrl+Alt+Del.
- Step 5, SeaBIOS's board code: `cpu.sh` (each P54C setting: name, TSC clock, JP2 bus and multiplier), `shadow.sh` (an
  ISA ROM at D8000 stays on the bus or is shadowed, C0000/E/F read-only after POST), `superio.sh` (IBM's COM/LPT
  defaults, LPT 3BCh found, MIDE PIO timings, INTEGRATED PERIPHERALS), `chipset.sh` (CHIPSET FEATURES reach the
  82C557M, Auto = the IBM BIOS's timing, fallback after unfinished POSTs, PCI IRQ, CHIPSET REGISTERS), `setup.sh`,
  `usbreset.sh` (a CPU-only reset with the VT6212 bus mastering), `dos.sh`, `cmosfuzz.sh` (native: `newbios.c` and the
  PIRQ routing), `genericbuild.sh` (MB-8433 and Aptiva code apart). The MB-8433 tests that hold for this board run on
  it through a wrapper (`vm_machine=aptiva2168`): `errors`, `deadcmos`, `floppy`, `bigdisk`, `hddtype`, `nokbd` (no
  PS/2 keyboard: the operator's case), `usbkbd`, `usbboot`, `usbfault`, `usblilo`, `pxe`, `nicrom`, `warmboot`,
  `kbdpower`, `cmoslayout`. Not `flashtime`: no flash writes on this board (PORT_PLAN D5).
- `bringup.sh` (step 6): the bring-up ROM's COM1 log in order (bootblock, CAR self-test, romstage, DRAM bank codes and
  size, postcar, ramstage, SeaBIOS's log, its screen) on 2 SIMM configurations, the operator's 24 MB with a USB
  keyboard and the RTL8139 socket ROM.
- Tests start an A90 with `vm_machine=aptiva2168 vm_start` (`test/lib.sh`, SIMMs by `opti_ram_cfg`);
  `BOX86_USB`/`BOX86_USB_KBD`/`BOX86_USB_DISK` add the VIA USB card as on the MB-8433.

## Our firmware (port step 5: SeaBIOS board code)

`./build.sh aptiva2168` -> `out/aptiva2168.rom` (128 KiB; `boards/aptiva2168/firmware.sh`). It needs the board's
Trident VGA BIOS X5.3B as `boards/aptiva2168/vgabios.bin` (a link to the Aptiva project's
`docs/bios-extract/trident_tgui9680_vgabios_X5.3B_1996-02-29.bin`; IBM's, never in git, sha256 checked), stored as
CBFS `pci1023,9660.rom.lzma` (SeaBIOS decompresses a file by that suffix). The build fails when something does not fit
and prints the free bytes (12,292 at step 4, 9,732 at step 5).
It also builds `out/aptiva2168-bringup.rom` for the first runs on the board (step 6, `BRINGUP.md`): coreboot's console
(INFO) and SeaBIOS's level 3 log on COM1, without the setup's diagnostic tools (292 bytes free).

coreboot (`coreboot-486`: mainboard `ibm/aptiva2168`, northbridge `opti/viperm`, southbridge `opti/82c558m`, the
FDC37C93x in `smscsuperio`):
- bootblock: the whole flash at E0000 (romstage runs there) and at 4 GiB (ROMCS# 4Ah/4Bh), E/F shadow off (a CPU-only
  reset keeps it), PCI bus mastering off on bus 0 before cache-as-RAM (a CPU-only reset, such as a Linux panic, leaves
  the VT6212 walking its schedules), cache-as-RAM, the FDC37C93x CR24 = C4h (IBM: IRQ8 active low, 16-bit decode),
  its keyboard controller, its RTC (off at reset; romstage reads the CMOS) and COM1.
- romstage: the IBM BIOS's 82C557M/82C558M register values without L2, DRAM timing and ATCLK by the JP2 bus clock
  (FDC37C93x GP21-GP20: 66/60 MHz 01h = DDh, 50 MHz or unknown FEh), refresh (PIT 1), DRAM sizing (`raminit.c`: each
  SIMM side probed for its row and column lines at bank code 5 with MA11 as RAS4#, as the IBM BIOS (code 7 with MA11
  sized the real board's 1Mx32 pair as 2 + 2 MB; `dramfuzz` refuses code 6/7 and 19h bit 3 = 0), then the largest
  code it fills: the IBM BIOS's codes; 3 votes per probe against a faulty bit; never the cache-as-RAM lines), then the IBM
  memory count (a dword per 64 KiB; the DRAM ends at the MiB below a failing block), then the CHIPSET FEATURES values
  (`newbios.c`, `NB_VIPERM_FIELDS`) unless Auto, an invalid CMOS or 2 unfinished POSTs.
- postcar: C0000-FFFFF shadow RAM read/write, C0000/F0000 cacheable, no flash below 1 MiB.
- ramstage: L1 write-back from its first step (write-through if CHIPSET FEATURES says so), PCI, PIRQ0-3# to
  IRQ10/11/10/11 level (IBM: 0Bh INTA PIRQ0#, 07h/0Ch INTA PIRQ1#; INTB-D by the IBM BIOS's swizzle, `$PIR`; a PCI IRQ
  set in setup kept if the 82C558M routes it), MIDE legacy mode, the FDC37C93x logical devices as the IBM BIOS sets
  them (LPT 3BCh, LD8 GPIO steering of IRQ14/15).

SeaBIOS (`NEWBIOS_BOARD_APTIVA2168`, chipset `NEWBIOS_CHIPSET_OPTI_VIPERM`, the cuts of `seabios.config`): BIOS name
aptiva2168; Pentium names and the core clock by the TSC (the rating within 2%), the bus by JP2; shadow RAM per segment
(82C557M 04h-06h): C8000-DFFFF blocks on the ISA bus unless an option ROM or "Shadow" in setup uses them, every
segment read from DRAM read-only after POST; the FDC37C93x ports and the MIDE channels from INTEGRATED PERIPHERALS
(defaults: IBM's), LPT 3BCh probed first; MIDE PIO timings from the drives' modes (40h the slowest up to mode 3, 43h
PIO 4 per drive); CHIPSET FEATURES (DRAM timing, posted write, pipelining, slow refresh, BIOS caching, L1 write-back,
PCI pre-snoop, HITM# one CLK later), CHIPSET
REGISTERS, the SIMM pairs on the CPU page; no L2 pages, no ESCD.

| SIMMs (simm_configs.txt) | IBM BIOS | ours |
|---|---|---|
| 2 x 16 MB double-sided 2Mx32 sides (`8 0`) | one 32 MB bank (05h), aliases, hangs at POST A7h | two 16 MB banks (CCh), 32 MB |
| 2 x 32 MB single-sided 8Mx32 (`10 0`) | 32 MB of 64 (MA11 is RAS4#) | the same (the probe does not see MA11) |
| a faulty bit at 7F0000h (`4 0`) | its memory count: 7168 KB | the same, and POST 34h |

POST codes (port 80h; the C ones after the bootblock has enabled COM1, i.e. 30h, also on COM1 at 115200 8N1):

| Code | Step that starts |
|---|---|
| `01` `03` `04` `10` | reset vector, IDT/GDT, protected mode, 32-bit code |
| `21` `22` `23` | cache-as-RAM: bank 0 = 2 MB, A20, L1 on, reading 1A0000h-1A1FFFh into it, CD = NW = 1 |
| `26` | DRAM decode off (82C557M 13h = 88h): the range now exists only in L1 |
| `29` / `2A` | CAR self-test (each dword its address, then the complement) passed / **failed: halted** |
| `27` `28` | cache-as-RAM zeroed, stack in it |
| `14` `15` | bootblock C code, BIST passed |
| `16` `17` `18` | northbridge (E/F shadow off), 82C558M (ROMCS#), CPU |
| `19` | romstage looked up in CBFS; then the FDC37C93x keyboard controller and COM1 are enabled |
| `30` | romstage: 82C557M/82C558M registers, bus clock |
| `32` | DRAM sizing and memory count |
| `33` | warning: a SIMM holds more than the 82C557M addresses, the rest is unused |
| `34` | warning: a 64 KiB block failed the memory count, the DRAM ends at the MiB below it |
| `3E` | **no usable DRAM (2 MiB at least): halted** |
| `3C` `3D` | postcar, cache-as-RAM left |
| `38` | shadow RAM C0000-FFFFF; then ramstage (coreboot's codes) and SeaBIOS (`B0`-`BD`) |

## Flashing from Linux

As root under Linux on the A90: `bios-update IMAGE aptiva2168` (`tools/bios-update.sh`; IMAGE: 128 KiB, anything else
is refused). It runs our flashrom (submodule `flashrom`, built for the test Linux by `tools/build_flashrom.sh`), which
- enables flash writes as IBM's flasher (ODYFLASH) does: 82C558M 47h bit 7 (ROMCS# on writes), plus 4Bh bits 5-4 so
  that the whole chip is decoded at 4 GB where flashrom maps it (the IBM BIOS decodes only its top 64 KB there),
  restored on exit; it refuses if the BIOS runs from the chip instead of shadow RAM (82C557M index 06h) or if 53h bit 1
  locks the flash;
- finds the 28F010 by its ID (Intel 89h/B4h, AMD Am28F010 01h/A7h) and writes it with the datasheet's algorithms:
  every byte programmed to 00h, bulk erase (20h 20h, 10 ms pulses, A0h verify, up to 3000 pulses), then each byte
  programmed (40h, data, C0h verify, up to 25 pulses), and verifies the whole chip.

The board has no DMI table and the Viper-M is also a notebook chipset, so `bios-update` tells flashrom it is not a
laptop (`-p internal:laptop=this_is_not_a_laptop`, also needed for a plain `flashrom -r`).

VPP: the 28F010 needs 12 V on pin 1 for every command, even its ID. No software switches it: it comes from JP9
("system board flash jumper", normal 1-2), inferred to give 12 V permanently at 1-2 (not measured on the board yet).
Without it the chip is a ROM: flashrom finds no chip and writes nothing; a program or erase that never verifies stops
with "no VPP (12 V)?". The test checks the first case in 86Box (`BOX86_FLASH_VPP=5`: no chip found, flash
unchanged); the second one cannot happen in the model.

On the operator's board the IBM BIOS stops at its keyboard error, so this is for when our firmware runs from the
TN28F010.

There is no boot-block recovery: a failed write leaves a board that does not boot. The IBM BIOS stays on its own
MX28F1000 as the fallback: swap the PLCC32 chips back. Its ID and command set are not confirmed, so flashrom does not
know it (the IBM flasher accepts any Macronix C2xxh part with the Intel algorithm).

## For the port

Facts the firmware needs, from running the IBM BIOS under trace (`docs/bios-extract` in the Aptiva project): the
82C557M index register and 82C558M PCI config values it sets, the Super I/O configuration, the PIRQ routing, the
Trident VGA BIOS (X5.3B) to put in CBFS for SeaBIOS, and the POST error/CPU speed logic.

## The operator's real machine

- The system board's PS/2 keyboard port is physically destroyed (the keyboard works on another board): the IBM BIOS
  reports 301 Keyboard Error and 8603 Pointing Device Error and stops at its SurePath error screen, which needs a key.
  Nothing boots or flashes through the IBM BIOS.
- So our firmware goes on a dedicated Intel TN28F010 (128 KiB, 12 V VPP; fits the BIOS socket) programmed outside the board, the
  original MX28F1000 with the IBM BIOS kept untouched as the fallback; it must boot without an AT keyboard
  (USB keyboard on a PCI USB card), and is debugged on the real board through POST codes and COM1.
