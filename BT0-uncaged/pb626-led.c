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

void spl_board_prepare_for_boot(void)
{
	/* Linux gpio-leds takes over PE8 and init-megi selects its PID1 pulse. */
	pb626_led_drive(true);
}

void pb626_led_error(unsigned int code)
{
	unsigned int phase = 0;
	unsigned int period;

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
