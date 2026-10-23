#!/bin/bash
# DRAM sizing oracle: the original IBM BIOS (boards/aptiva2168/BIOSORIGINAL.bin, BG2US0J, not in git) on the fork's
# 82C557M DRAM model (opti55x.c), one 86Box per SIMM configuration, from an empty CMOS. Past the Setup's error list
# and CMOS menu (factory settings), its System Information page shows the memory it found, and 13h/14h/19h are read
# through the test control. Each line is what the IBM BIOS does: on a configuration a real board can use, the
# configured size, which the bank codes add up to; "unusable" lines are its own choice, hang@<POST code>: its memory
# test stops there for good (an alias overwrites low memory); stuck=<address>:<bit>: that RAM bit reads 0 (the
# model's faulty bit; the BIOS sizes in 64 KB steps with 55AA55AAh).
# The operator's board: 2 x 8 MB double-sided in SIMM1/SIMM2, 2 x 4 MB in SIMM5/SIMM6: "5 4" if SIMM1/SIMM2 is J23/J24,
# "4 5" if it is J27/J28 (not known yet).
# usage: ramoracle.sh (all, from simm_configs.txt) | ramoracle.sh <one line of simm_configs.txt>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-ramoracle
[ -f "$bd/BIOSORIGINAL.bin" ] || fail "no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"
configs=$(grep -v '^#' "$bd/test/simm_configs.txt")
if [ $# -eq 0 ]; then
  mkdir -p "$vm_dir"
  xargs -P 6 -L 1 "$0" <<< "$configs" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 ramoracle"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = "$(wc -l <<< "$configs")" ] || { cat "$vm_dir/all.log"; fail "see above"; }
  echo "PASS [aptiva2168 ramoracle]"
  exit 0
fi

tag="$1_$2"
vm_dir=$vm_dir/$tag
vm_machine=aptiva2168 vm_ram=$(opti_ram_cfg "$1" "$2")
stuck=$(grep -oE 'stuck=[0-9a-f]+:[0-7]' <<< "$*" | cut -d= -f2) || true
if [ -n "$stuck" ]; then
  vm_ram+=$'\n'"stuck_addr = $((16#${stuck%:*}))"$'\n'"stuck_bit = ${stuck#*:}"
  tag+="_stuck"
fi
vm_start "aptiva2168 ramoracle $tag" "$bd/BIOSORIGINAL.bin"
if [[ $3 == hang@* ]]; then   # the last POST code, unchanged for 30 s
  last="" same=0 end=$((SECONDS + 300))
  while [ $same -lt 30 ]; do
    [ $SECONDS -lt $end ] || fail "POST codes still change after 300 s"
    sleep 1
    code=$(tail -n 1 "$vm/post.log" 2>/dev/null || true)
    [ "$code" = "$last" ] && same=$((same + 1)) || same=0
    last=$code
  done
  kb=hang@$code
else   # the error list: continue; CMOS error menu: factory settings; main menu: System Information
  for step in "POST Startup Error:1c" "CMOS Error Menu:1c" "Select a Menu:1c" "System Memory"; do
    vm_wait_text "${step%:*}" 180
    [ "${step#*:}" = "$step" ] || { sleep 2; vm_cmd key "${step#*:}"; }
  done
  read -r size unit <<< "$(grep -oE "System Memory +[0-9]+ [KM]B" "$vm/screen.txt" | grep -oE "[0-9]+ [KM]B")" || true
  [ -n "${size:-}" ] || fail "no System Memory size"
  kb=$size; [ "$unit" = KB ] || kb=$((size * 1024))
fi
rm -f "$vm/regs.txt"
for r in 13 14 19; do vm_cmd idx 22 24 $r "$vm/regs.txt"; done
for _ in $(seq 100); do [ "$(cat "$vm/regs.txt" 2>/dev/null | wc -l)" = 3 ] && break; sleep 0.1; done
read -r r13 r14 r19 <<< "$(awk '{printf "%s ", $2}' "$vm/regs.txt")"
vm_kill
got="$1 $2 $kb $r13 $r14 $r19"
[ "$got" = "${*:1:6}" ] || fail "got '$got', the IBM BIOS gave '${*:1:6}'"
if [ -z "${7:-}" ]; then
  sum=0   # 64-bit banks: code n = 2 MB << (n - 1); 13h and 14h hold two each, 19h's need its enable bits 3 and 7
  for code in $((16#$r13 & 7)) $((16#$r13 >> 4 & 7)) $((16#$r14 & 7)) $((16#$r14 >> 4 & 7)) \
              $((16#$r19 & 8 ? 16#$r19 & 7 : 0)) $((16#$r19 & 0x80 ? 16#$r19 >> 4 & 7 : 0)); do
    [ $code = 0 ] || sum=$((sum + (2048 << (code - 1))))
  done
  [ $((16#$r13 & 0x80)) != 0 ] || fail "13h $r13: not in full decode"
  [ $sum = "$kb" ] || fail "13h/14h/19h $r13 $r14 $r19 decode $sum KB, the Setup shows $kb KB"
fi
echo "PASS [aptiva2168 ramoracle $got]"
