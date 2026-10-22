#!/bin/bash
# Build everything the tests need (86Box fork, mb-8433UUD ROMs, iPXE once: tests building it in parallel raced, Linux
# test kernel) and run all tests in parallel, one per core: test/<name>.sh (MB-8433UUD-A) and boards/*/test/*.sh
# (given relative to the repository). usage: run_all.sh [test...]   (default: all)
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$here")
"$nb/fetch_sources.sh" && "$nb/build_86box.sh" > /dev/null && "$nb/build.sh" > /dev/null \
  && "$nb/tools/build_ipxe.sh" > /dev/null && "$here/linux/build.sh" > /dev/null || { echo "BUILD FAILED" >&2; exit 1; }
[ $# -gt 0 ] || set -- setup dos pxe nicrom chipset password bigdisk ram memtest post errors hddtype busclock isapnp pnpbios fmtlint floppy deadcmos halt1 l2guard bootmenu cachetest boardtest vgamem kbdpower flashtime cachepage otherflash warmboot flashlinux usbkbd usbboot usbfault usblilo nokbd bench awarddefaults l2sram dramfuzz cmoslayout cmosfuzz devfuzz genericbuild $(cd "$nb" && ls boards/*/test/*.sh | sed 's/\.sh$//')
mkdir -p "$here/vm"
for t; do   # one test per core: an overloaded host made timing checks fail (boardtest IRQ 0, memtest page)
  while [ "$(jobs -rp | wc -l)" -ge "$(nproc)" ]; do wait -n; done
  script=$here/$t.sh log=$here/vm/${t//\//_}
  [[ $t == */* ]] && script=$nb/$t.sh
  (timeout 600 "$script" > "$log.out" 2>&1; echo $? > "$log.rc") &
done
wait
fails=0
for t; do   # the exit status: a test with several VMs may print PASS for one, then fail
  log=$here/vm/${t//\//_}
  if [ "$(cat "$log.rc")" = 0 ]; then echo "PASS $t"; else echo "FAIL $t (log: $log.out)"; fails=$((fails + 1)); fi
done
exit $fails
