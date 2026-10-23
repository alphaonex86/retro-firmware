#!/bin/bash
# Port step 2 gate: the P54C L1 cache-as-RAM model of the 86Box fork (src/cpu/cache_l1.c, KEN# and WB/WT# from the
# 82C557M DRAM model), probed by car.asm (its POST codes 01-09: CAR with CD/NW, a write outside the CAR lines lost,
# more than 8 KiB evicting the least recently used way, code fetches apart, INVD losing Modified lines, WBINVD writing
# them back, no fill outside KEN#). On the DRAM model with the recompiler and the interpreter; on flat RAM (no SIMM
# pair: no model) the probe must fail at 03, so a missing model cannot pass.
# usage: boards/aptiva2168/test/car.sh
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-car
mkdir -p "$vm_dir"
nasm -f bin -o "$vm_dir/car.rom" "$(dirname "$(readlink -f "$0")")/car.asm" || fail "nasm"

run() {  # name, SIMM pair 0, recompiler, expected POST codes
  local codes=""
  vm_machine=aptiva2168 vm_ram=$(opti_ram_cfg "$2" 0) vm_dynarec=$3 vm_start "aptiva2168 car $1" "$vm_dir/car.rom"
  for _ in $(seq 100); do
    codes=$(grep -E '^[0-9A-F]{2}$' "$vm/post.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//') || true
    [[ $codes == *09 || $codes == *EE\ ?? ]] && break
    kill -0 "$vm_pid" 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
    sleep 0.1
  done
  vm_kill
  [ "$codes" = "$4" ] || fail "POST codes: $codes - expected: $4"
  echo "PASS [$vm_name]"
}

run dram 5 1 "01 02 03 04 05 06 07 08 09"
run interpreter 5 0 "01 02 03 04 05 06 07 08 09"
run flat 0 1 "01 02 EE 03"
