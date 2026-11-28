/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _DEFAULT_SOURCE
#include <ctype.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/sun5i-eink.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pb626-epd.h"

enum { SOURCES = HEIGHT, GATES = WIDTH,
       CLOCKS = 304, ROWS = 767, DATA_ROW = 6, DATA_CLOCK = 40,
       GATE_HIGH_CLOCKS = 85, GROUPS = SOURCES / 4,
       HEADER_WORDS = SUN5I_EINK_HDR_SIZE / sizeof(uint32_t),
       FRAME_WORDS = HEADER_WORDS + CLOCKS * ROWS, FRAME_BYTES = FRAME_WORDS * 4,
       LEVELS = 16, TRANSITIONS = LEVELS * LEVELS,
       LUT_BYTES = TRANSITIONS / 4, MAX_PHASES = 256, QUEUE_SIZE = 8,
       GROUP_CODES = 256, GROUP_HASH_SIZE = 2 * GROUP_CODES };

enum { S_LE = 1 << 13, G_MODE = 1 << 15, S_OE = 1 << 20,
       S_SP = 1 << 21, G_CLK = 1 << 22, G_SP = 1 << 23,
       BASE = G_MODE | G_SP, IDLE = BASE | S_SP };

enum mode { INIT, DU, GC16, GL16, A2, DU4, MIXED };
static const char *const modes[] = { "reset", "du", "full", "partial", "a2", "du4", "mixed" };
static const char state_path[] = "/run/pb626-epd.levels";
static const enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_OUTPUT;

struct waveform {
	const uint8_t *data;
	size_t size;
	unsigned int interval;
	unsigned int modes;
};

struct phase {
	uint8_t lut[TRANSITIONS];
	unsigned int scans;
};

struct update {
	struct phase phases[MAX_PHASES];
	unsigned int count;
};

/* WBF stores four 2-bit transition signals in each byte. Keep that
 * representation in the temperature cache; expand only the active plan. */
struct cached_update {
	uint8_t lut[MAX_PHASES * LUT_BYTES];
	unsigned int count;
};

static inline uint8_t packed_signal(const uint8_t *lut, unsigned int t)
{
	return (lut[t / 4] >> (2 * (t % 4))) & 3;
}

struct span_range {
	unsigned short first, end;
};

struct buffer {
	uint32_t *data;
	size_t length;
	struct span_range rows[GATES];
};

enum render_style { RENDER_SCALAR, RENDER_STAGED, RENDER_INDEXED };

struct renderer {
	int fd, profile;
	unsigned int buffers_count, prefill;
	enum render_style style;
	uint8_t *group_codes;
	uint16_t group_patterns[GROUP_CODES][4];
	unsigned int patterns_count;
	struct buffer buffers[QUEUE_SIZE];
	struct waveform wbf;
	struct cached_update cache[DU4 + 1];
	struct update planned;
	bool driven[DU4 + 1][TRANSITIONS];
	uint64_t temperature_checked;
	uint32_t neutral_data[2][GROUPS];
	uint8_t previous[PACKED_PIXELS];
#ifdef PB626_PACKED_TRANSITIONS
	/* Exact codes 0..256: low byte plus a bitmap for code 256.
	 * Only the experimental build selects this representation. */
	uint8_t transitions[PIXELS], transition_high[(PIXELS + 7) / 8];
#else
	uint16_t transitions[PIXELS];
#endif
	struct span_range rows[GATES];
	bool known, auto_fast, mixed_enabled, mixed_a2, mixed_du4;
};

static inline uint16_t transition_get(const struct renderer *r, size_t i)
{
#ifdef PB626_PACKED_TRANSITIONS
	return r->transitions[i] | (((r->transition_high[i >> 3] >> (i & 7)) & 1u) << 8);
#else
	return r->transitions[i];
#endif
}

static inline void transition_set(struct renderer *r, size_t i, uint16_t value)
{
	r->transitions[i] = value;
#ifdef PB626_PACKED_TRANSITIONS
	uint8_t bit = 1u << (i & 7);
	r->transition_high[i >> 3] = (r->transition_high[i >> 3] & ~bit) |
		(value == 256 ? bit : 0);
#endif
}

/* Spans are always aligned to four-source groups, including row boundaries. */
static inline void transition_clear(struct renderer *r, size_t first, size_t count)
{
	memset(r->transitions + first, 0, count * sizeof(*r->transitions));
#ifdef PB626_PACKED_TRANSITIONS
	if (!count)
		return;
	if (first & 7) {
		r->transition_high[first >> 3] &= 0x0f;
		first += 4;
		count -= 4;
	}
	if (count & 7) {
		r->transition_high[(first + count - 4) >> 3] &= 0xf0;
		count -= 4;
	}
	memset(r->transition_high + (first >> 3), 0, count >> 3);
#endif
}

static inline const uint16_t *transition_group(const struct renderer *r, size_t i,
					      uint16_t scratch[4])
{
#ifdef PB626_PACKED_TRANSITIONS
	unsigned int high = r->transition_high[i >> 3] >> (i & 7);
	for (unsigned int p = 0; p < 4; p++)
		scratch[p] = r->transitions[i + p] | (((high >> p) & 1u) << 8);
	return scratch;
#else
	(void)scratch;
	return r->transitions + i;
#endif
}

static _Noreturn void fail(const char *message)
{
	fprintf(stderr, "pb626-epd: %s\n", message);
	exit(EXIT_FAILURE);
}

static uint32_t le_value(const uint8_t *data, unsigned int bytes)
{
	uint32_t result = 0;

	for (unsigned int i = 0; i < bytes; i++)
		result |= (uint32_t)data[i] << (8 * i);
	return result;
}

static uint32_t wbf_crc(const uint8_t *data, size_t size)
{
	uint32_t crc = UINT32_MAX;

	for (size_t i = 0; i < size; i++) {
		crc ^= i < 4 ? 0 : data[i];
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (crc & 1 ? UINT32_C(0xedb88320) : 0);
	}
	return ~crc;
}

