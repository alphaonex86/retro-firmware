#!/bin/bash
# Port step 4 gate: our ROM (out/aptiva2168.rom) on the SIMM configurations of simm_configs.txt (the 82C557M DRAM
# model) sizes the DRAM as the IBM BIOS does on the same SIMMs (ramoracle.sh): the memory SeaBIOS counts
# (Extended Memory) and 13h/14h/19h read through the test control. Where the IBM BIOS fails, our values are the
# line's ours=; it reaches the POST prompt on every line, sends POST 33h on "partial" lines only (SIMMs addressed in
# part) and POST 34h on "stuck" lines only (memory count cut below a failing block).
# usage: ram.sh (all) | ram.sh <one line of simm_configs.txt>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-ram
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
configs=$(grep -v '^#' "$bd/test/simm_configs.txt")
if [ $# -eq 0 ]; then
  mkdir -p "$vm_dir"
  xargs -P 6 -L 1 "$0" <<< "$configs" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 ram"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = "$(wc -l <<< "$configs")" ] || { cat "$vm_dir/all.log"; fail "see above"; }
  echo "PASS [aptiva2168 ram]"
  exit 0
fi

line="$*"
want="${*:3:4}"
ours=$(grep -oE 'ours=[^ ]+' <<< "$line" | cut -d= -f2 | tr , ' ') || true
[ -z "$ours" ] || want=$ours
read -r kb r13 r14 r19 <<< "$want"
stuck=$(grep -oE 'stuck=[0-9a-f]+:[0-7]' <<< "$line" | cut -d= -f2) || true
tag="$1_$2${stuck:+_stuck}"
vm_dir=$vm_dir/$tag
vm_ram=$(opti_ram_cfg "$1" "$2")
[ -z "$stuck" ] || vm_ram+=$'\n'"stuck_addr = $((16#${stuck%:*}))"$'\n'"stuck_bit = ${stuck#*:}"
vm_machine=aptiva2168 vm_start "aptiva2168 ram $tag" "$rom"
vm_end_of_post 120
grep -q "Extended Memory  : $((kb - 1024))K" "$vm/screen.txt" || fail "no 'Extended Memory  : $((kb - 1024))K'"
grep -q "Memory test fail" "$vm/screen.txt" && fail "memory test failed"
rm -f "$vm/regs.txt"
for r in 13 14 19; do vm_cmd idx 22 24 $r "$vm/regs.txt"; done
for _ in $(seq 100); do [ "$(cat "$vm/regs.txt" 2>/dev/null | wc -l)" = 3 ] && break; sleep 0.1; done
got=$(awk '{printf "%s ", $2}' "$vm/regs.txt")
[ "$got" = "$r13 $r14 $r19 " ] || fail "13h/14h/19h $got- expected $r13 $r14 $r19"
codes=" $(grep -E '^[0-9A-F]{2}$' "$vm/post.log" | tr '\n' ' ')"
for flag in partial:33 stuck:34; do
  if grep -qw "${flag%:*}" <<< "${line//=/ }"; then
    [[ $codes == *" ${flag#*:} "* ]] || fail "no POST ${flag#*:}h (${flag%:*})"
  else
    [[ $codes != *" ${flag#*:} "* ]] || fail "POST ${flag#*:}h without ${flag%:*}"
  fi
done
vm_kill
echo "PASS [aptiva2168 ram $1 $2 $want${stuck:+ stuck=$stuck}]"
