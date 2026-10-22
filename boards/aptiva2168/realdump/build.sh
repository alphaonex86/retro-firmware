#!/bin/bash
# Build out/aptiva2168-realdump.img: a FAT12 1.44 MB floppy whose boot and reserved sectors hold realdump.asm, and
# whose first file, DUMP.BIN, is preallocated contiguously from cluster 2 for the program to fill.
# usage: boards/aptiva2168/realdump/build.sh
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$(dirname "$(dirname "$here")")")
out=$nb/out
img=$out/aptiva2168-realdump.img
bin=$out/aptiva2168-realdump.bin
dump_size=$((448 * 1024))   # the program's RAM buffer, 10000h-7FFFFh

mkdir -p "$out"
nasm -f bin -o "$bin" "$here/realdump.asm"
reserved=$(($(stat -c %s "$bin") / 512))
dd if=/dev/zero of="$img" bs=512 count=2880 status=none
mformat -i "$img" -f 1440 -R "$reserved" -B "$bin" ::
dd if="$bin" of="$img" bs=512 skip=1 seek=1 count=$((reserved - 1)) conv=notrunc status=none
head -c "$dump_size" /dev/zero | mcopy -i "$img" - ::DUMP.BIN

# The program trusts these: its code as assembled, its reserved sectors in the BPB, DUMP.BIN at clusters 2-n.
cmp -s <(tail -c +63 "$bin" | head -c 450) <(tail -c +63 "$img" | head -c 450) \
  || { echo "FAIL: mformat changed the boot code" >&2; exit 1; }
cmp -s <(head -c $((reserved * 512)) "$img" | tail -c +513) <(tail -c +513 "$bin") \
  || { echo "FAIL: reserved sectors differ from the program" >&2; exit 1; }
[ "$(od -An -tu2 -j 14 -N 2 "$img" | tr -d ' ')" = "$reserved" ] \
  || { echo "FAIL: the BPB does not reserve the program's $reserved sectors" >&2; exit 1; }
clusters=$(mshowfat -i "$img" ::DUMP.BIN)
[ "$clusters" = "::/DUMP.BIN <2-$((1 + dump_size / 512))>" ] \
  || { echo "FAIL: DUMP.BIN is not contiguous from cluster 2: $clusters" >&2; exit 1; }
echo "$img"
