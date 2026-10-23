#!/bin/bash
# test/usbfault.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): USB faults: the POST finishes, the boot fails
# with a message.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/usbfault.sh"
