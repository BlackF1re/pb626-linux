// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PocketBook 626 (sun5i A13) early boot LED.
 *
 * PE8 is the board's sole GPIO LED, active low. Keep this independent of
 * DM, malloc, serial, and any late GPIO framework: SPL errors can occur
 * before those services are available.
 */
#include <common.h>
#include <asm/barriers.h>
#include <asm/io.h>
#include <linux/delay.h>
#include <pb626-led.h>

#define PB626_PIO_BASE       0x01c20800U
#define PB626_PE_CFG1        (PB626_PIO_BASE + 0x94U)
#define PB626_PE_DATA        (PB626_PIO_BASE + 0xa0U)
#define PB626_LED_BIT        (1U << 8)
#define PB626_PE8_GPIO_OUT   1U
#define PB626_PIO_GATE       0x01c20068U
#define PB626_GATE_BIT       (1U << 5)
#define PB626_RTC_MAGIC      0x01c20d28U
#define PB626_TIMER0_VAL     0x01c20c18U
#define PB626_TIMER_HZ_MS    24000U
#define PB626_BOOT_EDGE_MS   100U

/* Nonzero initializers keep state in SRAM .data before BSS is cleared. */
static u32 boot_origin = ~0U;
static unsigned int boot_phase = 5;

static void pb626_led_drive(bool on)
{
	u32 value;

	/* Set the output latch before switching PE8 to GPIO output. */
	value = readl((void *)PB626_PE_DATA);
	if (on)
		value &= ~PB626_LED_BIT;
	else
		value |= PB626_LED_BIT;
	writel(value, (void *)PB626_PE_DATA);

	value = readl((void *)PB626_PE_CFG1);
	value = (value & ~0xfU) | PB626_PE8_GPIO_OUT;
	writel(value, (void *)PB626_PE_CFG1);
	dsb();
}

void pb626_led_boot_start(unsigned int count)
{
	/* Native cold boot only. Do not disturb FEL or retained DRAM. */
	if (readl((void *)4) != 0x4e4f4765U ||
	    readl((void *)8) != 0x3054422eU ||
	    readl((void *)PB626_RTC_MAGIC) == 0x53555350U)
		return;

	writel(readl((void *)PB626_PIO_GATE) | PB626_GATE_BIT,
	       (void *)PB626_PIO_GATE);
	dsb();
	boot_origin = count;
	boot_phase = 0;
	pb626_led_drive(true);
}

void pb626_led_boot_tick(unsigned int count)
{
	if (boot_phase >= 4)
		return;
	if (count - boot_origin < PB626_BOOT_EDGE_MS * PB626_TIMER_HZ_MS)
		return;

	/* Timestamp the actual edge, not a theoretical animation timeline.
	 * A long MMC operation may stretch a pulse but must never erase it. */
	boot_origin = count;
	++boot_phase;
	pb626_led_drive(!(boot_phase & 1));
}

void spl_board_prepare_for_boot(void)
{
	unsigned int i;

	/* Only an animation started by the native cold path may finish here.
	 * FEL and retained-DRAM paths must not write GPIO or wait. */
	if (boot_phase >= 4)
		return;

	/* Most edges happen during existing timer polls. Finish any missing
	 * phases before Linux takes PE8: at most four 100 ms intervals.
	 * udelay itself services boot_tick through the existing timer hook. */
	for (i = 0; i < 4 && boot_phase < 4; ++i) {
		udelay(PB626_BOOT_EDGE_MS * 1000UL);
		pb626_led_boot_tick(~readl((void *)PB626_TIMER0_VAL));
	}
	/* With a working timer phase 4 is already steady on. Stop the
	 * animation even if the timer did not advance as expected. */
	if (boot_phase < 4)
		pb626_led_drive(true);
	boot_phase = 5;
}

void pb626_led_error(unsigned int code)
{
	unsigned int phase = 0;
	unsigned int period;

	boot_phase = 5; /* timer reads must not override a fatal pattern */
	if (code < 1 || code > 13)
		code = PB626_ERR_DRAM_INIT;
	period = code < 10 ? 10 : 20;

	for (;;) {
		int ticks = pb626_morse_step(code, phase);

		pb626_led_drive(ticks > 0);
		udelay((unsigned long)(ticks > 0 ? ticks : -ticks) *
		       PB626_MORSE_T_MS * 1000UL);

		if (++phase == period)
			phase = 0;
	}
}
