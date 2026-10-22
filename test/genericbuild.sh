#!/bin/bash
# SeaBIOS for a board without board-specific code (NEWBIOS_BOARD_GENERIC, the starting point of a port) still
# builds, links, and holds nothing of the MB-8433UUD-A: names, UMC chipset (UM88xx/UM8663), its flash's ESCD.
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
xgcc=$nb/coreboot-486/util/crossgcc/xgcc/bin
out=$nb/build/seabios-486/out-generic cfg=$nb/build/seabios-486/out-generic.config log=$nb/test/vm/genericbuild.log
mkdir -p "$out" "$nb/test/vm"
{ cat "$nb/coreboot-486/src/mainboard/biostar/mb8433/config_seabios" "$nb/seabios.config"
  printf '# CONFIG_NEWBIOS_BOARD_MB8433 is not set\nCONFIG_NEWBIOS_BOARD_GENERIC=y\n'; } > "$cfg"
mk=(make -C "$nb/seabios-486" -s CROSS_PREFIX="$xgcc/i386-elf-" OUT="$out/" KCONFIG_CONFIG="$cfg")
"${mk[@]}" olddefconfig > "$log" 2>&1 && "${mk[@]}" -j"$(nproc)" >> "$log" 2>&1 \
  || { tail -20 "$log"; echo "FAIL [genericbuild]: SeaBIOS GENERIC does not build (log: $log)"; exit 1; }
grep -q '^CONFIG_NEWBIOS_BOARD_GENERIC=y' "$cfg" && ! grep -q '^CONFIG_NEWBIOS_CHIPSET_UMC=y' "$cfg" \
  || { echo "FAIL [genericbuild]: the GENERIC board was not selected"; exit 1; }
found=$(strings -n 5 "$out/bios.bin.raw" | grep -E 'MB-8433|Biostar|UM88[0-9]|UM8663' || true)
[ -z "$found" ] || { echo "FAIL [genericbuild]: board strings in the GENERIC build: $found"; exit 1; }
echo "PASS [genericbuild]"
