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

static void test_transition_storage(void)
{
	static struct renderer r;
	for (size_t i = 0; i < PIXELS; i++)
		transition_set(&r, i, i % 257);
	for (size_t i = 0; i < PIXELS; i += 4) {
		uint16_t scratch[4];
		const uint16_t *p = transition_group(&r, i, scratch);
		for (unsigned int j = 0; j < 4; j++) {
			assert(transition_get(&r, i + j) == (i + j) % 257);
			assert(p[j] == (i + j) % 257);
		}
	}
	/* Clear all start/end half-byte alignments, preserving neighbours. */
	for (size_t first = 0; first <= 12; first += 4)
		for (size_t count = 0; count <= 16; count += 4) {
			for (size_t i = 0; i < 32; i++)
				transition_set(&r, i, 256);
			transition_clear(&r, first, count);
			for (size_t i = 0; i < 32; i++)
				assert(transition_get(&r, i) == (i >= first && i < first + count ? 0 : 256));
		}
	transition_clear(&r, 0, PIXELS);
	for (size_t i = 0; i < PIXELS; i++)
		assert(transition_get(&r, i) == 0);
}

static void test_sparse_scan(void)
{
	static struct renderer renderer;
	static uint32_t buffer_words[FRAME_WORDS];
	struct buffer buffer = { .data = buffer_words };
	const size_t row = HEADER_WORDS + DATA_ROW * CLOCKS + DATA_CLOCK;
	struct phase phase = { .lut = { [0] = 1, [0xf0] = 2 }, .scans = 3 };
	static uint32_t neutral[FRAME_WORDS];
	init_neutral_data(&renderer);
	scan_template(neutral);
	for (unsigned int y = 0; y < GATES; y++)
		assert(!memcmp(renderer.neutral_data[y != 0],
			       neutral + HEADER_WORDS + (DATA_ROW + y) * CLOCKS + DATA_CLOCK,
			       GROUPS * sizeof(uint32_t)));
	memcpy(buffer_words, neutral, sizeof(buffer_words));
	assert(portrait_index(0, 0) == WIDTH - 1);
	assert(portrait_index(GATES - 1, SOURCES - 1) == PIXELS - WIDTH);

	renderer.rows[0] = (struct span_range){ 0, 1 };
	transition_set(&renderer, 0, 0xf0 + 1);
	transition_set(&renderer, 3, 1);
	render(&buffer, &renderer, &phase, false);
	assert(buffer_words[3] == htole32(2));
	assert(buffer_words[row] == (neutral[row] | htole32(source_word(0x81))));
	assert(buffer_words[row + 1] == neutral[row + 1]);

	renderer.rows[0] = (struct span_range){ 2, 3 };
	transition_set(&renderer, 8, 1);
	render(&buffer, &renderer, &phase, false);
	assert(buffer_words[row] == neutral[row]);
	assert(buffer_words[row + 2] == (neutral[row + 2] | htole32(source_word(0x40))));

	render(&buffer, &renderer, &phase, true);
	assert(buffer_words[row] == (neutral[row] | htole32(source_word(0x55))));
	renderer.rows[0] = (struct span_range){ 0, 0 };
	render(&buffer, &renderer, &phase, false);
	assert(!memcmp(buffer_words + HEADER_WORDS, neutral + HEADER_WORDS,
		       FRAME_BYTES - SUN5I_EINK_HDR_SIZE));
}

