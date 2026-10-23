# Aptiva 2168-A90: first boot of our firmware on the real board (port step 6)

`./build.sh aptiva2168` -> `out/aptiva2168-bringup.rom` (128 KiB): the release boot path (USB keyboard on the VT6212,
IDE, USB boot, option ROMs incl. the RTL8139 socket ROM) plus coreboot's console (INFO) and SeaBIOS's log (level 3) on
COM1; the setup's diagnostic tools are left out. Checked in 86Box by `test/bringup.sh`.

## Program the TN28F010 (minipro, T48)

The T48 database has no TN28F010 entry: use the Intel `N28F010@PLCC32` (same ID 89h/B4h). The T48 supplies the
12 V VPP itself. Do not use `-y` (an ID mismatch means a wrong chip or bad contact).

    minipro -p N28F010@PLCC32 -w out/aptiva2168-bringup.rom   # erase, program, verify
    minipro -p N28F010@PLCC32 -m out/aptiva2168-bringup.rom   # verify again

Label the chip (e.g. "bringup + date + git hash"). Keep the IBM MX28F1000QC-12 (BG2US0J) untouched and labelled: it
is the fallback. Use a PLCC extractor; pin 1 (the notch) as the IBM chip.

JP9 (silkscreen: 1-2 write enable, 2-3 write disable): keep 2-3. The firmware never writes the flash, and an IBM tip
reports stray flash writes on bus-master cycles.

## COM1

The board's serial port 1 (3F8h), 115200 8N1, no flow control. Null-modem cable: TX (DB9 pin 3) to RX (2) both ways,
GND (5) to GND. On the PC: `tools/post_time.py /dev/ttyUSB0 | tee a90-<step>.log` (times each line), started before
power-on. COM1 also gets each code from romstage on as a line `XX`. Bring-up runs without the riser (it covers the
BIOS socket): no POST card, no PCI/ISA cards, so checks 7 and 9-11 wait until the operator fits it with every card.

## Checklist, in order

At each point keep the COM1 log, the last POST code and a photo of the screen.

| # | Check | Pass | Failure means |
|---|---|---|---|
| 1 | Power on, no keyboard | POST card 01 03 04 10 21 22 23 26 29 27 28 14-19 | none/`FF`: chip, socket or programming (verify again); stuck 21-26: cache-as-RAM setup; **2Ah: the CAR self-test failed** (the P54C L1 does not hold the range: PORT_PLAN 2.3 fallback) |
| 2 | COM1 bootblock | `bootblock starting`, `CAR: self-test passed` | 19 on the card but COM1 silent: cable, or the FDC37C93x is not at 370h |
| 3 | romstage, DRAM | `30`, `32`, `DRAM: SIMM bank codes 3 3 3 0, 24576 KiB` (the operator's 2 SIMM pairs; = the IBM BIOS memory count) | stuck 30: chipset/JP2 bus clock; stuck 32: DRAM sizing; `33`: a SIMM larger than the 82C557M addresses; `34`: a 64 KiB block failed, the size is cut (bad SIMM); **3Eh: no usable DRAM** (SIMMs, seating, JP20) |
| 4 | postcar | `CBFS: Found 'fallback/postcar'`, card 3C 3D, `38` | stuck 3C/3D: leaving cache-as-RAM (L1 write-back); stuck 38: shadow RAM |
| 5 | ramstage | `ramstage starting`, PCI resources, then SeaBIOS `Found N PCI devices` | the last ramstage line names the device |
| 6 | VGA text | SeaBIOS screen; COM1 `Running option rom at c000:0003` | log ends at that line (card B2): the Trident BIOS |
| 7 | USB keyboard on the VT6212 | `USB keyboard initialized`; F1 at "CMOS checksum error" works | no `EHCI init` / `UHCI init on dev` lines: the card or its slot (BIOS USB needs no IRQ) |
| 8 | FreeDOS from IDE | `ata0-0: ... Hard-Disk` on COM1, DOS prompt | `BC` and no boot: the drive or MIDE timing |
| 9 | USB stick | its line in the boot menu (ESC), boots | card D6 missing: the stick did not answer |
| 10 | Linux | boots; keep `lspci -v` and `/proc/interrupts` (the USB card's IRQ: riser INTB-D wiring) | USB dead under Linux only: PIRQ routing |
| 11 | Network boot | `Running option rom at c800:` (RTL8139 socket ROM), iPXE by TFTP | no c800 line: the socket ROM or slot |

Back to the IBM chip once at the end to prove the fallback.
