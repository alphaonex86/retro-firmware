/* Fuzzes the CMOS values coreboot reads on the Aptiva 2168: newbios.c (compiled unchanged) runs its romstage chipset
   options and the ramstage PIRQ routing (pirq_routing.c, irq_tables.c, the 82C558M's pirq.c) against CMOS, 82C557M
   index register and PCI seams. */
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "newbios.c"
#include <device/pci.h>
#include <southbridge/opti/82c558m/82c558m.h>

unsigned long write_pirq_routing_table(unsigned long addr);

struct cmos_case {
	u8 settings[NB_COUNT];
	int byte255;		/* CMOS byte set to FFh (sum kept right), else -1 */
	int validity;		/* 0 valid, 1 wrong signature, 2 wrong sum */
	u8 bootfail;
};

enum { TRAP = 1, FIELD_BITS = 2, FIELD_VALUE = 4, MANUAL_AUTO = 8, BOOTFAIL = 16, PIRQ = 32, KINDS = 6 };
static const char *const kind_names[KINDS] = {
	"trap (array bounds, division by zero or shift)", "82C557M bits outside NB_VIPERM_FIELDS written",
	"82C557M field written with a value outside its domain", "82C557M written with Auto, an invalid CMOS or too many "
	"unfinished POSTs, or a manual value in range not applied", "boot failure counter not counted",
	"PCI IRQ the 82C558M cannot route, outside the slot's bitmap and the setup's choices, or 40h-42h bits outside the links"
};

static const u8 slot_devs[CONFIG_IRQ_SLOT_COUNT] = { 0x07, 0x0b, 0x0c };	/* irq_tables.c's order */

struct machine {
	u8 cmos[128];
	u8 idx[256], index;	/* 82C557M index registers */
	u8 isa[256];		/* 82C558M configuration space */
	int writes;
	u8 irq_slot[CONFIG_IRQ_SLOT_COUNT][4];
	sigjmp_buf trap;
};
static __thread struct machine *mc;

static void fatal(const char *what, unsigned value)
{
	fprintf(stderr, "cmosfuzz: %s %x\n", what, value);
	exit(2);
}

int printk(int level, const char *fmt, ...)
{
	(void)level;
	(void)fmt;
	return 0;
}

u8 cmos_read(u8 addr)
{
	if (addr >= sizeof(mc->cmos))
		fatal("CMOS read at", addr);
	return mc->cmos[addr];
}

void cmos_write(u8 value, u8 addr)
{
	if (addr >= sizeof(mc->cmos))
		fatal("CMOS write at", addr);
	mc->cmos[addr] = value;
}

u8 inb(u16 port)
{
	if (port != 0x24)
		fatal("inb from port", port);
	return mc->idx[mc->index];
}

void outb(u8 value, u16 port)
{
	if (port == 0x22)
		mc->index = value;
	else if (port == 0x24) {
		mc->idx[mc->index] = value;
		mc->writes++;
	} else
		fatal("outb to port", port);
}

static u8 *isa_config(pci_devfn_t dev, u16 reg)
{
	if (reg > 0xfe || dev != ISA_BRIDGE)
		fatal("config access, bdf/reg", dev << 8 | reg);
	return mc->isa + reg;
}

u8 pci_s_read_config8(pci_devfn_t dev, u16 reg)
{
	return *isa_config(dev, reg);
}

u16 pci_s_read_config16(pci_devfn_t dev, u16 reg)
{
	return isa_config(dev, reg)[0] | isa_config(dev, reg)[1] << 8;
}

void pci_s_write_config8(pci_devfn_t dev, u16 reg, u8 value)
{
	*isa_config(dev, reg) = value;
}

void pci_s_write_config16(pci_devfn_t dev, u16 reg, u16 value)
{
	isa_config(dev, reg)[0] = value;
	isa_config(dev, reg)[1] = value >> 8;
}

static struct device slots[32];

struct device *pcidev_path_on_bus(unsigned int bus, pci_devfn_t devfn)
{
	if (bus || devfn >= 0x100)
		fatal("device path", bus << 8 | devfn);
	slots[devfn >> 3].bdf = PCI_DEV(0, devfn >> 3, devfn & 7);
	return &slots[devfn >> 3];
}

