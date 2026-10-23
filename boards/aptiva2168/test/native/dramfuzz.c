/* Runs coreboot_486's Viper-M viperm_dram_init (raminit.c, compiled unchanged) against the C port of the fork's
   82C557M DRAM model: every pair of SIMM geometries (empty, or 9-12 row and 9-12 column bits, one or two sides) in
   J23/J24 and J27/J28, each without fault, with a floating bus that keeps the last value, and with a faulty bit at
   every dword the sizing reads and at random addresses. Checks the DRAM top against the best the chipset can
   address, that the banks decode one to one below it, the registers (the same with a faulty bit), the POST codes,
   that the cache-as-RAM lines are never touched; then the lines of simm_configs.txt read on stdin (the IBM BIOS's
   values, or ours where it fails). Workers are processes, one per core. */
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <seam.h>
#include "viperm_model.h"

void viperm_dram_init(void);

#define POST_PART 0x33
#define POST_CUT 0x34
#define POST_NO_DRAM 0x3e
#define MIN_DRAM (2u << 20)

static struct model *m;
static jmp_buf halted;
static uint8_t codes[256];
static int code_count, bad_port, car_touched, bad_decode;
static uint32_t reads[4096];
static int read_count, recording;

/* coreboot seams */
int printk(int level, const char *fmt, ...)
{
	(void)level;
	(void)fmt;
	return 0;
}

void post_code(u8 value)
{
	if (code_count < (int)sizeof(codes))
		codes[code_count++] = value;
}

void halt(void)
{
	longjmp(halted, 1);
}

static u8 refresh;

u8 inb(u16 port)
{
	if (port == 0x24)
		return m->regs[m->idx];
	if (port == 0x61)
		return refresh ^= 0x10;	/* refresh toggle */
	bad_port = 1;
	return 0xff;
}

void outb(u8 value, u16 port)
{
	if (port == 0x22)
		m->idx = value;
	else if (port == 0x24) {
		m->regs[m->idx] = value;
		/* IBM never decodes code 6/7 or MA11 as MA11; probing so missized the real board's 1Mx32 pair */
		if (((m->idx == 0x13 || m->idx == 0x14) && ((value & 7) > 5 || (value >> 4 & 7) > 5)) ||
		    (m->idx == 0x19 && !(value & 0x08)))
			bad_decode = 1;
	}
	else
		bad_port = 1;
}

static void check_car(uintptr_t addr)
{
	if (addr + 4 > CONFIG_DCACHE_RAM_BASE && addr < CONFIG_DCACHE_RAM_BASE + CONFIG_DCACHE_RAM_SIZE)
		car_touched = 1;
}

u32 read32p(uintptr_t addr)
{
	check_car(addr);
	if (recording && read_count < (int)ARRAY_SIZE(reads))
		reads[read_count++] = addr;
	return model_read32(m, addr);
}

void write32p(uintptr_t addr, u32 value)
{
	check_car(addr);
	model_write32(m, addr, value);
}

/* A geometry: 0 empty, else 1 + (rows - 9) * 8 + (cols - 9) * 2 + sides - 1 */
#define GEOMETRIES 33
static struct simm geometry(int g)
{
	if (!g--)
		return (struct simm){ 0 };
	return (struct simm){ 9 + g / 8, 9 + g / 2 % 4, 1 + g % 2 };
}

/* The largest code under which a side alone decodes one to one, at most 5 (MA11 is RAS4#); 0 if absent. */
static int best_code(int side, struct simm simm)
{
	struct model probe = { .simm = { simm } };
	int best = 0;

	for (int n = 1; n <= 5; n++) {
		const uint8_t regs[3] = { 0x80 | n << (4 * side), 0x80, 0x88 };
		if (model_flat(&probe, regs))
			best = n;
	}
	return best;
}

enum { TOP = 1, ALIAS = 2, REGS = 4, FAULT_REGS = 8, CODES = 16, CAR = 32, PORT = 64, HALT = 128, DECODE = 256, KINDS = 9 };
static const char *const kind_names[KINDS] = {
	"DRAM top not the best the SIMMs give", "a hole or alias below the top", "13h/14h/19h bits or other registers",
	"registers change with a faulty bit", "POST codes (33h partial, 34h cut, 3Eh no DRAM)",
	"cache-as-RAM line touched", "I/O port other than 22h/24h/61h", "halted (or not) wrongly",
	"a decode the IBM BIOS never writes (code 6/7, 19h bit 3 = 0)"
};

struct result {
	uint8_t regs[3];
	int halted;
	uint32_t top;
};

/* One run of viperm_dram_init; mask 0: no faulty bit. */
static void run(struct simm p0, struct simm p1, uint32_t seed, int float_last, uint32_t stuck, uint8_t mask,
		struct result *r)
{
	model_reset(m, p0, p1, seed);
	m->float_last = float_last;
	m->stuck_addr = stuck;
	m->stuck_mask = mask;
	code_count = bad_port = car_touched = bad_decode = 0;
	r->halted = setjmp(halted);
	if (!r->halted)
		viperm_dram_init();
	r->regs[0] = m->regs[0x13];
	r->regs[1] = m->regs[0x14];
	r->regs[2] = m->regs[0x19];
	r->top = r->halted ? 0 : cbmem_top_chipset();
}

