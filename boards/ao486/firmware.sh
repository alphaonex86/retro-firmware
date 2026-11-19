# ao486 FPGA core on the Terasic DE25-Standard (retroDE_ao486), sourced by build.sh: SeaBIOS alone, no coreboot (no
# chipset to set up: the SDRAM works from reset, there is no PCI bus). The core's HPS daemon writes the image to RAM at
# E0000-FFFFF, where the CPU starts it at the reset vector, and its pristine copy to FFFE0000, which a warm reboot
# restores the RAM image from. The VGA BIOS is the core's own ROM at C0000.
# Output: out/ao486.rom (128 KiB), also bootable in QEMU: boards/ao486/run_qemu.sh. DEBUG=3 ./build.sh ao486 adds
# out/ao486-debug.rom, logging on COM1.
trees coreboot-486 seabios-486   # the coreboot tree only for its cross compiler
sb_configs=("$nb/seabios.config" "$bd/seabios.config")

seabios ao486 ""
cp "$(sb_out ao486)/bios.bin.prep" "$out/ao486.rom"
[ "$(stat -c %s "$out/ao486.rom")" = 131072 ] || { echo "BUILD FAILED: $out/ao486.rom is not 128 KiB" >&2; exit 1; }
echo "$out/ao486.rom: $((131072 - $(stat -c %s "$(sb_out ao486)/bios.bin.raw"))) bytes free"
if [ -n "${DEBUG:-}" ]; then   # out/ao486-debug.rom: SeaBIOS's log on COM1 (115200 8N1)
  seabios ao486-debug "CONFIG_DEBUG_LEVEL=${DEBUG}
CONFIG_DEBUG_SERIAL=y
CONFIG_DEBUG_SERIAL_PORT=0x3f8"
  cp "$(sb_out ao486-debug)/bios.bin.prep" "$out/ao486-debug.rom"
fi
