#!/bin/bash
# test/kbdpower.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): slow 8042 and keyboard power-on.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/kbdpower.sh"
