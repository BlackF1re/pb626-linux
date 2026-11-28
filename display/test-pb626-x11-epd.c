/* SPDX-License-Identifier: GPL-2.0-or-later */
#define main pb626_x11_epd_main
#include "pb626-x11-epd.c"
#undef main

#include <assert.h>

static void test_worker_deadlines(void)
{
	int fds[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
	struct worker worker = { .socket = fds[0], .deadline = now_us() + 30000 };
	assert(await_ack(&worker, RESET) == -1);
	assert(write(fds[1], "R", 1) == 1);
	worker.deadline = now_us() + 1000000;
	assert(await_ack(&worker, RESET) == 0);
	assert(write(fds[1], "X", 1) == 1);
	assert(await_ack(&worker, RESET) == -1);
	close(fds[1]);
	assert(await_ack(&worker, RESET) == -1);
	close(fds[0]);
	pid_t child = fork();
	assert(child >= 0);
	if (!child) {
		for (;;)
			pause();
	}
	assert(wait_child(child, 30) == -1);
	assert(kill(child, SIGKILL) == 0);
	assert(wait_child(child, 1000) == 0);
}

static void test_packed_rgb565(void)
{
	uint8_t packed[2] = {0};
	for (unsigned int i = 0; i < 16; i++)
		for (unsigned int j = 0; j < 16; j++) {
			nibble_set(packed, 0, i);
			nibble_set(packed, 1, j);
			assert(nibble_get(packed, 0) == i && nibble_get(packed, 1) == j);
		}
	for (int profile = GRAY_BALANCED; profile <= GRAY_MONO; profile++)
		for (int tone = 0; tone < 2; tone++)
			for (int gamma = 0; gamma < 2; gamma++) {
				setup_gray(profile, tone, gamma ? 1.2 : 1.0);
				for (unsigned int p = 0; p <= 65535; p++)
					assert(rgb565_gray(p) == gray_value(channel(p, 0xf800),
						channel(p, 0x07e0), channel(p, 0x001f)));
			}
}

static void test_gray_rows(void)
{
	enum { N = 39 };
	uint8_t raw16[2 * N + 1], raw32[4 * N + 1], out[N + 2];
	uint8_t *src16 = raw16 + 1, *src32 = raw32 + 1;
	for (int i = 0; i < N; i++) {
		unsigned int p = i < 16 ? (i % 2 ? 0xffff : 0) : (i * 17237) & 0xffff;
		src16[2 * i] = p;
		src16[2 * i + 1] = p >> 8;
		src32[4 * i] = i * 37;
		src32[4 * i + 1] = i < 16 ? src32[4 * i] : i * 17;
		src32[4 * i + 2] = i < 16 ? src32[4 * i] : i * 71;
		src32[4 * i + 3] = i * 83;
	}
	for (int profile = GRAY_BALANCED; profile <= GRAY_MONO; profile++)
		for (int tone = 0; tone < 2; tone++)
			for (int gamma = 0; gamma < 2; gamma++) {
				setup_gray(profile, tone, gamma ? 1.2 : 1.0);
				for (int count = 0; count <= N; count++) {
					memset(out, 0x9a, sizeof(out));
					rgb565_gray_row(src16, out + 1, count);
					assert(out[0] == 0x9a && out[count + 1] == 0x9a);
					for (int i = 0; i < count; i++)
						assert(out[i + 1] == rgb565_gray(src16[2 * i] |
						       ((unsigned int)src16[2 * i + 1] << 8)));
					memset(out, 0x9a, sizeof(out));
					rgbx_gray_row(src32, out + 1, count);
					assert(out[0] == 0x9a && out[count + 1] == 0x9a);
					for (int i = 0; i < count; i++)
						assert(out[i + 1] == gray_value(src32[4 * i + 2],
						       src32[4 * i + 1], src32[4 * i]));
				}
			}
}

/* Candidate only: keep the production conversion unchanged until timings
 * on the reader establish whether a 64 KiB table is worth its footprint. */
static uint8_t rgb565_candidate[65536];

static void candidate_gray_row(const uint8_t *src, uint8_t *dst, int count)
{
	for (int x = 0; x < count; x++)
		dst[x] = rgb565_candidate[src[2 * x] | ((unsigned int)src[2 * x + 1] << 8)];
}

static void init_candidate_gray(void)
{
	for (unsigned int p = 0; p < 65536; p++)
		rgb565_candidate[p] = rgb565_gray(p);
}

static void test_rgb565_candidate(void)
{
	static uint8_t input[2 * 65536 + 1], reference[65536], candidate[65536];
	uint8_t *src = input + 1; /* exercise unaligned input */
	for (unsigned int p = 0; p < 65536; p++) {
		src[2 * p] = p;
		src[2 * p + 1] = p >> 8;
	}
	for (int profile = GRAY_BALANCED; profile <= GRAY_MONO; profile++)
		for (int tone = 0; tone < 2; tone++)
			for (int gamma = 0; gamma < 2; gamma++) {
				setup_gray(profile, tone, gamma ? 1.2 : 1.0);
				init_candidate_gray();
				rgb565_gray_row(src, reference, 65536);
				candidate_gray_row(src, candidate, 65536);
				assert(!memcmp(reference, candidate, sizeof(reference)));
			}
	puts("RGB565 candidate: all colors, profiles, tones and gammas passed");
}

static uint64_t cpu_ns(void)
{
	struct timespec t;
	assert(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t));
	return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

/* Run the ARM test executable with PB626_BENCH_RGB565=1 on the reader.
 * No X connection, panel, privileged operation or runtime service needed.
 * Report process CPU time; timings from an emulator are not comparable. */
static void bench_rgb565_candidate(void)
{
	enum { ROW = 760, ROWS = 128, REPEATS = 64 };
	static uint8_t input[2 * ROW * ROWS], output[ROW];
	static volatile unsigned int sink;
	setup_gray(GRAY_BALANCED, 0, 1.0);
	init_candidate_gray();
	puts("pattern,width,implementation,ns_per_pixel");
#ifdef PB626_RGB565_ARITHMETIC
	const char *production = "arithmetic";
#else
	const char *production = "expand96";
#endif
	for (int pattern = 0; pattern < 3; pattern++) {
		uint32_t rng = 1;
		for (unsigned int i = 0; i < ROW * ROWS; i++) {
			rng = rng * UINT32_C(1664525) + UINT32_C(1013904223);
			unsigned int v = (i / 7) & 31;
			unsigned int p = pattern == 0 ? ((i / 19) & 1 ? 65535 : 0) :
				pattern == 1 ? (v << 11) | ((v * 2) << 5) | v : rng >> 16;
			input[2 * i] = p;
			input[2 * i + 1] = p >> 8;
		}
		for (int width = 32; width <= ROW; width = width == 32 ? ROW : ROW + 1)
			for (int lookup = 0; lookup < 2; lookup++) {
				uint64_t start = cpu_ns();
				unsigned int checksum = 0;
				for (int pass = 0; pass < REPEATS; pass++)
					for (int row = 0; row < ROWS; row++) {
						const uint8_t *src = input + 2 * row * ROW;
						if (lookup)
							candidate_gray_row(src, output, width);
						else
							rgb565_gray_row(src, output, width);
						checksum += output[(row + pass) % width];
					}
				uint64_t elapsed = cpu_ns() - start;
				sink = checksum;
				(void)sink;
				printf("%s,%d,%s,%.2f\n",
				       pattern == 0 ? "binary" : pattern == 1 ? "gray" : "color",
				       width, lookup ? "lut" : production,
				       (double)elapsed / (REPEATS * ROWS * width));
			}
	}
}

static void test_contrast_row(void)
{
	uint8_t row[65], above[65], below[65];
	uint16_t result[65];
	for (int i = 0; i < 65; i++) {
		row[i] = (i * 71 + 19) & 255;
		above[i] = (i * 41 + 103) & 255;
		below[i] = (i * 131 + 5) & 255;
	}
	for (int left = 0; left < 65; left++)
		for (int right = left + 1; right <= 65; right++) {
			memset(result, 0xff, sizeof(result));
			contrast_row(row, above, below, result, left, right, 65);
			for (int x = 0; x < 65; x++) {
				if (x < left || x >= right) {
					assert(result[x] == UINT16_MAX);
					continue;
				}
				int v = row[x];
				assert(result[x] == abs(v - row[x ? x-1 : x]) +
				       abs(v - row[x+1 < 65 ? x+1 : x]) +
				       abs(v - above[x]) + abs(v - below[x]));
			}
		}
}

static void test_gray(void)
{
	quant_reference = 1;
	setup_gray(GRAY_BALANCED, 0, 1.0);
	assert(gray_value(255, 0, 0) == 127);
	assert(gray_value(0, 255, 0) == 220);
	assert(gray_value(0, 0, 255) == 76);
	for (unsigned int v = 0; v < 256; v++)
		assert(gray_value(v, v, v) == v);
	assert(gray_value(255, 255, 254) == 255);
	setup_gray(GRAY_UI, 0, 1.0);
	assert(quantize(127, 0, 0, 0) == 7 && quantize(127, 0, 1, 0) == 7);
	setup_gray(GRAY_MONO, 0, 1.0);
	for (unsigned int v = 0; v < 256; v++)
		assert(quantize(v, 0, 0, 0) == (v >= 128 ? WHITE : 0));
	setup_gray(GRAY_PHOTO, 0, 1.0);
	int count = 0;
	for (int y = 0; y < 16; y++)
		for (int x = 0; x < 16; x++) {
			for (unsigned int level = 0; level <= WHITE; level++)
				assert(quantize(level * 17, 0, x, y) == level);
			uint8_t level = quantize(127, 0, x, y);
			assert(level == 7 || level == 8);
			assert(level == quantize(127, 0, x + 16, y + 16));
			assert(quantize(127, 48, x, y) == 7);
			count += level == 8;
		}
	assert(count == 120);
	setup_gray(GRAY_PHOTO, 1, 1.0);
	assert(gray_value(0, 0, 255) == 82);
	assert(gray_value(0, 0, 0) == 0 && gray_value(255, 255, 255) == 255);
	setup_gray(GRAY_UI, 0, 1.2);
	assert(gray_value(128, 128, 128) > 128);
	setup_gray(GRAY_LEGACY, 0, 1.0);
	assert(gray_value(255, 0, 0) == 56);
	assert(quantize(127, 0, 0, 0) == paper_level(127, 0, 0, 0));
	unsetenv("PB626_EPD_QUANT_REFERENCE");
	for (int profile = GRAY_BALANCED; profile <= GRAY_MONO; profile++) {
		setup_gray(profile, 0, 1.0);
		setup_quantization();
		for (int y = 0; y < 16; y++)
			for (int x = 0; x < 16; x++)
				for (unsigned int v = 0; v < 256; v++) {
					assert(quantize(v, 47, x, y) == quantize_reference(v, 47, x, y));
					assert(quantize(v, 48, x, y) == quantize_reference(v, 48, x, y));
				}
	}
	puts("E Ink grayscale profiles, exact lookup and stable dithering passed");
}

/* Optional real-X-server regression: compare the packed strip path with
 * a full XGetImage reference, including partial regions and strip edges. */
static void test_power_press(void)
{
	int fds[2];
	assert(!pipe(fds));
	struct input_event events[] = {
		{ .type = EV_KEY, .code = KEY_POWER, .value = 0, .input_event_sec = 1 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 1, .input_event_sec = 2 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 2, .input_event_sec = 2 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 0, .input_event_sec = 2, .input_event_usec = 100000 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 1, .input_event_sec = 3 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 0, .input_event_sec = 5 },
	};
	assert(write(fds[1], events, sizeof(events)) == (ssize_t)sizeof(events));
	close(fds[1]);
	struct power_input pressed = {0};
	assert(power_press(fds[0], &pressed) == 1 && !pressed.pressed);
	close(fds[0]);
	assert(!pipe(fds));
	struct input_event overflow[] = {
		{ .type = EV_KEY, .code = KEY_POWER, .value = 1, .input_event_sec = 6 },
		{ .type = EV_SYN, .code = SYN_DROPPED },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 1, .input_event_sec = 7 },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 0, .input_event_sec = 7 },
		{ .type = EV_SYN, .code = SYN_REPORT },
		{ .type = EV_KEY, .code = KEY_POWER, .value = 0, .input_event_sec = 8 },
	};
	assert(write(fds[1], overflow, sizeof(overflow)) == (ssize_t)sizeof(overflow));
	close(fds[1]);
	assert(power_press(fds[0], &pressed) == 0 && !pressed.pressed && !pressed.dropped);
	close(fds[0]);
}

