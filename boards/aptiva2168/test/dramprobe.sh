#!/bin/bash
# tools/dramprobe.c (the Linux probe of SIMM pair J27/J28 on the real board) on the 82C557M DRAM model (-DMODEL):
# the operator's SIMMs ("5 4": 13h/14h/19h bb 83 88) give the IBM BIOS's code 03 and ours, no alias, no failing
# bit, a clean full test and 14h restored; a faulty bit in J27/J28 shows in its dword and in the full test.
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$(dirname "$(dirname "$here")")")
out=$nb/test/vm/aptiva2168-dramprobe
fail() { echo "FAIL [aptiva2168 dramprobe]: $*"; exit 1; }
mkdir -p "$out"
gcc -DMODEL -O2 -Wall -Wextra -Werror -I"$here/native" -o "$out/dramprobe" "$nb/tools/dramprobe.c" \
  "$here/native/dramprobe_model.c" "$here/native/viperm_model.c" || fail "build"
expect() { grep -qE "$2" "$out/$1.txt" || fail "$1: no '$2' in $out/$1.txt"; }

"$out/dramprobe" 5 4 bb 83 88 > "$out/clean.txt" || fail "clean: exit $?"
expect clean '^82C557M 13h bb 14h 83 19h 88: J27/J28 from 16 MB'
expect clean '^map 14h=83 o{8}-{120}$'
expect clean '^IBM count at 14h=d5: 8 MB, side B check not needed: code byte 03$'
expect clean '^ours side A: code 3 '
expect clean '^ours side B: code 0 '
expect clean '^side A code 3 \(14h=83\): aliasing address bits 00000000, failing data bits low dword 00000000, high 00000000$'
expect clean '^full test 14h=83, 8 MB from 16 MB: 0 errors$'
expect clean '^14h back to 83$'

"$out/dramprobe" 5 4 bb 83 88 10007fd 1 > "$out/faulty.txt" || fail "faulty: exit $?"
expect faulty '^side A code 3 \(14h=83\): .* high 00000200$'
expect faulty '^full test 14h=83, 8 MB from 16 MB: 0 errors$'
"$out/dramprobe" 5 4 bb 83 88 1010001 0 > "$out/faulty2.txt" || fail "faulty2: exit $?"
expect faulty2 '^full test 14h=83, 8 MB from 16 MB: [1-9][0-9]* errors$'
echo "PASS [aptiva2168 dramprobe]"
