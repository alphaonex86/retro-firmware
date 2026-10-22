#!/bin/bash
# Setup tools compiled out (CONFIG_NEWBIOS_TOOL_*): out/newbios.rom's SeaBIOS with each tool off alone and with all of
# them off (tools/option_sizes.sh) builds, fits in the ROM, is smaller and lacks the tool's menu title; out/p3bf.rom's
# (seabios-mainline) with all off too. In 86Box: with all off the main menu has no tool menus and still works; with
# MEMORY TEST off the HARDWARE TESTS menu skips it.
. "$(dirname "$0")/lib.sh"
mkdir -p "$vm_dir"
so=$nb/build/seabios-486
tools=$(sed -n 's/^ *config \(NEWBIOS_TOOL_[A-Z0-9_]*\)$/\1/p' "$nb/seabios-486/src/Kconfig")
[ -n "$tools" ] || fail "no NEWBIOS_TOOL_* in seabios-486/src/Kconfig"
JOBS=2 "$nb/tools/option_sizes.sh" newbios $tools > "$vm_dir/sizes.txt" 2>&1 \
  || { cat "$vm_dir/sizes.txt"; fail "tools/option_sizes.sh"; }
JOBS=2 "$nb/tools/option_sizes.sh" p3bf all > "$vm_dir/sizes-p3bf.txt" 2>&1 \
  || { cat "$vm_dir/sizes-p3bf.txt"; fail "tools/option_sizes.sh p3bf"; }
for t in $tools "NEWBIOS_TOOL_\*, all"; do
  grep -Eq "^CONFIG_$t +[1-9][0-9]* +[0-9]+$" "$vm_dir/sizes.txt" \
    || { cat "$vm_dir/sizes.txt"; fail "CONFIG_$t off: no build, no fit or nothing saved"; }
done
grep -Eq "^CONFIG_NEWBIOS_TOOL_\*, all +[1-9][0-9]* +[0-9]+$" "$vm_dir/sizes-p3bf.txt" \
  || { cat "$vm_dir/sizes-p3bf.txt"; fail "P3B-F without the tools: no build, no fit or nothing saved"; }

titles() {  # SeaBIOS build dir, file -> the strings of its image, one per line
  strings -n 4 "$1/bios.bin.raw" > "$2"
}
# the tool menus' entries: "#if CONFIG_NEWBIOS_TOOL_X" then '    { "TITLE", ...'
awk '/^#if CONFIG_NEWBIOS_TOOL_/ {t = substr($2, 8); next} t && match($0, /^    \{ "[^"]*"/) {print t "\t" substr($0, 8, RLENGTH - 8)} {t = ""}' \
  "$nb/seabios-486/src/setup.c" > "$vm_dir/titles.txt"
[ "$(wc -l < "$vm_dir/titles.txt")" = "$(echo $tools | wc -w)" ] || fail "not one menu entry per tool: $(cat "$vm_dir/titles.txt")"
titles "$so/out-rel" "$vm_dir/base.txt"
titles "$so/out-off-all" "$vm_dir/all.txt"
while IFS=$'\t' read -r t title; do
  grep -qxF "$title" "$vm_dir/base.txt" || fail "$title not in the ROM's SeaBIOS ($so/out-rel)"
  titles "$so/out-off-$t" "$vm_dir/off.txt"
  grep -qxF "$title" "$vm_dir/off.txt" && fail "$title still in SeaBIOS without CONFIG_$t"
  grep -qxF "$title" "$vm_dir/all.txt" && fail "$title still in SeaBIOS without the tools"
done < "$vm_dir/titles.txt"

main_menu=("STANDARD CMOS SETUP" "BIOS FEATURES SETUP" "CHIPSET FEATURES SETUP" "POWER MANAGEMENT SETUP"
           "PNP/PCI CONFIGURATION" "INTEGRATED PERIPHERALS" "SUPERVISOR PASSWORD" "LOAD BIOS DEFAULTS"
           "LOAD SETUP DEFAULTS" "SAVE & EXIT SETUP" "EXIT WITHOUT SAVING")
vm_start tooloptions "$so/out-off-all/newbios.rom"
vm_end_of_post 60
vm_setup
for m in "${main_menu[@]}"; do vm_expect "$m"; done
for m in "HARDWARE INFORMATION" "BENCHMARKS" "HARDWARE TESTS"; do
  grep -q "$m" "$vm/screen.txt" && fail "main menu still has $m"
done
vm_key $K_DOWN $K_ENTER                           # BIOS FEATURES SETUP
vm_wait_text "Boot Up NumLock Status" 5
vm_key $K_ESC
vm_wait_text "CMOS SETUP UTILITY" 5
vm_key $K_UP $K_UP $K_ENTER                       # wraps to the last entry: EXIT WITHOUT SAVING
vm_wait_text "Quit Without Saving \(Y/N\)\?" 5
vm_stop

vm_start tooloptions-memtest "$so/out-off-NEWBIOS_TOOL_MEMTEST/newbios.rom"
vm_end_of_post 60
vm_setup
for m in "${main_menu[@]}" "HARDWARE INFORMATION" "BENCHMARKS" "HARDWARE TESTS"; do vm_expect "$m"; done
vm_menu 9                                         # HARDWARE TESTS
vm_wait_text "Enter : Open" 5
vm_expect "BOARD TEST"
vm_expect "HDD SURFACE SCAN"
grep -q "MEMORY TEST" "$vm/screen.txt" && fail "HARDWARE TESTS still has MEMORY TEST"
vm_key $K_DOWN $K_ENTER                           # second entry: CACHE TEST
vm_wait_text "Policy +Timing +Tag" 10
vm_stop