static void test_capture_coordinates(void)
{
	for (int r = PB_ROT_0; r <= PB_ROT_270; r++) {
		int w = logical_width(r), h = logical_height(r);
		for (int y = 0; y < h; y++) {
			int px, py, dx, dy;
			capture_row_coordinates(r, 0, y, &px, &py, &dx, &dy);
			for (int x = 0; x < w; x++, px += dx, py += dy) {
				assert(px >= 0 && px < WIDTH && py >= 0 && py < HEIGHT);
				assert((size_t)py * WIDTH + px == panel_index(r, x, y));
			}
			/* Partial strip begins at its actual logical x, not at zero. */
			capture_row_coordinates(r, w / 3, y, &px, &py, &dx, &dy);
			assert((size_t)py * WIDTH + px == panel_index(r, w / 3, y));
		}
	}
}

static void test_ddx_layout(void)
{
	struct pb626_ddx_fb h = {
		.magic = PB626_DDX_FB_MAGIC, .version = PB626_DDX_FB_VERSION,
		.capacity = 760 * 1024 * 2, .width = 760, .height = 1024,
		.stride = 760 * 2, .depth = 16, .bpp = 16,
		.red = 0xf800, .green = 0x07e0, .blue = 0x001f,
	};
	size_t size = PB626_DDX_FB_OFFSET + h.capacity;
	assert(ddx_layout(&h, size, 1, 0, 758, 1024));
	assert(!ddx_layout(&h, size, -1, 0, 1, 1));
	assert(!ddx_layout(&h, size, 759, 0, 2, 1));
	assert(!ddx_layout(&h, size, 0, 1023, 1, 2));
	assert(!ddx_layout(&h, size - 1, 0, 0, 1, 1));
	h.stride = 16;
	assert(!ddx_layout(&h, size, 0, 0, 1, 1));
	h.stride = 760 * 2;
	h.height = UINT32_MAX;
	assert(!ddx_layout(&h, size, 0, 0, 1, 1));
	h.height = 1024;
	h.blue = 0xff;
	assert(!ddx_layout(&h, size, 0, 0, 1, 1));
}

