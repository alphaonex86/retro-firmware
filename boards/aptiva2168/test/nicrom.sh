#!/bin/bash
# test/nicrom.sh on the IBM Aptiva 2168 (our ROM, out/aptiva2168.rom): the RTL8139 socket ROM offered by its EEPROM's
# boot ROM size.
vm_machine=aptiva2168 exec "$(dirname "$(readlink -f "$0")")/../../../test/nicrom.sh"
