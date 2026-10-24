#!/bin/bash
# A CPU-only reset while the VT6212 bus masters (SeaBIOS polls the USB keyboard; a Linux panic reboots so): the next
# POST stops bus mastering before its cache-as-RAM fill (post_once) and completes.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-usbreset
mkdir -p "$vm_dir"
export BOX86_USB_KBD=1 BOX86_KBD_POWERON_MS=600000
vm_machine=aptiva2168 vm_start "aptiva2168 usbreset" "$rom" ""
vm_wait_text "Press F1 to continue, DEL to enter SETUP" 60   # fresh CMOS: POST waits, the keyboard polled
grep -q '^USB-DMA on' "$vm/post.log" || fail "no USB bus mastering before the reset"
vm_cmd out 92 01                                    # fast reset: the CPU only
vm_wait_text "Press F1 to continue, DEL to enter SETUP" 60
grep -A1000 '^RESET soft' "$vm/post.log" | grep -q '^USB-DMA off' || fail "no soft reset with USB bus mastering on"
vm_stop
