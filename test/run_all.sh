#!/bin/bash
# Build everything the tests need (86Box fork, each board's firmware, iPXE once: tests building it in parallel raced,
# Linux test kernel) and run all tests in parallel, one per core: test/<name>.sh (MB-8433UUD-A) and boards/*/test/*.sh
# (given relative to the repository). usage: run_all.sh [test...]   (default: all)
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$here")
"$nb/fetch_sources.sh" && "$nb/build_86box.sh" > /dev/null && "$nb/tools/build_ipxe.sh" > /dev/null \
  && "$here/linux/build.sh" > /dev/null || { echo "BUILD FAILED" >&2; exit 1; }
for b in "$nb"/boards/*/firmware.sh; do   # the firmware of every board that has a recipe
  b=$(basename "$(dirname "$b")")
  "$nb/build.sh" "$b" > /dev/null || { echo "BUILD FAILED: $b" >&2; exit 1; }
done
[ $# -gt 0 ] || set -- setup dos pxe nicrom chipset password bigdisk ram memtest post errors hddtype busclock isapnp pnpbios fmtlint floppy deadcmos halt1 l2guard bootmenu cachetest boardtest vgamem kbdpower flashtime cachepage otherflash warmboot flashlinux usbkbd usbboot usbfault usblilo nokbd bench awarddefaults l2sram dramfuzz cmoslayout cmosfuzz devfuzz genericbuild $(cd "$nb" && ls boards/*/test/*.sh | sed 's/\.sh$//')
mkdir -p "$here/vm"
limit=1800   # seconds per test, a hang guard: dramfuzz alone takes 6 min of all cores
for t; do   # one test per core: an overloaded host made timing checks fail (boardtest IRQ 0, memtest page)
  while [ "$(jobs -rp | wc -l)" -ge "$(nproc)" ]; do wait -n; done
  script=$here/$t.sh log=$here/vm/${t//\//_}
  [[ $t == */* ]] && script=$nb/$t.sh
  (timeout $limit "$script" > "$log.out" 2>&1; echo $? > "$log.rc") &
done
wait
fails=0
for t; do   # the exit status: a test with several VMs may print PASS for one, then fail
  log=$here/vm/${t//\//_}
  case $(cat "$log.rc") in
    0) echo "PASS $t";;
    124) echo "FAIL $t: TIMEOUT after $limit s (log: $log.out)"; fails=$((fails + 1));;
    *) echo "FAIL $t (log: $log.out)"; fails=$((fails + 1));;
  esac
done
exit $fails
