/*
 * dramprobe: what the IBM Aptiva 2168's 82C557M sees in SIMM pair J27/J28 (14h), on the real silicon. Under Linux,
 * as root, when Linux does not use that pair (the firmware left it out, or mem=), it reports:
 *  - where the pair answers, MB by MB, for each bank code (map);
 *  - the IBM BIOS's MB count (BG2US0J F000:120B) and side B check, and the code byte it would pick;
 *  - our raminit.c probe (coreboot-486 northbridge/opti/viperm), each vote;
 *  - per code 1-5 of each side: the address lines that alias, the data bits that fail per SIMM (low/high dword);
 *  - every dword of the pair at the IBM BIOS's code, with its address and then the complement.
 * Only 14h changes, interrupts off (iopl 3: cli), and it is back before they are on: PCI BARs above the firmware's
 * DRAM top lie in that range; an MB holding a BAR under 1 MB (device registers) is never written. Build for the 486/P5 (static, uClibc), e.g. with the HDD image's toolchain:
 *   i486-buildroot-linux-uclibc-gcc -O2 -static -o dramprobe tools/dramprobe.c
 * boards/aptiva2168/test/dramprobe.sh runs it on the DRAM model (-DMODEL).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MB (1u << 20)
#define WINDOW (128 * MB)

#ifdef MODEL
#include "viperm_model.h"
extern struct model *model;
#define reg_read(idx) (model->regs[idx])
#define reg_write(idx, v) (model->regs[idx] = (v))
#define refresh_bit() (rand() & 0x10)
#define interrupts(on) ((void)0)
#define FULL_STEP 0x10000	/* the model's store holds 16K dwords */
static uint32_t base;
static uint32_t rd(uint32_t a) { return model_read32(model, base + a); }
static void write_dword(uint32_t a, uint32_t v) { model_write32(model, base + a, v); }
int dramprobe_main(int argc, char **argv);
#define main dramprobe_main
#else
#include <fcntl.h>
#include <sys/io.h>
#include <sys/mman.h>
#define reg_read(idx) (outb(idx, 0x22), inb(0x24))
#define reg_write(idx, v) (outb(idx, 0x22), outb(v, 0x24))
#define refresh_bit() (inb(0x61) & 0x10)
#define FULL_STEP 4
static uint32_t base;
static volatile uint32_t *win;
static uint32_t rd(uint32_t a) { return win[a / 4]; }
static void write_dword(uint32_t a, uint32_t v) { win[a / 4] = v; }
static void interrupts(int on)
{
	if (on)
		__asm__ volatile("sti");
	else
		__asm__ volatile("cli");
}
#endif

static uint8_t reg14;	/* 14h as the firmware left it */
static uint8_t busy[WINDOW / MB];	/* MBs of the window with device registers */

static void wr(uint32_t a, uint32_t v)
{
	if (!busy[a / MB])
		write_dword(a, v);
}

/* 14h, then 128 refresh toggles of port 61h bit 4 (about 2 ms), as the IBM BIOS */
static void decode(uint8_t value)
{
	uint8_t last = refresh_bit();

	reg_write(0x14, value);
	for (int toggles = 0, reads = 0; toggles < 128 && reads < 100000; reads++) {
		uint8_t now = refresh_bit();
		toggles += now != last;
		last = now;
	}
}

static void enter(uint8_t value)
{
	interrupts(0);
	decode(value);
}

static void leave(void)
{
	decode(reg14);
	interrupts(1);
}

/* Which MB of the window each MB shows: its own ('o'), another's ('a'), nothing ('.'); '-': not written */
static void map(uint8_t value)
{
	char line[WINDOW / MB + 1] = { 0 };

	enter(value);
	for (uint32_t mb = 0; mb < WINDOW / MB; mb++) {
		wr(mb * MB + 0xf0, 0x5a000000 | mb);
		wr(mb * MB + 0xf4, 0);
	}
	for (uint32_t mb = 0; mb < WINDOW / MB; mb++) {
		uint32_t v = rd(mb * MB + 0xf0);
		line[mb] = busy[mb] ? '-' : v == (0x5a000000 | mb) ? 'o' : (v & 0xffffff80) == 0x5a000000 ? 'a' : '.';
	}
	leave();
	printf("map 14h=%02x %s\n", value, line);
}

