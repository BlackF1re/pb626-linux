/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Execute the production SPL LED code against a deterministic PE8 MMIO model. */
#include <assert.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "pb626-test-mmio.h"
#include "linux/delay.h"
#include "pb626-led.c"

#define PE_CFG1 0x01c20894U
#define PE_DATA 0x01c208a0U
#define LED_BIT (1U << 8)
#define MAX_PHASES 20

static uint32_t cfg1, data;
static jmp_buf escape;
static unsigned target, writes, delays;
static unsigned long durations[MAX_PHASES];
static int on[MAX_PHASES];

uint32_t pb626_test_readl(uintptr_t address)
{
	if (address == PE_CFG1) return cfg1;
	if (address == PE_DATA) return data;
	assert(!"unexpected MMIO read");
	return 0;
}

void pb626_test_writel(uint32_t value, uintptr_t address)
{
	if (address == PE_CFG1) cfg1 = value;
	else if (address == PE_DATA) {
		data = value;
		if (writes < MAX_PHASES)
			on[writes++] = !(value & LED_BIT);
	} else assert(!"unexpected MMIO write");
}

void pb626_test_udelay(unsigned long usec)
{
	assert(delays < MAX_PHASES);
	durations[delays++] = usec;
	if (delays == target)
		longjmp(escape, 1);
}

static void reset_model(void)
{
	cfg1 = 0xffffffffU;
	data = 0xffffffffU;
	writes = delays = 0;
	target = 0;
	memset(durations, 0, sizeof(durations));
	memset(on, 0, sizeof(on));
}

static void test_startup_handoff(void)
{
	reset_model();
	spl_board_prepare_for_boot();
	assert((cfg1 & 0xfU) == 1U);
	assert(!(data & LED_BIT)); /* PE8 low = LED on */
	assert(writes == 1 && on[0] == 1);
	assert(delays == 0); /* no boot delay */
}

static void test_error_cycle(unsigned code)
{
	unsigned period = code < 10 ? 10 : 20;
	reset_model();
	target = period;
	if (!setjmp(escape))
		pb626_led_error(code);
	assert(writes == period && delays == period);
	assert((cfg1 & 0xfU) == 1U);
	for (unsigned phase = 0; phase < period; ++phase) {
		int ticks = pb626_morse_step(code, phase);
		unsigned long expected = (unsigned long)(ticks > 0 ? ticks : -ticks) *
					 PB626_MORSE_T_MS * 1000UL;
		assert(on[phase] == (ticks > 0));
		assert(durations[phase] == expected);
	}
	assert(!!(data & LED_BIT) == !on[period - 1]);
}

int main(void)
{
	test_startup_handoff();
	for (unsigned code = 1; code <= 13; ++code)
		test_error_cycle(code);
	/* Invalid callers fall back to a bounded, recognizable DRAM-init code. */
	test_error_cycle(0);
	test_error_cycle(14);
	puts("PE8 MMIO model: no-delay handoff and all 13 Morse cycles passed");
	return 0;
}
