#!/bin/bash
# CHIPSET FEATURES on the Viper-M: Auto Configuration gives the IBM BIOS's DRAM timing for the bus clock (01h DDh at
# 66 MHz); manual values (NB_VIPERM_FIELDS: also L1 write-through, pre-snoop off, late HITM#) and BIOS caching reach the
# 82C557M, a PCI IRQ set in PNP/PCI reaches the 82C558M, a PIO mode the MIDE; the CHIPSET REGISTERS and CPU pages show
# them; two unfinished POSTs make coreboot fall back to Auto, a completed one re-arms the manual values.
. "$(dirname "$(readlink -f "$0")")/../../../test/lib.sh"
rom=$nb/out/aptiva2168.rom
[ -f "$rom" ] || "$nb/build.sh" aptiva2168 > /dev/null || fail "build failed"
vm_dir=$nb/test/vm/aptiva2168-chipset
dos_disk "$vm_dir/hdd.img"
idx() {  # 82C557M index -> its value (hex)
  rm -f "$vm/idx.txt"
  vm_cmd idx 22 24 "$1" "$vm/idx.txt"
  for _ in $(seq 50); do [ -s "$vm/idx.txt" ] && break; sleep 0.1; done
  awk '{print $2}' "$vm/idx.txt"
}

vm_machine=aptiva2168 vm_start "aptiva2168 chipset" "$rom" "$(disk_cfg "$vm_dir/hdd.img")"
vm_end_of_post 60
expect_bits "$(idx 01)" 0xff 0xdd "Auto DRAM timing at 66 MHz (01h, the IBM BIOS's)"
expect_bits "$(idx 06)" 0x30 0x30 "video and system BIOS cacheable (06h)"
vm_setup
vm_menu 2                                         # CHIPSET FEATURES SETUP
vm_wait_text "Auto Configuration +: Enabled" 5
vm_expect "DRAM RAS# Precharge +: 5 CLKs"
vm_key $K_PGUP                                    # auto configuration off
vm_key $K_DOWN $K_PGDN $K_PGDN                    # RAS# precharge 5 -> 3 CLKs
vm_key $K_DOWN $K_PGUP                            # read CAS# pulse 2 -> 3 CLKs
vm_key $K_DOWN $K_DOWN $K_DOWN $K_PGDN            # slow refresh on
vm_key $K_DOWN $K_DOWN $K_DOWN $K_PGUP            # system BIOS not cacheable
vm_key $K_DOWN $K_DOWN $K_PGUP                    # L1 write-through
vm_key $K_DOWN $K_PGUP                            # PCI pre-snoop off
vm_key $K_DOWN $K_PGDN                            # HITM# sampled one CLK later
vm_expect "DRAM RAS# Precharge +: 3 CLKs"
vm_expect "DRAM Read CAS# Pulse +: 3 CLKs"
vm_expect "Slow Refresh \(1/4 Freq\) +: Enabled"
vm_expect "System BIOS Cacheable +: Disabled"
vm_expect "L1 Cache Write-Back +: Disabled"
vm_expect "PCI Pre-Snoop +: Disabled"
vm_expect "HITM# Sampled 1 CLK Late: Enabled"
vm_key $K_ESC
vm_menu 4                                         # PNP/PCI
for _ in $(seq 4); do vm_key $K_PGDN; done        # INTA# Auto -> 5 -> 9 -> 10 -> 11
for _ in $(seq 4); do vm_key $K_DOWN; done        # primary master PIO
vm_key $K_PGDN $K_PGDN $K_PGDN                    # Auto -> Mode 2
vm_expect "PCI INTA# IRQ +: 11"
vm_expect "IDE Primary Master PIO +: Mode 2"
vm_save

chip_page() {  # setup CHIPSET REGISTERS: RAS# precharge and slow refresh in the chip -> back to the main menu
  vm_setup
  vm_tool 7 5
  vm_wait_text "DRAM RAS# Precharge +: +$1" 5
  vm_expect "Slow Refresh \(1/4 Freq\) +: +$2"
  vm_key $K_ESC $K_ESC
}

check_chipset() {  # manual values applied (1) or Auto (0)
  if [ "$1" = 1 ]; then
    expect_bits "$(idx 01)" 0x0f 0x07 "RAS# precharge 3 CLKs, CAS# read 3, write 2 CLKs (01h)"
    expect_bits "$(idx 12)" 0x0c 0x08 "slow refresh (12h)"
    expect_bits "$(idx 08)" 0x22 0x00 "L1 write-through, HITM# one CLK later (08h)"
    expect_bits "$(idx 0f)" 0x80 0x00 "PCI pre-snoop off (0Fh)"
  else
    expect_bits "$(idx 01)" 0xff 0xdd "Auto DRAM timing (01h)"
    expect_bits "$(idx 12)" 0x0c 0x00 "refresh on each REFRESH# (12h)"
    expect_bits "$(idx 08)" 0x22 0x22 "L1 write-back, HITM# without delay (08h)"
    expect_bits "$(idx 0f)" 0x80 0x80 "PCI pre-snoop (0Fh)"
  fi
  expect_bits "$(idx 06)" 0x30 0x20 "video BIOS cacheable, system BIOS not (06h)"
}

vm_end_of_post 60
vm_expect "Pri. Master Disk : 31MB, PIO 2"
check_chipset 1
expect_bits "$(vm_pci_byte 00:01.0 40)" 0x07 0x04 "PIRQ0 -> IRQ 11 (82C558M 40h bits 2-0)"
expect_bits "$(vm_pci_byte 00:14.0 40)" 0x03 0x02 "MIDE PIO 2 (40h)"
chip_page "3 CLKs" Enabled
vm_tool 7 0                                       # CPU page: timing and SIMMs
vm_wait_text "DRAM timing +: at 67 MHz \(bus\), RAS# precharge 3, CAS# read 3, write 2 CLKs" 5
vm_expect "SIMM J23/J24 +: 2 x 8 MB double-sided"
vm_expect "SIMM J27/J28 +: not used"
vm_expect "Chipset +: OPTi 82C557M rev"
vm_key $K_ESC $K_ESC

# Two unfinished POSTs: coreboot keeps Auto once, POST completion re-arms the manual values.
vm_cmd out 70 7e
vm_cmd out 71 02
vm_reset
vm_end_of_post 60
vm_expect "Chipset setup values not used after 2 unfinished POSTs"
check_chipset 0
chip_page "5 CLKs" Disabled                       # coreboot's values, not the setup's
vm_key $K_ESC
vm_wait_text "Quit Without Saving" 5
vm_key $K_Y
vm_wait_text "DOS-TEST-OK" 60                     # POST completed
vm_reset
vm_end_of_post 60
check_chipset 1
vm_stop
