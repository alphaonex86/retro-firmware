# IBM Aptiva 2168-A90 (OPTi Viper-M, Pentium P54C on the 486 trees), sourced by build.sh: coreboot, SeaBIOS with
# its board code (NEWBIOS_BOARD_APTIVA2168).
# Needs the board's Trident TGUI9680 VGA BIOS (X5.3B, 32 KiB, not in git: it is IBM's), boards/aptiva2168/vgabios.bin
# (the Aptiva project's docs/bios-extract/trident_tgui9680_vgabios_X5.3B_1996-02-29.bin, or a link to it): in CBFS as
# pci1023,9660.rom.lzma, which SeaBIOS decompresses by that suffix.
# Output: out/aptiva2168.rom, the board's 128 KiB TN28F010 (also 86Box machine aptiva2168). No ESCD (PORT_PLAN D5).
# out/aptiva2168-bringup.rom: the same boot path with coreboot's console and SeaBIOS's log on COM1 (115200 8N1) for
# the first runs on the board (BRINGUP.md); the setup's diagnostic tools make room for them.
trees coreboot-486 seabios-486
cb_mainboard=ibm/aptiva2168
cb_config=$bd/coreboot.config
sb_configs=("$cb/src/mainboard/$cb_mainboard/config_seabios" "$nb/seabios.config" "$bd/seabios.config")

h=mainboard/$cb_mainboard/post_serial.h   # the POST code line on COM1, one copy in each tree
cmp -s "$sb/src/${h##*/}" "$cb/src/$h" || { echo "BUILD REFUSED: ${sb##*/}/src/${h##*/} and ${cb##*/}/src/$h differ" >&2; exit 1; }

vga=$bd/vgabios.bin vga_sha256=0021d720843ad5338b0a2acd45ee93c04bc52e775d5f68e8a7d926b0e1a14e2a
[ -f "$vga" ] || { echo "BUILD REFUSED: no $vga (the board's Trident VGA BIOS X5.3B)" >&2; exit 1; }
[ "$(sha256sum < "$vga" | cut -d' ' -f1)" = $vga_sha256 ] \
  || { echo "BUILD REFUSED: $vga is not the Trident VGA BIOS X5.3B (sha256)" >&2; exit 1; }

rom() {  # tag, SeaBIOS name, extra coreboot config -> out/<tag>.rom with the VGA BIOS; fails when it does not fit
  local tag=$1 rom=$out/$1.rom cbfs=("$(cb_obj "$1")/cbfstool" "$out/$1.rom")
  coreboot_build "$@"
  cp "$(cb_obj "$tag")/coreboot.rom" "$rom"
  "${cbfs[@]}" add -t optionrom -n pci1023,9660.rom.lzma -f "$vga" -c lzma > /dev/null \
    || { echo "BUILD FAILED: $tag, no room for the VGA BIOS" >&2; "${cbfs[@]}" print >&2; rm -f "$rom"; exit 1; }
  "${cbfs[@]}" print > "$out/$tag.cbfs.txt"
  size_map "$tag" "$2"
  echo "$rom: $(awk '/empty/ {s += $4} END {print s + 0}' "$out/$tag.cbfs.txt") bytes free"
}

seabios aptiva ""
rom aptiva2168 aptiva "CONFIG_PAYLOAD_BCJ_X86=y
# CONFIG_CONSOLE_SERIAL is not set
# CONFIG_BOOTBLOCK_CONSOLE is not set
# CONFIG_POSTCAR_CONSOLE is not set"

# Bring-up: the setup's diagnostic tools out, SeaBIOS's level 3 log (PCI, USB, drives, option ROMs) and coreboot's
# console at INFO: stages, CAR, DRAM sizing (6, as 7 does not fit with level 3). postcar's console (4.5 KB) does not fit
# either: its POST codes 3C 3D 38 show it on COM1.
seabios aptiva-bringup "# CONFIG_NEWBIOS_TOOL_INFO_CPU is not set
# CONFIG_NEWBIOS_TOOL_INFO_PCI is not set
# CONFIG_NEWBIOS_TOOL_INFO_USB is not set
# CONFIG_NEWBIOS_TOOL_INFO_ISA is not set
# CONFIG_NEWBIOS_TOOL_INFO_IDE is not set
# CONFIG_NEWBIOS_TOOL_CHIPSET_REGS is not set
# CONFIG_NEWBIOS_TOOL_BENCH_MEMORY is not set
# CONFIG_NEWBIOS_TOOL_BENCH_CPU is not set
# CONFIG_NEWBIOS_TOOL_BENCH_DISK is not set
# CONFIG_NEWBIOS_TOOL_BENCH_DISK_SPEED is not set
# CONFIG_NEWBIOS_TOOL_MEMTEST is not set
# CONFIG_NEWBIOS_TOOL_SURFACE_SCAN is not set
CONFIG_DEBUG_LEVEL=3
CONFIG_DEBUG_SERIAL=y
CONFIG_DEBUG_SERIAL_PORT=0x3f8"
rom aptiva2168-bringup aptiva-bringup "CONFIG_PAYLOAD_BCJ_X86=y
CONFIG_CONSOLE_SERIAL=y
CONFIG_CONSOLE_SERIAL_115200=y
CONFIG_BOOTBLOCK_CONSOLE=y
# CONFIG_POSTCAR_CONSOLE is not set
CONFIG_DEFAULT_CONSOLE_LOGLEVEL_6=y"
