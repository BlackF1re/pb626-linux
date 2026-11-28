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

static uint32_t cfg1, data, gate, rtc, magic1, magic2, clock_count;
static jmp_buf escape;
static unsigned target, writes, delays;
static unsigned long durations[MAX_PHASES];
static int on[MAX_PHASES];

uint32_t pb626_test_readl(uintptr_t address)
{
	if (address == 4) return magic1;
	if (address == 8) return magic2;
	if (address == 0x01c20d28U) return rtc;
	if (address == 0x01c20c18U) return ~clock_count;
	if (address == 0x01c20068U) return gate;
	if (address == PE_CFG1) return cfg1;
	if (address == PE_DATA) return data;
	assert(!"unexpected MMIO read");
	return 0;
}

void pb626_test_writel(uint32_t value, uintptr_t address)
{
	if (address == 0x01c20068U) gate = value;
	else if (address == PE_CFG1) cfg1 = value;
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
	clock_count += (uint32_t)(usec * 24U);
	pb626_led_boot_tick(clock_count);
	if (delays == target)
		longjmp(escape, 1);
}

static void reset_model(void)
{
	cfg1 = 0xffffffffU;
	gate = 0x10U; rtc = 0; magic1 = 0x4e4f4765U; magic2 = 0x3054422eU;
	boot_phase = 5;
	clock_count = 0;
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
	assert(writes == 0 && delays == 0);
	pb626_led_boot_start(clock_count);
	spl_board_prepare_for_boot();
	assert(writes == 5 && delays == 4);
	for (unsigned i = 0; i < 5; ++i)
		assert(on[i] == !(i & 1));
	for (unsigned i = 0; i < 4; ++i)
		assert(durations[i] == 100000);
	assert((cfg1 & 0xfU) == 1U && !(data & LED_BIT));
	pb626_led_boot_tick(clock_count + 2400000U);
	assert(writes == 5);
}

static void test_startup_timing(void)
{
	reset_model();
	unsigned origin = 0xffff0000U;
	pb626_led_boot_start(origin);
	assert(gate == 0x30U && writes == 1 && on[0] == 1);
	for (unsigned i = 0; i < 4; ++i) {
		pb626_led_boot_tick(origin + (i+1) * 2400000U - 1);
		assert(writes == i + 1);
		pb626_led_boot_tick(origin + (i+1) * 2400000U);
		assert(writes == i + 2 && on[i+1] == (int)(i & 1));
	}
	spl_board_prepare_for_boot();
	assert(writes == 5 && delays == 0);
	assert((cfg1 & ~0xfU) == (0xffffffffU & ~0xfU));
	assert((data & ~LED_BIT) == (0xffffffffU & ~LED_BIT));

	/* Sparse timer polls used to skip every intermediate phase. */
	reset_model();
	pb626_led_boot_start(0);
	clock_count = 12000000U;
	pb626_led_boot_tick(clock_count);
	assert(writes == 2 && on[1] == 0 && delays == 0);
	pb626_led_boot_tick(clock_count);
	assert(writes == 2);
	spl_board_prepare_for_boot();
	assert(writes == 5 && delays == 3);
	for (unsigned i = 0; i < 5; ++i)
		assert(on[i] == !(i & 1));

	reset_model();
	rtc = 0x53555350U;
	pb626_led_boot_start(0);
	spl_board_prepare_for_boot();
	assert(writes == 0 && delays == 0 && gate == 0x10U);
	reset_model();
	magic2 = 0x4c45462eU;
	pb626_led_boot_start(0);
	spl_board_prepare_for_boot();
	assert(writes == 0 && delays == 0 && gate == 0x10U);
}

static void test_error_cycle(unsigned code)
{
	unsigned expected_code = (code < 1 || code > 13) ? PB626_ERR_DRAM_INIT : code;
	unsigned period = expected_code < 10 ? 10 : 20;
	reset_model();
	target = period;
	if (!setjmp(escape))
		pb626_led_error(code);
	assert(writes == period && delays == period);
	assert((cfg1 & 0xfU) == 1U);
	for (unsigned phase = 0; phase < period; ++phase) {
		int ticks = pb626_morse_step(expected_code, phase);
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
	test_startup_timing();
	for (unsigned code = 1; code <= 13; ++code)
		test_error_cycle(code);
	/* Invalid callers fall back to a bounded, recognizable DRAM-init code. */
	test_error_cycle(0);
	test_error_cycle(14);
	puts("PE8 MMIO model: complete pulses, sparse polling, FEL/resume isolation and all 13 Morse cycles passed");
	return 0;
}
