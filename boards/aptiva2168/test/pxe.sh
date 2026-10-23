#!/bin/bash
# test/pxe.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): network boot from the RTL8139's socket ROM
# (Etherboot, then iPXE), boot order.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/pxe.sh"
