# mb-8433UUD for the Biostar MB-8433UUD-A (UMC UM8881F/UM8886BF, 486), sourced by build.sh. Network boot is Etherboot
# in the RTL8139's socket ROM, not in this flash.
# Output: out/newbios.rom (1 Mbit flash, also used by the 86Box tests) and out/newbios-2mbit.rom (a 2 Mbit flash such
# as a W49F002A: the board's 1 Mbit socket keeps A17 high, only the upper half is reached; the BIOS is in both halves).
# [DEBUG=1] also builds out/newbios-debug.rom (SeaBIOS's log on COM1); [HALT_ON=1] builds out/newbios-halt1.rom
# whose Halt On default is No Errors (no keyboard, dead CMOS battery).
trees coreboot-486 seabios-486
cb_mainboard=biostar/mb8433
cb_config=$bd/coreboot.config
sb_configs=("$cb/src/mainboard/$cb_mainboard/config_seabios" "$nb/seabios.config")

# Headers shared by the setup utility (SeaBIOS) and coreboot: one copy in each tree, kept equal. The CMOS layout is
# the same on every board (<coreboot>/src/include), the BIOS name and the POST code port are this board's.
for h in include/newbios_cmos.h mainboard/$cb_mainboard/post_serial.h mainboard/$cb_mainboard/bios_name.h; do
  cmp -s "$sb/src/${h##*/}" "$cb/src/$h" \
    || { echo "BUILD REFUSED: ${sb##*/}/src/${h##*/} and ${cb##*/}/src/$h differ" >&2; exit 1; }
done

rom() {  # tag, SeaBIOS name, extra coreboot config, [CBFS files to add: name=path ...]
  local tag=$1 obj
  obj=$(cb_obj "$1")
  coreboot_build "$1" "$2" "$3"
  local rom=$out/$tag.rom cbfs=("$obj/cbfstool" "$out/$tag.rom") f
  cp "$obj/coreboot.rom" "$rom"
  # ESCD in the 4 KiB parameter block at flash 0x1c000 of the Intel 28F001BX-T: a raw file whose data fills
  # it (ESCD_OFF in SeaBIOS pnpbios.c). The payload and the first extra file fill the flash below it, postcar
  # the 8 KiB above it, the other files what is left. cmos_layout.bin goes: nothing reads it (no option table).
  head -c 4096 /dev/zero | tr '\0' '\377' > "$obj/escd.bin"
  for f in fallback/postcar fallback/payload cmos_layout.bin; do "${cbfs[@]}" remove -n "$f"; done
  "${cbfs[@]}" add -t raw -n escd -f "$obj/escd.bin" -b 0x1c000 \
    && "${cbfs[@]}" add-payload -n fallback/payload -f "$(sb_out "$2")/bios.bcj.elf" -c lzma > /dev/null \
    || { echo "BUILD FAILED: $tag, no room for the ESCD and the payload" >&2; exit 1; }
  for f in "${@:4:1}" postcar "${@:5}"; do
    if [ "$f" = postcar ]; then
      "${cbfs[@]}" add-stage -n fallback/postcar -f "$obj/cbfs/fallback/postcar.elf" -c none > /dev/null
    else
      "${cbfs[@]}" add -t raw -n "${f%%=*}" -f "${f#*=}" > /dev/null
    fi || { echo "BUILD FAILED: $tag, no room for ${f%%=*}" >&2; exit 1; }
  done
  "${cbfs[@]}" print > "$out/$tag.cbfs.txt"
  size_map "$tag" "$2"
  [ "$(awk '$1 == "escd" {print $2}' "$out/$tag.cbfs.txt")" = 0x1bfe0 ] \
    || { echo "BUILD FAILED: $tag, the ESCD data is not at flash 0x1c000" >&2; exit 1; }   # 32-byte header
  echo "$out/$tag.rom: $(awk '/empty/ {s += $4} END {print s}' "$out/$tag.cbfs.txt") bytes free"
  cat "$rom" "$rom" > "$out/$tag-2mbit.rom"
}

halt=${HALT_ON:-0} tag=newbios sbname=rel
[ "$halt" = 0 ] || tag=newbios-halt$halt sbname=halt$halt   # its own SeaBIOS build: out/newbios.size keeps rel's
# no coreboot log: its console alone takes 7 KB (13 KB with its messages), more than the flash has left; its POST codes
# on COM1 time each step, and the debug ROM's SeaBIOS logs the chipset values coreboot set
nolog="CONFIG_PAYLOAD_BCJ_X86=y
# CONFIG_CONSOLE_SERIAL is not set
# CONFIG_BOOTBLOCK_CONSOLE is not set
# CONFIG_POSTCAR_CONSOLE is not set"
seabios "$sbname" "CONFIG_NEWBIOS_HALT_ON=$halt"
rom "$tag" "$sbname" "$nolog"
if [ -n "${DEBUG:-}" ]; then   # SeaBIOS's level 1 log: its key places (device setup, option ROMs, boot, warnings)
  seabios debug "CONFIG_DEBUG_LEVEL=1
CONFIG_DEBUG_SERIAL=y
CONFIG_DEBUG_SERIAL_PORT=0x3f8"
  rom newbios-debug debug "$nolog"
fi
