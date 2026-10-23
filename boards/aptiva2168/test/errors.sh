#!/bin/bash
# test/errors.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): POST errors, Halt On, LOAD BIOS DEFAULTS.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/errors.sh"
