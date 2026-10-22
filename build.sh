#!/bin/bash
# Build a board's firmware: coreboot (chipset init) + SeaBIOS (BIOS services, option ROMs, CMOS setup), from the
# coreboot and seabios submodules (fetch_sources.sh); builds go to build/, the submodules stay clean, ROMs to out/.
# The board's recipe, boards/<board>/firmware.sh, sets cb_mainboard (its directory in coreboot/src/mainboard) and
# cb_config (coreboot options), then calls seabios, coreboot_build and size_map and lays out its flash.
# usage: build.sh [board]   (default mb8433uud; the recipe documents its own variables, e.g. DEBUG=1, HALT_ON=n)
set -euo pipefail
nb=$(dirname "$(readlink -f "$0")")
board=${1:-mb8433uud}
bd=$nb/boards/$board
[ -f "$bd/firmware.sh" ] || { echo "BUILD REFUSED: no firmware recipe boards/$board/firmware.sh" >&2; exit 1; }
cb=$nb/coreboot
sb=$nb/seabios
out=$nb/out
mkdir -p "$out"

"$nb/fetch_sources.sh" firmware > /dev/null
"$nb/tools/build_toolchain.sh"
xgcc=$cb/util/crossgcc/xgcc/bin

fresh() {  # build dir, source tree: a dir built from another commit of the tree goes (its dependency files are stale)
  local c
  c=$(git -C "$2" rev-parse HEAD)
  [ "$(cat "$1/.commit" 2>/dev/null)" = "$c" ] || { rm -rf "${1:?}"; mkdir -p "$1"; echo "$c" > "$1/.commit"; }
}

seabios() {  # name, extra SeaBIOS config -> build/seabios/out-<name>/bios.bcj.elf (x86 BCJ filtered)
  local cfg=$nb/build/seabios/.config-$1 so=$nb/build/seabios/out-$1 log=$out/seabios-$1.build.log
  fresh "$so" "$sb"
  { cat "$cb/src/mainboard/$cb_mainboard/config_seabios" "$nb/seabios.config"; echo "$2"; } > "$cfg"
  local mk=(make -C "$sb" -s CROSS_PREFIX="$xgcc/i386-elf-" OUT="$so/" KCONFIG_CONFIG="$cfg")
  "${mk[@]}" olddefconfig > "$log" 2>&1
  "${mk[@]}" -j"$(nproc)" >> "$log" 2>&1 \
    || { tail -30 "$log"; echo "SEABIOS BUILD FAILED (log: $log)" >&2; exit 1; }
  "$nb/tools/bcj_x86.py" "$so/bios.bin.elf" "$so/bios.bcj.elf"   # undone by coreboot's loader
}

# Same host-tool/warning workarounds as build_variants.sh (gcc>=15 host, author's %u for size_t).
coreboot_build() {  # tag, SeaBIOS name, extra coreboot config -> build/coreboot/<tag>/coreboot.rom
  local tag=$1 cfg=$out/$1.config obj=$nb/build/coreboot/$1 log=$out/$1.build.log
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
CONFIG_PAYLOAD_FILE="$nb/build/seabios/out-$2/bios.bcj.elf"
CONFIG_COMPRESSED_PAYLOAD_LZMA=y
CONFIG_PAYLOAD_BCJ_X86=y
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

size_map() {  # tag, SeaBIOS name: where the bytes of out/<tag>.rom go, filelight out/size/<tag>
  local obj=$nb/build/coreboot/$1 st=$nb/build/coreboot/$1/cbfs/fallback so=$nb/build/seabios/out-$2
  "$nb/tools/rom_size_tree.py" "$out/$1.rom" "$obj/cbfstool" "$xgcc/i386-elf-nm" "$xgcc/i386-elf-objdump" "$out/size/$1" \
    bootblock="$st/bootblock.debug" fallback/romstage="$st/romstage.debug" fallback/postcar="$st/postcar.debug" \
    fallback/ramstage="$st/ramstage.debug" fallback/payload="$so/rom.o,$so/rom16.o@0xf0000"
}

. "$bd/firmware.sh"