static void test_x11_capture(void)
{
	Display *display = XOpenDisplay(NULL);
	assert(display);
	int screen = DefaultScreen(display);
	assert(DisplayWidth(display, screen) >= WIDTH && DisplayHeight(display, screen) >= HEIGHT);
	Window root = RootWindow(display, screen);
	int offset = (DisplayWidth(display, screen) - WIDTH) / 2;
	GC gc = XCreateGC(display, root, 0, NULL);
	for (int y = 0; y < HEIGHT; y += 13)
		for (int x = 0; x < WIDTH; x += 17) {
			XColor color = {
				.red = (x * 137 + y * 53) & 65535,
				.green = (x * 71 + y * 167) & 65535,
				.blue = (x * 211 + y * 31) & 65535,
			};
			assert(XAllocColor(display, DefaultColormap(display, screen), &color));
			XSetForeground(display, gc, color.pixel);
			XFillRectangle(display, root, gc, x + offset, y, 17, 13);
		}
	XSync(display, False);
	XShmSegmentInfo shm = {0}, fallback = {0};
	setup_shm(display, &shm);
	assert(shm.shmaddr);
	/* Simulate an exported root pixmap and compare direct strided reads
	 * (including nonzero x/y offsets) against the existing server path. */
	XImage *root_image = XGetImage(display, root, 0, 0,
				     DisplayWidth(display, screen), DisplayHeight(display, screen),
				     AllPlanes, ZPixmap);
	assert(root_image);
	size_t capacity = (size_t)root_image->bytes_per_line * root_image->height;
	struct pb626_ddx_fb *mapping = calloc(1, PB626_DDX_FB_OFFSET + capacity);
	assert(mapping);
	*mapping = (struct pb626_ddx_fb){
		.magic = PB626_DDX_FB_MAGIC, .version = PB626_DDX_FB_VERSION,
		.capacity = capacity, .width = root_image->width, .height = root_image->height,
		.stride = root_image->bytes_per_line, .depth = root_image->depth,
		.bpp = root_image->bits_per_pixel, .red = root_image->red_mask,
		.green = root_image->green_mask, .blue = root_image->blue_mask,
	};
	memcpy((char *)mapping + PB626_DDX_FB_OFFSET, root_image->data, capacity);
	XDestroyImage(root_image);
	static uint8_t full_luma[PIXELS], reference[PACKED_PIXELS], candidate[PACKED_PIXELS];
	struct rect full = {0, 0, WIDTH, HEIGHT};
	struct rect pointer = {125, 125, 136, 136};
	for (int profile = GRAY_BALANCED; profile <= GRAY_MONO; profile++) {
		setup_gray(profile, 0, 1.0);
		setup_quantization();
		XImage *image = XGetImage(display, root, offset, 0, WIDTH, HEIGHT, AllPlanes, ZPixmap);
		assert(image);
		for (int y = 0; y < HEIGHT; y++)
			for (int x = 0; x < WIDTH; x++) {
				unsigned long p = XGetPixel(image, x, y);
				full_luma[y * WIDTH + x] = gray_value(channel(p, image->red_mask),
					channel(p, image->green_mask), channel(p, image->blue_mask));
			}
		XDestroyImage(image);
		for (int y = 0; y < HEIGHT; y++)
			for (int x = 0; x < WIDTH; x++) {
				size_t i = y * WIDTH + x;
				unsigned int v = full_luma[i], contrast = 0;
				if (profile != GRAY_UI && profile != GRAY_MONO) {
					contrast = abs((int)v - (int)(x ? full_luma[i - 1] : v)) +
						abs((int)v - (int)(x + 1 < WIDTH ? full_luma[i + 1] : v)) +
						abs((int)v - (int)(y ? full_luma[i - WIDTH] : v)) +
						abs((int)v - (int)(y + 1 < HEIGHT ? full_luma[i + WIDTH] : v));
				}
				uint8_t level = (profile == GRAY_MONO || v % 17) ? quantize_reference(v, contrast, x, y) : v / 17;
				nibble_set(reference, i, pointer_level(pointer, 1, x, y, level));
			}
		struct capture_stats stats = {0};
		memset(candidate, 0, sizeof(candidate));
		assert(!capture(display, root, offset, full, candidate, pointer, 1, &stats, &shm));
		assert(stats.pixels == PIXELS);
		assert(!memcmp(reference, candidate, sizeof(reference)));
		memset(candidate, 0, sizeof(candidate));
		for (int top = 0; top < HEIGHT; top += 173)
			for (int left = 0; left < WIDTH; left += 181) {
				struct rect area = {left, top, left + 181 < WIDTH ? left + 181 : WIDTH,
					top + 173 < HEIGHT ? top + 173 : HEIGHT};
				assert(!capture(display, root, offset, area, candidate, pointer, 1, &stats, &fallback));
			}
		assert(!memcmp(reference, candidate, sizeof(reference)));
		ddx_fb = mapping;
		ddx_size = PB626_DDX_FB_OFFSET + capacity;
		memset(candidate, 0, sizeof(candidate));
		for (int top = 0; top < HEIGHT; top += 173)
			for (int left = 0; left < WIDTH; left += 181) {
				struct rect area = {left, top, left + 181 < WIDTH ? left + 181 : WIDTH,
					top + 173 < HEIGHT ? top + 173 : HEIGHT};
				assert(!capture(display, root, offset, area, candidate, pointer, 1, &stats, &fallback));
			}
		assert(!memcmp(reference, candidate, sizeof(reference)));
		/* Prove direct path was eligible, not just the fallback. */
		XImage *direct = ddx_image(display, offset, 17, 19, 23);
		assert(direct);
		finish_image(display, direct, 1);
		ddx_fb = NULL;
		ddx_size = 0;
	}
	free(mapping);
	assert(!grab_lock(display, root));
	release_lock(display);
	XShmDetach(display, &shm);
	XSync(display, False);
	shmdt(shm.shmaddr);
	XFreeGC(display, gc);
	XCloseDisplay(display);
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
	puts("X11 strip capture matches full-frame reference in the server visual");
}

