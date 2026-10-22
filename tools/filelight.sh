#!/bin/bash
# Where the bytes of a ROM go, in Filelight: tools/rom_size_tree.py makes the tree in RAM (/dev/shm: no disk writes),
# Filelight shows it (its MiB are KiB of ROM), and the tree goes when Filelight closes.
# usage: tools/filelight.sh [rom]   (default newbios: out/newbios.rom and out/newbios.size, written by build.sh)
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
rom=${1:-newbios}
[ -f "$nb/out/$rom.rom" ] && [ -f "$nb/out/$rom.size" ] || { echo "no out/$rom.rom or out/$rom.size: run build.sh" >&2; exit 1; }
xgcc=$nb/coreboot/util/crossgcc/xgcc/bin
tree=$(mktemp -d /dev/shm/rom-size.XXXXXX)
trap 'rm -rf "$tree"' EXIT
mapfile -t elfs < "$nb/out/$rom.size"
"$nb/tools/rom_size_tree.py" "$nb/out/$rom.rom" "$nb/build/coreboot/$rom/cbfstool" "$xgcc/i386-elf-nm" \
  "$xgcc/i386-elf-objdump" "$tree/$rom" "${elfs[@]}"
filelight "$tree/$rom"
