#!/bin/bash
# run_all: alone (it uses every core; timing tests next to it fail)
# Port step 4 gate, native (no emulator): coreboot_486's Viper-M DRAM sizing (raminit.c, compiled unchanged) against
# a C port of the 86Box fork's 82C557M DRAM model (native/viperm_model.c): every pair of SIMM geometries in the two
# pairs, without fault, with a floating bus and with faulty bits (native/dramfuzz.c says what it checks), then the
# lines of simm_configs.txt. usage: dramfuzz.sh
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
nb=$(dirname "$(dirname "$(dirname "$here")")")
cb=$nb/coreboot-486/src
out=$nb/test/vm/aptiva2168-dramfuzz
config=$nb/out/aptiva2168.config
mkdir -p "$out"
[ -f "$config" ] || "$nb/build.sh" aptiva2168 > /dev/null || { echo "FAIL [aptiva2168 dramfuzz]: build failed"; exit 1; }

car=()
for opt in CONFIG_DCACHE_RAM_BASE CONFIG_DCACHE_RAM_SIZE; do
  value=$(sed -n "s/^$opt=//p" "$config")
  [ -n "$value" ] || { echo "FAIL [aptiva2168 dramfuzz]: no $opt in $config"; exit 1; }
  car+=("-D$opt=$value")
done
flags=(-m32 -O2 -fno-pie -Wall -I"$here/native/include" -I"$here/native" -idirafter "$cb/include" "${car[@]}")
gcc "${flags[@]}" -Wno-format -c "$cb/northbridge/opti/viperm/raminit.c" -o "$out/raminit.o"   # coreboot's %lu
for src in viperm_model dramfuzz; do
  gcc "${flags[@]}" -Wextra -Werror -c "$here/native/$src.c" -o "$out/$src.o"
done
gcc -m32 -no-pie "$out/raminit.o" "$out/viperm_model.o" "$out/dramfuzz.o" -o "$out/dramfuzz"

if "$out/dramfuzz" < "$here/simm_configs.txt"; then
  echo "PASS [aptiva2168 dramfuzz]"
else
  echo "FAIL [aptiva2168 dramfuzz]: see above"
  exit 1
fi
