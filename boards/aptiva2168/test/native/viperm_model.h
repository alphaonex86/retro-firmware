/* The 82C557M DRAM model of the 86Box fork (src/chipset/opti55x.c, opti55x_dram_decode/flat) in C for native
   tests: two SIMM pairs of banks 0-3 decoded from 13h/14h/19h, a faulty bit by CPU address, cells in a sparse
   store whose unwritten dwords hold power-on garbage. */
#ifndef VIPERM_MODEL_H
#define VIPERM_MODEL_H

#include <stdint.h>

struct simm {
	uint8_t rows, cols, sides;	/* of each SIMM of the pair; sides 0: empty */
};

#define STORE_SLOTS (1 << 14)

struct model {
	struct simm simm[2];
	uint8_t idx, regs[256];		/* 82C557M index registers (22h/24h) */
	uint32_t stuck_addr;		/* this byte reads stuck_mask as 0; stuck_mask 0: none */
	uint8_t stuck_mask;
	int float_last;			/* absent cells read the last value on the bus, else FFh (as the fork) */
	uint32_t bus;
	uint32_t seed, gen;
	uint32_t key[STORE_SLOTS], val[STORE_SLOTS], slot_gen[STORE_SLOTS];
};

extern const struct simm simm_types[11];	/* the fork's device option values */

void model_reset(struct model *m, struct simm pair0, struct simm pair1, uint32_t seed);
int64_t model_decode(const struct model *m, const uint8_t regs[3], uint32_t addr);	/* 13h 14h 19h; -1: none */
uint32_t model_top(const uint8_t regs[3]);
int model_flat(const struct model *m, const uint8_t regs[3]);
uint32_t model_read32(struct model *m, uint32_t addr);
void model_write32(struct model *m, uint32_t addr, uint32_t value);

#endif
