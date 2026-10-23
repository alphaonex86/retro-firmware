/* tools/dramprobe.c (-DMODEL) on the 82C557M DRAM model: usage <pair 0 type> <pair 1 type> <13h> <14h> <19h>
   [<faulty byte address> <bit>] */
#include <stdlib.h>

#include "viperm_model.h"

struct model *model;
int dramprobe_main(int argc, char **argv);

int main(int argc, char **argv)
{
	char *args[] = { "dramprobe", NULL };

	if (argc != 6 && argc != 8)
		return 2;
	model = calloc(1, sizeof(*model));
	if (!model)
		return 2;
	model_reset(model, simm_types[atoi(argv[1])], simm_types[atoi(argv[2])], 1);
	model->regs[0x13] = strtoul(argv[3], NULL, 16);
	model->regs[0x14] = strtoul(argv[4], NULL, 16);
	model->regs[0x19] = strtoul(argv[5], NULL, 16);
	if (argc == 8) {
		model->stuck_addr = strtoul(argv[6], NULL, 16);
		model->stuck_mask = 1 << atoi(argv[7]);
	}
	return dramprobe_main(1, args);
}