void pci_assign_irqs(struct device *dev, const unsigned char irqs[4])
{
	for (int s = 0; s < CONFIG_IRQ_SLOT_COUNT; s++)
		if (((dev->bdf >> 15) & 0x1f) == slot_devs[s]) {
			memcpy(mc->irq_slot[s], irqs, 4);
			return;
		}
	fatal("IRQs assigned to device", dev->bdf);
}

void pci_dev_write_config8(const struct device *dev, u16 reg, u8 value)
{
	(void)dev, (void)reg, (void)value;
}

static void on_trap(int sig)
{
	(void)sig;
	siglongjmp(mc->trap, 1);
}

static const struct nb_field fields[] = { NB_VIPERM_FIELDS };

/* The 82C557M after romstage (Auto, 66 MHz) and the 82C558M before the PIRQ routing (IBM: 40h-42h, 47h). */
static void apply_case(const struct cmos_case *c)
{
	static const u8 idx_defaults[][2] = {
		{ 0x01, 0xdd }, { 0x02, 0x33 }, { 0x08, 0x2c }, { 0x12, 0x02 }, { 0x13, 0xbb }, { 0x14, 0x80 },
	};
	u16 sum = 0;

	memset(mc->cmos, 0, sizeof(mc->cmos));
	for (int i = 0; i < NB_COUNT; i++)
		mc->cmos[NB_CMOS_BASE + i / 2] |= c->settings[i] << (i % 2 * 4);
	if (c->byte255 >= 0)
		mc->cmos[c->byte255] = 0xff;
	mc->cmos[NB_CMOS_SIG] = c->validity == 1 ? NB_SIG_VALUE ^ 1 : NB_SIG_VALUE;
	for (int i = NB_CMOS_BASE; i <= NB_CMOS_SIG; i++)
		sum += mc->cmos[i];
	sum += c->validity == 2;
	mc->cmos[NB_CMOS_SUM] = sum >> 8;
	mc->cmos[NB_CMOS_SUM + 1] = sum;
	mc->cmos[NB_CMOS_BOOTFAIL] = c->bootfail;
	memset(mc->idx, 0, sizeof(mc->idx));
	for (unsigned i = 0; i < ARRAY_SIZE(idx_defaults); i++)
		mc->idx[idx_defaults[i][0]] = idx_defaults[i][1];
	memset(mc->isa, 0, sizeof(mc->isa));
	mc->isa[PIRQ_ROUTE + 1] = 0x30;		/* bits 13:12, not links */
	mc->isa[MISC_1] = 0x01;
	mc->isa[CYCLE_CTL] = 0x40;
	mc->writes = 0;
}

static int field_failures(const u8 *idx0)
{
	u8 allowed[256] = { 0 };
	int fails = 0;

	for (unsigned i = 0; i < ARRAY_SIZE(fields); i++) {
		const struct nb_field *f = &fields[i];
		int ok = (mc->idx[f->reg] & f->mask) == (idx0[f->reg] & f->mask);
		for (int v = 0; v < f->count; v++)
			ok |= (mc->idx[f->reg] & f->mask) == f->value[v];
		allowed[f->reg] |= f->mask;
		if (!ok)
			fails |= FIELD_VALUE;
	}
	for (int reg = 0; reg < 256; reg++)
		if ((mc->idx[reg] ^ idx0[reg]) & ~allowed[reg])
			fails |= FIELD_BITS;
	return fails;
}

/* The 82C558M's IRQ codes (pirq.c); setup offers 5, 9-12, 14, 15 (newbios.c). */
static const u8 router_irqs[8] = { 0, 5, 9, 10, 11, 12, 14, 15 };
#define SETUP_IRQS 0xde20

