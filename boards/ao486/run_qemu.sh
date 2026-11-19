#!/bin/bash
# Boots out/ao486.rom in QEMU's ISA PC, the closest emulated machine to the ao486 core: 486, 64 MiB, ISA IDE, the
# VGA BIOS in place at C0000 (as the core's daemon loads it).
# usage: boards/ao486/run_qemu.sh <disk.img> <vga_bios.rom> [qemu options]   (retroDE_ao486's bios/boot1_opensource.rom)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../.."
disk=${1:?usage: $0 <disk.img> <vga_bios.rom>}; vga=${2:?usage: $0 <disk.img> <vga_bios.rom>}; shift 2
exec qemu-system-i386 -M isapc -cpu 486 -m 64 -bios out/ao486.rom -drive file="$disk",format=raw,if=ide \
    -device loader,file="$vga",addr=0xc0000,force-raw=on "$@"
