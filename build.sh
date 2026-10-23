#!/bin/bash
# Build a board's firmware: coreboot (chipset init) + SeaBIOS (BIOS services, option ROMs, CMOS setup); builds go to
# build/<tree>/, the submodules stay clean, ROMs to out/. Each firmware base is a pair of submodules named after it
# (coreboot-486 + seabios-486: the 486 trees of pc2005cz; a Socket 7 or Slot 1 board may use other ones).
# The board's recipe, boards/<board>/firmware.sh, calls trees (its coreboot and SeaBIOS submodules), sets cb_mainboard
# (its directory in <coreboot>/src/mainboard), cb_config and sb_configs (SeaBIOS config files), then calls seabios,
# coreboot_build and size_map and lays out its flash. usage: build.sh [board]   (default mb8433uud; the recipe documents its variables, e.g. DEBUG=1)
set -euo pipefail
nb=$(dirname "$(readlink -f "$0")")
board=${1:-mb8433uud}
bd=$nb/boards/$board
[ -f "$bd/firmware.sh" ] || { echo "BUILD REFUSED: no firmware recipe boards/$board/firmware.sh" >&2; exit 1; }
out=$nb/out
mkdir -p "$out"
"$nb/fetch_sources.sh" firmware > /dev/null
# Version strings with 12-digit hashes: git's own abbreviation grows with the objects of each clone, so two clones of
# one commit made different ROMs.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=12

trees() {  # coreboot submodule, SeaBIOS submodule: the trees of this board, and the coreboot tree's cross compiler
  cb=$nb/$1 sb=$nb/$2
  [ -d "$cb/src" ] && [ -d "$sb/src" ] || { echo "BUILD REFUSED: no submodule $1 or $2" >&2; exit 1; }
  "$nb/tools/build_toolchain.sh" "$cb"
  xgcc=$cb/util/crossgcc/xgcc/bin
}
cb_obj() { echo "$nb/build/${cb##*/}/$1"; }          # tag -> coreboot build dir
sb_out() { echo "$nb/build/${sb##*/}/out-$1"; }      # SeaBIOS name -> its build dir

fresh() {  # build dir, source tree: a dir built from another state of the tree (commit or uncommitted changes) goes:
  local c   # its dependency files are stale (e.g. after a Kconfig change)
  c=$(git -C "$2" rev-parse HEAD
      { git -C "$2" diff HEAD; git -C "$2" ls-files -z --others --exclude-standard | (cd "$2" && xargs -0r cat); } | sha1sum)
  [ "$(cat "$1/.commit" 2>/dev/null)" = "$c" ] || { rm -rf "${1:?}"; mkdir -p "$1"; echo "$c" > "$1/.commit"; }
}

seabios() {  # name, extra SeaBIOS config -> $(sb_out name)/bios.bcj.elf (x86 BCJ filtered)
  local so cfg log=$out/seabios-$1.build.log
  so=$(sb_out "$1") cfg=$(sb_out "$1").config
  fresh "$so" "$sb"
  { cat "${sb_configs[@]}"; echo "$2"; } > "$cfg"
  local mk=(make -C "$sb" -s CROSS_PREFIX="$xgcc/i386-elf-" OUT="$so/" KCONFIG_CONFIG="$cfg")
  "${mk[@]}" olddefconfig > "$log" 2>&1
  "${mk[@]}" -j"$(nproc)" >> "$log" 2>&1 \
    || { tail -30 "$log"; echo "SEABIOS BUILD FAILED (log: $log)" >&2; exit 1; }
  "$nb/tools/bcj_x86.py" "$so/bios.bin.elf" "$so/bios.bcj.elf"   # undone by coreboot's loader
}

# Same host-tool/warning workarounds as build_variants.sh (gcc>=15 host, author's %u for size_t).
coreboot_build() {  # tag, SeaBIOS name, extra coreboot config -> $(cb_obj tag)/coreboot.rom
  local tag=$1 cfg=$out/$1.config obj log=$out/$1.build.log elf=bios.bin.elf
  obj=$(cb_obj "$1")
  [[ $3 == *CONFIG_PAYLOAD_BCJ_X86=y* ]] && elf=bios.bcj.elf   # the payload x86 BCJ filtered: the 486 tree undoes it
  fresh "$obj" "$cb"
  { cat "$cb_config"; cat <<EOF
# CONFIG_DEBUG_HW_BREAKPOINTS is not set
# CONFIG_DEBUG_NULL_DEREF_BREAKPOINTS is not set
# CONFIG_DEBUG_CBFS is not set
# CONFIG_DEBUG_PIRQ is not set
# CONFIG_DEFAULT_CONSOLE_LOGLEVEL_8 is not set
CONFIG_DEFAULT_CONSOLE_LOGLEVEL_4=y
# CONFIG_PAYLOAD_SEABIOS is not set
CONFIG_PAYLOAD_ELF=y
CONFIG_PAYLOAD_FILE="$(sb_out "$2")/$elf"
CONFIG_COMPRESSED_PAYLOAD_LZMA=y
CONFIG_POST_DEVICE=y
CONFIG_POST_IO=y
# CONFIG_DECOMPRESS_OFAST is not set
$3
EOF
  } > "$cfg"
  local mk=(make -C "$cb" -s DOTCONFIG="$cfg" obj="$obj" HOSTCFLAGS="-g -Wno-error" WERROR= CONFIG_WARNINGS_ARE_ERRORS=)
  "${mk[@]}" olddefconfig > "$log" 2>&1
  "${mk[@]}" -j"$(nproc)" >> "$log" 2>&1 \
    || { tail -30 "$log"; echo "BUILD FAILED: $tag (log: $log)" >&2; exit 1; }
}

size_map() {  # tag, SeaBIOS name -> out/<tag>.size: tools and ELFs of the ROM's parts, for tools/filelight.sh
  local st so
  st=$(cb_obj "$1")/cbfs/fallback so=$(sb_out "$2")
  printf '%s\n' "$(cb_obj "$1")/cbfstool" "$xgcc/i386-elf-nm" "$xgcc/i386-elf-objdump" \
    "bootblock=$st/bootblock.debug" "fallback/romstage=$st/romstage.debug" "fallback/postcar=$st/postcar.debug" \
    "fallback/ramstage=$st/ramstage.debug" "fallback/payload=$so/rom.o,$so/rom16.o@0xf0000" > "$out/$1.size"
}

. "$bd/firmware.sh"
