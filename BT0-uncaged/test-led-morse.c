/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "led-morse.h"

int main(void)
{
    static const char *const numbers[] = {
        ".----", "..---", "...--", "....-", ".....",
        "-....", "--...", "---..", "----.",
        ".----/-----", ".----/.----", ".----/..---", ".----/...--"
    };
    static const unsigned periods[] = {
        4800, 4400, 4000, 3600, 3200, 3600, 4000,
        4400, 4800, 9200, 8800, 8400, 8000
    };
    assert(pb626_morse_step(0, 0) == 0);
    assert(pb626_morse_step(14, 0) == 0);
    for (unsigned code = 1; code <= 13; ++code) {
        const char *s = numbers[code - 1];
        unsigned phase = 0, elapsed = 0;
        while (*s) {
            assert(*s == '.' || *s == '-');
            int mark = *s++ == '.' ? 1 : 3;
            assert(pb626_morse_step(code, phase++) == mark);
            int gap = !*s ? 7 : (*s == '/' ? 3 : 1);
            if (*s == '/') ++s;
            assert(pb626_morse_step(code, phase++) == -gap);
            elapsed += (mark + gap) * PB626_MORSE_T_MS;
        }
        assert(phase == (code < 10 ? 10U : 20U));
        assert(elapsed == periods[code - 1]);
        for (unsigned i = 0; i < phase; ++i)
            assert(pb626_morse_step(code, i) ==
                   pb626_morse_step(code, i + 7 * phase));
        printf("code %u: %u ms, %u phases, cyclic\n", code, elapsed, phase);
    }
    return 0;
}
