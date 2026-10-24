#!/bin/bash
# NBMON payload build: payload.sh x.c ADDR -> x.bin, flat, linked at ADDR (hex) with its NBMON_ENTRY function first
# (nbmon_api.h), for "ld" and "call ADDR": 32-bit freestanding, Pentium code (the P54C has no CMOV). CC: the compiler.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 x.c ADDR" >&2; exit 1; }
src=$1 addr=$((16#${2#0x})) out=${1%.c}.bin elf=${1%.c}.elf ld=${1%.c}.ld
printf 'SECTIONS { . = %#x; .text : { *(.text.nbmon_entry) *(.text*) *(.rodata*) *(.data*) *(.bss*) *(COMMON) }\n /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) } }\n' \
  "$addr" > "$ld"
${CC:-gcc} -m32 -march=i586 -Os -ffreestanding -fno-pic -fno-stack-protector -fno-asynchronous-unwind-tables \
  -fcf-protection=none -nostdlib -static -Wl,--build-id=none -Wl,-T,"$ld" -I "$(dirname "$(readlink -f "$0")")" \
  -o "$elf" "$src"
rm "$ld"
entry=$(nm "$elf" | awk '$2 ~ /[Tt]/ {print $1, $3}' | sort | head -n 1)
[ $((16#${entry%% *})) = "$addr" ] || { echo "payload.sh: the first function ($entry) is not at $2" >&2; exit 1; }
objcopy -O binary "$elf" "$out"
echo "$out"