static void test_stock_sleep(void)
{
	static uint8_t input[PACKED_PIXELS], output[PIXELS], seen[PIXELS], bitmap[500000];
	for (int r = PB_ROT_0; r <= PB_ROT_270; r++) {
		enum pb_rotation rotation = r;
		int w = logical_width(rotation), h = logical_height(rotation);
		unsigned int stride = (w / 2 + 3) & ~3u;
		size_t size = 8 + (stride + (w + 7) / 8) * (size_t)h;
		memset(bitmap, 0, sizeof(bitmap));
		unsigned int fields[] = {(unsigned int)w, (unsigned int)h, 0x8004, stride};
		for (unsigned int i = 0; i < 4; i++) {
			bitmap[2*i] = fields[i] & 255;
			bitmap[2*i+1] = fields[i] >> 8;
		}
		memset(seen, 0, sizeof(seen));
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++) {
				size_t i = panel_index(rotation, x, y);
				assert(i < PIXELS && !seen[i]);
				seen[i] = 1;
			}
		assert(sleep_bitmap_valid(bitmap, size, rotation));
		assert(!sleep_bitmap_valid(bitmap, size - 1, rotation));
		memset(input, 0xff, sizeof(input));
		sleep_compose(input, output, bitmap, size, rotation);
		for (size_t i = 0; i < PIXELS; i++) assert(output[i] == WHITE);
		memset(input, 0, sizeof(input));
		sleep_compose(input, output, bitmap, size, rotation);
		/* Independent OpenCV reference on a black frame after DimArea:
		 * white checkerboard sites: 240*(86*86+4*85*85)/65536
		 * -> 133 -> level 8; other sites -> 107 -> level 6.
		 * Reflect-101 preserves parity, including at the panel edges. */
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
				assert(output[panel_index(rotation, x, y)] ==
				       (((x + y) & 1) ? 6 : 8));
		bitmap[8] = 0x2d;
		bitmap[8 + stride * h] = 0xc0;
		sleep_compose(input, output, bitmap, size, rotation);
		assert(output[panel_index(rotation, 0, 0)] == 2);
		assert(output[panel_index(rotation, 1, 0)] == 13);
		assert(output[panel_index(rotation, 2, 0)] == 8);
		assert(output[panel_index(rotation, 3, 0)] == 6);
		sleep_compose(input, output, bitmap, size - 1, rotation);
		assert(output[panel_index(rotation, 0, 0)] == 8);
	}
	assert(panel_index(PB_ROT_90, 0, 0) == WIDTH - 1);
	assert(panel_index(PB_ROT_270, 0, 0) == (HEIGHT - 1) * WIDTH);
	puts("Stock sleep filter, overlay mask and all four rotations passed");
}

