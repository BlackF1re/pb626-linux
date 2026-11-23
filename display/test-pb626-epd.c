/* SPDX-License-Identifier: GPL-2.0-or-later */
#define main pb626_epd_main
#include "pb626-epd.c"
#undef main

#include <assert.h>

static void test_quantization(void)
{
	for (int y = 0; y < 4; y++)
		for (int x = 0; x < 4; x++) {
			for (unsigned int level = 0; level <= WHITE; level++)
				assert(paper_level(level * 17, 0, x, y) == level);
			assert(paper_level(127, 80, x, y) == 7);
			assert(paper_level(127, 0, x, y) == paper_level(127, 0, x + 4, y + 4));
		}
	assert(paper_level(127, 0, 0, 0) != paper_level(127, 0, 1, 0));
	assert(preview_level(8, 0) == 0);
	assert(preview_level(7, WHITE) == WHITE);
	for (int i = 0; i <= WHITE; i++)
		for (int j = 0; j <= WHITE; j++)
			assert(preview_level(i, j) == 0 || preview_level(i, j) == WHITE);
}

static void test_sparse_scan(void)
{
	static struct renderer renderer;
	static uint32_t buffer_words[FRAME_WORDS];
	struct buffer buffer = { .data = buffer_words };
	const size_t row = HEADER_WORDS + DATA_ROW * CLOCKS + DATA_CLOCK;
	struct phase phase = { .lut = { [0] = 1, [0xf0] = 2 }, .scans = 3 };
	scan_template(renderer.neutral);
	memcpy(buffer_words, renderer.neutral, sizeof(buffer_words));
	assert(portrait_index(0, 0) == WIDTH - 1);
	assert(portrait_index(GATES - 1, SOURCES - 1) == PIXELS - WIDTH);

	renderer.rows[0] = (struct span_range){ 0, 1 };
	renderer.transitions[0] = 0xf0 + 1;
	renderer.transitions[3] = 1;
	render(&buffer, &renderer, &phase, false);
	assert(buffer_words[3] == htole32(2));
	assert(buffer_words[row] == (renderer.neutral[row] | htole32(source_word(0x81))));
	assert(buffer_words[row + 1] == renderer.neutral[row + 1]);

	renderer.rows[0] = (struct span_range){ 2, 3 };
	renderer.transitions[8] = 1;
	render(&buffer, &renderer, &phase, false);
	assert(buffer_words[row] == renderer.neutral[row]);
	assert(buffer_words[row + 2] == (renderer.neutral[row + 2] | htole32(source_word(0x40))));

	render(&buffer, &renderer, &phase, true);
	assert(buffer_words[row] == (renderer.neutral[row] | htole32(source_word(0x55))));
	renderer.rows[0] = (struct span_range){ 0, 0 };
	render(&buffer, &renderer, &phase, false);
	assert(!memcmp(buffer_words + HEADER_WORDS, renderer.neutral + HEADER_WORDS,
		       FRAME_BYTES - SUN5I_EINK_HDR_SIZE));
}


static void test_indexed_scan(void)
{
    static struct renderer renderer;
    static uint32_t direct[FRAME_WORDS];
    _Alignas(uint32_t) static uint8_t indexed[SUN5I_EINK_HDR_SIZE + CLOCKS * ROWS];
    struct buffer full = { .data = direct };
    struct buffer small = { .data = (uint32_t *)indexed };
    struct phase phase = { .lut = { [0x0f] = 1, [0xf0] = 2,
                                     [0x15] = 1, [0xa0] = 2 }, .scans = 3 };
    scan_template(renderer.neutral);
    init_indexed(&renderer);
    assert(renderer.palette_used <= 256);
    memcpy(direct, renderer.neutral, sizeof(direct));
    memcpy(indexed, renderer.neutral, SUN5I_EINK_HDR_SIZE);
    memcpy(indexed + SUN5I_EINK_HDR_SIZE, renderer.neutral8, CLOCKS * ROWS);
    renderer.rows[0] = (struct span_range){0, 2};
    renderer.transitions[0] = 0x0f + 1;
    renderer.transitions[1] = 0xf0 + 1;
    renderer.transitions[4] = 0xa0 + 1;
    renderer.rows[1] = (struct span_range){0, 1};
    renderer.transitions[SOURCES] = 0x15 + 1;
    for (int scenario = 0; scenario < 3; scenario++) {
        bool reset = scenario == 1;
        if (scenario == 2) {
            renderer.rows[0] = (struct span_range){2, 3};
            renderer.rows[1] = (struct span_range){0, 0};
            renderer.transitions[8] = 0xf0 + 1;
        }
        renderer.indexed = 0;
        render(&full, &renderer, &phase, reset);
        renderer.indexed = 1;
        render(&small, &renderer, &phase, reset);
        assert(direct[3] == ((uint32_t *)indexed)[3]);
        for (size_t i = 0; i < CLOCKS * ROWS; i++)
            assert(direct[HEADER_WORDS + i] ==
                   renderer.palette.lut[indexed[SUN5I_EINK_HDR_SIZE + i]]);
    }
}

static void test_waveform_policy(void)
{
	static struct renderer renderer;
	bool active[TRANSITIONS] = { [0x8f] = true };
	renderer.driven[GC16][0x8f] = true;
	assert(!supports(&renderer, DU, active));
	assert(supports(&renderer, GC16, active));
	renderer.cache[GC16].count = 4;
	renderer.cache[GC16].phases[0].lut[0x8f] = 1;
	renderer.cache[GC16].phases[1].lut[0x8f] = 1;
	renderer.cache[GC16].phases[1].lut[0x12] = 2;
	renderer.cache[GC16].phases[2].lut[0x8f] = 2;
	renderer.cache[GC16].phases[3].lut[0x8f] = 1;
	plan(&renderer, GC16, active);
	assert(renderer.planned.count == 3);
	assert(renderer.planned.phases[0].scans == 2);
	assert(renderer.planned.phases[0].lut[0x12] == 0);
	assert(renderer.planned.phases[1].lut[0x8f] == 2);
	assert(renderer.planned.phases[2].lut[0x8f] == 1);
}

int main(void)
{
	test_quantization();
	test_sparse_scan();
    test_indexed_scan();
	test_waveform_policy();
    assert(PREVIEW_A2 != PREVIEW && PREVIEW_DU4 != PREVIEW);
    assert(preview_level4(4) == 5 && preview_level4(8) == 10);
    assert(preview_level4(14) == WHITE);
	puts("E Ink quantization, transition eligibility and scan buffer reuse passed");
	return 0;
}
