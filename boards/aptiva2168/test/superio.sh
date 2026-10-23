#!/bin/bash
# FDC37C93x and MIDE: the IBM BIOS's ports by default (COM1 3F8h, COM2 2F8h, LPT 3BCh: SeaBIOS finds it), the
# MIDE PIO timing of the drives (40h[1:0] the slowest drive's mode up to 3, 43h PIO 4 per drive); INTEGRATED
# PERIPHERALS and PNP/PCI CONFIGURATION changed and saved: LPT 378h, COM2 off, secondary IDE channel off, primary master
# PIO mode 1.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-superio
mkdir -p "$vm_dir"
truncate -s $((20 * 16 * 63 * 512)) "$vm_dir/pri.img" "$vm_dir/sec.img"
menu_io=5 menu_pci=4
mide() {  # expected 40h & 0Bh (secondary off, mode), 43h
  local r40 r43
  r40=$(vm_pci_byte 00:14.0 40) r43=$(vm_pci_byte 00:14.0 43)
  [ $((16#$r40 & 0x0b)) = $(($1)) ] && [ "$r43" = "$2" ] || fail "MIDE 40h $r40 43h $r43, expected 40h & 0Bh = $1, 43h = $2"
}

vm_machine=aptiva2168 vm_start "aptiva2168 superio" "$rom" "[Storage controllers]
hdc = internal

[Hard disks]
hdd_01_parameters = 63, 16, 20, 0, ide
hdd_01_fn = $vm_dir/pri.img
hdd_01_ide_channel = 0:0
hdd_02_parameters = 63, 16, 20, 0, ide
hdd_02_fn = $vm_dir/sec.img
hdd_02_ide_channel = 1:0"
vm_end_of_post 60
vm_expect "Serial Port\(s\)   : 3F8 2F8"
vm_expect "Parallel Port\(s\) : 3BC"
vm_expect "Pri. Master Disk : 9MB, PIO 4"
vm_expect "Sec. Master Disk : 9MB, PIO 4"
mide 3 11                                         # both masters PIO 4
vm_setup
vm_menu "$menu_pci"
vm_wait_text "IDE Primary Master PIO +: Auto" 5
for _ in 1 2 3 4; do vm_key $K_DOWN; done
vm_key $K_PGDN $K_PGDN                            # Auto -> Mode 0 -> Mode 1
vm_expect "IDE Primary Master PIO +: Mode 1"
vm_key $K_ESC
vm_menu "$menu_io"
vm_wait_text "Onboard IDE Controller +: Enabled" 5
vm_expect "Onboard Serial Port 1 +: COM1/3F8"
vm_expect "Onboard Serial Port 2 +: COM2/2F8"
vm_expect "Onboard Parallel Port +: 3BCH"
vm_expect "Onboard Parallel Mode +: Printer"
vm_key $K_DOWN $K_PGUP                            # secondary IDE off
vm_key $K_DOWN $K_DOWN $K_DOWN $K_PGUP            # COM2 off
vm_key $K_DOWN $K_PGDN                            # LPT 378h
vm_expect "Onboard IDE Secondary +: Disabled"
vm_expect "Onboard Serial Port 2 +: Disabled"
vm_expect "Onboard Parallel Port +: 378H"
vm_save
vm_end_of_post 60
vm_expect "Serial Port\(s\)   : 3F8 "
vm_expect "Parallel Port\(s\) : 378"
vm_expect "Pri. Master Disk : 9MB, PIO 1"
vm_expect "Sec. Master Disk : None"
mide 9 00                                         # secondary off, PIO 1
vm_stop
