#!/bin/bash
# test/devfuzz.sh on the IBM Aptiva 2168: the fault-injection test of the device and CMOS handling on the Aptiva's
# SeaBIOS (build/seabios-486/out-aptiva), its models the Viper-M's (82C557M shadow, MIDE) and a P54C.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/devfuzz.sh"
