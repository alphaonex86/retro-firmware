#!/bin/bash
# Setup utility on the Aptiva (port of test/setup.sh): defaults on a cleared CMOS, the main menu, Standard CMOS and
# BIOS FEATURES edited, saved and kept after the reboot; HARDWARE INFORMATION (Pentium, bus by JP2, DRAM timing and
# SIMM pairs, PCI, USB, ISA/IRQ, IDE, chipset registers), the benchmark and test menus (no board or L2 tests); a disk
# on the secondary IDE channel.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-setup
export vm_machine=aptiva2168
mkdir -p "$vm_dir"
truncate -s $((20 * 16 * 63 * 512)) "$vm_dir/sec.img"
vm_start setup "$rom" "[Storage controllers]
hdc = internal

[Hard disks]
hdd_01_parameters = 63, 16, 20, 0, ide
hdd_01_fn = $vm_dir/sec.img
hdd_01_ide_channel = 1:0"

vm_end_of_post 60
vm_expect "CMOS checksum error - Defaults loaded"
vm_expect "Sec. Master Disk : 9MB"
vm_expect "CPU Type     : Pentium "
vm_setup
vm_expect "ROM PCI/ISA BIOS \(aptiva2168\)"
for m in "STANDARD CMOS SETUP" "BIOS FEATURES SETUP" "CHIPSET FEATURES SETUP" "POWER MANAGEMENT SETUP" \
         "PNP/PCI CONFIGURATION" "INTEGRATED PERIPHERALS" "SUPERVISOR PASSWORD" "HARDWARE INFORMATION" \
         "BENCHMARKS" "HARDWARE TESTS" "LOAD BIOS DEFAULTS" "LOAD SETUP DEFAULTS" "SAVE & EXIT SETUP" "EXIT WITHOUT SAVING"; do
  vm_expect "$m"
done

vm_menu 0                                         # STANDARD CMOS SETUP
vm_wait_text "Date \(mm:dd:yy\)" 5
vm_expect "Secondary Master : Auto +9M +20 +16 +63"
year=$(sed -nE 's/.*Date \(mm:dd:yy\) : [0-9]+:[0-9]+:([0-9]{4}).*/\1/p' "$vm/screen.txt")
vm_key $K_RIGHT $K_RIGHT $K_PGDN                  # year + 1
for _ in $(seq 12); do vm_key $K_DOWN; done       # Drive A
vm_expect "Drive A : 1.44M, 3.5 in."
vm_key $K_PGDN                                    # 1.44M -> 2.88M
vm_expect "Date \(mm:dd:yy\) : [0-9]+:[0-9]+:$((year + 1))"
vm_expect "Drive A : 2.88M, 3.5 in."
vm_key $K_ESC
vm_menu 1                                         # BIOS FEATURES SETUP
vm_wait_text "Boot Up NumLock Status" 5
grep -q "External Cache" "$vm/screen.txt" && fail "an External Cache item (no L2 code on this board)"
vm_expect "C8000-CBFFF Shadow +: Disabled"
vm_expect "1st Boot Device +: Hard Disk"           # default: Hard Disk, USB, Network, Floppy
vm_expect "2nd Boot Device +: USB"
vm_expect "4th Boot Device +: Floppy"
vm_net_first                                      # Network swapped with the 3rd: CD-ROM
vm_expect "3rd Boot Device +: CD-ROM"
vm_save

vm_end_of_post 60
grep -q "CMOS checksum error" "$vm/screen.txt" && fail "settings lost after reboot"
vm_expect "Diskette Drive A : 2.88M"
vm_setup
vm_menu 0
vm_wait_text "Date \(mm:dd:yy\) : [0-9]+:[0-9]+:$((year + 1))" 5
vm_expect "Drive A : 2.88M, 3.5 in."
vm_key $K_ESC
vm_menu 1
vm_wait_text "1st Boot Device +: Network" 5
vm_expect "3rd Boot Device +: CD-ROM"
vm_key $K_ESC
vm_tool 7 0                                       # HARDWARE INFORMATION: a menu of the pages
vm_wait_text "CPU +: Pentium \(GenuineIntel\)" 5
vm_expect "Core clock +: 166 MHz \(measured\)"
vm_expect "Bus clock \(FSB\): 66.7 MHz \(jumper JP2\) = core / 2.5"
vm_expect "L1 cache +: 8 KB, enabled, at 166 MHz \(core clock\)"
vm_expect "DRAM +: 16384 KB"
vm_expect "DRAM timing +: at 67 MHz \(bus\), RAS# precharge 5, CAS# read 2, write 2 CLKs"   # Auto: the IBM BIOS's
vm_expect "SIMM J23/J24 +: 2 x 8 MB double-sided"  # lib.sh: 2 x 8 MB double-sided in J23/J24
vm_expect "SIMM J27/J28 +: not used"
grep -q "L2 cache" "$vm/screen.txt" && fail "an L2 cache line (no L2 code on this board)"
vm_key $K_ESC $K_DOWN $K_ENTER
vm_wait_text "1045:c557 +OPTi +Host bridge" 5
vm_expect "1045:c621 +OPTi +IDE"
vm_expect "1023:9660 +Trident +VGA"
vm_key $K_ESC $K_DOWN $K_ENTER
vm_wait_text "USB DEVICES" 5
vm_expect "^ +none"                                # no USB card in this VM
vm_key $K_ESC $K_DOWN $K_ENTER
vm_wait_text "IRQ 15 : IDE secondary" 5
vm_expect "Parallel ports : 3bc"
vm_key $K_ESC $K_DOWN $K_ENTER
vm_wait_text "Secondary Master : 86B_HD" 5
vm_expect "PIO mode [0-4] \(drive max [0-4]\), block (2|4|8|16|32|64|128) "   # IDE HDD Block Mode
vm_key $K_ESC $K_DOWN $K_ENTER
vm_wait_text "82C557M  index 00:" 5
vm_expect "Shadow   : C0000 RW, C8000-DFFFF ISA ISA ISA ISA ISA ISA, E0000 RW, F0000 RW"
vm_expect "DRAM RAS# Precharge +: 5 CLKs"
vm_expect "FDC37C93x LD3: 01 03BC 07"
vm_key $K_ESC $K_ESC
vm_tool 8 0                                       # BENCHMARKS: MEMORY SPEED, graphics
sleep 20
vm_key $K_ESC
vm_wait_text "HARD DISK SPEED" 20                 # back in text mode, in the BENCHMARKS menu
vm_key $K_ESC
vm_menu 9                                         # HARDWARE TESTS
vm_wait_text "HDD SURFACE SCAN" 5
vm_expect "MEMORY TEST"
grep -Eq "BOARD TEST|CACHE TEST|L2 SRAM TEST" "$vm/screen.txt" && fail "board or L2 tests on this board"
vm_key $K_ESC $K_ESC
vm_wait_text "Quit Without Saving" 5
vm_key $K_Y                                       # quit without saving: boot continues
vm_wait_text "No bootable device|Boot failed" 60
vm_stop
