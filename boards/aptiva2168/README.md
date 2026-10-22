# IBM Aptiva A90 (machine type 2168, Type I-2 system board)

The second board of this repository. Status: emulated in the 86Box fork with the original IBM BIOS. The coreboot and
SeaBIOS port is not started. The board's photos, IBM manuals, datasheets and the BIOS analysis are in the Aptiva
project (`/mnt/data/perso/retro/Aptiva A90/docs`, `docs/bios-extract/README.md`).

## Hardware

| Part | Real board | 86Box fork (`86box` submodule) |
|---|---|---|
| Chipset | OPTi Viper-M 82C556M/557M/558M, MIDE IDE | `opti55x` (upstream 86Box PR #7349, backported) |
| CPU | Pentium P54C 166 (66 MHz x 2.5), Socket 7; P54C 75-166 on 50/60/66 MHz | `pentium_p54c`; P5 DIV/IDIV r32 41/46 clocks |
| Board register | EAh index, EBh data: index 2 bits 1-0 = JP2 bus speed (00 66, 10 60, 11 50 MHz) | follows the configured bus |
| Video | Trident TGUI9680XGi on board, PCI 00:02.0, 1 MB, VGA BIOS inside the system BIOS | `tgui9680_onboard_pci` |
| PCI slots | riser, devices 07h/0Bh/0Ch; INTA: 0Bh -> PIRQ0, 07h/0Ch -> PIRQ1 (as the IBM BIOS routes) | same |
| Super I/O | SMC FDC37C933 at 370h | FDC37C93x (ID 02h), 256-byte RTC |
| Flash | MX28F1000 128 KiB, IBM BIOS BG2US0J 03/06/96 | AMD 28F010 model |
| Sound/modem | Mwave "Dolphin" ISA card | Sound Blaster Pro 2 (Mwave not emulated) |

## Try it, test it

- `boards/aptiva2168/run_86box.sh [rom]`: the A90 with the IBM BIOS (`boards/aptiva2168/BIOSORIGINAL.bin`, a
  symlink to the dump, not in git), or a ROM of ours later.
- `boards/aptiva2168/test/boot.sh` (also in `test/run_all.sh`): from an empty CMOS, each P54C setting gives exactly
  its POST errors (162/163; 127 where the IBM CPU speed check rejects the CPU: P75, P90, P100).

## For the port

Facts the firmware needs, from running the IBM BIOS under trace (`docs/bios-extract` in the Aptiva project): the
82C557M index register and 82C558M PCI config values it sets, the Super I/O configuration, the PIRQ routing, the
Trident VGA BIOS (X5.3B) to put in CBFS for SeaBIOS, and the POST error/CPU speed logic.
