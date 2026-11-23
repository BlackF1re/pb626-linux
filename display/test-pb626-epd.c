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

static void test_render_equivalence(void)
{
	static struct renderer renderer;
	static uint32_t reference_words[FRAME_WORDS], candidate_words[FRAME_WORDS];
	static uint8_t codes[GATES * GROUPS];
	struct buffer reference = { .data = reference_words };
	struct buffer candidate = { .data = candidate_words };
	struct phase phase = { .scans = 4 };
	renderer.group_codes = codes;
	scan_template(renderer.neutral);
	memcpy(reference_words, renderer.neutral, FRAME_BYTES);
	memcpy(candidate_words, renderer.neutral, FRAME_BYTES);
	for (unsigned int pass = 0; pass < 12; pass++) {
		memset(renderer.rows, 0, sizeof(renderer.rows));
		memset(renderer.transitions, 0, sizeof(renderer.transitions));
		for (unsigned int y = 0; y < GATES; y++) {
			if ((y + pass) % 3 == 0)
				continue;
			unsigned int first = (y + pass) % 17;
			unsigned int end = GROUPS - y % 31;
			renderer.rows[y] = (struct span_range){first, end};
			for (unsigned int x = first; x < end; x++) {
				uint16_t *p = renderer.transitions + y * SOURCES + 4 * x;
				for (unsigned int i = 0; i < 4; i++)
					p[i] = (x + y + i) % 5 == 0 ? 0 : (x + y + i) % 2 ? 256 : 1;
			}
		}
		for (unsigned int i = 0; i < TRANSITIONS; i++)
			phase.lut[i] = (i + pass) % 4;
		bool reset = pass % 4 == 0;
		renderer.style = RENDER_SCALAR;
		renderer.patterns_count = 0;
		render(&reference, &renderer, &phase, reset);
		renderer.style = pass % 2 ? RENDER_INDEXED : RENDER_STAGED;
		if (renderer.style == RENDER_INDEXED) {
			renderer.patterns_count = index_groups(&renderer);
			assert(renderer.patterns_count > 1);
		}
		render(&candidate, &renderer, &phase, reset);
		assert(!memcmp(reference_words, candidate_words, FRAME_BYTES));
	}
	renderer.rows[0] = (struct span_range){0, GROUPS};
	renderer.rows[1] = (struct span_range){0, GROUPS};
	for (unsigned int x = 0; x < 2 * GROUPS; x++) {
		renderer.transitions[4 * x] = x % 257;
		renderer.transitions[4 * x + 1] = x / 257;
	}
	assert(index_groups(&renderer) == 0);
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
	test_render_equivalence();
	test_waveform_policy();
    assert(PREVIEW_A2 != PREVIEW && PREVIEW_DU4 != PREVIEW);
    assert(preview_level4(4) == 5 && preview_level4(8) == 10);
    assert(preview_level4(14) == WHITE);
	puts("E Ink quantization, transition eligibility and scan buffer reuse passed");
	return 0;
}
