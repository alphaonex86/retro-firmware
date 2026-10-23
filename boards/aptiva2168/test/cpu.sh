#!/bin/bash
# Our ROM on each P54C setting of the board (50, 60, 66 MHz bus, as boot.sh): the POST summary names a Pentium at
# its rating (TSC clock) and HARDWARE INFORMATION's CPU page shows the bus clock of jumper JP2 and the multiplier.
# usage: cpu.sh (all, in parallel) | cpu.sh <MHz> <86Box cpu_speed> <bus MHz x10> <multiplier>
bd=$(dirname "$(dirname "$(readlink -f "$0")")")
. "$bd/../../test/lib.sh"
vm_dir=$nb/test/vm/aptiva2168-cpu
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
settings="75 75000000 500 1.5
90 90000000 600 1.5
100 100000000 667 1.5
120 120000000 600 2.0
133 133333333 667 2.0
150 150000000 600 2.5
166 166666666 667 2.5"
if [ $# -eq 0 ]; then
  mkdir -p "$vm_dir"
  xargs -P 4 -L 1 "$0" <<< "$settings" > "$vm_dir/all.log" 2>&1 || true
  vm_name="aptiva2168 cpu"
  [ "$(grep -c '^PASS' "$vm_dir/all.log")" = 7 ] || { cat "$vm_dir/all.log"; fail "see above"; }
  echo "PASS [aptiva2168 cpu]"
  exit 0
fi

mhz=$1 speed=$2 bus10=$3 multi=$4
vm_dir=$vm_dir/$mhz
vm_machine=aptiva2168 vm_cpu_speed=$speed vm_cpu_multi=$multi vm_start "aptiva2168 cpu $mhz" "$rom"
vm_end_of_post 120
vm_expect "CPU Type     : Pentium  "
vm_expect "CPU Clock    : ${mhz}MHz"
vm_setup
vm_tool 7 0
vm_wait_text "CPU +: Pentium \(GenuineIntel\)" 5
vm_expect "CPUID +: family 5, model 2"
vm_expect "Core clock +: $mhz MHz \(measured\)"
vm_expect "Bus clock \(FSB\): ${bus10:0:2}.${bus10:2} MHz \(jumper JP2\) = core / ${multi%.0}"
vm_stop