static uint8_t checksum(const uint8_t *data, size_t size)
{
	uint8_t sum = 0;

	while (size--)
		sum += *data++;
	return sum;
}

static size_t table_ptr(const struct waveform *wbf, size_t offset, bool checked)
{
	if (offset + 4 > wbf->size)
		fail("truncated WBF table pointer");
	const uint8_t *data = wbf->data + offset;
	size_t addr = le_value(data, 3);

	if (!addr || addr >= wbf->size || (checked && checksum(data, 3) != data[3]))
		fail("invalid WBF table pointer");
	return addr;
}

static bool read_temperature_mc(int *result)
{
	glob_t hwmon = {0};
	int temperature = 0;
	bool found = false;

	if (glob("/sys/class/hwmon/hwmon*/name", 0, NULL, &hwmon)) {
		globfree(&hwmon);
		return false;
	}
	for (size_t i = 0; i < hwmon.gl_pathc; i++) {
		const char *name = hwmon.gl_pathv[i];
		char id[32], path[256];
		FILE *file = fopen(name, "r");
		bool panel = file && fscanf(file, "%31s", id) == 1 && !strcmp(id, "tps65185");

		if (file)
			fclose(file);
		if (!panel)
			continue;
		snprintf(path, sizeof(path), "%.*s/temp1_input", (int)strlen(name) - 5, name);
		file = fopen(path, "r");
		found = file && fscanf(file, "%d", &temperature) == 1;
		if (file)
			fclose(file);
		break;
	}
	globfree(&hwmon);
	if (found)
		*result = temperature;
	return found;
}

/* Retry transient reads before driving the panel; never guess temperature. */
static int temperature_mc(void)
{
	int temperature;
	for (unsigned int attempt = 0; attempt < 5; attempt++) {
		if (read_temperature_mc(&temperature))
			return temperature;
		if (attempt < 4)
			usleep(250000);
	}
	fail("could not read the TPS65185 panel temperature after retries");
}

