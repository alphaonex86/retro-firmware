#!/bin/bash
# Where the bytes of a ROM go, in Filelight: tools/rom_size_tree.py makes the tree in RAM (/dev/shm: no disk writes),
# Filelight shows it (its MiB are KiB of ROM), and the tree goes when Filelight closes. Each CONFIG option that
# tools/option_sizes.sh measured (run first when out/<rom>.options is older than the ROM) is a top-level directory
# of what it saves.
# usage: tools/filelight.sh [rom]   (default newbios: out/newbios.rom and out/newbios.size, written by build.sh)
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
rom=${1:-newbios}
[ -f "$nb/out/$rom.rom" ] && [ -f "$nb/out/$rom.size" ] || { echo "no out/$rom.rom or out/$rom.size: run build.sh" >&2; exit 1; }
[ "$nb/out/$rom.options" -nt "$nb/out/$rom.rom" ] || "$nb/tools/option_sizes.sh" "$rom"
tree=$(mktemp -d /dev/shm/rom-size.XXXXXX)
trap 'rm -rf "$tree"' EXIT
mapfile -t size < "$nb/out/$rom.size"   # cbfstool, nm, objdump, then the CBFS-NAME=ELF list
groups=()
while read -r name dir saved; do groups+=(-g "$name=$dir:$saved"); done < "$nb/out/$rom.options"
"$nb/tools/rom_size_tree.py" "${groups[@]}" "$nb/out/$rom.rom" "${size[0]}" "${size[1]}" "${size[2]}" "$tree/$rom" "${size[@]:3}"
filelight "$tree/$rom"
