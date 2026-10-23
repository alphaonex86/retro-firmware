#!/bin/bash
# Port step 4 gate: our ROM (out/aptiva2168.rom) boots to SeaBIOS's text screen on the emulated Aptiva 2168 with the
# 82C557M DRAM model and the P54C cache-as-RAM model (default SIMM pair: 2 x 8 MB double-sided): the Trident VGA BIOS
# from CBFS runs, the POST memory test (POST B5h) passes over the 16 MB that the summary shows, and after F1 (empty
# CMOS) the boot attempts the floppy and the hard disk. The POST codes pass through romstage, postcar and SeaBIOS.
# Ctrl+Alt+Del (a CPU-only reset: the chipset keeps its shadow RAM, ROMCS# and DRAM decode) boots the same way again,
# with the same POST codes.
# usage: boards/aptiva2168/test/post.sh
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-post

vm_machine=aptiva2168 vm_start "aptiva2168 post" "$rom"
vm_end_of_post 60
vm_expect "Extended Memory  : 15360K"
grep -q "Memory test fail" "$vm/screen.txt" && fail "memory test failed"
vm_wait_text "No bootable device" 60
vm_expect "Booting from Floppy"
vm_expect "Booting from Hard Disk"
vm_cad 60
vm_expect "Extended Memory  : 15360K"
codes=" $(grep -E '^[0-9A-F]{2}$' "$vm/post.log" | uniq | tr '\n' ' ')"
[[ $codes == " 01 03 04 10 21 22 23 26 29 27 28 14 15 16 17 18 19 30 32 3C 3D 38 "*" B0 B1 B2 B3 B4 "*" B5 B6 B7 B8 "* ]] \
  || fail "POST codes:$codes"
warm=" $(awk '/^RESET soft/ { p = 1 } p && /^[0-9A-F]{2}$/' "$vm/post.log" | uniq | tr '\n' ' ')"
[[ $warm == " 01 03 04 10 21 22 23 26 29 27 28 14 15 16 17 18 19 30 32 3C 3D 38 "* ]] || fail "POST codes after Ctrl+Alt+Del:$warm"
vm_stop