static void test_pattern_pins(void)
{
	struct phase phase = {0};
	for (unsigned int t = 0; t < TRANSITIONS; t++)
		phase.lut[t] = t % 4;
	for (unsigned int c = 0; c <= TRANSITIONS; c++)
		for (unsigned int k = 0; k < 4; k++) {
			uint16_t p[4] = {1, 256, 0, 17};
			p[k] = c;
			uint32_t expected = 0;
			for (unsigned int i = 0; i < 4; i++)
				if (p[i])
					expected |= htole32(source_word(phase.lut[p[i]-1] << (6-2*i)));
			assert(pattern_pins(&phase, p) == expected);
		}
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
	init_neutral_data(&renderer);
	scan_template(reference_words);
	scan_template(candidate_words);
	for (unsigned int pass = 0; pass < 12; pass++) {
		memset(renderer.rows, 0, sizeof(renderer.rows));
		transition_clear(&renderer, 0, PIXELS);
		for (unsigned int y = 0; y < GATES; y++) {
			if ((y + pass) % 3 == 0)
				continue;
			unsigned int first = (y + pass) % 17;
			unsigned int end = GROUPS - y % 31;
			renderer.rows[y] = (struct span_range){first, end};
			for (unsigned int x = first; x < end; x++) {
				for (unsigned int i = 0; i < 4; i++)
					transition_set(&renderer, y * SOURCES + 4 * x + i,
						(x + y + i) % 5 == 0 ? 0 : (x + y + i) % 2 ? 256 : 1);
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
		transition_set(&renderer, 4 * x, x % 257);
		transition_set(&renderer, 4 * x + 1, x / 257);
	}
	assert(index_groups(&renderer) == 0);
}

static void set_cached_signal(struct cached_update *cache, unsigned int phase,
			      unsigned int transition, uint8_t signal)
{
	unsigned int shift = 2 * (transition % 4);
	uint8_t *byte = &cache->lut[phase * LUT_BYTES + transition / 4];
	*byte = (*byte & ~(3u << shift)) | ((signal & 3u) << shift);
}

static void test_packed_cache(void)
{
	static struct renderer renderer;
	struct cached_update *cache = &renderer.cache[GC16];
	bool active[TRANSITIONS];
	cache->count = 2;
	for (unsigned int t = 0; t < TRANSITIONS; t++) {
		active[t] = t % 2;
		for (unsigned int i = 0; i < cache->count; i++) {
			set_cached_signal(cache, i, t, (t + i) % 3);
			assert(packed_signal(cache->lut + i * LUT_BYTES, t) == (t + i) % 3);
		}
	}
	for (unsigned int filtered = 0; filtered < 4; filtered++) {
		for (unsigned int t = 0; t < TRANSITIONS; t++)
			active[t] = filtered == 1 ? t % 2 : filtered == 2 ? t % 4 == 0 : t == 255;
		plan(&renderer, GC16, filtered ? active : NULL);
		assert(renderer.planned.count == 2);
		for (unsigned int i = 0; i < cache->count; i++)
			for (unsigned int t = 0; t < TRANSITIONS; t++)
				assert(renderer.planned.phases[i].lut[t] ==
				       (!filtered || active[t] ? (t + i) % 3 : 0));
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
	set_cached_signal(&renderer.cache[GC16], 0, 0x8f, 1);
	set_cached_signal(&renderer.cache[GC16], 1, 0x8f, 1);
	set_cached_signal(&renderer.cache[GC16], 1, 0x12, 2);
	set_cached_signal(&renderer.cache[GC16], 2, 0x8f, 2);
	set_cached_signal(&renderer.cache[GC16], 3, 0x8f, 1);
	plan(&renderer, GC16, active);
	assert(renderer.planned.count == 3);
	assert(renderer.planned.phases[0].scans == 2);
	assert(renderer.planned.phases[0].lut[0x12] == 0);
	assert(renderer.planned.phases[1].lut[0x8f] == 2);
	assert(renderer.planned.phases[2].lut[0x8f] == 1);
}

static void test_mixed_plan(void)
{
	static struct renderer r;
	const unsigned int codes[] = {0xf0, 0x01, 0x5f, 0x9f};
	const enum mode expected[] = {A2, DU, DU4, GL16};
	bool active[TRANSITIONS] = {0};
	r.cache[A2].count = 2;
	r.cache[DU].count = 3;
	r.cache[DU4].count = 4;
	r.cache[GL16].count = 6;
	r.cache[GC16].count = 6;
	r.mixed_a2 = r.mixed_du4 = true;
	for (unsigned int j = 0; j < 4; j++) {
		unsigned int t = codes[j];
		active[t] = true;
		r.driven[GL16][t] = r.driven[GC16][t] = true;
		r.driven[expected[j]][t] = true;
		for (unsigned int i = 0; i < r.cache[expected[j]].count; i++)
			set_cached_signal(&r.cache[expected[j]], i, t, 1 + i % 2);
		assert(mixed_transition(&r, t) == expected[j]);
	}
	assert(plan_mixed(&r, active));
	unsigned int scan = 0;
	for (unsigned int p = 0; p < r.planned.count; p++)
		for (unsigned int n = 0; n < r.planned.phases[p].scans; n++, scan++)
			for (unsigned int t = 0; t < TRANSITIONS; t++) {
				unsigned int want = 0;
				for (unsigned int j = 0; j < 4; j++)
					if (t == codes[j] && scan < r.cache[expected[j]].count)
						want = 1 + scan % 2;
				assert(r.planned.phases[p].lut[t] == want);
			}
	assert(scan == 6);
	r.mixed_a2 = false;
	assert(mixed_transition(&r, codes[0]) == GL16);
	active[0xff] = true;
	assert(!plan_mixed(&r, active));
	active[0xff] = false;
	active[0x32] = true;
	assert(!plan_mixed(&r, active));
}

static void test_fast_mode_selection(void)
{
	static struct renderer renderer;
	bool active[TRANSITIONS] = { [0xf0] = true };
	renderer.auto_fast = true;
	renderer.driven[A2][0xf0] = true;
	renderer.driven[DU][0xf0] = true;
	renderer.cache[A2].count = 10;
	renderer.cache[DU].count = 15;
	assert(select_a2_or_du(&renderer, active) == A2);
	renderer.cache[DU].count = 10;
	assert(select_a2_or_du(&renderer, active) == DU);
	renderer.cache[DU].count = 9;
	assert(select_a2_or_du(&renderer, active) == DU);
	renderer.auto_fast = false;
	assert(select_a2_or_du(&renderer, active) == A2);
	renderer.driven[A2][0xf0] = false;
	assert(select_a2_or_du(&renderer, active) == DU);
}

static void test_state_format(void)
{
	static uint8_t before[PACKED_PIXELS], after[PACKED_PIXELS];
	for (size_t i = 0; i < PIXELS; i++)
		nibble_set(before, i, (i ^ (i / WIDTH)) & WHITE);
	FILE *file = tmpfile();
	assert(file);
	assert(write_state_data(file, before));
	assert(ftell(file) == PIXELS);
	rewind(file);
	for (unsigned int gate = 0; gate < GATES; gate++)
		for (unsigned int source = 0; source < SOURCES; source++)
			assert(fgetc(file) == nibble_get(before, portrait_index(gate, source)));
	rewind(file);
	assert(read_state_data(file, after));
	assert(!memcmp(before, after, PACKED_PIXELS));
	assert(!fseek(file, 0, SEEK_SET));
	assert(fputc(WHITE + 1, file) != EOF);
	rewind(file);
	assert(!read_state_data(file, after));
	for (size_t i = 0; i < PIXELS; i++)
		assert(nibble_get(after, i) == WHITE);
	fclose(file);
	file = tmpfile();
	assert(file);
	assert(fputc(0, file) != EOF);
	rewind(file);
	assert(!read_state_data(file, after));
	fclose(file);
}

/* CPU-only synthetic scan preparation, never access panel hardware. */
static void bench_transitions(void)
{
	static struct renderer r;
	static uint32_t words[FRAME_WORDS];
	static uint8_t codes[GATES * GROUPS];
	struct buffer buffer = { .data = words };
	struct phase phase = { .scans = 1 };
	r.group_codes = codes;
	init_neutral_data(&r);
	puts("pattern,style,renderer_bytes,ns_per_frame");
	for (int pattern = 0; pattern < 3; pattern++) {
		transition_clear(&r, 0, PIXELS);
		for (unsigned int y = 0; y < GATES; y++) {
			unsigned int first = pattern == 0 ? 20 : 0;
			unsigned int end = pattern == 0 ? 24 : GROUPS;
			r.rows[y] = (struct span_range){first, end};
			for (unsigned int x = 4 * first; x < 4 * end; x++)
				transition_set(&r, y * SOURCES + x,
					       pattern == 2 ? (y * 13 + x * 17) % 257 :
					       ((x + y) & 1 ? 256 : 1));
		}
		for (int style = RENDER_SCALAR; style <= RENDER_INDEXED; style++) {
			r.style = style;
			r.patterns_count = style == RENDER_INDEXED ? index_groups(&r) : 0;
			scan_template(words);
			memset(buffer.rows, 0, sizeof(buffer.rows));
			struct timespec start, end;
			assert(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &start));
			enum { REPEATS = 32 };
			for (unsigned int i = 0; i < REPEATS; i++) {
				for (unsigned int t = 0; t < TRANSITIONS; t++)
					phase.lut[t] = (t + i) % 4;
				render(&buffer, &r, &phase, false);
			}
			assert(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &end));
			double elapsed = (end.tv_sec - start.tv_sec) * 1e9 +
					 (end.tv_nsec - start.tv_nsec);
			printf("%d,%d,%zu,%.0f\n", pattern, style, sizeof(r), elapsed / REPEATS);
		}
	}
}

int main(void)
{
	if (getenv("PB626_BENCH_TRANSITIONS")) {
		bench_transitions();
		return 0;
	}
	test_state_format();
	test_transition_storage();
	test_quantization();
	test_sparse_scan();
	test_render_equivalence();
	test_pattern_pins();
	test_packed_cache();
	test_waveform_policy();
	test_fast_mode_selection();
	test_mixed_plan();
    assert(PREVIEW_A2 != PREVIEW && PREVIEW_DU4 != PREVIEW);
    assert(preview_level4(4) == 5 && preview_level4(8) == 10);
    assert(preview_level4(14) == WHITE);
	puts("E Ink quantization, transition eligibility and scan buffer reuse passed");
	return 0;
}