/* The IBM BIOS's MBs of 0-64 MB whose 8 dword pairs keep their address */
static unsigned int ibm_count(void)
{
	unsigned int kept = 0;

	for (uint32_t mb = 0; mb < 64 * MB; mb += MB)
		for (uint32_t a = mb + 0xf0; a < mb + 0x2000; a += 0x400) {
			wr(a, base + a);
			wr(a + 4, base + a);
		}
	for (uint32_t mb = 0; mb < 64 * MB; mb += MB)
		for (uint32_t a = mb + 0xf0; a < mb + 0x2000; a += 0x400)
			kept += rd(a) == base + a;
	return kept / 8;
}

static uint8_t ibm_code(void)
{
	static const uint8_t codes[] = { 0x00, 0x01, 0x11, 0x03, 0x33, 0x05, 0x55 };

	enter(0x80 | 0x55);
	unsigned int n = ibm_count(), side_b = 1;
	uint8_t code = n ? codes[__builtin_ctz(n)] : 0;
	if (n & 0x54) {
		decode(0x80 | code);
		wr(n * MB / 2, 0xa2d75a5a);
		wr(n * MB / 2 + 4, 0);
		side_b = rd(n * MB / 2) == 0xa2d75a5a;
	}
	leave();
	if (!side_b)
		code = (code & 7) + 1;
	printf("IBM count at 14h=d5: %u MB, side B check %s: code byte %02x\n", n,
	       n & 0x54 ? side_b ? "kept" : "lost" : "not needed", code);
	return code;
}

/* raminit.c's distinct(): the dword at a keeps its pattern when the complement goes to a + delta, 3 votes */
static int distinct(uint32_t a, uint32_t delta, char *votes)
{
	static const uint16_t offsets[] = { 0x000, 0x48c, 0x918 };
	int kept = 0;

	for (int i = 0; i < 3; i++) {
		uint32_t p = a + offsets[i], pattern = (base + p) ^ 0x5aa5c33c;
		wr(p, pattern);
		wr(p + delta, ~pattern);
		uint32_t v = rd(p);
		kept += v == pattern;
		votes += sprintf(votes, " %08x%s", v, v == pattern ? "" : v == ~pattern ? "(alias)" : "(bad)");
	}
	return kept >= 2;
}

static void ours(void)
{
	char votes[2][64];

	enter(0x80 | 0x55);
	for (int side = 0; side < 2; side++) {
		uint32_t a = side * 32 * MB;
		int rows = 0, cols = 0, present = distinct(a, 8, votes[0]);
		if (present) {
			while (rows < 2 && distinct(a, 2 * MB << (2 * rows), votes[1]))
				rows++;
			while (cols < 2 && distinct(a, 4 * MB << (2 * cols), votes[1]))
				cols++;
		}
		int code = present ? 2 * rows + 1 < 2 * cols + 2 ? 2 * rows + 1 : 2 * cols + 2 : 0;
		printf("ours side %c: code %d (rows %d, cols %d; dwords after a write at +8:%s)\n", 'A' + side,
		       code > 5 ? 5 : code, rows, cols, votes[0]);
	}
	leave();
}

/* Side (0 A, 1 B) at code: the address bits that alias, and the failing data bits of each dword at 4 places */
static void lines(int side, int code)
{
	uint8_t value = 0x80 | code | (side ? code << 4 : 0);
	uint32_t start = side ? MB << code : 0, size = MB << code, aliases = 0, bad[2] = { 0, 0 };

	enter(value);
	for (int bit = 3; (1u << bit) < size; bit++) {
		wr(start, 0x3c5aa5c3);
		wr(start + (1u << bit), 0xc3a55a3c);
		aliases |= (rd(start) != 0x3c5aa5c3) << bit;
	}
	for (uint32_t place = 0; place < 4; place++) {
		uint32_t a = start + place * (size / 4) + 0x7f8;
		for (int bit = 0; bit < 64; bit++) {
			uint32_t ones = 1u << (bit % 32);
			for (int invert = 0; invert < 2; invert++) {
				uint32_t pattern = invert ? ~ones : ones;
				wr(a + bit / 32 * 4, pattern);
				wr(a + 8 + bit / 32 * 4, ~pattern);
				bad[bit / 32] |= rd(a + bit / 32 * 4) ^ pattern;
			}
		}
	}
	leave();
	printf("side %c code %d (14h=%02x): aliasing address bits %08x, failing data bits low dword %08x, high %08x\n",
	       'A' + side, code, value, aliases, bad[0], bad[1]);
}

