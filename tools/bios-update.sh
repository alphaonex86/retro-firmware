#!/bin/sh
# bios-update IMAGE [BOARD]: rewrite the BIOS from Linux with flashrom (the flashrom submodule), as root.
# BOARD mb8433uud (default), the MB-8433UUD-A: its 1 Mbit socket leaves A17 of a 2 Mbit chip high: only the upper
# 128 KiB is reachable, the lower half reads as an alias of it. So only that region is erased, written and verified
# (the image holds the BIOS in both halves, what the chip reads). flashrom alone refuses (max decode 128 KiB) rather
# than erase the BIOS through the alias. IMAGE: a 128 KiB mb-8433UUD ROM, or a 256 KiB one (its upper half is taken).
# BOARD aptiva2168, the IBM Aptiva A90: its 128 KiB 28F010 is erased and written whole (12 V VPP: JP9 at 1-2). Its
# BIOS has no DMI table and the Viper-M is also a notebook chipset: flashrom is told it is not a laptop.
set -eu
[ $# -ge 1 ] && [ $# -le 2 ] && [ -f "$1" ] || { echo "usage: bios-update IMAGE [mb8433uud|aptiva2168]" >&2; exit 1; }
size=$(wc -c < "$1")
case ${2:-mb8433uud} in
	mb8433uud) ;;
	aptiva2168)
		[ "$size" = 131072 ] || { echo "bios-update: $1 is not 128 KiB" >&2; exit 1; }
		exec flashrom -p internal:laptop=this_is_not_a_laptop -w "$1" ;;
	*) echo "bios-update: unknown board $2" >&2; exit 1 ;;
esac
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
case $size in
	131072) cp "$1" "$tmp/bios" ;;
	262144) dd if="$1" of="$tmp/bios" bs=1024 skip=128 count=128 2>/dev/null ;;
	*) echo "bios-update: $1 is neither 128 nor 256 KiB" >&2; exit 1 ;;
esac
cat "$tmp/bios" "$tmp/bios" > "$tmp/image"
printf '00020000:0003ffff bios\n' > "$tmp/layout"
flashrom -p internal --force --noverify-all -l "$tmp/layout" -i bios -w "$tmp/image"
