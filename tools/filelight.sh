#!/bin/bash
# Where the bytes of a ROM go, in Filelight: tools/rom_size_tree.py makes the tree in RAM (/dev/shm: no disk writes),
# /dev/shm/rom-size/<rom> (MiB = KiB), kept until the next run or a reboot. Filelight counts 4 KiB disk blocks, so each
# file is 1024 times its ROM bytes: Filelight's MiB are KiB of ROM, as the directory name says. Each
# CONFIG option that tools/option_sizes.sh measured (run first when out/<rom>.options is older than the ROM) is a
# top-level directory of what it saves.
# usage: tools/filelight.sh [rom]   (default newbios: out/newbios.rom and out/newbios.size, written by build.sh)
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
rom=${1:-newbios}
[ -f "$nb/out/$rom.rom" ] && [ -f "$nb/out/$rom.size" ] || { echo "no out/$rom.rom or out/$rom.size: run build.sh" >&2; exit 1; }
[ "$nb/out/$rom.options" -nt "$nb/out/$rom.rom" ] || "$nb/tools/option_sizes.sh" "$rom"
tree=/dev/shm/rom-size
view="$tree/$rom (MiB = KiB)"
rm -rf "$view"
mkdir -p "$tree"
mapfile -t size < "$nb/out/$rom.size"   # cbfstool, nm, objdump, then the CBFS-NAME=ELF list
groups=()
while read -r name dir saved; do groups+=(-g "$name=$dir:$saved"); done < "$nb/out/$rom.options"
"$nb/tools/rom_size_tree.py" "${groups[@]}" "$nb/out/$rom.rom" "${size[0]}" "${size[1]}" "${size[2]}" "$view" "${size[@]:3}"
filelight "$view"
