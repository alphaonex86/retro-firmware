#!/bin/bash
# test/floppy.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): boot from drive A.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/floppy.sh"
