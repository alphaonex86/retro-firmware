#!/bin/bash
# test/usbboot.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): FreeDOS from a USB disk, Ctrl+Alt+Del while
# USB runs, boot order IDE/USB.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/usbboot.sh"
