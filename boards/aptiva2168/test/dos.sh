#!/bin/bash
# DOS on the Aptiva (port of test/dos.sh): FreeDOS 1.3 boots from the IDE disk (INT 13h/10h/16h/1Ah) and loads HIMEMX
# (XMS via INT 15h); the shared RAM of a WD8013 ISA network card at D0000 is reachable. POST screen: BIOS name, release
# date, drive detection lines. In DOS: the L1 cache on, the IBM BIOS's DRAM timing at 66 MHz (Auto), no PCI interrupt
# on IRQ 14/15.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-dos
export vm_machine=aptiva2168
mkdir -p "$vm_dir"
nasm -f bin -o "$vm_dir/shmem.com" "$nb/test/dos/shmem.asm"
dos_disk "$vm_dir/hdd.img" "$vm_dir/shmem.com"
rm -f "$vm_dir/post-b5.txt"
BOX86_POSTTEXT=B5:$vm_dir/post-b5.txt vm_start dos "$rom" "$(disk_cfg "$vm_dir/hdd.img")

[Network]
net_01_card = wd8013ebt
net_01_net_type = slirp
net_01_link = 0"
for _ in $(seq 300); do [ -f "$vm_dir/post-b5.txt" ] && break; sleep 0.1; done
b5() { grep -Eq "$1" "$vm_dir/post-b5.txt" 2>/dev/null || fail "POST screen at B5 (memory test) lacks /$1/"; }
b5 "Detecting HDD Primary Master +\.\.\. 86B_HD"        # POST screen: BIOS name, release date, CPU, drives
b5 "^aptiva2168"
b5 "^[0-3][0-9]/[01][0-9]/20[0-9]{2} "
b5 "Pentium CPU at 166MHz"
b5 "Detecting HDD Primary Slave +\.\.\. None"
b5 "^rel-[0-9.]+-[0-9]+-g[0-9a-f]+(-dirty-[0-9]{8}_[0-9]{6})? "   # SeaBIOS version: its commit (+ build time if dirty)
vm_end_of_post
vm_wait_text "DOS-TEST-OK" 90
expect_bits "$(vm_cr0)" 0x60000000 0 "L1 cache enabled in DOS (CR0.CD, NW)"
rm -f "$vm/idx.txt"
vm_cmd idx 22 24 01 "$vm/idx.txt"
for _ in $(seq 50); do [ -s "$vm/idx.txt" ] && break; sleep 0.1; done
expect_bits "$(awk '{print $2}' "$vm/idx.txt")" 0xff 0xdd "Auto DRAM timing at 66 MHz (82C557M 01h, the IBM BIOS's)"
links=$((16#$(vm_pci_byte 00:01.0 41)$(vm_pci_byte 00:01.0 40)))   # PCI INTA#-INTD#: 3-bit codes, 6 and 7 are IRQ 14, 15
for l in 0 1 2 3; do
  [ $((links >> (3 * l) & 7)) -lt 6 ] || fail "PCI interrupt link $l on IRQ 14/15 (82C558M 40h-41h $links)"
done
vm_expect "FreeDOS"
vm_expect "Extended \(XMS\) +15,[0-9]{3}K"       # 16 MB minus HMA and CBMEM/SeaBIOS at the top
vm_expect "Conventional +63[0-9]K"
vm_expect "SHMEM-OK"
vm_stop