static int pirq_failures(const struct irq_routing_table *rt, const u8 *isa0)
{
	u16 links = mc->isa[PIRQ_ROUTE] | mc->isa[PIRQ_ROUTE + 1] << 8, link_mask[5] = { 0 };
	u8 level = 0;
	int fails = 0;

	for (int s = 0; s < CONFIG_IRQ_SLOT_COUNT; s++)
		for (int intx = 0; intx < 4; intx++) {
			u8 irq = mc->irq_slot[s][intx], link = rt->slots[s].irq[intx].link;
			u16 bitmap = rt->slots[s].irq[intx].bitmap;
			if (link <= 4)
				link_mask[link] |= bitmap;
			if (irq && (irq > 15 || !((bitmap | SETUP_IRQS) >> irq & 1)))
				fails |= PIRQ;
		}
	for (int link = 0; link < 4; link++) {
		u8 irq = router_irqs[links >> (3 * link) & 7];
		if (irq && !((link_mask[link + 1] | SETUP_IRQS) >> irq & 1))
			fails |= PIRQ;
		for (int code = 1; code < 8; code++)
			if (irq == router_irqs[code])
				level |= 1 << code;
	}
	if ((links & 0xf000) != (isa0[PIRQ_ROUTE + 1] << 8 & 0xf000) || mc->isa[MISC_1] != (level | (isa0[MISC_1] & 1)))
		fails |= PIRQ;
	for (int reg = 0; reg < 256; reg++)
		if (reg != PIRQ_ROUTE && reg != PIRQ_ROUTE + 1 && reg != MISC_1 && mc->isa[reg] != isa0[reg])
			fails |= PIRQ;
	return fails;
}

static int run_case(const struct cmos_case *c)
{
	static __thread unsigned long table[(32 + 16 * CONFIG_IRQ_SLOT_COUNT) / sizeof(long) + 4];
	u8 idx0[256], isa0[256];

	apply_case(c);
	volatile int manual = !c->validity && !NB_CMOS_GET(cmos_read, NB_CHIPSET_AUTO) && c->bootfail < NB_BOOTFAIL_MAX;
	memcpy(idx0, mc->idx, sizeof(idx0));
	memcpy(isa0, mc->isa, sizeof(isa0));
	memset(mc->irq_slot, 0, sizeof(mc->irq_slot));
	if (sigsetjmp(mc->trap, 1))
		return TRAP;
	newbios_chipset_options();
	int fails = mc->cmos[NB_CMOS_BOOTFAIL] != (c->bootfail < 0xff ? c->bootfail + 1 : 0xff) ? BOOTFAIL : 0;
	if (!manual && mc->writes)
		fails |= MANUAL_AUTO;
	for (unsigned i = 0; manual && i < ARRAY_SIZE(fields); i++) {
		const struct nb_field *f = &fields[i];
		u8 v = NB_CMOS_GET(cmos_read, f->setting);
		if (v < f->count && (mc->idx[f->reg] & f->mask) != f->value[v])
			fails |= MANUAL_AUTO;
	}
	unsigned long addr = ALIGN_UP((unsigned long)table, 16);
	write_pirq_routing_table(addr);
	return fails | field_failures(idx0) | pirq_failures((const struct irq_routing_table *)addr, isa0);
}

static const u8 bootfails[] = { 0, NB_BOOTFAIL_MAX - 1, NB_BOOTFAIL_MAX, NB_BOOTFAIL_MAX + 1, 254, 255 };

static struct cmos_case *cases;
static int case_count, case_max;

static struct cmos_case *new_case(void)
{
	if (case_count == case_max && !(cases = realloc(cases, (case_max = 2 * case_max + 1024) * sizeof(*cases))))
		fatal("out of memory, cases", case_max);
	struct cmos_case *c = &cases[case_count++];
	memset(c, 0, sizeof(*c));
	c->byte255 = -1;
	return c;
}