static void load_waveform(struct waveform *wbf, const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat info;

	if (fd < 0 || fstat(fd, &info) || info.st_size < 0x33 || info.st_size > 0xffffff)
		fail("could not open the factory WBF");
	wbf->size = info.st_size;
	wbf->data = mmap(NULL, wbf->size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (wbf->data == MAP_FAILED)
		fail("could not map the factory WBF");

	const uint8_t *data = wbf->data;
	if (le_value(data + 4, 4) != wbf->size || le_value(data, 4) != wbf_crc(data, wbf->size) ||
	    data[0x10] != 0x23 || data[0x18] != 85 || data[0x24] != 0 || data[0x27] != 1 ||
	    data[0x28] != 255 || data[0x29] != 252)
		fail("expected the factory 16-level WBF, mode version 0x23");

	const uint8_t *bounds = data + 0x30;
	unsigned int ranges = data[0x26] + 1;
	if (0x30 + ranges + 2 > wbf->size || checksum(bounds, ranges + 1) != bounds[ranges + 1])
		fail("invalid WBF temperature table");
	for (unsigned int i = 0; i < ranges; i++)
		if (bounds[i] >= bounds[i + 1])
			fail("non-increasing WBF temperature table");

	wbf->modes = data[0x25] + 1;
	wbf->interval = UINT32_MAX;
}

static unsigned int temperature_interval(const struct waveform *wbf, int temp)
{
	const uint8_t *bounds = wbf->data + 0x30;
	unsigned int ranges = wbf->data[0x26] + 1;

	for (unsigned int i = 0; i < ranges; i++) {
		if (temp >= 1000 * bounds[i] && temp < 1000 * bounds[i + 1])
			return i;
	}
	fail("panel temperature is outside the factory WBF range");
}

static size_t decode(const struct waveform *wbf, enum mode mode, uint8_t *lut)
{
	if ((unsigned int)mode >= wbf->modes)
		fail("the WBF lacks the requested mode");
	size_t table = table_ptr(wbf, 0x20, false);
	table = table_ptr(wbf, table + mode * 4, true);
	size_t start = table_ptr(wbf, table + wbf->interval * 4, true);
	size_t offset = start, written = 0;
	bool rle = true;

	while (offset < wbf->size && wbf->data[offset] != 255) {
		uint8_t token = wbf->data[offset++];
		if (token == 252) {
			rle = !rle;
			continue;
		}
		if (rle && offset == wbf->size)
			fail("truncated WBF run");
		size_t count = rle ? wbf->data[offset++] + 1 : 1;
		if (count > MAX_PHASES * LUT_BYTES - written)
			fail("too many WBF phases");
		memset(lut + written, token, count);
		written += count;
	}
	if (offset + 1 >= wbf->size || !written || written % LUT_BYTES ||
	    checksum(wbf->data + start, offset - start + 1) != wbf->data[offset + 1])
		fail("invalid WBF phase data");
	return written / LUT_BYTES;
}

static void cache_mode(struct renderer *renderer, enum mode mode)
{
	struct cached_update *decoded = &renderer->cache[mode];
	if (decoded->count)
		return;

	uint64_t start = now_us();
	decoded->count = decode(&renderer->wbf, mode, decoded->lut);
	memset(renderer->driven[mode], 0, sizeof(renderer->driven[mode]));
	for (unsigned int i = 0; i < decoded->count; i++) {
		const uint8_t *lut = decoded->lut + i * LUT_BYTES;
		uint8_t first = packed_signal(lut, 0);
		for (unsigned int t = 0; t < TRANSITIONS; t++) {
			uint8_t signal = packed_signal(lut, t);
			if (signal == 3)
				fail("unsupported WBF source voltage");
			renderer->driven[mode][t] |= signal != 0;
			if (mode == INIT && signal != first)
				fail("RESET requires a uniform waveform");
		}
	}
	if (renderer->profile)
		fprintf(stderr, "epd: decode mode=%s interval=%u phases=%u us=%llu\n",
			modes[mode], renderer->wbf.interval, decoded->count,
			(unsigned long long)(now_us() - start));
}

static bool supports(const struct renderer *renderer, enum mode mode, const bool *active)
{
	for (unsigned int t = 0; t < TRANSITIONS; t++)
		if (active[t] && t % (LEVELS + 1) && !renderer->driven[mode][t])
			return false;
	return true;
}

static void plan(struct renderer *renderer, enum mode mode, const bool *active)
{
	struct update *update = &renderer->planned;
	const struct cached_update *decoded = &renderer->cache[mode];
	update->count = 0;
	/* Sparse text/cursor updates often use only a few of 256 transitions.
	 * Collect them once, then expand only those entries in each scan. */
	uint8_t active_codes[TRANSITIONS];
	unsigned int active_count = 0;
	if (active)
		for (unsigned int t = 0; t < TRANSITIONS; t++)
			if (active[t])
				active_codes[active_count++] = t;
	for (unsigned int i = 0; i < decoded->count; i++) {
		uint8_t phase[TRANSITIONS];
		const uint8_t *lut = decoded->lut + i * LUT_BYTES;
		if (active && active_count <= TRANSITIONS / 4) {
			memset(phase, 0, sizeof(phase));
			for (unsigned int j = 0; j < active_count; j++) {
				unsigned int t = active_codes[j];
				phase[t] = packed_signal(lut, t);
			}
		} else {
			for (unsigned int t = 0; t < TRANSITIONS; t++)
				phase[t] = !active || active[t] ? packed_signal(lut, t) : 0;
		}

		struct phase *last = update->count ? &update->phases[update->count - 1] : NULL;
		if (last && !memcmp(last->lut, phase, sizeof(phase))) {
			last->scans++;
		} else {
			struct phase *next = &update->phases[update->count++];
			memcpy(next->lut, phase, sizeof(phase));
			next->scans = 1;
		}
	}
}

/* Each transition retains its complete temperature-specific factory
 * sequence. Shorter sequences are neutral after completion. No waveform
 * truncation, interpolation, or new voltage signals. */
static enum mode mixed_transition(const struct renderer *r, unsigned int t)
{
	unsigned int old = t & 15, target = t >> 4;
	enum mode best = GL16;
	if (!r->driven[GL16][t])
		best = GC16;
	if (target == 0 || target == 15) {
		if (r->driven[DU][t] && r->cache[DU].count < r->cache[best].count)
			best = DU;
		if (r->mixed_a2 && (old == 0 || old == 15) &&
		    r->driven[A2][t] && r->cache[A2].count < r->cache[best].count)
			best = A2;
	} else if (r->mixed_du4 && (target == 5 || target == 10) &&
		   r->driven[DU4][t] && r->cache[DU4].count < r->cache[best].count)
		best = DU4;
	return best;
}

static bool plan_mixed(struct renderer *r, const bool *active)
{
	enum mode selected[TRANSITIONS];
	unsigned int scans = 0, counts[DU4 + 1] = {0};
	for (unsigned int t = 0; t < TRANSITIONS; t++) {
		if (!active[t])
			continue;
		/* Never mix a same-level scrub or an unknown transition. */
		if (!(t % (LEVELS + 1)))
			return false;
		enum mode m = mixed_transition(r, t);
		if (!r->cache[m].count || !r->driven[m][t])
			return false;
		selected[t] = m;
		counts[m]++;
		if (r->cache[m].count > scans)
			scans = r->cache[m].count;
	}
	if (!scans)
		return false;
	struct update *u = &r->planned;
	u->count = 0;
	for (unsigned int i = 0; i < scans; i++) {
		uint8_t phase[TRANSITIONS] = {0};
		for (unsigned int t = 0; t < TRANSITIONS; t++) {
			if (!active[t])
				continue;
			const struct cached_update *c = &r->cache[selected[t]];
			if (i < c->count)
				phase[t] = packed_signal(c->lut + i * LUT_BYTES, t);
		}
		struct phase *last = u->count ? &u->phases[u->count - 1] : NULL;
		if (last && !memcmp(last->lut, phase, sizeof(phase)))
			last->scans++;
		else {
			struct phase *next = &u->phases[u->count++];
			memcpy(next->lut, phase, sizeof(phase));
			next->scans = 1;
		}
	}
	if (r->profile)
		fprintf(stderr, "epd: mixed transitions du=%u a2=%u du4=%u gl16=%u gc16=%u scans=%u\n",
			counts[DU], counts[A2], counts[DU4], counts[GL16], counts[GC16], scans);
	return true;
}

static unsigned int pgm_number(FILE *file)
{
	int c;
	do {
		c = fgetc(file);
		if (c == '#') {
			while (c != '\n' && c != EOF)
				c = fgetc(file);
		}
	} while (isspace(c));

	if (!isdigit(c))
		fail("invalid PGM header");
	unsigned int n = 0;
	do {
		n = 10 * n + c - '0';
		if (n > SOURCES)
			fail("unsupported PGM header value");
		c = fgetc(file);
	} while (isdigit(c));
	if (!isspace(c))
		fail("invalid PGM header separator");
	if (c == '\r') {
		c = fgetc(file);
		if (c != '\n' && c != EOF)
			ungetc(c, file);
	}
	return n;
}

static void read_image(const char *path, uint8_t *target)
{
	FILE *file = fopen(path, "rb");
	if (!file || fgetc(file) != 'P' || fgetc(file) != '5' || !isspace(fgetc(file)) ||
	    pgm_number(file) != GATES || pgm_number(file) != SOURCES)
		fail("expected a binary PGM of 758 by 1024 pixels in portrait orientation");
	unsigned int maxval = pgm_number(file);
	if (maxval != 15 && maxval != 255)
		fail("expected a PGM maximum sample of 15 or 255");

	uint8_t row[GATES];
	for (unsigned int y = 0; y < SOURCES; y++) {
		if (fread(row, 1, GATES, file) != GATES)
			fail("truncated PGM pixels");
		for (unsigned int x = 0; x < GATES; x++) {
			if (row[x] > maxval)
				fail("PGM sample exceeds its maximum");
			target[y * WIDTH + x] = (row[x] * WHITE + maxval / 2) / maxval;
		}
	}
	if (fgetc(file) != EOF || ferror(file))
		fail("unexpected data after the PGM pixels");
	fclose(file);
}

static size_t portrait_index(unsigned int gate, unsigned int source)
{
	return source * WIDTH + (GATES - 1 - gate);
}

/* Keep the gate-major disk format without a second full-size image. */
static bool read_state_data(FILE *file, uint8_t *previous)
{
	uint8_t row[SOURCES];
	bool valid = file != NULL;
	for (unsigned int gate = 0; valid && gate < GATES; gate++) {
		valid = fread(row, 1, sizeof(row), file) == sizeof(row);
		for (unsigned int source = 0; valid && source < SOURCES; source++) {
			valid = row[source] <= WHITE;
			nibble_set(previous, portrait_index(gate, source), row[source]);
		}
	}
	if (valid)
		valid = fgetc(file) == EOF && !ferror(file);
	if (!valid)
		memset(previous, 0xff, PACKED_PIXELS);
	return valid;
}

static bool load_state(uint8_t *previous)
{
	FILE *file = fopen(state_path, "rb");
	bool valid = read_state_data(file, previous);
	if (file)
		fclose(file);
	return valid;
}

static uint32_t *span(uint32_t *out, unsigned int clocks, uint32_t state)
{
	while (clocks--)
		*out++ = htole32(state);
	return out;
}

static void scan_template(uint32_t *frame)
{
	/* ED060XD4 geometry and control sequences from Megi's fixed-panel driver. */
	const unsigned int third = CLOCKS / 3;
	uint32_t *out = frame + HEADER_WORDS;
	frame[0] = htole32(SUN5I_EINK_HDR_MAGIC);
	out = span(out, 20, IDLE);
	out = span(out, 2 * third, IDLE | G_CLK);
	out = span(out, CLOCKS - 20 - 2 * third, IDLE);
	out = span(out, third, IDLE | G_CLK);
	out = span(out, third, G_MODE | S_SP | G_CLK);
	out = span(out, CLOCKS - 2 * third, G_MODE | S_SP);
	out = span(out, third, G_MODE | S_SP | G_CLK);
	out = span(out, third, IDLE | G_CLK);
	out = span(out, CLOCKS - 2 * third, IDLE);
	for (int row = 0; row < 3; row++) {
		out = span(out, 2 * third, IDLE | G_CLK);
		out = span(out, CLOCKS - 2 * third, IDLE);
	}
	for (int row = 0; row <= GATES; row++) {
		uint32_t oe = row ? S_OE : 0, latch = row ? S_LE : 0;
		uint32_t data = BASE | oe | (row == GATES ? S_SP : 0);
		out = span(out, 22, IDLE);
		out = span(out, 6, IDLE | latch);
		out = span(out, 2, IDLE | latch | oe);
		out = span(out, 8, IDLE | oe);
		out = span(out, 2, IDLE | oe | G_CLK);
		out = span(out, GATE_HIGH_CLOCKS, data | G_CLK);
		out = span(out, GROUPS - GATE_HIGH_CLOCKS, data);
		out = span(out, 8, IDLE | oe);
	}
	span(out, 2 * CLOCKS, G_SP | S_SP);
}

/* Retain only the two data-row patterns used by render. */
static void init_neutral_data(struct renderer *renderer)
{
	for (unsigned int row = 0; row < 2; row++) {
		uint32_t data = BASE | (row ? S_OE : 0);
		uint32_t *out = span(renderer->neutral_data[row], GATE_HIGH_CLOCKS, data | G_CLK);
		span(out, GROUPS - GATE_HIGH_CLOCKS, data);
	}
}

static uint32_t source_word(unsigned int data)
{
	return ((data & 0x1f) << 3) | ((data & 0xe0) << 5);
}

/* Index repeated four-source patterns once per update. The bounded table
 * leaves complex frames on the general renderer and keeps each phase LUT hot.
 */
static unsigned int index_groups(struct renderer *renderer)
{
	uint16_t hash[GROUP_HASH_SIZE] = {0};
	unsigned int count = 0;
	for (unsigned int y = 0; y < GATES; y++) {
		struct span_range row = renderer->rows[y];
		for (unsigned int x = row.first; x < row.end; x++) {
			uint16_t scratch[4];
			const uint16_t *p = transition_group(renderer, y * SOURCES + 4 * x, scratch);
			unsigned int slot = (p[0] * 137 + p[1] * 149 + p[2] * 167 +
					     p[3] * 179) & (GROUP_HASH_SIZE - 1);
			while (hash[slot] &&
			       memcmp(p, renderer->group_patterns[hash[slot] - 1],
				      sizeof(renderer->group_patterns[0])))
				slot = (slot + 1) & (GROUP_HASH_SIZE - 1);
			if (!hash[slot]) {
				if (count == GROUP_CODES)
					return 0;
				memcpy(renderer->group_patterns[count], p,
				       sizeof(renderer->group_patterns[0]));
				hash[slot] = ++count;
			}
			renderer->group_codes[y * GROUPS + x] = hash[slot] - 1;
		}
	}
	return count;
}

static void render(struct buffer *buffer, const struct renderer *renderer,
		   const struct phase *phase, bool reset)
{
	uint32_t pins[4][TRANSITIONS + 1] = {0};
	buffer->data[3] = htole32(phase->scans - 1);
	if (!reset) {
		for (unsigned int pixel = 0; pixel < 4; pixel++)
			for (unsigned int t = 0; t < TRANSITIONS; t++)
				pins[pixel][t + 1] = htole32(source_word(phase->lut[t] << (6 - 2 * pixel)));
	}
	uint32_t uniform = htole32(source_word(phase->lut[0] * 0x55));
	uint32_t group_pins[GROUP_CODES];
	bool indexed = !reset && renderer->patterns_count;
	if (indexed)
		for (unsigned int i = 0; i < renderer->patterns_count; i++) {
			const uint16_t *p = renderer->group_patterns[i];
			group_pins[i] = pins[0][p[0]] | pins[1][p[1]] |
					pins[2][p[2]] | pins[3][p[3]];
		}
	for (unsigned int y = 0; y < GATES; y++) {
		struct span_range old = buffer->rows[y];
		struct span_range row = reset ? (struct span_range){0, GROUPS} : renderer->rows[y];
		size_t offset = HEADER_WORDS + (DATA_ROW + y) * CLOCKS + DATA_CLOCK;
		uint32_t *out = buffer->data + offset;
		const uint32_t *neutral = renderer->neutral_data[y != 0];
		if (old.end > old.first && row.end == row.first) {
			memcpy(out + old.first, neutral + old.first, (old.end - old.first) * sizeof(*out));
		} else if (row.end > row.first) {
			if (old.first < row.first && old.end > old.first) {
				unsigned int end = old.end < row.first ? old.end : row.first;
				memcpy(out + old.first, neutral + old.first, (end - old.first) * sizeof(*out));
			}
			if (old.end > row.end) {
				unsigned int first = old.first > row.end ? old.first : row.end;
				memcpy(out + first, neutral + first, (old.end - first) * sizeof(*out));
			}
			uint32_t staged[GROUPS];
			uint32_t *dest = renderer->style == RENDER_SCALAR ? out : staged;
			if (reset) {
				for (unsigned int x = row.first; x < row.end; x++)
					dest[x] = neutral[x] | uniform;
			} else if (indexed) {
				const uint8_t *codes = renderer->group_codes + y * GROUPS;
				for (unsigned int x = row.first; x < row.end; x++)
					dest[x] = neutral[x] | group_pins[codes[x]];
			} else {
				for (unsigned int x = row.first; x < row.end; x++) {
					uint16_t scratch[4];
					const uint16_t *pixels = transition_group(renderer, y * SOURCES + 4 * x, scratch);
					dest[x] = neutral[x] | pins[0][pixels[0]] | pins[1][pixels[1]] |
						  pins[2][pixels[2]] | pins[3][pixels[3]];
				}
			}
			if (dest == staged)
				memcpy(out + row.first, staged + row.first,
				       (row.end - row.first) * sizeof(*out));
		}
		buffer->rows[y] = row;
	}
}

static int retry_ioctl(int fd, unsigned long request, void *data)
{
	int result;
	do {
		result = ioctl(fd, request, data);
	} while (result < 0 && errno == EINTR);
	return result;
}

static void allocate_queue(struct renderer *renderer)
{
	struct v4l2_requestbuffers req = { .count = QUEUE_SIZE, .type = type,
					  .memory = V4L2_MEMORY_MMAP };
	if (retry_ioctl(renderer->fd, VIDIOC_REQBUFS, &req) || !req.count || req.count > QUEUE_SIZE)
		fail("could not allocate the E Ink scanout queue");
	renderer->buffers_count = req.count;

	for (unsigned int i = 0; i < req.count; i++) {
		struct v4l2_buffer info = { .index = i, .type = type, .memory = V4L2_MEMORY_MMAP };
		if (retry_ioctl(renderer->fd, VIDIOC_QUERYBUF, &info) || info.length < FRAME_BYTES)
			fail("could not query an E Ink scanout buffer");
		renderer->buffers[i].data = mmap(NULL, info.length, PROT_READ | PROT_WRITE,
						 MAP_SHARED, renderer->fd, info.m.offset);
		if (renderer->buffers[i].data == MAP_FAILED)
			fail("could not map an E Ink scanout buffer");
		renderer->buffers[i].length = info.length;
		memset(renderer->buffers[i].data, 0, FRAME_BYTES);
		scan_template(renderer->buffers[i].data);
	}
}

/* Only called in the command loop, after the preceding update's
 * STREAMOFF and ACK. Keep the exclusive device fd and logical history.
 * The next apply() lazily recreates the full eight-buffer queue. */
static void release_queue(struct renderer *renderer)
{
	if (!renderer->buffers_count)
		return;
	for (unsigned int i = 0; i < renderer->buffers_count; i++) {
		struct buffer *buffer = &renderer->buffers[i];
		if (munmap(buffer->data, buffer->length))
			fail("could not unmap idle scanout buffer");
		memset(buffer, 0, sizeof(*buffer));
	}
	struct v4l2_requestbuffers req = { .count = 0, .type = type,
					  .memory = V4L2_MEMORY_MMAP };
	if (retry_ioctl(renderer->fd, VIDIOC_REQBUFS, &req))
		fail("could not release idle scanout queue");
	renderer->buffers_count = 0;
	if (renderer->profile)
		fprintf(stderr, "epd: idle DMA queue released\n");
}

static void enqueue(struct renderer *renderer, unsigned int index, const struct phase *phase,
		    bool reset, uint64_t *render_us)
{
	struct v4l2_buffer info = { .index = index, .type = type, .memory = V4L2_MEMORY_MMAP,
				   .bytesused = FRAME_BYTES, .field = V4L2_FIELD_NONE };
	uint64_t start = renderer->profile ? now_us() : 0;
	render(&renderer->buffers[index], renderer, phase, reset);
	if (renderer->profile)
		*render_us += now_us() - start;
	if (retry_ioctl(renderer->fd, VIDIOC_QBUF, &info))
		fail("could not queue an E Ink phase");
}

static void refresh(struct renderer *renderer, enum mode mode)
{
	const struct update *update = &renderer->planned;
	int fd = renderer->fd;
	uint64_t start = now_us(), render_us = 0;
	unsigned int queued = 0, scans = 0;
	for (unsigned int i = 0; i < update->count; i++)
		scans += update->phases[i].scans;

	unsigned int initial = renderer->buffers_count;
	if (renderer->prefill && renderer->prefill < initial)
		initial = renderer->prefill;
	renderer->patterns_count = 0;
	if (mode != INIT && update->count >= 6 && renderer->group_codes)
		renderer->patterns_count = index_groups(renderer);
	uint64_t index_done = now_us();
	for (; queued < initial && queued < update->count; queued++)
		enqueue(renderer, queued, &update->phases[queued], mode == INIT, &render_us);

	uint64_t preloaded = now_us(), first_irq = 0, last_irq = 0, max_gap = 0;
	enum v4l2_buf_type stream = type;
	unsigned int start_retries = 0;
	while (retry_ioctl(fd, VIDIOC_STREAMON, &stream)) {
		int error = errno;
		fprintf(stderr, "epd: STREAMON mode=%s queued=%u interval=%u us=%llu errno=%d\n",
			modes[mode], queued, renderer->wbf.interval,
			(unsigned long long)(now_us() - preloaded), error);
		/* sun5i-eink returns queued buffers before TCON starts on power failure.
		 * Retry only PMIC startup timeouts, while all phases remain queued.
		 */
		if (error != ETIMEDOUT || start_retries++)
			fail("could not start E Ink scanout");
		usleep(100000);
	}
	uint64_t streaming = now_us();
	for (; queued < renderer->buffers_count && queued < update->count; queued++)
		enqueue(renderer, queued, &update->phases[queued], mode == INIT, &render_us);
	for (unsigned int done = 0; done < update->count; done++) {
		struct pollfd pollfd = { .fd = fd, .events = POLLOUT };
		struct v4l2_buffer info = { .type = type, .memory = V4L2_MEMORY_MMAP };
		int ready;
		do {
			ready = poll(&pollfd, 1, 6000);
		} while (ready < 0 && errno == EINTR);
		if (ready <= 0 || !(pollfd.revents & POLLOUT) ||
		    retry_ioctl(fd, VIDIOC_DQBUF, &info) || info.index >= renderer->buffers_count ||
		    info.sequence != done || (info.flags & V4L2_BUF_FLAG_ERROR))
			fail("did not complete every E Ink phase");
		if (renderer->profile) {
			uint64_t irq = (uint64_t)info.timestamp.tv_sec * 1000000 + info.timestamp.tv_usec;
			if (done) {
				uint64_t gap = irq - last_irq;
				unsigned int repeats = update->phases[done].scans;
				/* Neutral reference at the configured 84.5 scans/s. */
				uint64_t expected = repeats * UINT64_C(2000000) / 169;
				if (gap > expected && gap - expected > max_gap)
					max_gap = gap - expected;
			} else {
				first_irq = irq;
			}
			last_irq = irq;
		}
		if (queued < update->count)
			enqueue(renderer, info.index, &update->phases[queued++], mode == INIT, &render_us);
	}
	uint64_t finished = now_us();
	if (retry_ioctl(fd, VIDIOC_STREAMOFF, &stream))
		fail("could not stop E Ink scanout");
	if (renderer->profile) {
		uint64_t elapsed = now_us() - start;
		fprintf(stderr, "epd: mode=%s scans=%u buffers=%u render_us=%llu v4l2_us=%llu scan_total_us=%llu\n",
			modes[mode], scans, update->count, (unsigned long long)render_us,
			(unsigned long long)(elapsed - render_us), (unsigned long long)elapsed);
		fprintf(stderr, "epd: index_us=%llu patterns=%u preload_us=%llu streamon_us=%llu "
			"first_irq_us=%llu last_irq_us=%llu first_scans=%u max_irq_excess_us=%llu streamoff_us=%llu interval=%u start_retries=%u\n",
			(unsigned long long)(index_done - start), renderer->patterns_count,
			(unsigned long long)(preloaded - index_done), (unsigned long long)(streaming - preloaded),
			(unsigned long long)(first_irq - start), (unsigned long long)(last_irq - start),
			update->phases[0].scans, (unsigned long long)max_gap,
			(unsigned long long)(now_us() - finished), renderer->wbf.interval, start_retries);
	}
}

static enum mode select_a2_or_du(const struct renderer *renderer,
				const bool *active)
{
	if (!supports(renderer, A2, active))
		return DU;
	/* Decoding yields one LUT per physical scan. Only the subsequent plan
	 * combines identical LUTs and assigns their repeat counts. */
	if (renderer->auto_fast && supports(renderer, DU, active) &&
	    renderer->cache[DU].count <= renderer->cache[A2].count)
		return DU;
	return A2;
}

static void invalidate(void)
{
	if (unlink(state_path) && errno != ENOENT)
		fail("could not invalidate the saved screen state");
}

static void apply(struct renderer *renderer, enum mode mode, const uint8_t *image,
		  const uint8_t (*tiles)[TILE_COLS], bool reset, bool fallback)
{
	uint64_t started = now_us();
	bool reset_first = reset || !renderer->known || mode == INIT;
	uint8_t *previous = renderer->previous;
	bool active[TRANSITIONS] = {0};
	bool changed = false;

	if (reset_first)
		memset(previous, 0xff, PACKED_PIXELS);
	if (mode != INIT) {
		for (unsigned int gate = 0; gate < GATES; gate++) {
			struct span_range old = renderer->rows[gate];
			transition_clear(renderer, gate * SOURCES + 4 * old.first,
					 4 * (old.end - old.first));
			renderer->rows[gate] = (struct span_range){0};
		}
		for (int ty = 0; ty < TILE_ROWS; ty++)
			for (int tx = 0; tx < TILE_COLS; tx++) {
				if (tiles && !tiles[ty][tx]) {
					if (reset_first)
						fail("a recovery frame must supply every tile");
					continue;
				}
				int right, bottom;
				tile_bounds(tx, ty, &right, &bottom);
				for (int source = ty * TILE; source < bottom; source++)
					for (int x = tx * TILE; x < right; x++) {
						size_t portrait = source * WIDTH + x;
						uint8_t sample = image[portrait];
						if (sample == KEEP) {
							if (reset_first)
								fail("a recovery frame must supply all pixels");
							continue;
						}
						if (sample & ~(SCRUB | WHITE))
							fail("invalid E Ink pixel");
						unsigned int old = nibble_get(previous, portrait), level = sample & WHITE;
						if (old == level && !(mode == GC16 && (sample & SCRUB)))
							continue;
						unsigned int gate = GATES - 1 - x;
						unsigned int t = old | (level << 4);
						active[t] = true;
						changed = true;
						transition_set(renderer, gate * SOURCES + source, t + 1);
						struct span_range *row = &renderer->rows[gate];
						if (!row->end)
							row->first = source / 4;
						row->end = source / 4 + 1;
					}
			}
	}
	if (!reset_first && !changed)
		return;

	if (!renderer->temperature_checked || started - renderer->temperature_checked >= 3000000) {
		unsigned int interval = temperature_interval(&renderer->wbf, temperature_mc());
		if (interval != renderer->wbf.interval) {
			for (unsigned int i = 0; i <= DU4; i++)
				renderer->cache[i].count = 0;
			renderer->wbf.interval = interval;
		}
		renderer->temperature_checked = now_us();
	}
	if (mode != INIT && changed) {
		cache_mode(renderer, mode);
		if (fallback && mode == A2) {
			cache_mode(renderer, DU);
			mode = select_a2_or_du(renderer, active);
		}
		/* Exact DU4 can itself contain both binary and gray targets.
		 * Allow per-transition planning there too, but never mix an
		 * approximate frame, unknown history, RESET or CLEAN. */
		if (fallback && (mode == GL16 || mode == DU4) &&
		    renderer->mixed_enabled && !reset_first) {
			cache_mode(renderer, GL16);
			cache_mode(renderer, GC16);
			cache_mode(renderer, DU);
			if (renderer->mixed_a2) cache_mode(renderer, A2);
			if (renderer->mixed_du4) cache_mode(renderer, DU4);
			if (plan_mixed(renderer, active))
				mode = MIXED;
		}
		if (fallback && mode == DU4 && !supports(renderer, mode, active)) {
			mode = GL16;
			cache_mode(renderer, mode);
		}
		if (fallback && mode == GL16 && !supports(renderer, mode, active)) {
			mode = GC16;
			cache_mode(renderer, mode);
		}
		if (mode != MIXED && !supports(renderer, mode, active))
			fail("this mode cannot perform every requested transition; use partial or full");
	}
	invalidate();
	if (!renderer->buffers_count)
		allocate_queue(renderer);
	uint64_t scan_us = 0;
	if (reset_first) {
		cache_mode(renderer, INIT);
		plan(renderer, INIT, NULL);
		uint64_t start = now_us();
		refresh(renderer, INIT);
		scan_us += now_us() - start;
	}
	if (mode != INIT && changed) {
		if (mode != MIXED)
			plan(renderer, mode, active);
		uint64_t start = now_us();
		refresh(renderer, mode);
		scan_us += now_us() - start;
	}
	/* Only commit transitions after STREAMOFF confirmed every phase. */
	if (mode != INIT)
		for (unsigned int gate = 0; gate < GATES; gate++) {
			struct span_range row = renderer->rows[gate];
			for (unsigned int source = 4 * row.first; source < 4 * row.end; source++) {
				uint16_t transition = transition_get(renderer, gate * SOURCES + source);
				if (transition)
					nibble_set(previous, portrait_index(gate, source), (transition - 1) >> 4);
			}
		}
	renderer->known = true;
	if (renderer->profile) {
		uint64_t total = now_us() - started;
		fprintf(stderr, "epd: prepare_us=%llu update_us=%llu\n",
			(unsigned long long)(total - scan_us), (unsigned long long)total);
	}
}

static bool write_state_data(FILE *file, const uint8_t *previous)
{
	uint8_t row[SOURCES];
	for (unsigned int gate = 0; gate < GATES; gate++) {
		for (unsigned int source = 0; source < SOURCES; source++)
			row[source] = nibble_get(previous, portrait_index(gate, source));
		if (fwrite(row, 1, sizeof(row), file) != sizeof(row))
			return false;
	}
	return true;
}

static void save_state(const uint8_t *previous)
{
	char pending[] = "/run/pb626-epd.XXXXXX";
	int tmp = mkstemp(pending);
	if (tmp < 0)
		fail("could not create screen state");
	FILE *file = fdopen(tmp, "wb");
	bool saved = file && write_state_data(file, previous);
	int close_error = file ? fclose(file) : close(tmp);
	if (!saved || close_error || rename(pending, state_path)) {
		unlink(pending);
		fail("could not save screen state");
	}
}

int main(int argc, char **argv)
{
    /* Never silently accept an unsupported scanout setting. The factory
     * pin-level frame needs more than 256 possible palette states. */
    const char *scanout = getenv("PB626_EPD_SCANOUT");
    if (scanout && strcmp(scanout, "pin32")) {
        fail("IDX8 cannot losslessly encode all ED060XD4 control states; use pin32");
    }
    if (argc == 2 && !strcmp(argv[1], "--protocol")) {
		puts("pb626-epd-shm-4");
		return EXIT_SUCCESS;
	}
	if ((argc == 2 && !strcmp(argv[1], "--help")) || argc < 3 || argc > 4) {
		fprintf(stderr, "Usage: pb626-epd DEFAULT.WBF reset |\n"
				"       pb626-epd DEFAULT.WBF full|partial|du|a2|du4 IMAGE.pgm\n");
		return argc == 2 && !strcmp(argv[1], "--help") ? EXIT_SUCCESS : EXIT_FAILURE;
	}
	bool serve = !strcmp(argv[2], "serve");
	enum mode mode = INIT;
	if (!serve) {
		while (mode <= DU4 && strcmp(argv[2], modes[mode]))
			mode++;
		if (mode > DU4 || argc != (mode == INIT ? 3 : 4))
			fail("invalid update mode or image argument");
	} else if (argc != 4) {
		fail("serve requires a shared frame descriptor");
	}
	if (access("/proc/device-tree/chosen/pb626,display-bringup", F_OK))
		fail("boot the verified elan-display DTB first");

	struct v4l2_capability caps = {0};
	int fd = open("/dev/video0", O_RDWR | O_CLOEXEC | O_NONBLOCK);
	if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) || retry_ioctl(fd, VIDIOC_QUERYCAP, &caps) ||
	    strcmp((const char *)caps.driver, "sun5i-eink"))
		fail("could not acquire the sun5i-eink output (is the desktop running?)");

	struct v4l2_format fmt = { .type = type, .fmt.pix = {
		.width = CLOCKS, .height = ROWS, .pixelformat = SUN5I_EINK_FMT_PIN32,
	} };
	if (retry_ioctl(fd, VIDIOC_S_FMT, &fmt) || fmt.fmt.pix.sizeimage != FRAME_BYTES ||
	    fmt.fmt.pix.bytesperline != CLOCKS * 4)
		fail("the output does not support the ED060XD4 scanout format");

	static struct renderer renderer;
	renderer.fd = fd;
	renderer.profile = getenv("PB626_EPD_PROFILE") != NULL;
	const char *style = getenv("PB626_EPD_RENDER");
	if (!style || !strcmp(style, "scalar"))
		renderer.style = RENDER_SCALAR;
	else if (!strcmp(style, "staged"))
		renderer.style = RENDER_STAGED;
	else if (!strcmp(style, "indexed")) {
		renderer.style = RENDER_INDEXED;
		renderer.group_codes = malloc(GATES * GROUPS);
		if (!renderer.group_codes) {
			fprintf(stderr, "pb626-epd: indexed allocation failed, using staged renderer\n");
			renderer.style = RENDER_STAGED;
		}
	} else {
		fail("PB626_EPD_RENDER must be scalar, staged or indexed");
	}
	const char *prefill = getenv("PB626_EPD_PREFILL");
	if (prefill) {
		char *end;
		unsigned long n = strtoul(prefill, &end, 10);
		if (!n || n > QUEUE_SIZE || *end)
			fail("PB626_EPD_PREFILL must be between 1 and 8");
		renderer.prefill = n;
	}
	const char *fast = getenv("PB626_EPD_FAST_MODE");
	renderer.auto_fast = fast && !strcmp(fast, "auto");
	renderer.mixed_a2 = renderer.auto_fast || (fast && !strcmp(fast, "a2"));
	renderer.mixed_du4 = renderer.auto_fast || (fast && !strcmp(fast, "du4"));
	const char *mixed = getenv("PB626_EPD_MIXED");
	const char *approx = getenv("PB626_EPD_APPROX_PREVIEW");
	renderer.mixed_enabled = serve && mixed && !strcmp(mixed, "1") &&
		(!approx || strcmp(approx, "1")) &&
		!access("/etc/pb626/mixed-waveform-qualified", F_OK);
	if (mixed && !strcmp(mixed, "1") && !renderer.mixed_enabled)
		fprintf(stderr, "epd: mixed waveform not qualified; retaining normal SETTLE\n");
	load_waveform(&renderer.wbf, argv[1]);
	/* The stock WBF targets 85 scans/s. The A13 clock tree supplies
	 * 22.5 MHz here, giving 84.5 scans/s with Megi's porch settings.
	 */
	struct sun5i_eink_timing timing = {
		.sclk_hz = 135000000, .dclk_div = 6,
		.hbp = 40, .vbp = 1, .hsync = 1, .vsync = 1, .clk_delay = 3,
	};
	if (retry_ioctl(fd, SUN5I_EINK_S_TIMING, &timing))
		fail("could not select the factory WBF scan rate");
	init_neutral_data(&renderer);
	renderer.known = load_state(renderer.previous);

	if (serve) {
		char *end;
		long frame_fd = strtol(argv[3], &end, 10);
		struct stat info;
		if (!*argv[3] || *end || frame_fd < 3 || frame_fd > INT32_MAX ||
		    fstat(frame_fd, &info) || info.st_size != (off_t)sizeof(struct shared_frame))
			fail("invalid shared frame descriptor");
		const struct shared_frame *image = mmap(NULL, sizeof(*image), PROT_READ, MAP_SHARED, frame_fd, 0);
		close(frame_fd);
		if (image == MAP_FAILED)
			fail("could not map shared frame");
		int command;
		while ((command = fgetc(stdin)) != EOF) {
			if (command == RELEASE_QUEUE) {
				release_queue(&renderer);
				if (fputc(command, stdout) == EOF || fflush(stdout))
					fail("could not acknowledge queue release");
				continue;
			}
			switch (command) {
			case PREVIEW: mode = DU; break;
            case PREVIEW_A2: mode = A2; break;
            case PREVIEW_DU4: mode = DU4; break;
			case SETTLE: mode = GL16; break;
			case INIT_PANEL: mode = INIT; break;
			case CLEAN: case RESET: mode = GC16; break;
			default: fail("invalid update command");
			}
			apply(&renderer, mode, image->pixels, image->tiles, command == RESET, true);
			if (fputc(command, stdout) == EOF || fflush(stdout))
				fail("could not acknowledge E Ink update");
		}
		if (ferror(stdin))
			fail("could not read update command");
	} else {
		uint8_t *target = NULL;
		if (mode != INIT) {
			target = malloc(PIXELS);
			if (!target)
				fail("could not allocate one-shot image");
			read_image(argv[3], target);
			if (mode == GC16)
				for (size_t i = 0; i < PIXELS; i++)
					target[i] |= SCRUB;
		}
		apply(&renderer, mode, target, NULL, false, false);
		free(target);
	}
	if (renderer.known)
		save_state(renderer.previous);
	return EXIT_SUCCESS;
}
