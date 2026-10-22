#!/bin/bash
# BIOS update from Linux on the emulated A90 (86Box aptiva2168 with BOX86_FLASH=tn28f010: the operator's Intel
# TN28F010, 89h/B4h, and the 28F010 command register) under the IBM BIOS. Past the fresh-CMOS Setup, the BIOS boots
# an IDE disk whose SYSLINUX loads the test Linux (test/linux, 64 MB: it does not boot in the A90's 16 MB) and an
# initrd with the tools and images:
#  - flashrom (the flashrom submodule: OPTi Viper-M chipset enable, 28F010 quick-pulse algorithms) finds the chipset
#    and the 28F010 and reads the chip back as the IBM image;
#  - tools/bios-update.sh refuses a file of the wrong size, then writes a test image (bits set and cleared: erase and
#    program) that reads back identical; after a reset 86Box's flash file holds it;
#  - with VPP at 5 V (BOX86_FLASH_VPP=5: JP9 not at 1-2) the chip is a ROM: no chip found, nothing written.
# usage: boards/aptiva2168/test/flashlinux.sh   (PASS/FAIL, exit 1 on failure)
set -euo pipefail
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
nb=$(dirname "$(dirname "$bd")")
emu=$nb/build/86box/out/src/86Box
work=$nb/test/vm/aptiva2168-flashlinux
fail() { echo "FAIL [aptiva2168 flashlinux${vpp:+ $vpp}]: $*"; exit 1; }
[ -f "$bd/BIOSORIGINAL.bin" ] || fail "no $bd/BIOSORIGINAL.bin (the board's BIOS dump)"
[ -x "$emu" ] || "$nb/build_86box.sh" > /dev/null
"$nb/tools/build_flashrom.sh" > /dev/null || fail "flashrom does not build"
k=$nb/build/bzImage
[ -f "$k" ] && [ "$k" -nt "$nb/test/linux/init" ] && [ "$k" -nt "$nb/test/linux/kernel.config" ] \
  || "$nb/test/linux/build.sh" > /dev/null || fail "test Linux does not build"

rm -rf "$work"
mkdir -p "$work/initrd/flash"
f=$work/initrd/flash
cp "$nb/build/flashrom" "$f/flashrom"
cp "$nb/tools/bios-update.sh" "$f/bios-update"
cp "$bd/BIOSORIGINAL.bin" "$f/a.rom"
head -c 1000 "$f/a.rom" > "$f/bad.rom"
python3 -I - "$f/a.rom" "$f/b.rom" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[0x8000:0x8400] = bytes(x ^ 0xff for x in d[0x8000:0x8400])   # bits to set (an erase) and to clear
open(sys.argv[2], 'wb').write(d)
PY
(cd "$work/initrd" && find flash | cpio -o -H newc -R 0:0 --quiet) > "$work/flash.cpi"

disk() {  # image, kernel command line -> IDE disk (CHS 65/16/63): MBR, FAT16 partition with SYSLINUX, Linux, initrd
  local part=$((63 * 512))
  truncate -s $((65 * 16 * 63 * 512)) "$1"
  printf 'label: dos\nstart=63, type=6, bootable\n' | /sbin/sfdisk -q "$1"
  dd if=/usr/share/syslinux/mbr.bin of="$1" bs=440 count=1 conv=notrunc status=none
  mformat -i "$1@@$part" -T $((65 * 16 * 63 - 63)) -h 16 -s 63 -H 63 ::
  syslinux -t $part -i "$1"
  mcopy -i "$1@@$part" "$k" ::/bzimage
  mcopy -i "$1@@$part" "$work/flash.cpi" ::/flash.cpi
  printf 'DEFAULT linux\nLABEL linux\n  KERNEL bzimage\n  APPEND initrd=flash.cpi %s\n' "$2" \
    | mcopy -i "$1@@$part" - ::/syslinux.cfg
}

