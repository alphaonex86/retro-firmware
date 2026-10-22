#!/bin/bash
# Get what the firmware is built and tested from, at the tested versions: the forks as submodules (86box, coreboot,
# seabios, ipxe: their commits are pinned here), the rest into sources/ (idempotent: existing entries, e.g. symlinks
# to local copies, are kept). Tarballs are checked against their SHA-256.
set -euo pipefail
nb=$(dirname "$(readlink -f "$0")")
src=$nb/sources
mkdir -p "$src"
# A submodule is moved to its pinned commit only from a commit this repository pinned before (after a pull, or a fresh
# clone): one at any other commit holds work the pointer does not record, it is refused, never reset (`git add <it>`).
for m in $(git -C "$nb" config -f .gitmodules --get-regexp 'path$' | awk '{print $2}'); do
  pin=$(git -C "$nb" ls-files -s "$m" | awk '{print $2}')
  head=$(git -C "$nb/$m" rev-parse -q --verify HEAD 2>/dev/null || true)
  [ -z "$head" ] || [ "$head" = "$pin" ] || git -C "$nb" log --format=%H -- "$m" \
    | while read -r c; do git -C "$nb" ls-tree "$c" "$m"; done | grep -q " $head"$'\t' \
    || { echo "REFUSED: submodule $m is at ${head:0:12}, not its pinned ${pin:0:12}: git add $m" >&2; exit 1; }
done
git -C "$nb" -c protocol.file.allow=always submodule update --init --quiet   # local origins need file:// allowed

file_sha() {  # url, sha256, file
  [ -e "$3" ] && return 0
  { curl -sfL --retry 3 -o "$3.part" "$1" && echo "$2  $3.part" | sha256sum -c --quiet \
      && mv "$3.part" "$3" && echo "got $(basename "$3")"; } \
    || { rm -f "$3.part"; echo "FAILED: $1" >&2; exit 1; }
}

[ "${1:-}" = firmware ] && exit 0

# Tests: FreeDOS 1.3, Linux 6.18 (last i486 LTS).
file_sha https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/official/FD13-LiteUSB.zip \
  64a934585087ccd91a18c55e20ee01f5f6762be712eeaa5f456be543778f9f7e "$src/FD13-LiteUSB.zip"
file_sha https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.55.tar.xz \
  f410638061a165c12f42ab871d2f3fcd525515359b5faeee80969cff84524df9 "$src/linux-6.18.55.tar.xz"
# BIOS update from Linux: flashrom (the HDD image's Buildroot version), patched by patches/buildroot/flashrom.
file_sha https://github.com/flashrom/flashrom/archive/v1.7.0/flashrom-1.7.0.tar.gz \
  c5a8892158bd749aadfee6e114eec268130cdd8c2027fd1ddf44273755b07b59 "$src/flashrom-1.7.0.tar.gz"
