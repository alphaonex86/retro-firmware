/* NBMON payload interface (seabios-486 src/nbmon.c). The monitor's "call ADDR ARG" runs the NBMON_ENTRY function as
   uint32_t f(uint32_t arg, const struct nbmon_api *api): 32-bit flat protected mode, interrupts off, cdecl; the
   value it returns is printed. */
#ifndef NBMON_API_H
#define NBMON_API_H
#include <stdint.h>

struct nbmon_api {
    void (*putc)(int c);              /* COM1; lines end in "\r\n" */
    int (*getc)(uint32_t timeout_ms); /* -1 on timeout; 0xffffffff: wait */
    void (*mdelay)(uint32_t ms);
    uint32_t (*ticks)(void);          /* milliseconds, wraps */
};

#define NBMON_ENTRY __attribute__((section(".text.nbmon_entry")))

#endif
