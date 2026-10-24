#!/bin/bash
# NBMON, the COM1 monitor (seabios-486 src/nbmon.c), through tools/nbmon.py as on the real board: from a fresh CMOS
# (its POST error halt comes after the window) it enters the monitor, reads 82C557M 01h (ob 22, ib 24), writes and
# reads back RAM of the free range it reports, loads and calls tools/nbmon/hello.c there (its line, its value), gets
# ERR on a bad command; "reset" gives NBMON start and ready again, then "boot" ends in the usual POST, and the
# boot failure (no drive) offers the monitor again.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-nbmon
mkdir -p "$vm_dir"
vm_machine=aptiva2168 vm_start "aptiva2168 nbmon" "$rom"
nbmon() { timeout 180 python3 -I "$nb/tools/nbmon.py" --rx "$vm/serial.log" --tx "$vm/com1.in" --log "$vm/nbmon.log" "$@"; }
range=$(nbmon --from-start wait 120) || fail "no monitor: $(tail -n 5 "$vm/nbmon.log")"
lo=${range%-*} hi=${range#*-}
[ $((16#$hi - 16#$lo)) -ge $((1 << 20)) ] || fail "free range $range: under 1 MiB"
nbmon cmd ob 22 01 && [ "$(nbmon cmd ib 24)" = dd ] || fail "82C557M 01h through ob 22 / ib 24"
nbmon cmd wl "$lo" 12345678 9abcdef0 && nbmon cmd wb "$(printf %x $((16#$lo + 8)))" a5 \
  && [ "$(nbmon cmd rl "$lo" 3)" = "$lo: 12345678 9abcdef0 $(nbmon cmd rl "$(printf %x $((16#$lo + 8)))" | cut -d' ' -f2)" ] \
  && [ "$(nbmon cmd rb "$(printf %x $((16#$lo + 8)))")" = "$(printf %08x $((16#$lo + 8))): a5" ] || fail "RAM write/read back"
cp "$nb/tools/nbmon/hello.c" "$vm_dir/hello.c"
"$nb/tools/nbmon/payload.sh" "$vm_dir/hello.c" "$lo" > /dev/null || fail "payload.sh"
nbmon load "$vm_dir/hello.bin" "$lo" || fail "load"
[ "$(nbmon call "$lo" 1 | tr '\n' ' ')" = "HELLO FROM PAYLOAD 00001235 " ] || fail "call: $(tail -n 4 "$vm/nbmon.log")"
! nbmon cmd zz 2> /dev/null || fail "no ERR for a bad command"
grep -q "^< ERR command$" "$vm/nbmon.log" || fail "ERR line: $(tail -n 2 "$vm/nbmon.log")"
nbmon reset || fail "reset"
printf 'cmd ob 22 01\ncmd ib 24\n' > "$vm_dir/loop.txt"   # loop mode: takes the next NBMON ready
[ "$(nbmon loop "$vm_dir/loop.txt" 1 | tr '\n' ' ')" = "ready $range dd " ] || fail "no monitor after the reset"
[ "$(grep -ac "NBMON start" "$vm/serial.log")" = 2 ] || fail "NBMON start: not twice"
nbmon boot || fail "boot"
vm_end_of_post 60
[ "$(nbmon wait 120)" = "$range" ] || fail "no monitor (same range) at the boot failure"   # no boot device
nbmon cmd ob 22 01 && [ "$(nbmon cmd ib 24)" = dd ] && nbmon boot || fail "monitor at the boot failure"
vm_wait_text "No bootable device" 10
vm_stop
