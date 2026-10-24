#!/bin/bash
# No DRAM refresh request (port 61h bit 4 never toggles, BOX86_REFRESH_DEAD=1): romstage halts at POST 3Fh before the
# DRAM sizing, as the IBM BIOS stops with beep 1-2-4 (F000:0574); with refresh it goes on (32h).
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-refresh
mkdir -p "$vm_dir"
BOX86_REFRESH_DEAD=1 vm_machine=aptiva2168 vm_start "aptiva2168 refresh" "$rom"
for _ in $(seq 100); do grep -q '^3F$' "$vm/post.log" 2>/dev/null && break; sleep 0.1; done
sleep 3
codes=$(grep -E '^[0-9A-F]{2}$' "$vm/post.log" | tr '\n' ' ')
[[ $codes == *" 30 3F " ]] || fail "POST codes: $codes - expected to end with 30 3F"
vm_kill
trap - EXIT
echo "PASS [$vm_name]"
