#!/bin/bash
# test/nokbd.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): no AT keyboard (the board's destroyed PS/2
# port): everything from the USB keyboard, LILO, FreeDOS, Linux; no keyboard at all.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/nokbd.sh"
