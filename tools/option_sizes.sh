#!/bin/bash
# What each SeaBIOS CONFIG option costs in a ROM: every setup tool (NEWBIOS_TOOL_*), all of them at once, and the
# existing options listed below that the ROM has on. Each is built off alone in build/<tree>/out-off-<option> from the
# ROM's SeaBIOS config; its payload replaces the ROM's in a copy (cbfstool, LZMA, as build.sh): the bytes saved in the
# compressed payload and the free space gained. Prints the table; with the default options also writes out/<rom>.options
# for tools/filelight.sh (option, its build, payload bytes saved) and out/<rom>.options.txt (the table).
# usage: tools/option_sizes.sh [rom [option...]]   (default newbios: out/<rom>.rom and out/<rom>.size, from build.sh;
#        default options: the above; "all" alone: only every NEWBIOS_TOOL_* off; JOBS=n builds at once, default nproc)
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
rom=${1:-newbios}
shift $(($# > 0))
[ -f "$nb/out/$rom.rom" ] && [ -f "$nb/out/$rom.size" ] || { echo "no out/$rom.rom or out/$rom.size: run build.sh" >&2; exit 1; }
mapfile -t size < "$nb/out/$rom.size"   # cbfstool, nm, objdump, then the CBFS-NAME=ELF list
cbfstool=${size[0]} xgcc=$(dirname "${size[1]}")
so=$(printf '%s\n' "${size[@]}" | sed -n 's|^fallback/payload=\(.*\)/rom\.o,.*|\1|p')
sb=$nb/$(basename "$(dirname "$so")")
[ -f "$so.config" ] && [ -d "$sb/src" ] || { echo "no SeaBIOS build of out/$rom.rom ($so): run build.sh" >&2; exit 1; }
elf=bios.bin.elf
grep -q '^CONFIG_PAYLOAD_BCJ_X86=y' "$nb/out/$rom.config" && elf=bios.bcj.elf
tools=$(sed -n 's/^ *config \(NEWBIOS_TOOL_[A-Z0-9_]*\)$/\1/p' "$sb/src/Kconfig")
candidates="USB_OHCI USB_UHCI USB_EHCI USB_MSC USB_UAS USB_HUB USB_MOUSE AHCI ATA_DMA FLOPPY SERIAL LPT CDROM_BOOT
  CDROM_EMU APMBIOS PNPBIOS MOUSE BOOTSPLASH BOOTORDER HOST_BIOS_GEOMETRY TCGBIOS"
list=$nb/out/$rom.options table=$nb/out/$rom.options.txt
[ $# -eq 0 ] || list=/dev/null table=/dev/null
if [ $# -eq 0 ]; then
  set -- $(for o in $tools $candidates; do grep -q "^CONFIG_$o=y" "$so.config" && echo "$o"; done)
fi

measure() {  # ELF, ROM copy -> "payload bytes, free bytes" with the ELF as the copy's payload; "- -" if it does not fit
  cp "$nb/out/$rom.rom" "$2"
  "$cbfstool" "$2" remove -n fallback/payload \
    && "$cbfstool" "$2" add-payload -n fallback/payload -f "$1" -c lzma > /dev/null 2>&1 || { echo "- -"; return; }
  "$cbfstool" "$2" print | awk '$1 == "fallback/payload" {p = $5} $1 == "(empty)" {f += $4} END {print p, f}'
}

variant() {  # option (all: every NEWBIOS_TOOL_*) -> $d.result: "option payload free" or "option FAIL"
  local o=$1 d=${so%/*}/out-off-$1 c
  c=$(git -C "$sb" rev-parse HEAD)
  [ "$(cat "$d/.commit" 2>/dev/null)" = "$c" ] || { rm -rf "${d:?}"; mkdir -p "$d"; echo "$c" > "$d/.commit"; }
  local mk=(make -C "$sb" -s CROSS_PREFIX="$xgcc/i386-elf-" OUT="$d/" KCONFIG_CONFIG="$d.config") want
  want=$(cat "$so.config"; for t in $([ "$o" = all ] && echo $tools || echo "$o"); do echo "# CONFIG_$t is not set"; done)
  : > "$d.log"
  if [ "$want" != "$(cat "$d/config.in" 2>/dev/null)" ]; then   # a new config: everything is built again
    rm -f "$d/config.in"
    echo "$want" > "$d.config"
    "${mk[@]}" olddefconfig >> "$d.log" 2>&1 && echo "$want" > "$d/config.in"
  fi
  if [ -f "$d/config.in" ] && "${mk[@]}" -j"$(nproc)" >> "$d.log" 2>&1 \
      && "$nb/tools/bcj_x86.py" "$d/bios.bin.elf" "$d/bios.bcj.elf" >> "$d.log" 2>&1; then
    echo "$o $(measure "$d/$elf" "$d/$rom.rom")" > "$d.result"
  else
    echo "$o FAIL" > "$d.result"
  fi
}

read -r base_payload base_free < <(measure "$so/$elf" "${so%/*}/out-off-$rom.rom")
cmp -s "${so%/*}/out-off-$rom.rom" "$nb/out/$rom.rom" \
  || echo "note: out/$rom.rom differs from its payload put in again ($so): the deltas are against the latter" >&2
opts=("$@")
[[ " $* " = *" all "* ]] || opts+=(all)
for o in "${opts[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "${JOBS:-$(nproc)}" ]; do wait -n; done
  rm -f "${so%/*}/out-off-$o.result"
  variant "$o" &
done
wait
part=.part   # the list and table replace the old ones only once complete
[ "$list" != /dev/null ] || part=
: > "$list$part"
row() {  # option -> its table line
  local name=CONFIG_$1 payload free
  [ "$1" = all ] && name="CONFIG_NEWBIOS_TOOL_*, all"
  read -r _ payload free < "${so%/*}/out-off-$1.result"
  if [ "$payload" = FAIL ]; then
    printf '%-36s %14s  %s\n' "$name" "build fails" "${so%/*}/out-off-$1.log"
  elif [ "$payload" = - ]; then
    printf '%-36s %14s\n' "$name" "does not fit"
  else
    printf '%-36s %14d %14d\n' "$name" $((base_payload - payload)) $((free - base_free))
    [ "$1" = all ] || echo "CONFIG_$1 ${so%/*}/out-off-$1 $((base_payload - payload))" >> "$list$part"
  fi
}
{
  printf '%-36s %14s %14s\n' "Off" "payload saved" "free gained"
  for o in "$@"; do [ "$o" = all ] || row "$o"; done | sort -k2,2nr
  row all
  echo "out/$rom.rom: payload $base_payload bytes (LZMA), free $base_free bytes"
} | tee "$table$part"
[ -z "$part" ] || { mv "$list.part" "$list"; mv "$table.part" "$table"; }
