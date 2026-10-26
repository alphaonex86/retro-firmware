#!/bin/bash
# tools/nbmon/usbdma.c, the USB-DMA corruption payload for the real board, through tools/nbmon.py on the 8 MB board
# with a USB disk of random data: 20 iterations without an error, each read's CRC that of the image's first 64 KB;
# its self-test (arg bit 31: one A and one B fault at iteration 2) gives 2 errors, both shown (with bit 30 also one
# IRQ0 checksum mismatch: 3); the same 20 clean reads with interrupts (bit 30: IRQ0 and USB IRQs counted, no handler
# error), on the EHCI at high speed (bit 29), and both; with A at 00500000 (bits 16-23), in 16 slots (bit 28), and
# with shared lines (bit 27: 127 blocks at A + 24h, guards intact; its self-test adds one guard fault); the same
# with write+readback (bit 26, also with wbinvd: bit 25), its self-test flipping a byte of the read back; EHCI qTD/QH
# overrun guards (bit 24) unchanged on reads and on writes with interrupts, its self-test changing one.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-usbdma
mkdir -p "$vm_dir"
head -c 16M /dev/urandom > "$vm_dir/usb.img"
truncate -s 128M "$vm_dir/usb.img"   # bit 26 writes at LBA 37800h
export vm_machine=aptiva2168 BOX86_USB_DISK=$vm_dir/usb.img
vm_ram=$(opti_ram_cfg 0 4)
vm_start usbdma "$rom"
nbmon() { timeout 300 python3 -I "$nb/tools/nbmon.py" --rx "$vm/serial.log" --tx "$vm/com1.in" --log "$vm/nbmon.log" "$@"; }
range=$(nbmon --from-start wait 120) || fail "no monitor: $(tail -n 5 "$vm/nbmon.log")"
[ "${range%-*}" = 00100000 ] && [ $((16#${range#*-})) -ge $((0x770000)) ] || fail "free range $range: not the payload's"
cp "$nb/tools/nbmon/usbdma.c" "$vm_dir/usbdma.c"
"$nb/tools/nbmon/payload.sh" "$vm_dir/usbdma.c" 100000 > /dev/null || fail "payload.sh"
[ "$(stat -c %s "$vm_dir/usbdma.bin")" -lt 65536 ] || fail "payload over 64 KB: it would reach its DMA area"
nbmon load "$vm_dir/usbdma.bin" 100000 || fail "load"
crc=$(python3 -I -c 'import sys, zlib; print("%08x" % zlib.crc32(open(sys.argv[1], "rb").read(65536)))' "$vm_dir/usb.img")
out=$(nbmon call 100000 14) || fail "call: $(tail -n 4 "$vm/nbmon.log")"
[ "$(grep -c "^it [0-9]* crc $crc OK A 0 B 0$" <<< "$out")" = 20 ] && [ "$(tail -n 1 <<< "$out")" = 00000000 ] \
  || fail "20 clean reads of CRC $crc: $out"
out=$(nbmon call 100000 80000003) || fail "self-test call: $(tail -n 4 "$vm/nbmon.log")"
grep -q "^it 2 crc [0-9a-f]* BAD A 1 @00121234 x00000040 B 1 @00463450 x00010000$" <<< "$out" \
  && grep -q "^  A 00121234 got" <<< "$out" && grep -q "^  B 00463450 got" <<< "$out" \
  && [ "$(grep -c "^it [13] crc $crc OK A 0 B 0$" <<< "$out")" = 2 ] && [ "$(tail -n 1 <<< "$out")" = 00000002 ] \
  || fail "self-test faults not reported: $out"
irqs=" irq0 [1-9][0-9]* usb [1-9][0-9]* spur 0 vec 0 stack 0 sum 0"
clean_run() {  # arg, controller line, iteration line suffix, [iterations, CRC]
  local n=${4:-20} c=${5:-$crc}
  out=$(nbmon call 100000 "$1") || fail "call $1: $(tail -n 4 "$vm/nbmon.log")"
  grep -q "^usbdma: stick on $2" <<< "$out" && [ "$(grep -c "^it [0-9]* crc $c OK A 0 B 0$3$" <<< "$out")" = "$n" ] \
    && [ "$(tail -n 1 <<< "$out")" = 00000000 ] || fail "arg $1, $n clean reads of CRC $c on $2: $out"
}
out=$(nbmon call 100000 c0000003) || fail "self-test call with interrupts: $(tail -n 4 "$vm/nbmon.log")"
grep -q "^it 2 crc [0-9a-f]* BAD A 1 @00121234 x00000040 B 1 @00463450 x00010000 irq0 [0-9]* usb [0-9]* spur 0 vec 0 stack 0 sum 1$" \
  <<< "$out" && [ "$(tail -n 1 <<< "$out")" = 00000003 ] || fail "self-test checksum fault not reported: $out"
clean_run 40000014 "UHCI" "$irqs"
clean_run 20000014 "EHCI" ""
clean_run 60000014 "EHCI" "$irqs"
clean_run 00500014 "UHCI" ""
clean_run 70000014 "EHCI" " slot [0-9a-f]*$irqs"
[ "$(grep -o " slot [0-9a-f]*" <<< "$out" | sort -u | wc -l)" = 16 ] || fail "arg 70000014: not 16 A slots: $out"
crc127=$(python3 -I -c 'import sys, zlib; print("%08x" % zlib.crc32(open(sys.argv[1], "rb").read(65024)))' "$vm_dir/usb.img")
clean_run 2800000a "EHCI" " G 0" 10 "$crc127"
clean_run 4800000a "UHCI" " G 0$irqs" 10 "$crc127"
out=$(nbmon call 100000 88000003) || fail "shared lines self-test call: $(tail -n 4 "$vm/nbmon.log")"
grep -q "^it 2 crc [0-9a-f]* BAD A 1 @00121234 x00000040 B 1 @00463450 x00010000 G 1 @00120020 x00000100$" <<< "$out" \
  && grep -q "^  G 00120020 got" <<< "$out" && [ "$(tail -n 1 <<< "$out")" = 00000003 ] \
  || fail "shared lines self-test: guard fault not reported: $out"
clean_run 0400000a "UHCI" " W 0" 10 "[0-9a-f]*"
clean_run 6600000a "EHCI" " W 0$irqs" 10 "[0-9a-f]*"
clean_run 2c00000a "EHCI" " W 0 G 0" 10 "[0-9a-f]*"
out=$(nbmon call 100000 84000003) || fail "write+readback self-test call: $(tail -n 4 "$vm/nbmon.log")"
grep -q "^it 2 crc [0-9a-f]* BAD A 0 B 1 @00463450 x00010000 W 1 @00001234 x00000040$" <<< "$out" \
  && grep -q "^  W 00141234 got" <<< "$out" && [ "$(tail -n 1 <<< "$out")" = 00000002 ] \
  || fail "write+readback self-test: A2 fault not reported: $out"
clean_run 2100000a "EHCI" " O 0" 10
clean_run 6500000a "EHCI" " W 0 O 0$irqs" 10 "[0-9a-f]*"
out=$(nbmon call 100000 a1000003) || fail "overrun guards self-test call: $(tail -n 4 "$vm/nbmon.log")"
grep -q "^it 2 crc [0-9a-f]* BAD A 1 @00121234 x00000040 B 1 @00463450 x00010000 O 1$" <<< "$out" \
  && grep -q "^  O qTD CBW out+40 6a6a0040 -> 6a6b0040 x1$" <<< "$out" && [ "$(tail -n 1 <<< "$out")" = 00000003 ] \
  || fail "overrun guards self-test: changed guard not reported: $out"
vm_stop
