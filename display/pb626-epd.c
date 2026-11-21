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

enum { SOURCES = 1024, GATES = 758, PIXELS = SOURCES * GATES,
       CLOCKS = 304, ROWS = 767, DATA_ROW = 6, DATA_CLOCK = 40,
       GATE_HIGH_CLOCKS = 85, GROUPS = SOURCES / 4,
       HEADER_WORDS = SUN5I_EINK_HDR_SIZE / sizeof(uint32_t),
       FRAME_WORDS = HEADER_WORDS + CLOCKS * ROWS, FRAME_BYTES = FRAME_WORDS * 4,
       LEVELS = 16, WHITE = LEVELS - 1, TRANSITIONS = LEVELS * LEVELS,
       LUT_BYTES = TRANSITIONS / 4, MAX_PHASES = 256, QUEUE_SIZE = 12 };

enum { S_LE = 1 << 13, G_MODE = 1 << 15, S_OE = 1 << 20,
       S_SP = 1 << 21, G_CLK = 1 << 22, G_SP = 1 << 23,
       BASE = G_MODE | G_SP, IDLE = BASE | S_SP };

enum mode { INIT, DU, GC16, GL16, A2, DU4 };
static const char *const modes[] = { "reset", "du", "full", "partial", "a2", "du4" };
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

struct buffer {
	uint32_t *data;
	size_t size;
};

static void fail(const char *message)
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

static int temperature_mc(void)
{
	glob_t hwmon = {0};
	int temperature = 0;
	bool found = false;

	if (glob("/sys/class/hwmon/hwmon*/name", 0, NULL, &hwmon))
		fail("could not enumerate hwmon devices");
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
	if (!found)
		fail("could not read the TPS65185 panel temperature");
	return temperature;
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

	int temp = temperature_mc();
	for (unsigned int i = 0; i < ranges; i++) {
		if (temp >= 1000 * bounds[i] && temp < 1000 * bounds[i + 1]) {
			wbf->interval = i;
			wbf->modes = data[0x25] + 1;
			return;
		}
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

static void plan(struct update *update, const struct waveform *wbf, enum mode mode,
		 const bool *active)
{
	uint8_t packed[MAX_PHASES * LUT_BYTES];
	bool driven[TRANSITIONS] = {0};
	size_t count = decode(wbf, mode, packed);

	for (size_t i = 0; i < count; i++) {
		const uint8_t *lut = packed + i * LUT_BYTES;
		uint8_t phase[TRANSITIONS] = {0};

		for (unsigned int t = 0; t < TRANSITIONS; t++) {
			uint8_t signal = (lut[t / 4] >> (2 * (t % 4))) & 3;

			if (signal == 3)
				fail("unsupported WBF source voltage");
			if (mode == INIT || active[t]) {
				phase[t] = signal;
				driven[t] |= signal != 0;
			}
		}
		if (mode == INIT)
			for (unsigned int t = 1; t < TRANSITIONS; t++)
				if (phase[t] != phase[0])
					fail("RESET requires a uniform waveform");

		struct phase *last = update->count ? &update->phases[update->count - 1] : NULL;
		if (last && !memcmp(last->lut, phase, sizeof(phase))) {
			last->scans++;
		} else {
			struct phase *next = &update->phases[update->count++];
			memcpy(next->lut, phase, sizeof(phase));
			next->scans = 1;
		}
	}
	if (mode != INIT)
		for (unsigned int t = 0; t < TRANSITIONS; t++)
			if (active[t] && t % (LEVELS + 1) && !driven[t])
				fail("this mode cannot perform every requested transition; use partial or full");
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
			target[(GATES - 1 - x) * SOURCES + y] = (row[x] * WHITE + maxval / 2) / maxval;
		}
	}
	if (fgetc(file) != EOF || ferror(file))
		fail("unexpected data after the PGM pixels");
	fclose(file);
}

