#!/bin/bash
# CPU-only resets with a CMOS shutdown code (resume.asm in DOS: 0Ah through port 92h, 05h through the 8042, 06h as the
# IBM BIOS): coreboot hands them to SeaBIOS (POST 01 02, no POST), which clears 0Fh and jumps via 40h:67h back into
# the program. Then a reset with 0Fh = 0 still boots (POST to the prompt).
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-resume
mkdir -p "$vm_dir"
nasm -f bin -o "$vm_dir/resume.com" "$(dirname "$(readlink -f "$0")")/resume.asm" || fail "nasm"
dos_disk "$vm_dir/hdd.img" "$vm_dir/resume.com"
vm_machine=aptiva2168 vm_start "aptiva2168 resume" "$rom" "$(disk_cfg "$vm_dir/hdd.img")"
vm_end_of_post 60
vm_wait_text "DOS-TEST-OK" 90
for code in 0A 05 06; do vm_expect "RESUME-$code-OK 0Fh=00"; done
[ "$(grep -A2 '^RESET soft' "$vm/post.log" | grep -v '^--' | tr '\n' ' ')" = "RESET soft 01 02 RESET soft 01 02 RESET soft 01 02 " ] \
  || fail "the resets are not CPU-only resumes: $(grep -A2 '^RESET' "$vm/post.log" | tr '\n' ' ')"
fast_reset() { vm_cmd out 92 00; vm_cmd out 92 01; }   # the program left bit 0 set
vm_reboot fast_reset
vm_stop
