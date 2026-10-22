#!/bin/bash
# The IBM Aptiva A90 (2168-A90) in the 86Box fork (Qt GUI): Type I-2 board (OPTi Viper-M), P166, 16 MB, on-board
# TGUI9680 1 MB, IBM DJAA-31700 geometry (3308/16/63, empty image), NEC 6X ATAPI CD, Sound Blaster Pro 2 for the
# Mwave, POST card in the status bar. The VM persists in boards/aptiva2168/vm (CMOS, disk) like the real machine.
# usage: run_86box.sh [rom]   default boards/aptiva2168/BIOSORIGINAL.bin, the IBM BIOS BG2US0J (not in git)
set -euo pipefail
bd=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$(dirname "$bd")")
vm=$bd/vm
rom=$(readlink -f "${1:-$bd/BIOSORIGINAL.bin}")
[ -f "$rom" ] || { echo "no ROM: $rom" >&2; exit 1; }
GUI=1 "$nb/build_86box.sh" > /dev/null
mkdir -p "$vm/roms/machines/aptiva2168"
cp "$rom" "$vm/roms/machines/aptiva2168/BG2US0J.BIN"   # -R paths are searched before the default ROM set
[ -f "$vm/hdd.img" ] || truncate -s $((3308 * 16 * 63 * 512)) "$vm/hdd.img"
[ -f "$vm/86box.cfg" ] || cat > "$vm/86box.cfg" <<CFG
[Machine]
machine = aptiva2168
cpu_family = pentium_p54c
cpu_speed = 166666666
cpu_multi = 2.5
cpu_use_dynarec = 1
fpu_type = internal
mem_size = 16384

[Video]
gfxcard = internal

[Trident TGUI 9680XGi On-Board PCI #1]
memory = 1

[Input devices]
keyboard_type = keyboard_ps2
mouse_type = ps2

[Sound]
sndcard = sbprov2

[Hard disks]
hdd_01_parameters = 63, 16, 3308, 0, ide
hdd_01_fn = $vm/hdd.img
hdd_01_ide_channel = 0:0
hdd_01_speed = 1994_4500rpm

[Floppy and CD-ROM drives]
fdd_01_type = 35_2hd
fdd_02_type = none
cdrom_01_parameters = 1, atapi
cdrom_01_ide_channel = 1:0
cdrom_01_speed = 6
cdrom_01_type = nec_1300a

[Other peripherals]
postcard_enabled = 1
CFG
exec "$nb/build/86box/out-qt/src/86Box" -P "$vm" -R "$vm/roms"
