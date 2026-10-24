#!/bin/bash
# The real board's 8 MB (silver pair in J27/J28) with a high-speed USB disk: PCI memory from 1 GiB, as the IBM BIOS
# (coreboot put the EHCI BAR just above the DRAM, below 16 MiB: SeaBIOS rejected it and the disk ran at full speed).
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-usbhs
export vm_machine=aptiva2168
mkdir -p "$vm_dir"
dos_disk "$vm_dir/usb.img"
export BOX86_USB_DISK=$vm_dir/usb.img
vm_ram=$(opti_ram_cfg 0 4)
vm_start usbhs "$rom"
vm_end_of_post 60
vm_expect "Extended Memory +: 7168K"
ehci=$(vm_pci_byte 00:00.0 00 > /dev/null; awk '$2 == "00:" && $3 == "06" && $4 == "11" && $5 == "04" && $6 == "31" {print $1}' "$vm/pci.txt")
[ -n "$ehci" ] || fail "no VT6212 EHCI in the PCI dump"
bar=$(awk -v d="$ehci" '$1 == d && $2 == "10:" {print $6 $5 $4 $3}' "$vm/pci.txt")
[ $((16#$bar & ~0xff)) -ge $((0x40000000)) ] || fail "EHCI BAR0 $bar below 1 GiB"
vm_setup
vm_tool 7 2                                       # HARDWARE INFORMATION: USB
vm_wait_text "USB DEVICES" 5
vm_expect "storage, high speed"
vm_stop
echo "PASS [$vm_name]"
