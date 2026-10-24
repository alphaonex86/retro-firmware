#!/bin/bash
# The bus clock jumper JP2 read wrong (FDC37C93x GP21-GP20 at EAh/EBh index 2) on a 66 MHz board: coreboot must keep
# the DRAM timing safe for 66 MHz (82C557M 01h = DDh; FEh gives a 60 ns refresh RAS# pulse at 66 MHz, below tRAS)
# and ATCLK at LCLK/4 (82C558M 47h bits 5-4 = 00). Faults of the 86Box model, unverified on the chip: the invalid
# code 01 (BOX86_JP2=1), the first reads after a configuration exit floating (FFh: 50 MHz; BOX86_JP2_FLOAT=5), GP2
# floating while LD8 is inactive (BOX86_GPIO_LD8=1: read after the IBM BIOS's LD8 setup, POST 89h, it is 66 MHz).
# usage: jp2.sh [fault...]   (default: all three)
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-jp2
mkdir -p "$vm_dir"
export vm_machine=aptiva2168
for fault in ${*:-BOX86_JP2=1 BOX86_JP2_FLOAT=5 BOX86_GPIO_LD8=1}; do
  export "${fault?}"
  vm_start "aptiva2168 jp2 $fault" "$rom"
  vm_end_of_post 60
  rm -f "$vm/idx.txt"
  vm_cmd idx 22 24 01 "$vm/idx.txt"
  for _ in $(seq 50); do [ -s "$vm/idx.txt" ] && break; sleep 0.1; done
  expect_bits "$(awk '{print $2}' "$vm/idx.txt")" 0xff 0xdd "$fault: 82C557M 01h (DRAM timing)"
  expect_bits "$(vm_pci_byte 00:01.0 47)" 0x30 0 "$fault: 82C558M 47h bits 5-4 (ATCLK)"
  vm_stop
  unset "${fault%=*}"
done
