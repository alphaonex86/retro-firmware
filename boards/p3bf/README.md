# ASUS P3B-F (Intel 440BX, Slot 1)

The first board on the mainline base (Slot 1 / Socket 370 family, 256 KiB flash, Pentium II/III): mainline coreboot
26.09 (mainboard `asus/p2b`, variant `p3b-f`) + our SeaBIOS (`seabios-mainline`: rel-1.17.0 + the setup utility,
USB, ATA... with no board-specific code, `NEWBIOS_BOARD_GENERIC`). It boots in the 86Box fork's `p3bf` machine.

- `./build.sh p3bf` → `out/p3bf.rom` (256 KiB, ~49 KiB free). No CPU microcode in CBFS: the default set (82 KiB)
  does not fit; a single CPU's update (~2 KiB) would.
- `boards/p3bf/test/boot.sh` (also in `test/run_all.sh`): on a Pentium II 400 with 128 MB, the POST screen shows the
  memory, the fresh CMOS stops at "Press F1", and F1 goes on to "No bootable device".
- 86Box needs the fork's P6 cache-as-RAM emulation (coreboot's stack lives in an MTRR write-back range with no RAM).
- 86Box machine `p3bf`: i440BX, PIIX4E, W83977EF, SST39SF020 flash; its CPU list stops at the Pentium II (Deschutes).

To do: the setup's CPU page detects only 486s ("unknown", 0 MHz here); 440BX shadow locking (PAM, like 440FX) is not
done, so the BIOS areas stay writable.
