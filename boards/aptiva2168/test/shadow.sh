#!/bin/bash
# Shadow RAM (82C557M index 04h-06h, per segment): an 8 KiB ISA option ROM at D8000 stays on the ISA bus and the
# blocks without a ROM go back to it; the VGA BIOS (C0000-C7FFF), E and F segments are read-only after POST
# (shadow.asm from DOS, and the registers). With "D8000-DBFFF Shadow" on, the ROM runs from a read-only copy.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-shadow
mkdir -p "$vm_dir"
nasm -f bin -o "$vm_dir/shadow.com" "$nb/boards/aptiva2168/test/shadow.asm"
dos_disk "$vm_dir/hdd.img" "$vm_dir/shadow.com"
python3 -c 'import sys; r = bytearray(8192); r[0:4] = b"\x55\xaa\x10\xcb"; r[-1] = -sum(r) & 0xff
sys.stdout.buffer.write(r)' > "$vm_dir/isarom.bin"

regs() {  # -> "04h 05h 06h" read through the test control
  rm -f "$vm/regs.txt"
  for r in 04 05 06; do vm_cmd idx 22 24 $r "$vm/regs.txt"; done
  for _ in $(seq 100); do [ "$(cat "$vm/regs.txt" 2>/dev/null | wc -l)" = 3 ] && break; sleep 0.1; done
  awk '{printf "%s%s", (NR > 1 ? " " : ""), $2}' "$vm/regs.txt"
}

vm_other="isarom0_type = isarom"
vm_machine=aptiva2168 vm_start "aptiva2168 shadow" "$rom" "$(disk_cfg "$vm_dir/hdd.img")

[Generic ISA ROM Board #1]
bios_fn = $vm_dir/isarom.bin
bios_addr = d8000
bios_size = 8192"
vm_end_of_post 60
vm_wait_text "DOS-TEST-OK" 90
vm_expect "SHADOW-OK"
got=$(regs)
[ "$got" = "01 00 35" ] || fail "04h-06h in DOS: $got, expected 01 00 35 (C0000, E, F read-only; C8000-DFFFF ISA)"

vm_reset 60
vm_setup
vm_menu 1                                         # BIOS FEATURES SETUP
vm_wait_text "C8000-CBFFF Shadow +: Disabled" 5
vm_key $K_RIGHT $K_DOWN $K_DOWN $K_DOWN $K_DOWN $K_PGDN
vm_expect "D8000-DBFFF Shadow +: Enabled"
vm_save
vm_wait_text "DOS-TEST-OK" 120
vm_expect "SHADOW-OK"
got=$(regs)
[ "$got" = "01 10 35" ] || fail "04h-06h in DOS with D8000 shadowed: $got, expected 01 10 35"
vm_stop
