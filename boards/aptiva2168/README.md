# IBM Aptiva A90 (machine type 2168, Type I-2 system board)

The second board of this repository. Status: emulated in the 86Box fork with the original IBM BIOS; the coreboot and
SeaBIOS port is at step 3 of its plan (below). The board's photos, IBM manuals, datasheets, the BIOS analysis and the
port plan are in the Aptiva project (`/mnt/data/perso/retro/Aptiva A90/docs`, `docs/bios-extract/README.md`,
`docs/port/PORT_PLAN.md`).

## Hardware

| Part | Real board | 86Box fork (`86box` submodule) |
|---|---|---|
| Chipset | OPTi Viper-M 82C556M/557M/558M, MIDE IDE | `opti55x` (upstream 86Box) |
| DRAM | 4 x 72-pin SIMM in two pairs, J23/J24 (RAS0#/RAS1#, inferred) and J27/J28 (RAS2#/RAS3#) | flat RAM; with a pair set in `[OPTi 82C55x (Viper)]` `pair0`/`pair1`, the 82C557M decode (13h/14h/19h, MA map, aliases, absent banks, `stuck_addr`/`stuck_bit`) |
| CPU | Pentium P54C 166 (66 MHz x 2.5), Socket 7; P54C 75-166 on 50/60/66 MHz | `pentium_p54c`; P5 DIV/IDIV r32 41/46 clocks |
| Bus-speed jumper JP2 | on the FDC37C933 GPIO GP21/GP20, read at EAh (index 2) / EBh: 00 66, 10 60, 11 50 MHz | Super I/O GPIO input, follows the configured bus |
| Video | Trident TGUI9680XGi on board, PCI 00:02.0, 1 MB, VGA BIOS inside the system BIOS | `tgui9680_onboard_pci` |
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
  on COM1.
- `boards/aptiva2168/test/ramoracle.sh`: the IBM BIOS on 13 SIMM configurations of the DRAM model: the memory its
  Setup shows and its 13h/14h/19h, the oracle for our raminit. SIMMs it cannot size: 2 x 32 MB 8Mx32 (MA11 is RAS4#)
  gives 32 MB; 2 x 16 MB double-sided (2Mx32 sides) hangs its memory test at 16 MB (POST A7, an alias overwrites low
  memory; inferred for the real board).
- Tests start an A90 with `vm_machine=aptiva2168 vm_start` (`test/lib.sh`, SIMMs by `opti_ram_cfg`);
  `BOX86_USB`/`BOX86_USB_KBD`/`BOX86_USB_DISK` add the VIA USB card as on the MB-8433.

## Our firmware (port step 3: skeleton)

`./build.sh aptiva2168` -> `out/aptiva2168.rom` (128 KiB; `boards/aptiva2168/firmware.sh`). It needs the board's
Trident VGA BIOS X5.3B as `boards/aptiva2168/vgabios.bin` (a link to the Aptiva project's
`docs/bios-extract/trident_tgui9680_vgabios_X5.3B_1996-02-29.bin`; IBM's, never in git, sha256 checked), stored as
CBFS `pci1023,9660.rom` (LZMA). The build fails when something does not fit and prints the free bytes.

coreboot (`coreboot-486`: mainboard `ibm/aptiva2168`, northbridge `opti/viperm`, southbridge `opti/82c558m`, the
FDC37C93x in `smscsuperio`) runs the bootblock and cache-as-RAM, then stops in romstage: no DRAM init yet (step 4).
SeaBIOS is built without board code (`NEWBIOS_BOARD_GENERIC`), with the cuts of `seabios.config`; nothing runs it yet.
POST codes (port 80h; the C ones after the bootblock has enabled COM1, i.e. 30h, also on COM1 at 115200 8N1):

| Code | Step that starts |
|---|---|
| `01` `03` `04` `10` | reset vector, IDT/GDT, protected mode, 32-bit code |
| `21` `22` `23` | cache-as-RAM: L1 on, reading 1A0000h-1A1FFFh into it (the 82C557M's reset 2 MB of DRAM), CD = NW = 1 |
| `26` | DRAM decode off (82C557M 13h = 88h): the range now exists only in L1 |
| `29` / `2A` | CAR self-test (each dword its address, then the complement) passed / **failed: halted** |
| `27` `28` | cache-as-RAM zeroed, stack in it |
| `14` `15` | bootblock C code, BIST passed |
| `16` `17` `18` | northbridge (nothing), 82C558M: the whole flash below 4 GiB (ROMCS# 4Bh), CPU |
| `19` | romstage looked up in CBFS; then the FDC37C93x keyboard controller and COM1 are enabled |
| `30` | romstage: the skeleton halts here |

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