static void test_optional_halo_filters(void)
{
	static uint8_t panel[PACKED_PIXELS];
	memset(panel, 0xff, sizeof(panel));
	assert(!halo_allowed(panel, 7, 11, HALO_HQ, 0));
	assert(halo_allowed(panel, 0, 11, HALO_HQ, 0));
	nibble_set(panel, 11 * WIDTH + 6, 0);
	assert(halo_allowed(panel, 7, 11, HALO_HQ, 0));
	assert(halo_allowed(panel, 6, 11, HALO_HQ, 0));
	assert(halo_allowed(panel, 6, 11, HALO_SHADOW, 0));
	nibble_set(panel, 11 * WIDTH + 6, WHITE);
	for (int y = 0; y < HEIGHT; y++)
		for (int x = 0; x < WIDTH; x++) {
			unsigned int total = 0;
			for (unsigned int stage = 0; stage < 4; stage++)
				total += halo_allowed(panel, x, y, HALO_SHADOW, stage);
			assert(total == 1);
		}
	/* Mandatory cleanup remains eligible in both modes, regardless of
	 * surrounding white and phase. */
	const int x = 15, y = 17;
	nibble_set(fast_changes, y * WIDTH + x, CLEAN_AFTER);
	for (unsigned int stage = 0; stage < 4; stage++) {
		shadow_stage = stage;
		cleanup_filter = HALO_SHADOW;
		assert(needs_scrub(panel, x, y));
	}
	cleanup_filter = HALO_HQ;
	assert(needs_scrub(panel, x, y));
	assert(!needs_scrub(panel, x + 1, y));
	cleanup_filter = HALO_NONE;
	assert(needs_scrub(panel, x + 1, y));
	nibble_set(fast_changes, y * WIDTH + x, 0);
	shadow_stage = 0;
}

