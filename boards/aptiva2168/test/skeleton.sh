#!/bin/bash
# Port step 3 gate: our ROM (out/aptiva2168.rom) on the emulated Aptiva 2168 (86Box machine aptiva2168, headless)
# sends exactly the bootblock and cache-as-RAM POST codes, the CAR self-test passes (29h, never 2Ah) and romstage is
# reached (30h, where the skeleton halts); the romstage code also arrives on COM1 (FDC37C93x enabled by the
# bootblock), and post_once finds no reset. Not a CAR proof: no SIMM pair is set, so 86Box RAM stays flat, and it has
# no P5 L1 model: writes outside L1 still land in RAM and the self-test cannot fail here. With the opti55x DRAM model
# on (a SIMM pair, as vm_start sets for aptiva2168), 13h = 88h leaves no DRAM behind the range and the self-test
# fails (2Ah) until 86Box has the P5 CAR model (port step 2): hence this test's own VM start.
# usage: boards/aptiva2168/test/skeleton.sh
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_name=skeleton vm=$nb/test/vm/aptiva2168-skeleton
expected="01 03 04 10 21 22 23 26 29 27 28 14 15 16 17 18 19 30"

rm -rf "$vm"
mkdir -p "$vm/roms/machines/aptiva2168"
cp "$rom" "$vm/roms/machines/aptiva2168/BG2US0J.BIN"
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

[Ports (COM & LPT)]
serial1_device = pipe

[Other peripherals]
postcard_enabled = 1

[Named Pipe (COM) #1]
path = $vm/com1
EOF
mkfifo "$vm/ctl" "$vm/com1.out"
while [ "$(pgrep -cx 86Box)" -ge "$(nproc)" ]; do sleep 0.5; done   # one emulator per core
exec {vm_ctl}<>"$vm/ctl"
cat 0<>"$vm/com1.out" > "$vm/serial.log" & vm_serial=$!
BOX86_TESTCTL=$vm/ctl BOX86_POSTLOG=$vm/post.log SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  "$emu" -N -X both -P "$vm" -R "$vm/roms" > "$vm/86box.log" 2>&1 & vm_pid=$!
trap vm_kill EXIT

codes() { grep -E '^[0-9A-F]{2}$' "$vm/post.log" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ $//'; }
for _ in $(seq 300); do
  [ "$(codes | sed 's/.* //')" = 30 ] && break
  kill -0 "$vm_pid" 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
  sleep 0.1
done
sleep 1   # the skeleton halts at 30h: nothing may follow
[ "$(codes)" = "$expected" ] || fail "POST codes: $(codes) - expected: $expected"
grep -q "^30\$" <(tr -d '\r' < "$vm/serial.log") || fail "no romstage POST code on COM1: $(tr '\r\n' '  ' < "$vm/serial.log")"
vm_stop
