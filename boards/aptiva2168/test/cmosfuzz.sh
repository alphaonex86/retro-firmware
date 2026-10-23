#!/bin/bash
# run_all: alone (it uses every core; timing tests next to it fail)
# Native (no emulator) fuzz of the CMOS values coreboot reads on the Aptiva (port of test/cmosfuzz.sh):
# mainboard/ibm/aptiva2168/newbios.c's romstage chipset options and its PCI IRQ presets through the PIRQ routing
# (irq_tables.c, the 82C558M's pirq.c), compiled unchanged against CMOS, 82C557M index and PCI seams, with array
# bounds, division and shifts trapping (native/cmosfuzz.c says what it checks). usage: cmosfuzz.sh
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$(dirname "$(dirname "$here")")")
cb=$nb/coreboot-486/src
out=$nb/test/vm/aptiva2168-cmosfuzz
config=$nb/out/aptiva2168.config
mkdir -p "$out"
[ -f "$config" ] || "$nb/build.sh" aptiva2168 > /dev/null || { echo "FAIL [aptiva2168 cmosfuzz]: build failed"; exit 1; }

defs=()
for opt in PIRQ_ROUTE DEBUG_PIRQ GENERATE_PIRQ_TABLE MAX_PIRQ_LINKS IRQ_SLOT_COUNT; do
  value=$(sed -n "s/^CONFIG_$opt=//p" "$config")
  case "$value" in y) value=1 ;; "") value=0 ;; esac
  defs+=("-DCONFIG_$opt=$value")
done
flags=(-m32 -O2 -pthread -fsanitize=bounds,integer-divide-by-zero,shift -fsanitize-trap=all -I"$nb/test/native/include"
  -I"$cb/arch/486/include" -I"$cb/mainboard/ibm/aptiva2168" -I"$cb" -idirafter "$cb/include" "${defs[@]}"
  -include "$here/native/cmosfuzz_seam.h")
for src in "$cb/arch/486/pirq_routing.c" "$cb/mainboard/ibm/aptiva2168/irq_tables.c" \
           "$cb/southbridge/opti/82c558m/pirq.c"; do
  gcc "${flags[@]}" -Wall -c "$src" -o "$out/$(basename "$src" .c).o"
done
gcc "${flags[@]}" -Wall -Wextra -Werror -Wno-unused-parameter -c "$here/native/cmosfuzz.c" -o "$out/cmosfuzz.o"
gcc -m32 -pthread "$out"/*.o -o "$out/cmosfuzz"

if "$out/cmosfuzz"; then
  echo "PASS [aptiva2168 cmosfuzz]"
else
  echo "FAIL [aptiva2168 cmosfuzz]: see above"
  exit 1
fi
