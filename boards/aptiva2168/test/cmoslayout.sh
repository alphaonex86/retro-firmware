#!/bin/bash
# test/cmoslayout.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): its setting defaults match the fingerprint
# of this NB_SIG_VALUE, an older layout's CMOS loads the defaults.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/cmoslayout.sh"