static void test_combined_cleanup(void)
{
	static uint8_t desired[PACKED_PIXELS], panel[PACKED_PIXELS];
	static struct shared_frame frame;
	const size_t ghost = WIDTH + 1, changed = 3 * TILE + 1;
	memset(desired, 0xff, sizeof(desired));
	memset(panel, 0xff, sizeof(panel));
	memset(fast_changes, 0, sizeof(fast_changes));
	memset(cleanup_pixels, 0, sizeof(cleanup_pixels));
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
	nibble_set(fast_changes, ghost, CLEAN_AFTER);
	cleanup_pixels[0][0] = 1;
	nibble_set(fast_changes, changed, 2);
	nibble_set(desired, changed, 7);
	dirty_tiles[0][3] = 1;
	int old_halo = clean_halo;
	clean_halo = 0;
	assert(automatic_command(CLEAN_QUIET_US - 1, 0, 0, 1, 1) == SETTLE);
	assert(automatic_command(CLEAN_QUIET_US, 1, 0, 1, 1) == 0);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 1, 1) == SETTLE_CLEAN);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 1, LARGE_CLEAN_PIXELS) == SETTLE);
	assert(automatic_command(LARGE_CLEAN_QUIET_US, 0, 0, 1, LARGE_CLEAN_PIXELS) == SETTLE_CLEAN);
	assert(prepare(SETTLE_CLEAN, desired, panel, &frame) == 2);
	assert(frame.tiles[0][0] && frame.tiles[0][3]);
	assert(frame.pixels[ghost] == (WHITE | SCRUB));
	assert(frame.pixels[changed] == (7 | SCRUB));
	assert(frame.pixels[changed + 1] == KEEP);
	acknowledge(SETTLE_CLEAN, &frame, desired, panel);
	assert(!cleanup_pixels[0][0] && !nibble_get(fast_changes, ghost));
	assert(!nibble_get(fast_changes, changed) && nibble_get(panel, changed) == 7);
	assert(!dirty_tiles_pending());
	clean_halo = old_halo;
}

static void test_settle_cleanup_budget(void)
{
	static uint8_t desired[PACKED_PIXELS], panel[PACKED_PIXELS];
	static struct shared_frame frame;
	const size_t pixel = WIDTH + 1;
	memset(desired, 0xff, sizeof(desired));
	memset(panel, 0xff, sizeof(panel));
	memset(fast_changes, 0, sizeof(fast_changes));
	memset(cleanup_pixels, 0, sizeof(cleanup_pixels));
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
	for (int i = 0; i < CLEAN_AFTER + 2; i++) {
		nibble_set(desired, pixel, i & 1 ? 6 : 9);
		dirty_tiles[0][0] = 1;
		assert(prepare(SETTLE, desired, panel, &frame) == 1);
		/* Preparation alone must not consume the budget. */
		assert(nibble_get(fast_changes, pixel) == (i < CLEAN_AFTER ? i : CLEAN_AFTER));
		acknowledge(SETTLE, &frame, desired, panel);
	}
	assert(nibble_get(fast_changes, pixel) == CLEAN_AFTER && cleanup_pixels[0][0] == 1);
	int old_halo = clean_halo;
	clean_halo = 0;
	assert(prepare(CLEAN, desired, panel, &frame) == 1);
	assert(frame.pixels[pixel] == (nibble_get(panel, pixel) | SCRUB));
	acknowledge(CLEAN, &frame, desired, panel);
	assert(!nibble_get(fast_changes, pixel) && !cleanup_pixels[0][0]);
	clean_halo = old_halo;
}