shot() {  # -> md5 of the screen's pixels, from a new 86Box screenshot
  local n=0 png
  [ -d "$vm/screenshots" ] && n=$(ls "$vm/screenshots" | wc -l)
  echo shot >&$ctl
  for _ in $(seq 100); do
    [ -d "$vm/screenshots" ] && [ "$(ls "$vm/screenshots" | wc -l)" -gt "$n" ] && break
    sleep 0.2
  done
  sleep 0.5
  png=$(ls -t "$vm/screenshots"/*.png) || return 1
  png=${png%%$'\n'*}
  magick "$png" rgb:- | md5sum
  rm "$png"
}

settled() {  # previous screen md5 -> the md5 of the screen once it differs and stays the same for 2 s (load-proof
             # key timing: the Setup takes ~10 s to act on a key, much longer on a loaded host)
  local now last=$1 same=0 end=$((SECONDS + 120))
  while [ $same -lt 2 ]; do
    [ $SECONDS -lt $end ] && kill -0 $pid 2>/dev/null || return 1
    sleep 1
    now=$(shot) || return 1
    if [ "$now" != "$last" ]; then same=0; elif [ "$now" != "$1" ]; then same=$((same + 1)); fi
    last=$now
  done
  echo "$now"
}

run() {  # VPP (12 or 5), kernel command line, line in the serial log that ends the test -> $vm (86Box powered off)
  vpp=$1
  vm=$work/vpp$1
  mkdir -p "$vm/roms/machines/aptiva2168"
  cp "$bd/BIOSORIGINAL.bin" "$vm/roms/machines/aptiva2168/BG2US0J.BIN"
  disk "$vm/hdd.img" "$2"
  cat > "$vm/86box.cfg" <<EOF
[Machine]
machine = aptiva2168
cpu_family = pentium_p54c
cpu_speed = 166666666
cpu_multi = 2.5
cpu_use_dynarec = 1
fpu_type = internal
mem_size = 65536

[Video]
gfxcard = internal

[Trident TGUI 9680XGi On-Board PCI #1]
memory = 1

[Input devices]
keyboard_type = keyboard_ps2
mouse_type = ps2

[Ports (COM & LPT)]
serial1_device = pipe

[Named Pipe (COM) #1]
path = $vm/com1

[Hard disks]
hdd_01_parameters = 63, 16, 65, 0, ide
hdd_01_fn = $vm/hdd.img
hdd_01_ide_channel = 0:0

[Floppy and CD-ROM drives]
fdd_01_type = 35_2hd
fdd_02_type = none
EOF
  mkfifo "$vm/ctl" "$vm/com1.out"
  while [ "$(pgrep -cx 86Box)" -ge "$(nproc)" ]; do sleep 0.5; done
  exec {ctl}<>"$vm/ctl"
  cat 0<>"$vm/com1.out" > "$vm/serial.log" & serial=$!
  BOX86_TESTCTL=$vm/ctl BOX86_FLASH=tn28f010 BOX86_FLASH_VPP=$1 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    "$emu" -N -P "$vm" -R "$vm/roms" > "$vm/86box.log" 2>&1 & pid=$!
  trap 'kill -KILL $pid $serial 2>/dev/null || true' EXIT

  local end=$((SECONDS + 60))
  until rm -f "$vm/screen.txt"; echo "text $vm/screen.txt" >&$ctl; sleep 0.5
      grep -q "IBM SurePath Setup Utility" "$vm/screen.txt" 2>/dev/null; do
    kill -0 $pid 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
    [ $SECONDS -lt $end ] || fail "no IBM SurePath Setup in 60 s"
  done
  local screen
  screen=$(settled "") || fail "the Setup screen did not settle"
  for key in 1c 1c 01 1c; do   # the error list: continue; CMOS error menu: factory settings; main menu: exit; save
    echo "key $key" >&$ctl
    screen=$(settled "$screen") || fail "the Setup did not take key $key"
  done
  end=$((SECONDS + 300))
  until grep -aq "$3" "$vm/serial.log"; do
    kill -0 $pid 2>/dev/null || fail "86Box exited (see $vm/86box.log)"
    [ $SECONDS -lt $end ] || { tail -20 "$vm/serial.log"; fail "Linux did not run the flash test in 300 s"; }
    sleep 1
  done
  echo reset >&$ctl   # a hard reset closes the devices: 86Box saves the chip (its power-off does not)
  for _ in $(seq 300); do [ -f "$vm/nvr/aptiva2168.bin" ] && break; sleep 0.1; done
  sleep 1
  echo quit >&$ctl
  for _ in $(seq 50); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  kill -KILL $pid $serial 2>/dev/null || true
  trap - EXIT
}

check_12v() {
  run 12 aptivaflash FLASHTEST-RC=
  local log=$vm/serial.log
  grep -aq 'Found chipset "OPTi 82C558M (Viper-M)"' "$log" || fail "flashrom did not find the Viper-M chipset"
  grep -aq 'Found Intel flash chip "28F010" (128 kB, Parallel)' "$log" || fail "flashrom did not find the 28F010"
  grep -aq "FLASHTEST-READ-RC=0" "$log" || fail "the chip did not read back as the IBM image"
  grep -aq "FLASHTEST-BAD-RC=1" "$log" || fail "a file of the wrong size was not refused"
  grep -aq "FLASHTEST-RC=0" "$log" || { grep -a "flashrom\|chip\|rror\|VPP\|FAIL" "$log"; fail "bios-update failed"; }
  cmp -s "$vm/nvr/aptiva2168.bin" "$f/b.rom" || fail "86Box's flash file does not hold the written image"
  grep -a "^Found \|Erasing and writing\|VERIFIED" "$log" | tr -d '\r' | sort | uniq -c | sed 's/^/flashrom: /'
  echo "PASS [aptiva2168 flashlinux]"
}

check_5v() {
  run 5 aptivaflash=novpp FLASHTEST-NOVPP-RC=
  grep -aq "FLASHTEST-NOVPP-RC=0" "$vm/serial.log" && fail "bios-update wrote without VPP"
  grep -aq "No EEPROM/flash device found" "$vm/serial.log" || fail "flashrom did not report a missing chip"
  cmp -s "$vm/nvr/aptiva2168.bin" "$f/a.rom" || fail "the chip changed without VPP"
  echo "PASS [aptiva2168 flashlinux VPP 5 V]"
}

check_12v & a=$!
check_5v & b=$!
status=0
wait $a || status=1
wait $b || status=1
exit $status
