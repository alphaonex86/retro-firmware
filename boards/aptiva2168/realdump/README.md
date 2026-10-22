# realdump: hardware dump floppy for the real Aptiva 2168-A90

A bootable 1.44 MB floppy that reads the board's registers and BIOS tables and writes them to `DUMP.BIN` on the
same floppy. It is meant to run on the real board under our coreboot + SeaBIOS firmware: it runs unattended (no key),
and anything missing (no `$PnP`, no Super I/O GPIO, no E820) is recorded as absent rather than failing. It also runs
under the original IBM BIOS (validated in 86Box).

## Build, write, run

```
boards/aptiva2168/realdump/build.sh          # -> out/aptiva2168-realdump.img (needs nasm, mtools)
dd if=out/aptiva2168-realdump.img of=/dev/fd0 bs=18432 conv=fsync    # or the USB floppy's /dev/sdX
```

Boot the board from the floppy. The screen shows `realdump: reading the hardware`, `writing DUMP.BIN`, then
`realdump: done, bytes 0x...` and the machine halts (about 15 s). Power off, then on Linux:

```
mcopy -i /dev/fd0 ::DUMP.BIN .               # or: dd if=/dev/fd0 of=floppy.img bs=18432
boards/aptiva2168/realdump/decode.py DUMP.BIN            # also accepts the whole floppy image
boards/aptiva2168/realdump/decode.py -x dumpdir DUMP.BIN # plus each record's raw bytes in dumpdir/
```

The header byte sum must print `OK`. An error message on screen (floppy I/O, read-back mismatch, `DUMP.BIN`
missing) means nothing usable was written: rebuild/rewrite the floppy, or try another disk. It must boot from a
floppy drive (BIOS drive 00h/01h), not from a USB stick seen as a hard disk.

## Image layout

The boot sector plus 8 reserved sectors hold `realdump.asm`. `DUMP.BIN` (448 KB of zeros) is the first root entry,
contiguous from cluster 2 (`build.sh` checks this, the program checks the root entry again). The program collects
everything in RAM at 10000h-7FFFFh, then writes it track by track with read-back verification.

## DUMP.BIN layout

16-byte header: `RDMP`, u32 total length, u32 byte sum of bytes 16..length-1, u32 layout version (1). Then records:
4-byte ASCII tag, u32 data length, data. Little-endian.

| Tag | Data |
|---|---|
| `IVT ` | 0000-03FF, captured first, before the program's own disk I/O |
| `BDA ` | 0400-04FF |
| `ROM ` | C0000-FFFFF (VGA ROM, option ROMs, BIOS shadow) |
| `EBDA` | u16 segment from 40:0E, then the EBDA (its KB byte, below A0000), or nothing |
| `BIOS` | INT 12h AX, INT 11h AX, INT 15h 88h FLAGS AX, INT 15h E801h FLAGS AX BX CX DX (u16 each) |
| `CPU ` | CPUID 0 EAX EBX EDX ECX, CPUID 1 EAX EBX ECX EDX; empty without CPUID |
| `E820` | 20-byte INT 15h E820h entries; empty when unsupported |
| `PNPH` | the `$PnP` header (F0000 scan, checksum valid); absent without one |
| `PNP0` | function 00h: u16 return, u8 node count, u16 max node size |
| `PNPN` | function 01h per node: u8 node asked, u16 return, the node as returned |
| `PCI ` | per present bus 0 function: u8 devfn, 256 bytes config (mechanism #1, CF8h restored) |
| `557M` | port 22h as read, then index 00h-FFh read via 22h/24h (82C557M 00h-1Fh, 558M shadows and PMU E0h-FFh) |
| `CMS0` | port 70h as read, then CMOS 00h-7Fh via 70h/71h with the NMI bit (70h bit 7) as read |
| `CMS2` | 128 bytes via 72h/73h (the FDC37C933 does not decode them: FFh) |
| `SIO ` | u16 config port (370h, or 0 when nothing answers), global 00h-2Fh, LD0-LD9 30h-FFh (208 bytes each) |
| `CMS1` | CMOS 80h-FFh via 70h/71h, banked by FDC37C93x LD6 F0h bit 7 (device ID 02h only) |
| `GPIO` | Super I/O CR03 as found; when CR03 bit 7 is set with base EAh: port EAh as read, index 00h-FFh via EAh/EBh |
| `PORT` | ports 92h, 61h, 21h, A1h |
| `IDE ` | status 1F7h, alternate status 3F6h, 177h, 376h |
| `CYRX` | Cyrix CCR C0h-CFh, E8h, FEh, FFh via 22h/23h; only on a Cyrix CPU (CPUID vendor, or the DIV flags test) |
| `KBC ` | 8042 status, then value + timeout flag for commands 20h, C0h, D0h, then status |
| `END ` | empty |

## What it writes to the hardware

Only index registers and configuration-mode keys, each restored: CF8h, 22h (557M index), 70h, 72h, the FDC37C93x
configuration mode at 370h (55h 55h ... AAh, LD select restored) with LD6 F0h bit 7 set for the upper CMOS bank
and restored, EAh (restored), 22h/23h on a Cyrix only. It reads but does not command the KBC (20h, C0h, D0h). The
floppy is the only thing written.

Reads deliberately skipped: Super I/O register AAh (writing AAh to the index port exits configuration mode) and
LD6 F5h (Read EEPROM Data advances the EEPROM pointer); both read as FFh in the dump. Ports ECh/EDh (the power
microcontroller) are never touched. 557M reads have no side effects per the Viper-M data book (status bits clear on
write only).

Known side effects of plain reads: CMOS 0Ch clears pending RTC flags, 0Dh latches VRT; 1F7h/177h clear a pending IDE
interrupt; a KBC reply byte may be seen once more by the IRQ1 handler (the dump is already taken). If port 70h
does not read back on the real board (FFh), the dump runs with NMI masked and leaves it masked.

## Validation (86Box fork, IBM BIOS BG2US0J, P166, 16 MB, IDE disk + ATAPI CD)

Booted after the Setup error screens (keys sent to exit Setup). Each register read matched an independent read by
the emulator itself (testctl `pci`, `out`/`in`): PCI config of all functions, 557M 00h-FFh, Super I/O global and
LD0-9, EBh index 2; the CMOS matched 86Box's NVR file except the running clock (00h, 02h) and register D. The VGA ROM equals
`trident_tgui9680_vgabios_X5.3B_1996-02-29.bin`; E0000-FFFFF equals `runtime_shadow_E0000-FFFFF.bin` except
14 runtime-data bytes in EDxxx. Differences from `docs/bios-extract` final values are expected: 557M 06h/08h/0Ch/11h
match the later "Final (86Box)" column of `chipset_memory_init.md` (written at POST 6F, after that trace's end),
07h reads FFh in 86Box; 558M 4Fh bit 5 and Trident 04h bit 7 are 86Box read masks; SIO LD0 F2h is computed by
86Box; the CMOS reference predates Setup and the reboot. Under QEMU/SeaBIOS (no IBM hardware) it runs unattended and
records E820, the SeaBIOS `$PnP` stub (00h returns 82h), no Super I/O and no GPIO.