static int has_code(uint8_t code)
{
	return memchr(codes, code, code_count) != NULL;
}

/* Every 4 KiB page below the top on its own cells; a page's cells are its base cell plus address bits 0-11 */
static int one_to_one(const uint8_t regs[3], uint32_t top)
{
	static uint8_t seen[2][(256u << 20) >> 15];
	memset(seen, 0, sizeof(seen));
	for (uint32_t a = 0; a < top; a += 0x1000) {
		if (a == 0xa0000)
			a = 0x100000;
		int64_t cell = model_decode(m, regs, a);
		if (cell < 0)
			return 0;
		uint32_t page = (uint32_t)cell >> 12;
		uint8_t *byte = &seen[cell >> 32][page >> 3];
		if (*byte & (1 << (page & 7)))
			return 0;
		*byte |= 1 << (page & 7);
	}
	return 1;
}

static int count_block(uint32_t a)
{
	return (a < 0xa0000 || a >= 0x100000) &&
	       (a < CONFIG_DCACHE_RAM_BASE || a >= CONFIG_DCACHE_RAM_BASE + CONFIG_DCACHE_RAM_SIZE);
}

/* What the result must be: the best codes, and the memory count cut below a faulty count block. */
static int check(struct simm p0, struct simm p1, const struct result *r, const struct result *clean, int faulty)
{
	const struct simm pair[2] = { p0, p1 };
	uint32_t best = 0;
	int partial = 0, fails = 0;

	for (int bank = 0; bank < 4; bank++) {
		const struct simm s = pair[bank >> 1];
		int n = best_code(bank & 1, s);
		best += n ? 1u << (20 + n) : 0;
		partial |= n && MIN(s.rows, 11) + MIN(s.cols, 11) + 3 > 20 + n;	/* the probe sees MA0-10 only */
	}
	uint32_t top = best;
	if (faulty) {
		uint32_t block = m->stuck_addr & ~3u;
		if (!(block & 0xffff) && block < best && count_block(block))
			top = block & ~0xfffffu;
	}
	int no_dram = top < MIN_DRAM;
	if (r->halted != no_dram)
		fails |= HALT;
	if (!r->halted && r->top != top)
		fails |= TOP;
	if (faulty && memcmp(r->regs, clean->regs, 3))
		fails |= FAULT_REGS;
	if ((r->regs[0] & 0x88) != 0x88 || (r->regs[1] & 0x88) != 0x80 || r->regs[2] != 0x88 || model_top(r->regs) != best)
		fails |= REGS;
	for (int reg = 0; reg < 256; reg++)
		if (reg != 0x13 && reg != 0x14 && reg != 0x19 && m->regs[reg])
			fails |= REGS;
	if (has_code(POST_PART) != partial || has_code(POST_CUT) != (top < best) || has_code(POST_NO_DRAM) != no_dram)
		fails |= CODES;
	if (car_touched)
		fails |= CAR;
	if (bad_port)
		fails |= PORT;
	if (bad_decode)
		fails |= DECODE;
	return fails;
}

#define RANDOM_FAULTS 24

struct shared {
	int next;
	unsigned cases, fails, kinds;
	unsigned kind_cases[KINDS];
	char example[KINDS][160];
};
static struct shared *sh;

static uint32_t rng(uint32_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 17;
	*state ^= *state << 5;
	return *state;
}

static void report(int fails, struct simm p0, struct simm p1, const char *variant, const struct result *r)
{
	__atomic_fetch_add(&sh->fails, 1, __ATOMIC_RELAXED);
	for (int k = 0; k < KINDS; k++)
		if (fails & 1 << k && !__atomic_fetch_add(&sh->kind_cases[k], 1, __ATOMIC_RELAXED))
			snprintf(sh->example[k], sizeof(sh->example[k]),
				 "pairs %d/%d/%d %d/%d/%d (rows/cols/sides), %s: 13h=%02x 14h=%02x 19h=%02x top %u KiB",
				 p0.rows, p0.cols, p0.sides, p1.rows, p1.cols, p1.sides, variant, r->regs[0], r->regs[1],
				 r->regs[2], r->top >> 10);
}