static void test_exact_preview_policy(void)
{
	static uint8_t desired[PACKED_PIXELS], panel[PACKED_PIXELS];
	static struct shared_frame frame;
	const enum fast_profile profiles[] = { FAST_DU, FAST_A2, FAST_DU4, FAST_AUTO };
	const size_t pixel = WIDTH + 1;
	for (unsigned int m = 0; m < sizeof(profiles)/sizeof(profiles[0]); m++)
		for (unsigned int old = 0; old <= WHITE; old++)
			for (unsigned int target = 0; target <= WHITE; target++) {
				memset(desired, 0xff, sizeof(desired));
				memset(panel, 0xff, sizeof(panel));
				memset(dirty_tiles, 0, sizeof(dirty_tiles));
				nibble_set(desired, pixel, target);
				nibble_set(panel, pixel, old);
				dirty_tiles[0][0] = 1;
				uint8_t command = PREVIEW;
				unsigned int count = prepare_update(&command, desired, panel, &frame, 0, profiles[m]);
				assert(count == (old != target));
				if (count) {
					assert(frame.pixels[pixel] == target);
					assert(frame.tiles[0][0]);
				}
				if (count) {
					uint8_t expected = SETTLE;
					if (profiles[m] == FAST_DU4)
						expected = target % 5 ? SETTLE : PREVIEW_DU4;
					else if (target == 0 || target == WHITE)
						expected = (profiles[m] == FAST_A2 || profiles[m] == FAST_AUTO) &&
							(old == 0 || old == WHITE) ? PREVIEW_A2 : PREVIEW;
					else if (profiles[m] == FAST_AUTO && target % 5 == 0)
						expected = PREVIEW_DU4;
					assert(command == expected);
				}
			}
	/* A mixed tile must not leak a partially prepared fast frame. */
	memset(desired, 0xff, sizeof(desired));
	memset(panel, 0xff, sizeof(panel));
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
	nibble_set(desired, pixel, 0);
	nibble_set(desired, pixel + 1, 6);
	dirty_tiles[0][0] = 1;
	uint8_t command = PREVIEW;
	assert(prepare_update(&command, desired, panel, &frame, 0, FAST_AUTO) == 2);
	assert(command == SETTLE && frame.pixels[pixel] == 0 && frame.pixels[pixel + 1] == 6);
	command = PREVIEW;
	assert(prepare_update(&command, desired, panel, &frame, 1, FAST_DU) == 2);
	assert(command == PREVIEW && frame.pixels[pixel + 1] == 0);
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
}

