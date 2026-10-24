#include "viperm_model.h"

const struct simm simm_types[11] = {
	{ 0 }, { 9, 9, 1 }, { 9, 9, 2 }, { 10, 9, 1 }, { 10, 10, 1 }, { 10, 10, 2 },
	{ 11, 10, 1 }, { 11, 11, 1 }, { 11, 10, 2 }, { 11, 11, 2 }, { 12, 11, 1 }
};

void model_reset(struct model *m, struct simm pair0, struct simm pair1, uint32_t seed)
{
	m->simm[0] = pair0;
	m->simm[1] = pair1;
	m->idx = 0;
	for (int i = 0; i < 256; i++)
		m->regs[i] = 0;
	m->stuck_mask = 0;
	m->float_last = 0;
	m->bus = 0;
	m->seed = seed;
	if (++m->gen == 0) {	/* wrapped: forget every slot */
		for (int i = 0; i < STORE_SLOTS; i++)
			m->slot_gen[i] = 0;
		m->gen = 1;
	}
}

/* Bank codes 0-5 in full decode (13h bit 7, always set by the code under test): bank 4 needs 19h bit 3, bank 5 bit 7. */
static void bank_codes(const uint8_t regs[3], uint8_t code[6])
{
	for (int bank = 0; bank < 6; bank++)
		code[bank] = (regs[bank >> 1] >> ((bank & 1) * 4)) & 7;
	if (!(regs[0] & 0x80))
		code[0] = 1, code[1] = code[2] = code[3] = 0;	/* 82C546/547 mode: 00h = 0, 2 MB in bank 0 */
	if (!(regs[2] & 0x08))
		code[4] = 0;
	if (!(regs[2] & 0x80))
		code[5] = 0;
}

/* The socket pair of a bank: J23/J24 banks 0/1, J27/J28 banks 4/5 (RAS4#/RAS5#); -1: banks 2/3, no sockets */
static int bank_pair(int bank)
{
	return bank < 2 ? 0 : bank >= 4 ? 1 : -1;
}

int64_t model_decode(const struct model *m, const uint8_t regs[3], uint32_t addr)
{
	uint8_t code[6];
	uint32_t base = 0;
	int bank;

	bank_codes(regs, code);
	for (bank = 0; bank < 6; bank++) {
		uint32_t size = code[bank] ? 1u << (20 + code[bank]) : 0;
		if (addr - base < size)
			break;
		base += size;
	}
	int pair = bank < 6 ? bank_pair(bank) : -1;
	if (pair < 0 || (bank & 1) >= m->simm[pair].sides)
		return -1;

	const struct simm *simm = &m->simm[pair];
	int n = code[bank];
	uint32_t row = (addr >> 12) & 0x1ff, col = (addr >> 3) & 0x1ff;
	for (int i = 0; i < ((regs[2] & 0x08) ? 2 : 3); i++) {
		if (i < n / 2)
			row |= ((addr >> (21 + 2 * i)) & 1) << (9 + i);
		if (i < (n - 1) / 2)
			col |= ((addr >> (22 + 2 * i)) & 1) << (9 + i);
	}
	row &= (1u << simm->rows) - 1;
	col &= (1u << simm->cols) - 1;
	int64_t pair_base = (int64_t)pair << 32;
	return pair_base + ((((((int64_t)(bank & 1) << simm->rows) | row) << simm->cols) | col) << 3) + (addr & 7);
}

uint32_t model_top(const uint8_t regs[3])
{
	uint8_t code[6];
	uint32_t top = 0;

	bank_codes(regs, code);
	for (int bank = 0; bank < 6; bank++)
		top += code[bank] ? 1u << (20 + code[bank]) : 0;
	return top;
}

int model_flat(const struct model *m, const uint8_t regs[3])
{
	uint8_t code[6];

	bank_codes(regs, code);
	for (int bank = 0; bank < 6; bank++) {
		int n = code[bank];
		int pair = bank_pair(bank);
		if (n && (pair < 0 || (bank & 1) >= m->simm[pair].sides || ((regs[2] & 0x08) && n >= 6) ||
			  9 + n / 2 > m->simm[pair].rows || 9 + (n - 1) / 2 > m->simm[pair].cols))
			return 0;
	}
	return 1;
}

static uint32_t *slot(struct model *m, uint32_t key, int create)
{
	uint32_t h = (key * 0x9e3779b1u) >> (32 - 14);

	for (;; h = (h + 1) & (STORE_SLOTS - 1)) {
		if (m->slot_gen[h] != m->gen) {
			if (!create)
				return 0;
			m->slot_gen[h] = m->gen;
			m->key[h] = key;
			return &m->val[h];
		}
		if (m->key[h] == key)
			return &m->val[h];
	}
}

static uint32_t garbage(uint32_t key, uint32_t seed)
{
	uint32_t x = key * 0x85ebca6bu ^ seed;
	x ^= x >> 13;
	x *= 0xc2b2ae35u;
	return x ^ (x >> 16);
}

/* Cells are stored per dword (an aligned dword is one 32-bit SIMM's cells); a pair holds at most 2^28 bytes. */
static uint32_t cell_key(int64_t cell)
{
	return (uint32_t)(cell >> 2);
}

uint32_t model_read32(struct model *m, uint32_t addr)
{
	const uint8_t regs[3] = { m->regs[0x13], m->regs[0x14], m->regs[0x19] };
	int64_t cell = model_decode(m, regs, addr);
	uint32_t value;

	if (cell < 0)
		value = m->float_last ? m->bus : 0xffffffff;
	else {
		uint32_t *v = slot(m, cell_key(cell), 0);
		value = v ? *v : garbage(cell_key(cell), m->seed);
	}
	if (m->stuck_mask && m->stuck_addr - addr < 4)
		value &= ~((uint32_t)m->stuck_mask << 8 * (m->stuck_addr - addr));
	return m->bus = value;
}

void model_write32(struct model *m, uint32_t addr, uint32_t value)
{
	const uint8_t regs[3] = { m->regs[0x13], m->regs[0x14], m->regs[0x19] };
	int64_t cell = model_decode(m, regs, addr);

	m->bus = value;
	if (cell >= 0)
		*slot(m, cell_key(cell), 1) = value;
}
