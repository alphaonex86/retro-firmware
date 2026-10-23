#!/bin/bash
# Port step 3 gate: our ROM (out/aptiva2168.rom) on the emulated Aptiva 2168 (86Box machine aptiva2168, headless,
# 82C557M DRAM model with the default SIMM pair) sends exactly the bootblock and cache-as-RAM POST codes, the CAR
# self-test passes (29h, never 2Ah: with 13h = 88h no DRAM is left behind the range, only the P54C L1 model holds it)
# and romstage is reached (30h, where the skeleton halts); the romstage code also arrives on COM1 (FDC37C93x enabled
# by the bootblock), and post_once finds no reset.
# usage: boards/aptiva2168/test/skeleton.sh
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-skeleton
expected="01 03 04 10 21 22 23 26 29 27 28 14 15 16 17 18 19 30"

vm_machine=aptiva2168 vm_start skeleton "$rom"
codes() { grep -E '^[0-9A-F]{2}$' "$vm/post.log" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ $//'; }
for _ in $(seq 300); do
  [ "$(codes | sed 's/.* //')" = 30 ] && break
  kill -0 "$vm_pid" 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
  sleep 0.1
done
sleep 1   # the skeleton halts at 30h: nothing may follow
[ "$(codes)" = "$expected" ] || fail "POST codes: $(codes) - expected: $expected"
grep -q "^30\$" <(tr -d '\r' < "$vm/serial.log") || fail "no romstage POST code on COM1: $(tr '\r\n' '  ' < "$vm/serial.log")"
vm_stop
