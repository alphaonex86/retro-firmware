# IBM Aptiva 2168-A90 (OPTi Viper-M, Pentium P54C on the 486 trees), sourced by build.sh: coreboot, SeaBIOS with
# its board code (NEWBIOS_BOARD_APTIVA2168).
# Needs the board's Trident TGUI9680 VGA BIOS (X5.3B, 32 KiB, not in git: it is IBM's), boards/aptiva2168/vgabios.bin
# (the Aptiva project's docs/bios-extract/trident_tgui9680_vgabios_X5.3B_1996-02-29.bin, or a link to it): in CBFS as
# pci1023,9660.rom.lzma, which SeaBIOS decompresses by that suffix.
# Output: out/aptiva2168.rom, the board's 128 KiB TN28F010 (also 86Box machine aptiva2168). No ESCD (PORT_PLAN D5).
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

tag=aptiva2168
seabios aptiva ""
coreboot_build $tag aptiva "CONFIG_PAYLOAD_BCJ_X86=y
# CONFIG_CONSOLE_SERIAL is not set
# CONFIG_BOOTBLOCK_CONSOLE is not set
# CONFIG_POSTCAR_CONSOLE is not set"
rom=$out/$tag.rom cbfs=("$(cb_obj $tag)/cbfstool" "$out/$tag.rom")
cp "$(cb_obj $tag)/coreboot.rom" "$rom"
free_bytes() { "${cbfs[@]}" print | awk '/empty/ {s += $4} END {print s + 0}'; }
"${cbfs[@]}" add -t optionrom -n pci1023,9660.rom.lzma -f "$vga" -c lzma > /dev/null \
  || { echo "BUILD FAILED: $tag, no room for the VGA BIOS ($(free_bytes) bytes free)" >&2; rm -f "$rom"; exit 1; }
"${cbfs[@]}" print > "$out/$tag.cbfs.txt"
size_map $tag aptiva
echo "$rom: $(free_bytes) bytes free"
