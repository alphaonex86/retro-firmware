#!/bin/bash
# Boot test of out/p3bf.rom (mainline coreboot + our SeaBIOS) on the 86Box fork's ASUS P3B-F (Pentium II 400, 128 MB,
# no disk, headless): the POST screen shows the memory, the fresh CMOS stops at "Press F1", F1 goes on to the boot,
# and SeaBIOS reports that nothing can boot.
# usage: boards/p3bf/test/boot.sh
set -euo pipefail
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
nb=$(dirname "$(dirname "$bd")")
emu=$nb/build/86box/out/src/86Box
vm=$nb/test/vm/p3bf-boot
[ -f "$nb/out/p3bf.rom" ] || { echo "FAIL [p3bf boot]: no out/p3bf.rom (build.sh p3bf)"; exit 1; }
[ -x "$emu" ] || "$nb/build_86box.sh" > /dev/null
rm -rf "$vm"
mkdir -p "$vm/roms/machines/p3bf"
cp "$nb/out/p3bf.rom" "$vm/roms/machines/p3bf/1008f.004"
cat > "$vm/86box.cfg" <<CFG
[Machine]
machine = p3bf
cpu_family = pentium2_deschutes
cpu_speed = 400000000
cpu_multi = 4
cpu_use_dynarec = 1
fpu_type = internal
mem_size = 131072

[Video]
gfxcard = cl_gd5434_pci

[Input devices]
keyboard_type = keyboard_ps2
mouse_type = ps2

[Other peripherals]
postcard_enabled = 1
CFG
mkfifo "$vm/ctl"
exec {ctl}<>"$vm/ctl"
while [ "$(pgrep -cx 86Box)" -ge "$(nproc)" ]; do sleep 0.5; done   # one emulator per core: timing checks
BOX86_TESTCTL=$vm/ctl BOX86_POSTLOG=$vm/post.log SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  "$emu" -N -P "$vm" -R "$vm/roms" > "$vm/86box.log" 2>&1 & pid=$!
wait_text() {  # regex, timeout seconds -> 0 when the text screen shows it
  for _ in $(seq $(($2 * 5))); do
    rm -f "$vm/screen.txt"
    echo "text $vm/screen.txt" >&$ctl
    sleep 0.2
    kill -0 $pid 2>/dev/null || return 1
    grep -Eq "$1" "$vm/screen.txt" 2>/dev/null && return 0
  done
  return 1
}
result="PASS [p3bf boot]"
if ! wait_text 'Press F1 to continue' 60; then
  result="FAIL [p3bf boot]: no POST screen with the CMOS error in 60 s (POST codes: $vm/post.log)"
elif ! grep -q 'Extended Memory  : 130048K' "$vm/screen.txt"; then
  result="FAIL [p3bf boot]: POST screen without the 128 MB (screen: $vm/screen.txt)"
else
  echo "key 3b" >&$ctl   # F1
  wait_text 'No bootable device' 30 || result="FAIL [p3bf boot]: F1 did not lead to the boot (screen: $vm/screen.txt)"
fi
echo quit >&$ctl
for _ in $(seq 50); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill -KILL $pid 2>/dev/null || true
echo "$result"
[ "${result%% *}" = PASS ]