static void worker(void)
{
	struct result clean, r;
	char variant[64];

	for (int combo; (combo = __atomic_fetch_add(&sh->next, 1, __ATOMIC_RELAXED)) < GEOMETRIES * GEOMETRIES;) {
		struct simm p0 = geometry(combo % GEOMETRIES), p1 = geometry(combo / GEOMETRIES);
		uint32_t state = 0x9e3779b9u ^ combo * 2654435761u;
		unsigned cases = 0;

		recording = 1;
		read_count = 0;
		run(p0, p1, combo, 0, 0, 0, &clean);
		recording = 0;
		int fails = check(p0, p1, &clean, &clean, 0);
		if (!clean.halted && !one_to_one(clean.regs, clean.top))
			fails |= ALIAS;
		if (fails)
			report(fails, p0, p1, "no fault", &clean);
		cases++;

		/* the floating bus, then a faulty bit at each dword read, at random addresses, in random count blocks */
		for (int i = -1; i < read_count + RANDOM_FAULTS; i++) {
			uint32_t addr = i < 0 ? 0 : i < read_count ? reads[i] + rng(&state) % 4 :
					i < read_count + RANDOM_FAULTS / 2 ? rng(&state) % (256u << 20) :
					rng(&state) % (clean.top ? clean.top : 1) & ~0xffffu;
			uint8_t mask = i < 0 ? 0 : 1 << rng(&state) % 8;
			run(p0, p1, combo + i, i < 0, addr, mask, &r);
			fails = check(p0, p1, &r, &clean, i >= 0);
			if (fails) {
				snprintf(variant, sizeof(variant), i < 0 ? "bus floating to the last value" :
					 "bit %d of byte %08x stuck at 0", __builtin_ctz(mask | 0x100), addr);
				report(fails, p0, p1, variant, &r);
			}
			cases++;
		}
		__atomic_fetch_add(&sh->cases, cases, __ATOMIC_RELAXED);
	}
}

/* A line of simm_configs.txt: the fork's SIMM types, memory KB or hang@, 13h 14h 19h, [stuck=] [ours=] */
static int check_oracle(char *line)
{
	char *tok[12];
	int n = 0;

	if (line[0] == '#')
		return 0;
	for (char *t = strtok(line, " \t\n"); t && n < 12; t = strtok(NULL, " \t\n"))
		tok[n++] = t;
	if (n == 0)
		return 0;
	if (n < 6) {
		printf("FAIL oracle: %d fields\n", n);
		return 1;
	}
	unsigned want[4] = { atoi(tok[2]), strtoul(tok[3], 0, 16), strtoul(tok[4], 0, 16), strtoul(tok[5], 0, 16) };
	uint32_t stuck = 0;
	int bit = -1;
	for (int i = 6; i < n; i++)
		if (!strncmp(tok[i], "ours=", 5))
			sscanf(tok[i] + 5, "%u,%x,%x,%x", &want[0], &want[1], &want[2], &want[3]);
		else if (!strncmp(tok[i], "stuck=", 6))
			sscanf(tok[i] + 6, "%x:%d", &stuck, &bit);
	struct result r;
	run(simm_types[atoi(tok[0])], simm_types[atoi(tok[1])], 1, 0, stuck, bit < 0 ? 0 : 1 << bit, &r);
	unsigned got[4] = { r.top >> 10, r.regs[0], r.regs[1], r.regs[2] };
	if (memcmp(got, want, sizeof(got))) {
		printf("FAIL oracle %s %s: %u KB %02x %02x %02x, expected %u KB %02x %02x %02x\n", tok[0], tok[1], got[0],
		       got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
		return 1;
	}
	return 0;
}

int main(void)
{
	char line[256];
	int oracle_lines = 0, oracle_fails = 0;

	m = malloc(sizeof(*m));
	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (!m || sh == MAP_FAILED) {
		perror("dramfuzz");
		return 2;
	}
	memset(m, 0, sizeof(*m));
	while (fgets(line, sizeof(line), stdin)) {
		oracle_lines += line[0] != '#' && strspn(line, " \t\n") != strlen(line);
		oracle_fails += check_oracle(line);
	}

	long workers = sysconf(_SC_NPROCESSORS_ONLN);
	struct timespec t0, t1;
	fflush(stdout);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (long i = 0; i < workers; i++) {
		pid_t pid = fork();
		if (pid < 0) {
			perror("fork");
			return 2;
		}
		if (!pid) {
			worker();
			_exit(0);
		}
	}
	int worker_failures = 0;
	for (long i = 0; i < workers; i++) {
		int status;
		if (wait(&status) < 0) {
			perror("wait");
			return 2;
		}
		worker_failures += !WIFEXITED(status) || WEXITSTATUS(status);
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	double seconds = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

	printf("%u cases (%d SIMM pair geometries, each without fault, floating bus, faulty bits) in %.2f s: "
	       "%.0f cases/s, %ld workers\n", sh->cases, GEOMETRIES * GEOMETRIES, seconds, sh->cases / seconds, workers);
	printf("oracle: %d of %d lines match\n", oracle_lines - oracle_fails, oracle_lines);
	printf("%u cases fail\n", sh->fails);
	for (int k = 0; k < KINDS; k++)
		if (sh->kind_cases[k])
			printf("  %u: %s, e.g. %s\n", sh->kind_cases[k], kind_names[k], sh->example[k]);
	return worker_failures || sh->fails || oracle_fails || !oracle_lines ? 1 : 0;
}