int main(void)
{
	if (getenv("PB626_BENCH_RGB565")) {
		bench_rgb565_candidate();
		return 0;
	}
	if (getenv("PB626_TEST_X11")) {
		test_x11_capture();
		return 0;
	}
	test_power_press();
	test_worker_deadlines();
	test_packed_rgb565();
	test_rgb565_candidate();
	test_gray_rows();
	test_ddx_layout();
	test_capture_coordinates();
	assert(damage_capture_due(0, 1000) == 1000 + CAPTURE_COALESCE_US);
	assert(damage_capture_due(100000, 1000) == 100000);
	assert(may_retry_capture(1, 0, 0, 0));
	assert(!may_retry_capture(0, 0, 0, 0));
	assert(!may_retry_capture(1, 1, 0, 0));
	assert(!may_retry_capture(1, 0, 1, 0));
	assert(!may_retry_capture(1, 0, 0, 1));
	test_gray();
	test_contrast_row();
	test_stock_sleep();
	test_optional_halo_filters();
	test_exact_preview_policy();
	test_settle_cleanup_budget();
	test_combined_cleanup();
	assert(binding_index(KEY_LEFT) == 0 && binding_index(KEY_RIGHT) == 1);
	assert(binding_index(KEY_HOME) == 2 && binding_index(KEY_MENU) == 3);
	assert(binding_index(KEY_POWER) == -1);
	assert(valid_button_action("Page_Up") && valid_button_action("light-toggle"));
	assert(!valid_button_action("sh -c anything") && !valid_button_action("F13"));
	struct controls buttons = {0};
	assert(binding_deadline(&buttons) == UINT64_MAX);
	buttons.bindings[0].pending = 1;
	buttons.bindings[0].deadline = 1234;
	assert(binding_deadline(&buttons) == 1234);
	buttons.bindings[0].down = 1;
	assert(binding_deadline(&buttons) == UINT64_MAX);
	static struct shared_frame frame;
	static uint8_t desired[PACKED_PIXELS], panel[PACKED_PIXELS];
	const size_t pixel = 100 * WIDTH + 50;
	const int tx = 50 / TILE, ty = 100 / TILE;
	memset(desired, 0xff, sizeof(desired));
	memset(panel, 0xff, sizeof(panel));
	nibble_set(desired, pixel, 6);
	dirty_tiles[ty][tx] = 1;

	assert(prepare(PREVIEW, desired, panel, &frame) == 1);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	assert(frame.pixels[pixel] == 0 && frame.pixels[pixel + 1] == KEEP);
	assert(nibble_get(panel, pixel) == WHITE);
	acknowledge(PREVIEW, &frame, desired, panel);
	assert(nibble_get(panel, pixel) == 0 && dirty_tiles[ty][tx]);
	assert(dirty_tiles_pending());
	assert(prepare(PREVIEW, desired, panel, &frame) == 0);
	assert(dirty_tiles[ty][tx]);
	assert(prepare(SETTLE, desired, panel, &frame) == 1);
	acknowledge(SETTLE, &frame, desired, panel);
	assert(nibble_get(panel, pixel) == 6 && !dirty_tiles[ty][tx]);
	assert(!dirty_tiles_pending());

	for (int i = 0; i < CLEAN_AFTER + 2; i++) {
		nibble_set(desired, pixel, nibble_get(desired, pixel) ? 0 : WHITE);
		dirty_tiles[ty][tx] = 1;
		assert(prepare(PREVIEW, desired, panel, &frame) == 1);
		acknowledge(PREVIEW, &frame, desired, panel);
	}
	assert(nibble_get(fast_changes, pixel) == CLEAN_AFTER && cleanup_pixels[ty][tx] == 1);
	assert(automatic_command(100000, 0, 1, 1, 1) == PREVIEW);
	assert(bound_preview(PREVIEW, MAX_PENDING_US - 1) == PREVIEW);
	assert(bound_preview(PREVIEW, MAX_PENDING_US) == SETTLE);
	assert(bound_preview(PREVIEW_DU4, MAX_PENDING_US) == SETTLE);
	assert(bound_preview(CLEAN, MAX_PENDING_US) == CLEAN);
	assert(bound_preview(0, MAX_PENDING_US) == 0);
	assert(automatic_command(200000, 0, 0, 1, 1) == 0);
	assert(automatic_command(QUIET_US, 0, 0, 1, 1) == SETTLE);
	assert(automatic_command(CLEAN_QUIET_US - 1, 0, 0, 0, 1) == 0);
	assert(automatic_command(CLEAN_QUIET_US, 1, 0, 0, 1) == 0);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 0, 1) == CLEAN);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 0, LARGE_CLEAN_PIXELS - 1) == CLEAN);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 0, LARGE_CLEAN_PIXELS) == 0);
	assert(automatic_command(LARGE_CLEAN_QUIET_US, 0, 0, 0, LARGE_CLEAN_PIXELS) == CLEAN);
	clean_halo = 0;
	assert(prepare(CLEAN, desired, panel, &frame) == 1);
	assert(frame.pixels[pixel] == (nibble_get(panel, pixel) | SCRUB));
	assert(frame.pixels[pixel + 1] == KEEP);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(nibble_get(fast_changes, pixel) == 0 && cleanup_pixels[ty][tx] == 0 && !dirty_tiles[ty][tx]);

	clean_halo = 1;
	const size_t edge = (TILE - 1) * WIDTH + TILE - 1;
	nibble_set(fast_changes, edge, CLEAN_AFTER);
	cleanup_pixels[0][0] = 1;
	nibble_set(fast_changes, edge + WIDTH, 2);
	nibble_set(desired, edge + 1, 0); nibble_set(panel, edge + 1, 0);
	assert(prepare(CLEAN, desired, panel, &frame) == 8);
	assert(frame.pixels[edge + 1] == KEEP);
	assert(frame.pixels[edge + WIDTH + 1] == (WHITE | SCRUB) && frame.tiles[1][1]);
	assert(frame.pixels[edge + WIDTH + 2] == KEEP && !frame.tiles[0][2]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(!cleanup_pixels[0][0] && !cleanup_pixels[1][0]);
	assert(!nibble_get(fast_changes, edge) && !nibble_get(fast_changes, edge + WIDTH));

	dirty_tiles[ty][tx] = 1; /* Damage that reverted before the next capture. */
	assert(prepare(SETTLE, desired, panel, &frame) == 0 && !dirty_tiles[ty][tx]);
    /* Fast-mode semantics: no fake gray->A2 conversion, exact DU4 levels. */
    static struct shared_frame ff;
    static uint8_t fd[PACKED_PIXELS], fp[PACKED_PIXELS];
    memset(fd, 0xff, sizeof(fd));
    memset(fp, 0xff, sizeof(fp));
    memset(dirty_tiles, 0, sizeof(dirty_tiles));
    const size_t p = 3 * WIDTH + 4;
    nibble_set(fd, p, 0); dirty_tiles[0][0] = 1;
    assert(prepare(PREVIEW, fd, fp, &ff) == 1);
    assert(a2_eligible(&ff, fp));
    nibble_set(fp, p, 7);
    assert(!a2_eligible(&ff, fp));
    nibble_set(fp, p, 0); nibble_set(fd, p, WHITE);
    assert(prepare(PREVIEW, fd, fp, &ff) == 1);
    assert(a2_eligible(&ff, fp));
    nibble_set(fp, p, WHITE); nibble_set(fd, p, 9);
    /* A dirty tile also contains unchanged gray. Never quantize it. */
    nibble_set(fp, p + 1, 7); nibble_set(fd, p + 1, 7);
    assert(!exact_du4_candidate(fd, fp));
    nibble_set(fd, p, 10);
    assert(exact_du4_candidate(fd, fp));
    nibble_set(fd, p, 0);
    assert(!exact_du4_candidate(fd, fp)); /* binary-only uses DU/A2 */
    nibble_set(fd, p, 9);
    assert(prepare(PREVIEW_DU4, fd, fp, &ff) == 1);
    assert(ff.pixels[p + 1] == KEEP);
    assert(ff.pixels[p] == 10 && !a2_eligible(&ff, fp));
    acknowledge(PREVIEW_DU4, &ff, fd, fp);
    assert(nibble_get(fp, p) == 10 && nibble_get(fast_changes, p) == 1);
	for (unsigned int i = 0; i <= WHITE; i++) {
		assert(preview_level4(i) <= WHITE && preview_level4(i) % 5 == 0);
	}
	puts("E Ink preview, settle, bounded local cleanup and sparse updates passed");
	return 0;
}
