/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PB626_LED_H
#define PB626_LED_H

#include "led-morse.h"

/* Fatal SPL diagnostics never return. The watchdog remains armed on the
 * experimental retained-DRAM path and will still perform its cold reset. */
void pb626_led_error(unsigned int code) __attribute__((noreturn));

/* Cooperative startup indication: count is the existing 24 MHz timer0.
 * No timer registers, IRQ vectors, or BootROM state are changed. */
void pb626_led_boot_start(unsigned int count);
void pb626_led_boot_tick(unsigned int count);

/* Strong SPL hook: leave the active-low PE8 LED on for kernel takeover. */
void spl_board_prepare_for_boot(void);

#endif
