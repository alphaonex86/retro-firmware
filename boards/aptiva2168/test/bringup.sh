#!/bin/bash
# Port step 6: the bring-up ROM (out/aptiva2168-bringup.rom) logs the whole boot on COM1, in order: coreboot's
# bootblock, the cache-as-RAM self-test, romstage, the DRAM sizing (the bank codes and size of simm_configs.txt),
# postcar (its POST codes), ramstage, then SeaBIOS's log; and it reaches the same SeaBIOS screen as the release ROM.
# On the operator's SIMMs (5 4, 24 MB) with a USB keyboard and the RTL8139 socket ROM, and on 1 2 (6 MB, mixed codes).
# usage: bringup.sh (all) | bringup.sh <one line of simm_configs.txt>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-bringup
rom=$nb/out/aptiva2168-bringup.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
if [ $# -eq 0 ]; then
  mkdir -p "$vm_dir"
  configs=$(grep -E '^(5 4|1 2) ' "$bd/test/simm_configs.txt")
  xargs -P 2 -L 1 "$0" <<< "$configs" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 bringup"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = 2 ] || { cat "$vm_dir/all.log"; fail "see above"; }
  echo "PASS [aptiva2168 bringup]"
  exit 0
fi

read -r p0 p1 kb r13 _ r19 _ <<< "$*"
codes="$((16#$r13 & 7)) $((16#$r13 >> 4 & 7)) $((16#$r19 & 7)) $((16#$r19 >> 4 & 7))"
vm_dir=$vm_dir/${p0}_$p1
vm_ram=$(opti_ram_cfg "$p0" "$p1")
extra="" sb_extra=()
if [ "$p0 $p1" = "5 4" ]; then
  export BOX86_USB_KBD=1
  extra=$(nic_cfg "$etherboot")
  sb_extra=("USB keyboard initialized" "^Running option rom at c800:" "^Registering bootable: rtl8139")
fi
vm_machine=aptiva2168 vm_start "aptiva2168 bringup $p0 $p1" "$rom" "$extra"
vm_end_of_post 120
vm_expect "Extended Memory  : $((kb - 1024))K"
for _ in $(seq 50); do grep -q "^Press DEL to enter SETUP" "$vm/serial.log" && break; sleep 0.1; done   # COM1 lags

com1=$vm/com1.txt
tr -d '\r' < "$vm/serial.log" > "$com1"
in_order() {  # extended regexes that COM1 must show in this order
  local at=0 n re
  for re; do
    n=$(at=$at re=$re awk 'NR > ENVIRON["at"] && $0 ~ ENVIRON["re"] { print NR; exit }' "$com1")
    [ -n "$n" ] || fail "COM1 lacks /$re/ after line $at (see $com1)"
    at=$n
  done
}
in_order "^coreboot-.* bootblock starting" "^CAR: self-test passed" "^coreboot-.* romstage starting" "^30$" "^32$" \
  "^DRAM: SIMM bank codes $codes, $kb KiB$" "^CBFS: Found 'fallback/postcar'" "^38$" "^coreboot-.* ramstage starting" \
  "^Found CBFS header" "^Found [0-9]+ PCI devices" "^Running option rom at c000:" "^SeaBIOS \(version" \
  "${sb_extra[@]}" "Extended Memory  : $((kb - 1024))K" "^Press DEL to enter SETUP"
vm_kill
echo "PASS [aptiva2168 bringup $p0 $p1: $kb KiB, bank codes $codes]"
