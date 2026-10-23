#!/bin/bash
# Board code apart (port of test/genericbuild.sh): the Aptiva's SeaBIOS (out/aptiva2168.rom's) holds nothing of the
# MB-8433UUD-A (names, UMC chipset UM88xx/UM8663), and SeaBIOS for a board without board code (NEWBIOS_BOARD_GENERIC)
# on the Aptiva's settings still builds and holds nothing of the Aptiva (name, Viper-M, FDC37C93x, JP2).
set -euo pipefail
nb=$(dirname "$(dirname "$(dirname "$(dirname "$(readlink -f "$0")")")")")
xgcc=$nb/coreboot-486/util/crossgcc/xgcc/bin
sb=$nb/build/seabios-486
[ -f "$sb/out-aptiva/bios.bin.raw" ] || "$nb/build.sh" aptiva2168 > /dev/null \
  || { echo "FAIL [aptiva2168 genericbuild]: build failed"; exit 1; }
found=$(strings -n 5 "$sb/out-aptiva/bios.bin.raw" | grep -E 'MB-8433|Biostar|UM88[0-9]|UM8663' || true)
[ -z "$found" ] || { echo "FAIL [aptiva2168 genericbuild]: MB-8433 strings in the Aptiva's SeaBIOS: $found"; exit 1; }

out=$sb/out-aptiva-generic cfg=$sb/out-aptiva-generic.config log=$nb/test/vm/aptiva2168-genericbuild.log
mkdir -p "$out" "$nb/test/vm"
{ cat "$nb/coreboot-486/src/mainboard/ibm/aptiva2168/config_seabios" "$nb/seabios.config" "$nb/boards/aptiva2168/seabios.config"
  printf '# CONFIG_NEWBIOS_BOARD_APTIVA2168 is not set\nCONFIG_NEWBIOS_BOARD_GENERIC=y\n'; } > "$cfg"
mk=(make -C "$nb/seabios-486" -s CROSS_PREFIX="$xgcc/i386-elf-" OUT="$out/" KCONFIG_CONFIG="$cfg")
"${mk[@]}" olddefconfig > "$log" 2>&1 && "${mk[@]}" -j"$(nproc)" >> "$log" 2>&1 \
  || { tail -20 "$log"; echo "FAIL [aptiva2168 genericbuild]: SeaBIOS GENERIC does not build (log: $log)"; exit 1; }
grep -q '^CONFIG_NEWBIOS_BOARD_GENERIC=y' "$cfg" && ! grep -q '^CONFIG_NEWBIOS_CHIPSET_OPTI_VIPERM=y' "$cfg" \
  || { echo "FAIL [aptiva2168 genericbuild]: the GENERIC board was not selected"; exit 1; }
found=$(strings -n 4 "$out/bios.bin.raw" | grep -E 'aptiva|Aptiva|82C55[78]M|FDC37C93x|JP2|OPTi' || true)
[ -z "$found" ] || { echo "FAIL [aptiva2168 genericbuild]: Aptiva strings in the GENERIC build: $found"; exit 1; }
echo "PASS [aptiva2168 genericbuild]"