static bool load_state(uint8_t *previous)
{
	FILE *file = fopen(state_path, "rb");
	bool valid = file && fread(previous, 1, PIXELS, file) == PIXELS &&
		     fgetc(file) == EOF && !ferror(file);
	if (file)
		fclose(file);
	for (size_t i = 0; valid && i < PIXELS; i++)
		valid = previous[i] <= WHITE;
	if (!valid)
		memset(previous, WHITE, PIXELS);
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

static uint32_t source_word(unsigned int data)
{
	return ((data & 0x1f) << 3) | ((data & 0xe0) << 5);
}

static void render(uint32_t *frame, const uint32_t *neutral, const struct phase *phase,
		   const uint8_t *transitions)
{
	uint32_t pins[4][TRANSITIONS];

	memcpy(frame, neutral, FRAME_BYTES);
	frame[3] = htole32(phase->scans - 1);
	/* The first pixel of each group uses D7:D6 and the last uses D1:D0. */
	for (unsigned int pixel = 0; pixel < 4; pixel++)
		for (unsigned int t = 0; t < TRANSITIONS; t++)
			pins[pixel][t] = htole32(source_word(phase->lut[t] << (6 - 2 * pixel)));
	for (unsigned int y = 0; y < GATES; y++) {
		uint32_t *out = frame + HEADER_WORDS + (DATA_ROW + y) * CLOCKS + DATA_CLOCK;
		const uint8_t *row = transitions ? transitions + y * SOURCES : NULL;
		if (!row) {
			uint32_t data = htole32(source_word(phase->lut[0] * 0x55));
			for (unsigned int x = 0; x < GROUPS; x++)
				out[x] |= data;
			continue;
		}
		for (unsigned int x = 0; x < GROUPS; x++, row += 4)
			out[x] |= pins[0][row[0]] | pins[1][row[1]] | pins[2][row[2]] | pins[3][row[3]];
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

static void enqueue(int fd, unsigned int index, struct buffer *buffers, const uint32_t *neutral,
		    const struct phase *phase, const uint8_t *transitions)
{
	struct v4l2_buffer info = { .index = index, .type = type, .memory = V4L2_MEMORY_MMAP,
				   .bytesused = FRAME_BYTES, .field = V4L2_FIELD_NONE };
	render(buffers[index].data, neutral, phase, transitions);
	if (retry_ioctl(fd, VIDIOC_QBUF, &info))
		fail("could not queue an E Ink phase");
}

static void refresh(int fd, const uint32_t *neutral, const struct update *update,
		    const uint8_t *transitions)
{
	struct buffer buffers[QUEUE_SIZE] = {0};
	struct v4l2_requestbuffers req = { .count = QUEUE_SIZE, .type = type,
					  .memory = V4L2_MEMORY_MMAP };
	if (req.count > update->count)
		req.count = update->count;
	if (retry_ioctl(fd, VIDIOC_REQBUFS, &req) || !req.count || req.count > QUEUE_SIZE)
		fail("could not allocate the E Ink scanout queue");

	unsigned int queued = 0;
	for (; queued < req.count; queued++) {
		struct v4l2_buffer info = { .index = queued, .type = type, .memory = V4L2_MEMORY_MMAP };
		if (retry_ioctl(fd, VIDIOC_QUERYBUF, &info) || info.length < FRAME_BYTES)
			fail("could not query an E Ink scanout buffer");
		buffers[queued].size = info.length;
		buffers[queued].data = mmap(NULL, info.length, PROT_READ | PROT_WRITE,
					    MAP_SHARED, fd, info.m.offset);
		if (buffers[queued].data == MAP_FAILED)
			fail("could not map an E Ink scanout buffer");
		enqueue(fd, queued, buffers, neutral, &update->phases[queued], transitions);
	}

	enum v4l2_buf_type stream = type;
	if (retry_ioctl(fd, VIDIOC_STREAMON, &stream))
		fail("could not start E Ink scanout");
	for (unsigned int done = 0; done < update->count; done++) {
		struct pollfd pollfd = { .fd = fd, .events = POLLOUT };
		struct v4l2_buffer info = { .type = type, .memory = V4L2_MEMORY_MMAP };
		int ready;
		do {
			ready = poll(&pollfd, 1, 6000);
		} while (ready < 0 && errno == EINTR);
		if (ready <= 0 || !(pollfd.revents & POLLOUT) ||
		    retry_ioctl(fd, VIDIOC_DQBUF, &info) || info.index >= req.count ||
		    info.sequence != done || (info.flags & V4L2_BUF_FLAG_ERROR))
			fail("did not complete every E Ink phase");
		if (queued < update->count)
			enqueue(fd, info.index, buffers, neutral, &update->phases[queued++], transitions);
	}
	if (retry_ioctl(fd, VIDIOC_STREAMOFF, &stream))
		fail("could not stop E Ink scanout");
	for (unsigned int i = 0; i < req.count; i++)
		munmap(buffers[i].data, buffers[i].size);
	req.count = 0;
	if (retry_ioctl(fd, VIDIOC_REQBUFS, &req))
		fail("could not release E Ink scanout buffers");
}

int main(int argc, char **argv)
{
	if ((argc == 2 && !strcmp(argv[1], "--help")) || argc < 3 || argc > 4) {
		fprintf(stderr, "Usage: pb626-epd DEFAULT.WBF reset |\n"
				"       pb626-epd DEFAULT.WBF full|partial|du|a2|du4 IMAGE.pgm\n");
		return argc == 2 && !strcmp(argv[1], "--help") ? EXIT_SUCCESS : EXIT_FAILURE;
	}
	enum mode mode = INIT;
	while (mode <= DU4 && strcmp(argv[2], modes[mode]))
		mode++;
	if (mode > DU4 || argc != (mode == INIT ? 3 : 4))
		fail("invalid update mode or image argument");
	if (access("/proc/device-tree/chosen/pb626,display-bringup", F_OK))
		fail("boot the verified elan-display DTB first");

	struct v4l2_capability caps = {0};
	int fd = open("/dev/video0", O_RDWR | O_CLOEXEC | O_NONBLOCK);
	if (fd < 0 || flock(fd, LOCK_EX) || retry_ioctl(fd, VIDIOC_QUERYCAP, &caps) ||
	    strcmp((const char *)caps.driver, "sun5i-eink"))
		fail("could not acquire the sun5i-eink output");

	struct v4l2_format fmt = { .type = type, .fmt.pix = {
		.width = CLOCKS, .height = ROWS, .pixelformat = SUN5I_EINK_FMT_PIN32,
	} };
	if (retry_ioctl(fd, VIDIOC_S_FMT, &fmt) || fmt.fmt.pix.sizeimage != FRAME_BYTES ||
	    fmt.fmt.pix.bytesperline != CLOCKS * 4)
		fail("the output does not support the ED060XD4 scanout format");

	struct waveform wbf;
	load_waveform(&wbf, argv[1]);
	/* The stock WBF targets 85 scans/s. The A13 clock tree supplies
	 * 22.5 MHz here, giving 84.5 scans/s with Megi's porch settings.
	 */
	struct sun5i_eink_timing timing = {
		.sclk_hz = 135000000, .dclk_div = 6,
		.hbp = 40, .vbp = 1, .hsync = 1, .vsync = 1, .clk_delay = 3,
	};
	if (retry_ioctl(fd, SUN5I_EINK_S_TIMING, &timing))
		fail("could not select the factory WBF scan rate");
	uint8_t *target = malloc(PIXELS), *transitions = malloc(PIXELS);
	uint32_t *neutral = calloc(FRAME_WORDS, sizeof(*neutral));
	if (!target || !transitions || !neutral)
		fail("could not allocate E Ink working memory");
	struct update update = {0}, reset = {0};
	bool active[TRANSITIONS] = {0};
	bool known = load_state(transitions);

	if (mode == INIT || !known)
		plan(&reset, &wbf, INIT, NULL);
	if (mode == INIT) {
		memset(target, WHITE, PIXELS);
	} else {
		read_image(argv[3], target);
		bool changed = false;
		for (size_t i = 0; i < PIXELS; i++) {
			bool differs = transitions[i] != target[i];
			transitions[i] |= target[i] << 4;
			active[transitions[i]] |= differs || mode == GC16;
			changed |= differs;
		}
		if (known && !changed && mode != GC16)
			return EXIT_SUCCESS;
		plan(&update, &wbf, mode, active);
	}

	scan_template(neutral);
	/* Interruptions leave the physical image unknown; the next update resets it. */
	if (unlink(state_path) && errno != ENOENT)
		fail("could not invalidate the saved screen state");
	if (reset.count)
		refresh(fd, neutral, &reset, NULL);
	if (update.count)
		refresh(fd, neutral, &update, transitions);

	char pending[] = "/run/pb626-epd.XXXXXX";
	int tmp = mkstemp(pending);
	if (tmp < 0)
		fail("could not create screen state");
	FILE *file = fdopen(tmp, "wb");
	bool saved = file && fwrite(target, 1, PIXELS, file) == PIXELS;
	if (!file || fclose(file) || !saved || rename(pending, state_path)) {
		unlink(pending);
		fail("could not save screen state");
	}
	return EXIT_SUCCESS;
}
