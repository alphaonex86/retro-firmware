#!/bin/bash
# test/hddtype.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): User and fixed hard disk types.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/hddtype.sh"