/* Every FULL_STEP of the pair at code byte: its address, then the complement; the first 8 errors */
static void full(uint8_t code)
{
	uint32_t size = 0, errors = 0;

	for (int bank = 0; bank < 2; bank++)
		size += code >> 4 * bank & 7 ? MB << (code >> 4 * bank & 7) : 0;
	if (!size)
		return;
	enter(0x80 | code);
	uint32_t first[8][2];
	for (uint32_t flip = 0; flip < 2; flip++) {
		for (uint32_t a = 0; a < size; a += FULL_STEP)
			wr(a, (base + a) ^ -flip);
		for (uint32_t a = 0; a < size; a += FULL_STEP) {
			uint32_t v = rd(a) ^ (base + a) ^ -flip;
			if (v && errors < 8)
				first[errors][0] = base + a, first[errors][1] = v;
			errors += v != 0;
		}
	}
	leave();
	printf("full test 14h=%02x, %u MB from %u MB: %u errors\n", 0x80 | code, size / MB, base / MB, errors);
	for (uint32_t i = 0; i < errors && i < 8; i++)
		printf("  %08x: bits %08x wrong\n", first[i][0], first[i][1]);
}

/* The end of the RAM Linux uses (top-level System RAM of /proc/iomem); busy[]: the MBs with ranges under 1 MB */
static uint32_t linux_ram_top(void)
{
#ifdef MODEL
	return base;
#else
	FILE *f = fopen("/proc/iomem", "r");
	char line[128];
	unsigned long long first, last, top = 0;

	if (!f) {
		perror("dramprobe: /proc/iomem");
		exit(1);
	}
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "%llx-%llx", &first, &last) != 2)
			continue;
		if (line[0] != ' ' && strstr(line, ": System RAM") && last + 1 > top)
			top = last + 1;
		if (!strstr(line, "System RAM") && last - first + 1 < MB)
			for (unsigned long long mb = first / MB; mb <= last / MB; mb++)
				if (mb >= base / MB && mb < (base + WINDOW) / MB)
					busy[mb - base / MB] = 1;
	}
	fclose(f);
	if (!top) {
		fprintf(stderr, "dramprobe: no System RAM in /proc/iomem (not root?)\n");
		exit(1);
	}
	return top;
#endif
}

int main(int argc, char **argv)
{
	(void)argv;
	if (argc != 1) {
		fprintf(stderr, "usage: dramprobe   (root, on the IBM Aptiva 2168)\n");
		return 2;
	}
#ifndef MODEL
	if (iopl(3)) {
		perror("dramprobe: iopl");
		return 1;
	}
#endif
	uint8_t r13 = reg_read(0x13), r19 = reg_read(0x19);
	reg14 = reg_read(0x14);
	base = 0;
	for (int bank = 0; bank < 2; bank++)
		base += r13 >> 4 * bank & 7 ? MB << (r13 >> 4 * bank & 7) : 0;
	uint32_t ram_top = linux_ram_top();
	printf("82C557M 13h %02x 14h %02x 19h %02x: J27/J28 from %u MB; Linux RAM ends at %u KB\n", r13, reg14, r19,
	       base / MB, ram_top / 1024);
	if (ram_top > base || (reg14 & 0x80) != 0x80 || (r13 & 0x80) != 0x80) {
		fprintf(stderr, "dramprobe: Linux uses J27/J28, or 13h/14h are not in full decode: not touched "
			"(boot with mem=%uM)\n", base / MB);
		return 1;
	}
#ifndef MODEL
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("dramprobe: /dev/mem");
		return 1;
	}
	win = mmap(NULL, WINDOW, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, base);
	if (win == MAP_FAILED || mlockall(MCL_CURRENT)) {
		perror("dramprobe: mmap /dev/mem");
		return 1;
	}
#endif
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int code = 1; code <= 5; code++)
		map(0x80 | code);
	map(0x80 | 0x55);
	uint8_t ibm = ibm_code();
	ours();
	for (int side = 0; side < 2; side++)
		for (int code = 1; code <= 5; code++)
			lines(side, code);
	full(ibm);
	printf("14h back to %02x\n", reg_read(0x14));
	return 0;
}
