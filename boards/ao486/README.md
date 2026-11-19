# ao486 FPGA core (Terasic DE25-Standard)

SeaBIOS alone (no coreboot) for the ao486 soft 486 of
[retroDE_ao486](https://github.com/Thejayman77/retroDE_ao486) on the DE25-Standard: an ISA PC with 64 MiB of SDRAM,
ISA IDE, the core's own VGA BIOS at C0000, no PCI.

- `./build.sh ao486` → `out/ao486.rom` (128 KiB). `DEBUG=3 ./build.sh ao486` also builds `out/ao486-debug.rom`,
  logging on COM1.
- The core's HPS daemon (`software/ao486d.c` there) writes the image to RAM at E0000-FFFFF, where the CPU starts it,
  and a pristine copy at the SDRAM's end, seen at FFFE0000-FFFFFFFF: a warm reboot restores the RAM image from it
  (`qemu_reboot()`), then resets through the keyboard controller (the core has no port CF9h).
- The memory size is fixed (64 MiB minus that copy), setup settings are lost at power off (no battery-backed CMOS:
  defaults are loaded, the boot goes on), no floppy, no CD-ROM, no USB.
- `boards/ao486/run_qemu.sh <disk.img> <vga_bios.rom>` boots it in QEMU's `isapc` (tested: FreeDOS boots, warm reboot
  works). The core itself is tested by the operator on the board.

SeaBIOS changes (`seabios-486`, `CONFIG_NEWBIOS_BOARD_AO486`): the e820 map without a coreboot table
(`src/fw/coreboot.c`), the reboot restore (`src/fw/shadow.c`, `src/resume.c`), the VGA BIOS left in place
(`src/optionroms.c`), no diskette drive A by default and the setup name (`src/setup.c`).
