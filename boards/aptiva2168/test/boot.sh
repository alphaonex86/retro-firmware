#!/bin/bash
# Boot test of the original IBM BIOS (boards/aptiva2168/BIOSORIGINAL.bin, BG2US0J, not in git) on the emulated Aptiva
# 2168 (86Box fork, machine aptiva2168, headless),
# one 86Box per CPU setting, in parallel, from an empty CMOS: the POST errors must be exactly the expected ones.
# 161/163: a new CMOS (its RTC reads VRT 0 once, as after a battery loss). 127: INT 15h AX=2305h fails, i.e. the
# measured CPU speed code (32 IDIV r32 timed by the PIT, EBDA:1C7h) has no entry whose bus speed matches the IBM
# jumper JP2 (Super I/O GPIO at EAh/EBh): P100 measures F3h past the BIOS's EFh limit, P75/P90 overflow the 16-bit tick
# count. A CPU it accepts reaches the SurePath Setup; otherwise
# the errors stay on the logo screen (POST 6Fh, waiting for F1). Screens are read by the local tesseract OCR (no AI).
# usage: boards/aptiva2168/test/boot.sh   (prints PASS/FAIL per CPU, exit 1 on any failure)
set -euo pipefail
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
nb=$(dirname "$(dirname "$bd")")
emu=$nb/build/86box/out/src/86Box
[ -f "$bd/BIOSORIGINAL.bin" ] || { echo "FAIL [aptiva2168 boot]: no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"; exit 1; }
[ -x "$emu" ] || "$nb/build_86box.sh" > /dev/null

ocr() {  # screenshot, crop geometry, imagemagick options making the text black on white -> its 3-digit error codes, sorted
  magick "$1" -crop "$2" +repage $3 -scale 300% pgm:- | tesseract - - --psm 6 2>/dev/null \
    | grep -oE '^ *[0-9]{3} ' | tr -d ' ' | sort | tr '\n' ' ' || true
}

boot() {  # name, cpu speed, multiplier, expected error codes (sorted)
  local vm=$nb/test/vm/aptiva2168-$1 pid shot found="" last="" stable=0
  rm -rf "$vm"
  mkdir -p "$vm/roms/machines/aptiva2168"
  cp "$bd/BIOSORIGINAL.bin" "$vm/roms/machines/aptiva2168/BG2US0J.BIN"
  cat > "$vm/86box.cfg" <<EOF
[Machine]
machine = aptiva2168
cpu_family = pentium_p54c
cpu_speed = $2
cpu_multi = $3
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

[Other peripherals]
postcard_enabled = 1
EOF
  mkfifo "$vm/ctl"
  while [ "$(pgrep -cx 86Box)" -ge "$(nproc)" ]; do sleep 0.5; done   # one emulator per core: timing checks
  exec {ctl}<>"$vm/ctl"
  BOX86_TESTCTL=$vm/ctl BOX86_POSTLOG=$vm/post.log SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    "$emu" -N -P "$vm" -R "$vm/roms" > "$vm/86box.log" 2>&1 & pid=$!
  local result="FAIL: neither the Setup nor the logo error screen in 120 s"
  for _ in $(seq 600); do
    rm -f "$vm/screen.txt"
    echo "text $vm/screen.txt" >&$ctl
    sleep 0.2
    kill -0 $pid 2>/dev/null || { result="FAIL: 86Box exited (see $vm/86box.log)"; break; }
    local code
    code=$(tail -n 1 "$vm/post.log" 2>/dev/null || true)
    [ "$code" = "$last" ] && stable=$((stable + 1)) || stable=0
    last=$code
    local layout=""
    grep -q 'IBM SurePath Setup Utility' "$vm/screen.txt" 2>/dev/null && layout=setup
    [ "$code" = 6F ] && [ $stable -ge 25 ] && layout=logo   # 5 s at 6Fh: waiting for F1 under the logo
    [ -n "$layout" ] || continue
    sleep 2   # the error list is drawn after the title
    echo shot >&$ctl
    for _ in $(seq 50); do shot=$(ls "$vm/screenshots/"*.png 2>/dev/null || true); [ -n "$shot" ] && break; sleep 0.1; done
    sleep 0.5
    if [ $layout = setup ]; then
      found=$(ocr "$shot" 520x90+100+150 "-threshold 30%")          # 720x400 text mode dialog: black on cyan
    else
      found=$(ocr "$shot" 300x64+0+32 "-threshold 50% -negate")      # 640x480 logo screen: white on black, top left
    fi
    [ "$found" = "$4 " ] && result="PASS ($layout: $found)" || result="FAIL: $layout errors [$found], expected [$4]"
    break
  done
  echo quit >&$ctl
  for _ in $(seq 50); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill -KILL $pid 2>/dev/null || true
  echo "$result [$1]"
  [ "${result%% *}" = PASS ]
}

pids=()   # the P54C settings of the Type I-2 board (HMM): 50, 60 and 66 MHz bus; the A90 itself is P166
for cpu in "p75_50mhz:75000000:1.5:127 161 163" "p90_60mhz:90000000:1.5:127 161 163" \
           "p100_66mhz:100000000:1.5:127 161 163" "p120_60mhz:120000000:2.0:161 163" \
           "p133_66mhz:133333333:2.0:161 163" "p150_60mhz:150000000:2.5:161 163" "p166_66mhz:166666666:2.5:161 163"; do
  IFS=: read -r name speed multi expected <<< "$cpu"
  boot "$name" "$speed" "$multi" "$expected" & pids+=($!)
done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
exit $status
