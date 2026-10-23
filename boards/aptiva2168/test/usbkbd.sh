#!/bin/bash
# test/usbkbd.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): USB keyboard only, then with an AT one.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/usbkbd.sh"
