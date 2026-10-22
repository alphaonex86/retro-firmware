# ASUS P3B-F (Intel 440BX + PIIX4E, Slot 1 Pentium II/III, Winbond W83977 Super I/O), sourced by build.sh: mainline
# coreboot (mainboard asus/p2b, variant p3b-f) + SeaBIOS. No CPU microcode in CBFS: with it the ROM does not fit.
# Output: out/p3bf.rom, the board's 256 KiB SST39SF020 (also 86Box machine p3bf).
trees coreboot-mainline seabios-mainline
cb_mainboard=asus/p2b
cb_config=$bd/coreboot.config
sb_configs=("$nb/seabios.config" "$bd/seabios.config")

seabios p3bf ""
coreboot_build p3bf p3bf ""
cp "$(cb_obj p3bf)/coreboot.rom" "$out/p3bf.rom"
"$(cb_obj p3bf)/cbfstool" "$out/p3bf.rom" print > "$out/p3bf.cbfs.txt"
size_map p3bf p3bf
echo "$out/p3bf.rom: $(awk '/empty/ {s += $4} END {print s}' "$out/p3bf.cbfs.txt") bytes free"
