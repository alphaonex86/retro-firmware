#!/bin/bash
# test/usblilo.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): LILO's countdown from USB without an AT
# keyboard.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/usblilo.sh"
