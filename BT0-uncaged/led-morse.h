/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PB626_LED_MORSE_H
#define PB626_LED_MORSE_H

/* Pure timing model: no MMIO, timers, stack relocation, or watchdog changes.
 * Positive ticks = LED on, negative = LED off. One tick is 200 ms.
 * Index wraps automatically. Invalid/reserved-out-of-range codes return 0.
 * Codes 4 and 7 have patterns but are reserved pending reachability review.
 */
#define PB626_MORSE_T_MS 200U
enum pb626_fatal_code {
    PB626_ERR_MBUS = 1,
    PB626_ERR_DRAM_TIMEOUT = 2,
    PB626_ERR_DRAM_INIT = 3,
    PB626_ERR_SPL_INIT_RESERVED = 4,
    PB626_ERR_MMC_FIND = 5,
    PB626_ERR_MMC_INIT = 6,
    PB626_ERR_MMC_PART_RESERVED = 7,
    PB626_ERR_HEADER_READ = 8,
    PB626_ERR_HEADER_CRC = 9,
    PB626_ERR_PAYLOAD_READ = 10,
    PB626_ERR_PAYLOAD_CRC = 11,
    PB626_ERR_RESUME_DRAM = 12,
    PB626_ERR_RESUME_CPU_STATE = 13,
};

static inline int pb626_morse_step(unsigned code, unsigned phase)
{
    unsigned digit, symbol;
    if (code < 1 || code > 13)
        return 0;
    phase %= code < 10 ? 10U : 20U;
    digit = code < 10 ? code : (phase < 10 ? 1U : code - 10U);
    symbol = (phase % 10U) / 2U;
    if (phase & 1U) {
        if (symbol < 4)
            return -1;
        return (code >= 10 && phase == 9) ? -3 : -7;
    }
    if (!digit)
        return 3;
    if (digit <= 5)
        return symbol < digit ? 1 : 3;
    return symbol < digit - 5 ? 3 : 1;
}
#endif
