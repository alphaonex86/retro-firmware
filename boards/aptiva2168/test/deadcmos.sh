#!/bin/bash
# test/deadcmos.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): garbage CMOS at power-on (dead battery): POST
# to the error prompt, DOS boots.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/deadcmos.sh"
