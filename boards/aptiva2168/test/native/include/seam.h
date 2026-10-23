/* Seam for compiling coreboot_486's Viper-M raminit.c on the host: the coreboot headers it includes map here. */
#ifndef NATIVE_SEAM_H
#define NATIVE_SEAM_H

#include <stdint.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;

#define KiB (1 << 10)
#define MiB (1 << 20)
#define ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define ALIGN_DOWN(x, a) ((x) & ~((__typeof__(x))(a) - 1))

#define BIOS_EMERG 0
#define BIOS_WARNING 4
#define BIOS_INFO 6
int printk(int level, const char *fmt, ...);
void post_code(u8 value);

u8 inb(u16 port);
void outb(u8 value, u16 port);
u32 read32p(uintptr_t addr);
void write32p(uintptr_t addr, u32 value);
void halt(void) __attribute__((noreturn));
uintptr_t cbmem_top_chipset(void);

#endif
