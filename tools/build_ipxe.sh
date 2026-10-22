#!/bin/bash
# iPXE for the RTL8139 (realtek driver: RTL8139, 8139C+, 8169, plus the 10ec:8039 clone, in the ipxe submodule), config
# configs/ipxe. build/nic-rtl8139-ipxe-64k.rom: the card's socket ROM (64 KiB chip, 0xFF padded; its EEPROM must select
# 64 KiB: tools/rtl8139-bootrom 64), script configs/ipxe/nic-rom.ipxe (DHCP, then pxelinux.0 by TFTP).
# build/ipxe-chain.pxe, tests only: the PXE program Etherboot in the socket loads by TFTP (Etherboot cannot load Linux);
# it does DHCP again and runs the test's boot.ipxe (test/ipxe/chain.ipxe).
set -euo pipefail
nb=$(dirname "$(dirname "$(readlink -f "$0")")")
src=$nb/ipxe   # builds in src/bin and takes configs in src/config/local, both ignored by iPXE's git
log=$nb/build/ipxe.build.log
mkdir -p "$nb/build"
cp "$nb/configs/ipxe/general.h" "$nb/configs/ipxe/usb.h" "$src/src/config/local/"
"$nb/tools/build_toolchain.sh"
ipxe() {  # embedded script, target
  env -u DEBUG make -C "$src/src" -s -j"$(nproc)" CROSS="$nb/coreboot/util/crossgcc/xgcc/bin/i386-elf-" \
    EMBED="$1" "$2" > "$log" 2>&1 || { tail -20 "$log"; echo "IPXE BUILD FAILED (log: $log)" >&2; exit 1; }
}
ipxe "$nb/test/ipxe/chain.ipxe" bin/realtek.pxe
ipxe "$nb/configs/ipxe/nic-rom.ipxe" bin/10ec8139.rom
cp "$src/src/bin/realtek.pxe" "$nb/build/ipxe-chain.pxe"
rom=$src/src/bin/10ec8139.rom
[ "$(stat -c %s "$rom")" -le 65536 ] || { echo "IPXE: $rom is larger than the 64 KiB socket ROM" >&2; exit 1; }
{ cat "$rom"; head -c $((65536 - $(stat -c %s "$rom"))) /dev/zero | tr '\0' '\377'; } > "$nb/build/nic-rtl8139-ipxe-64k.rom"
