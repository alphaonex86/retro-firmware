#!/bin/bash
# test/warmboot.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): Ctrl+Alt+Del from DOS, setup and a receiving
# network card.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/warmboot.sh"
