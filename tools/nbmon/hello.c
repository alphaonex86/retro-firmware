/* Example NBMON payload: prints a line, returns its argument + 1234h. */
#include "nbmon_api.h"

NBMON_ENTRY uint32_t
hello(uint32_t arg, const struct nbmon_api *api)
{
    for (const char *s = "HELLO FROM PAYLOAD\r\n"; *s; s++)
        api->putc(*s);
    return arg + 0x1234;
}
