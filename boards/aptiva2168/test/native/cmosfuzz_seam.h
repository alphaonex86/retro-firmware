/* Seam for compiling the Aptiva's newbios.c, irq_tables.c and the 82C558M's pirq.c on the host: test/native/include
   holds the coreboot headers they include; these are the Viper-M ones. */
#include <types.h>

#define PCI_VID_OPTI		0x1045
#define PCI_DID_OPTI_82C558	0xc558

u8 pci_s_read_config8(pci_devfn_t dev, u16 reg);
u16 pci_s_read_config16(pci_devfn_t dev, u16 reg);
void pci_s_write_config8(pci_devfn_t dev, u16 reg, u8 value);
void pci_s_write_config16(pci_devfn_t dev, u16 reg, u16 value);
