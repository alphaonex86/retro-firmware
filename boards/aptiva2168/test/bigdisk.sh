#!/bin/bash
# test/bigdisk.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): 1 TB LBA48 IDE disk through INT 13h
# extensions.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/bigdisk.sh"
