#!/bin/bash
# The real-board dump floppy (boards/aptiva2168/realdump) under the IBM BIOS on the emulated A90: past the fresh-CMOS
# Setup (continue, reload the factory settings, exit and save), the BIOS boots the floppy, the program writes DUMP.BIN,
# and its decode shows this board: byte sum OK, the chipset/VGA/IDE PCI IDs, the FDC37C933 at 370h, the 18 PnP
# nodes, and JP2 at 66 MHz read through the Super I/O GPIO (EAh/EBh, enabled by the BIOS's CR03).
# usage: boards/aptiva2168/test/realdump.sh   (PASS/FAIL, exit 1 on failure)
set -euo pipefail
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
nb=$(dirname "$(dirname "$bd")")
emu=$nb/build/86box/out/src/86Box
vm=$nb/test/vm/aptiva2168-realdump
fail() { echo "FAIL [aptiva2168 realdump]: $*"; exit 1; }
[ -f "$bd/BIOSORIGINAL.bin" ] || fail "no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"
[ -x "$emu" ] || "$nb/build_86box.sh" > /dev/null
"$bd/realdump/build.sh" > /dev/null

rm -rf "$vm"
mkdir -p "$vm/roms/machines/aptiva2168"
cp "$bd/BIOSORIGINAL.bin" "$vm/roms/machines/aptiva2168/BG2US0J.BIN"
cp "$nb/out/aptiva2168-realdump.img" "$vm/floppy.img"
cat > "$vm/86box.cfg" <<EOF
[Machine]
machine = aptiva2168
cpu_family = pentium_p54c
cpu_speed = 166666666
cpu_multi = 2.5
cpu_use_dynarec = 1
fpu_type = internal
mem_size = 16384

[Video]
gfxcard = internal

[Trident TGUI 9680XGi On-Board PCI #1]
memory = 1

[Input devices]
keyboard_type = keyboard_ps2
mouse_type = ps2

[Floppy and CD-ROM drives]
fdd_01_type = 35_2hd
fdd_01_fn = $vm/floppy.img
fdd_01_writeprot = 0
fdd_02_type = none
EOF
mkfifo "$vm/ctl"
while [ "$(pgrep -cx 86Box)" -ge "$(nproc)" ]; do sleep 0.5; done
exec {ctl}<>"$vm/ctl"
BOX86_TESTCTL=$vm/ctl SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  "$emu" -N -P "$vm" -R "$vm/roms" > "$vm/86box.log" 2>&1 & pid=$!
trap 'echo quit >&$ctl; sleep 1; kill -KILL $pid 2>/dev/null || true' EXIT

screen_has() { rm -f "$vm/screen.txt"; echo "text $vm/screen.txt" >&$ctl; sleep 0.3; grep -q "$1" "$vm/screen.txt" 2>/dev/null; }
wait_screen() {  # text, seconds
  for _ in $(seq $(($2 * 2))); do
    kill -0 $pid 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
    screen_has "$1" && return 0
    sleep 0.2
  done
  fail "no '$1' in $2 s"
}
wait_screen "IBM SurePath Setup Utility" 60
for key in 1c 1c 01 1c; do   # the error list: continue; CMOS error menu: factory settings; main menu: exit; save
  sleep 9
  echo "key $key" >&$ctl
done
wait_screen "realdump: done" 180

mcopy -o -i "$vm/floppy.img" ::DUMP.BIN "$vm/DUMP.BIN"
"$bd/realdump/decode.py" "$vm/DUMP.BIN" > "$vm/decode.txt"
for want in "byte sum [0-9A-F]* OK" "PCI 00:00.0 1045:C557" "PCI 00:01.0 1045:C558" "PCI 00:02.0 1023:9660" \
            "PCI 00:14.0 1045:C621" "Super I/O at 370h: device ID 02" "PnP function 00h: return 0000, 18 nodes" \
            "CR03 = 83, .*GP2x (index 2) FC (JP2 bus speed on GP21/GP20: 66 MHz)"; do
  grep -q "$want" "$vm/decode.txt" || fail "decode lacks /$want/ (see $vm/decode.txt)"
done
echo "PASS [aptiva2168 realdump]"
