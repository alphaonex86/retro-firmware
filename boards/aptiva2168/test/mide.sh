#!/bin/bash
# MIDE (82C621-class IDE, 00:14.0) as the IBM BIOS sets it (E000:31DF-342F): PCI 40h (24h: 32-byte FIFO; 27h with a
# PIO 4 drive), 43h (PIO 4 per drive), the index registers of both channels (1F0h/1F1h of index 0 and 1, 1F3h, 1F5h,
# 1F6h; 170h-176h) read past their unlock (two 16-bit reads of 1F1h, 1F2h = 03h). Oracle: the original IBM BIOS on the
# same drives, at its Setup menu (past the new-CMOS errors), at 66 and 60 MHz. Drives A: three disks (PIO 4), two on
# the primary channel, a master alone on the secondary; B: a disk and a CD-ROM on the primary, two CD-ROMs on the
# secondary (the IBM BIOS gives these CD-ROMs PIO 3, ours is set to Mode 3 in setup); C: CD-ROMs of PIO 2, 0 and 2.
# At 50 MHz, which the IBM BIOS cannot run (P75: error 127, then its 66 MHz table), ours on C: its 50 MHz table.
# usage: mide.sh (all, in parallel) | mide.sh <ibm|ours> <A|B> <CPU Hz> <multiplier>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-mide
rom=$nb/out/aptiva2168.rom
if [ $# -eq 0 ]; then
  [ -f "$bd/BIOSORIGINAL.bin" ] || fail "no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"
  [ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
  mkdir -p "$vm_dir"
  cases=$(for d in A B C; do for cpu in "166666666 2.5" "150000000 2.5"; do echo "ibm $d $cpu"; echo "ours $d $cpu"; done
           done; echo "ours C 75000000 1.5")
  xargs -P 13 -L 1 "$0" <<< "$cases" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 mide"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = 13 ] || { cat "$vm_dir/all.log"; fail "see above"; }
  regs() { cat "$vm_dir/$1.regs"; }
  for c in A_166666666 A_150000000 B_166666666 B_150000000 C_166666666 C_150000000; do
    [ "$(regs ibm_$c)" = "$(regs ours_$c)" ] || fail "$c: ours $(regs ours_$c), the IBM BIOS $(regs ibm_$c)"
  done
  # E000:3282 at 50 MHz: PIO 2 00h, 21h; PIO 0 10h, 46h
  [ "$(regs ours_C_75000000)" = "40=24 43=00 1f3=95 1f5=e0 1f6=11 21 21 46 46 173=95 175=60 176=01 21 21 00 00" ] \
    || fail "C at 50 MHz: $(regs ours_C_75000000)"
  echo "PASS [aptiva2168 mide]"
  exit 0
fi

tag=$1_$2_$3
vm_dir=$vm_dir/$tag
mkdir -p "$vm_dir"
truncate -s $((20 * 16 * 63 * 512)) "$vm_dir/a.img" "$vm_dir/b.img" "$vm_dir/c.img"
disk() { printf 'hdd_0%s_parameters = 63, 16, 20, 0, ide\nhdd_0%s_fn = %s\nhdd_0%s_ide_channel = %s\n' "$1" "$1" "$vm_dir/$2.img" "$1" "$3"; }
cdrom() { printf 'cdrom_0%s_parameters = 0, atapi\ncdrom_0%s_ide_channel = %s\ncdrom_0%s_type = %s\n' "$1" "$1" "$2" "$1" "${3:-86cd}"; }
if [ "$2" = C ]; then
  drives="[Floppy and CD-ROM drives]
$(cdrom 1 0:0 matshita_574)
$(cdrom 2 0:1 matshita_571)
$(cdrom 3 1:0 ecs_300)"
elif [ "$2" = A ]; then
  drives="[Hard disks]
$(disk 1 a 0:0)
$(disk 2 b 0:1)
$(disk 3 c 1:0)"
else
  drives="[Hard disks]
$(disk 1 a 0:0)

[Floppy and CD-ROM drives]
$(cdrom 1 0:1)
$(cdrom 2 1:0)
$(cdrom 3 1:1)"
fi
vm_machine=aptiva2168 vm_cpu_speed=$3 vm_cpu_multi=$4
vm_start "aptiva2168 mide $tag" "$([ "$1" = ibm ] && echo "$bd/BIOSORIGINAL.bin" || echo "$rom")" "[Storage controllers]
hdc = internal

$drives"
if [ "$1" = ibm ]; then   # the error list: continue; CMOS error menu: factory settings; the main menu
  for step in "POST Startup Error:1c" "CMOS Error Menu:1c" "Select a Menu"; do
    vm_wait_text "${step%:*}" 180
    [ "${step#*:}" = "$step" ] || { sleep 2; vm_cmd key "${step#*:}"; }
  done
  sleep 2
else
  vm_end_of_post 60
  if [ "$2" = B ]; then   # the CD-ROMs in PIO 3, as the IBM BIOS sets them
    vm_setup
    vm_menu 4
    vm_wait_text "IDE Primary Slave  PIO +: Auto" 5
    for _ in 1 2 3 4; do vm_key $K_DOWN; done
    for _ in 1 2 3; do vm_key $K_DOWN $K_PGDN $K_PGDN $K_PGDN $K_PGDN; done
    vm_expect "IDE Primary Slave  PIO +: Mode 3"
    vm_expect "IDE Secondary Master PIO +: Mode 3"
    vm_expect "IDE Secondary Slave  PIO +: Mode 3"
    vm_key $K_ESC
    vm_save
    vm_end_of_post 60
  fi
fi
io() { rm -f "$vm/io.txt"; vm_cmd io "$vm/io.txt" "$@"; for _ in $(seq 50); do [ -s "$vm/io.txt" ] && break; sleep 0.1; done; }
regs=""
for base in 1f 17; do   # 1F3h/1F5h/1F6h, then 1F0h/1F1h of index 0 and 1 with 1F6h kept
  io R${base}1 R${base}1 w${base}2=03 r${base}3 r${base}5 r${base}6 w${base}2=80
  read -r c3 c5 c6 <<< "$(tail -n 3 "$vm/io.txt" | awk '{printf "%s ", $2}')"
  i0=$(printf %x $((16#$c6 & 0xfe))) i1=$(printf %x $((16#$c6 | 1)))
  io R${base}1 R${base}1 w${base}2=03 w${base}6=$i0 r${base}0 r${base}1 w${base}6=$i1 r${base}0 r${base}1 w${base}6=$c6 w${base}2=80
  regs+=" ${base}3=$c3 ${base}5=$c5 ${base}6=$c6 $(tail -n 4 "$vm/io.txt" | awk '{print $2}' | paste -sd ' ')"
done
regs="40=$(vm_pci_byte 00:14.0 40) 43=$(vm_pci_byte 00:14.0 43)$regs"
vm_kill
echo "$regs" > "$vm_dir.regs"
echo "PASS [aptiva2168 mide $tag: $regs]"
