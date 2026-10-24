#!/bin/bash
# Soft off through the power microcontroller at ECh/EDh (86Box model m_aptiva2168_power.c): in DOS, ours by APM
# (apmoff.asm: INT 15h AX=5307h CX=3), the original IBM BIOS by its own soft off routine (F000:5405; its APM needs
# an SMI the model does not raise, CC4Ah). With the controller the VM powers off ("POWER off" in the POST log, 86Box
# exits); without it (BOX86_POWER_CTL=0) both take the IBM BIOS's fallback: CMOS 0Fh = 0, an 8042 reset, a reboot.
# usage: softoff.sh (all, in parallel) | softoff.sh <ibm|ours> <1: controller, 0: none>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-softoff
rom=$nb/out/aptiva2168.rom
if [ $# -eq 0 ]; then
  [ -f "$bd/BIOSORIGINAL.bin" ] || fail "no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"
  [ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
  mkdir -p "$vm_dir"
  printf 'ibm 1\nibm 0\nours 1\nours 0\n' | xargs -P 4 -L 1 "$0" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 softoff"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = 4 ] || { cat "$vm_dir/all.log"; fail "see above"; }
  echo "PASS [aptiva2168 softoff]"
  exit 0
fi

vm_dir=$vm_dir/$1_$2
mkdir -p "$vm_dir"
nasm -f bin $([ "$1" = ibm ] && echo -DIBM) -o "$vm_dir/apmoff.com" "$bd/test/apmoff.asm" || fail "nasm"
dos_disk "$vm_dir/hdd.img" "$vm_dir/apmoff.com"
export BOX86_POWER_CTL=$2
vm_machine=aptiva2168
if [ "$1" = ibm ]; then   # new-CMOS errors: continue, factory settings, then save and exit: the reboot boots DOS
  vm_start "aptiva2168 softoff $1 $2" "$bd/BIOSORIGINAL.bin" "$(disk_cfg "$vm_dir/hdd.img")"
  for step in "POST Startup Error:1c" "CMOS Error Menu:1c" "Select a Menu:01" "Do you want to save your changes:1c"; do
    vm_wait_text "${step%:*}" 180
    sleep 2
    vm_cmd key "${step#*:}"
  done
else
  vm_start "aptiva2168 softoff $1 $2" "$rom" "$(disk_cfg "$vm_dir/hdd.img")"
  vm_end_of_post 60
fi
resets=""
for _ in $(seq 900); do   # 180 s: DOS, the off (the IBM BIOS waits 2 s for the power to go), a reboot
  kill -0 "$vm_pid" 2>/dev/null || break
  [ -n "$resets" ] || ! (vm_screen && grep -q "APM-OFF" "$vm/screen.txt") > /dev/null 2>&1 || resets=$(vm_resets)
  [ -z "$resets" ] || [ "$(vm_resets)" -eq "$resets" ] || break
  sleep 0.2
done
if [ "$2" = 1 ]; then
  ! kill -0 "$vm_pid" 2>/dev/null || fail "still running 180 s after the start (APM-OFF shown: ${resets:+yes})"
  grep -q '^POWER off$' "$vm/post.log" || fail "86Box exited without powering off (see $vm/86box.log)"
  vm_kill
  trap - EXIT
  echo "PASS [$vm_name]"
else
  [ -n "$resets" ] || fail "the program did not run"
  ! grep -q '^POWER off$' "$vm/post.log" || fail "powered off without the controller"
  [ "$(vm_resets)" -gt "$resets" ] || fail "no reset after the power off without the controller"
  sleep 5   # the reboot's POST under way
  vm_stop
fi