/* Smallest cases first, so the first failing case of a kind is a minimal one. */
static void build_cases(void)
{
	for (int auto_on = 0; auto_on < 2; auto_on++)
		for (int validity = 0; validity < 3; validity++)
			for (unsigned b = 0; b < ARRAY_SIZE(bootfails); b++) {
				struct cmos_case *c = new_case();
				c->settings[NB_CHIPSET_AUTO] = auto_on;
				c->validity = validity;
				c->bootfail = bootfails[b];
			}
	for (int auto_on = 0; auto_on < 2; auto_on++)
		for (unsigned b = 0; b < ARRAY_SIZE(bootfails); b++) {
			for (int setting = 0; setting < NB_COUNT; setting++)
				for (int value = 0; value < 16; value++) {
					struct cmos_case *c = new_case();
					c->settings[NB_CHIPSET_AUTO] = auto_on;
					c->settings[setting] = value;
					c->bootfail = bootfails[b];
				}
			for (int byte = NB_CMOS_BASE; byte <= NB_CMOS_BASE + (NB_COUNT - 1) / 2; byte++) {
				struct cmos_case *c = new_case();
				c->settings[NB_CHIPSET_AUTO] = auto_on;
				c->byte255 = byte;
				c->bootfail = bootfails[b];
			}
		}
	for (int a = 0; a < 16; a++)		/* every pair of PCI IRQ settings on two links */
		for (int b = 0; b < 16; b++)
			for (int link = 0; link < 3; link++) {
				struct cmos_case *c = new_case();
				c->settings[NB_PCI_IRQ_A + link] = a;
				c->settings[NB_PCI_IRQ_A + link + 1] = b;
			}
	uint64_t x = 0x2545f4914f6cdd1dULL;
	for (int n = 0; n < 100000; n++) {
		struct cmos_case *c = new_case();
		for (int i = 0; i < NB_COUNT; i++) {
			x ^= x << 13, x ^= x >> 7, x ^= x << 17;
			c->settings[i] = x & 15;
		}
		c->validity = (x >> 8) % 8 == 0 ? 1 + (x >> 11) % 2 : 0;
		c->bootfail = bootfails[(x >> 16) % ARRAY_SIZE(bootfails)];
	}
}

static int *results;
static int next_case;

static void *worker(void *unused)
{
	(void)unused;
	if (!(mc = calloc(1, sizeof(*mc))))
		fatal("out of memory, bytes", sizeof(*mc));
	for (int i; (i = __atomic_fetch_add(&next_case, 1, __ATOMIC_RELAXED)) < case_count;)
		results[i] = run_case(&cases[i]);
	return NULL;
}

static void print_case(const struct cmos_case *c)
{
	static const char *const validity[] = { "valid", "wrong signature", "wrong sum" };

	printf("CMOS %s", validity[c->validity]);
	for (int i = 0; i < NB_COUNT; i++)
		if (c->settings[i])
			printf(", setting %d=%d", i, c->settings[i]);
	if (c->byte255 >= 0)
		printf(", byte %02Xh=FFh", c->byte255);
	printf(", BOOTFAIL=%d", c->bootfail);
}

int main(void)
{
	struct sigaction trap = { .sa_handler = on_trap };
	struct timespec t0, t1;
	pthread_t threads[256];
	long workers = sysconf(_SC_NPROCESSORS_ONLN);

	if (sigaction(SIGILL, &trap, NULL) || sigaction(SIGFPE, &trap, NULL)) {
		perror("sigaction");
		return 2;
	}
	if (workers < 1 || workers > 256)
		fatal("CPUs", workers);
	build_cases();
	if (!(results = calloc(case_count, sizeof(*results))))
		fatal("out of memory, cases", case_count);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (long i = 0; i < workers; i++)
		if (pthread_create(&threads[i], NULL, worker, NULL)) {
			perror("pthread_create");
			return 2;
		}
	for (long i = 0; i < workers; i++)
		if (pthread_join(threads[i], NULL)) {
			perror("pthread_join");
			return 2;
		}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	double seconds = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	printf("%d cases in %.2f s: %.0f cases/s, %ld workers\n", case_count, seconds, case_count / seconds, workers);

	int failing = 0;
	for (int kind = 0; kind < KINDS; kind++) {
		int count = 0, first = -1;
		for (int i = 0; i < case_count; i++)
			if (results[i] & (1 << kind) && !count++)
				first = i;
		failing += count;
		if (!count)
			continue;
		printf("FAIL %d cases: %s; first: ", count, kind_names[kind]);
		print_case(&cases[first]);
		printf("\n");
	}
	return failing ? 1 : 0;
}
