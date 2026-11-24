/* SPDX-License-Identifier: GPL-2.0-or-later */
#define main pb626_x11_epd_main
#include "pb626-x11-epd.c"
#undef main

#include <assert.h>

static int covers(struct rect a, struct rect b)
{
	return a.left <= b.left && a.top <= b.top &&
	       a.right >= b.right && a.bottom >= b.bottom;
}

static void test_damage_merge(void)
{
	struct rect areas[MAX_REGIONS] = {{0}};
	struct rect inputs[MAX_REGIONS + 1];
	int used = 0;
	for (int i = 0; i < MAX_REGIONS + 1; i++) {
		inputs[i] = (struct rect){
			.left = (i < 5 ? i : i - 5) * TILE,
			.top = i < 5 ? 0 : HEIGHT - TILE,
			.right = (i < 5 ? i : i - 5) * TILE + TILE,
			.bottom = i < 5 ? TILE : HEIGHT
		};
		add_damage_rect(areas, &used, inputs[i]);
	}
	assert(used == MAX_REGIONS);
	for (int j = 0; j < MAX_REGIONS + 1; j++) {
		int found = 0;
		for (int i = 0; i < used; i++)
			found |= covers(areas[i], inputs[j]);
		assert(found);
	}
	int sum = 0;
	for (int i = 0; i < used; i++)
		sum += rect_area(areas[i]);
	assert(sum < WIDTH * HEIGHT / 4);
	/* A moving pointer remains a small extra region even when full. */
	struct rect pointer = {WIDTH - TILE, HEIGHT / 2, WIDTH, HEIGHT / 2 + TILE};
	add_damage_rect(areas, &used, pointer);
	assert(used == MAX_REGIONS);
	int found = 0;
	for (int i = 0; i < used; i++)
		found |= covers(areas[i], pointer);
	assert(found);
}

static void test_async_protocol(void)
{
	int sockets[2];
	assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
	struct worker worker = { .socket = sockets[0] };
	uint8_t command;
	assert(submit_async(&worker, PREVIEW) == 0);
	assert(read(sockets[1], &command, 1) == 1 && command == PREVIEW);
	assert(write(sockets[1], &command, 1) == 1);
	assert(complete_async(&worker, PREVIEW) == 0);
	assert(submit_async(&worker, SETTLE) == 0);
	assert(read(sockets[1], &command, 1) == 1 && command == SETTLE);
	command = PREVIEW;
	assert(write(sockets[1], &command, 1) == 1);
	assert(complete_async(&worker, SETTLE) == -1);
	close(sockets[0]);
	close(sockets[1]);
}

static void test_async_state(void)
{
	static struct shared_frame work;
	static uint8_t desired[PIXELS], panel[PIXELS];
	memset(panel, WHITE, sizeof(panel));
	memset(desired, WHITE, sizeof(desired));
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
	const size_t pos = 35 * WIDTH + 35;
	const int tx = 35 / TILE, ty = 35 / TILE;
	desired[pos] = 0;
	assert(prepare(RESET, desired, panel, &work) == PIXELS);
	desired[pos] = WHITE; /* A later XDamage changes the desired screen. */
	acknowledge(RESET, &work, desired, panel);
	assert(panel[pos] == 0 && dirty_tiles[ty][tx] == 1);

	/* Preserve the in-flight preview and notice the newer target on ACK. */
	desired[pos] = WHITE;
	assert(prepare(PREVIEW, desired, panel, &work) == 1);
	desired[pos] = 0;
	acknowledge(PREVIEW, &work, desired, panel);
	assert(panel[pos] == WHITE && dirty_tiles[ty][tx] == 1);
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
	for (int profile = GRAY_BALANCED; profile <= GRAY_LEGACY; profile++) {
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

int main(void)
{
	test_damage_merge();
	test_async_protocol();
	test_async_state();
	test_gray();
	static struct shared_frame frame;
	static uint8_t desired[PIXELS], panel[PIXELS];
	const size_t pixel = 100 * WIDTH + 50;
	const int tx = 50 / TILE, ty = 100 / TILE;
	memset(desired, WHITE, sizeof(desired));
	memset(panel, WHITE, sizeof(panel));
	desired[pixel] = 6;
	dirty_tiles[ty][tx] = 1;

	assert(prepare(PREVIEW, desired, panel, &frame) == 1);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	assert(frame.pixels[pixel] == 0 && frame.pixels[pixel + 1] == KEEP);
	assert(panel[pixel] == WHITE);
	acknowledge(PREVIEW, &frame, desired, panel);
	assert(panel[pixel] == 0 && dirty_tiles[ty][tx]);
	assert(prepare(PREVIEW, desired, panel, &frame) == 0);
	assert(dirty_tiles[ty][tx]);
	assert(prepare(SETTLE, desired, panel, &frame) == 1);
	acknowledge(SETTLE, &frame, desired, panel);
	assert(panel[pixel] == 6 && !dirty_tiles[ty][tx]);

	for (int i = 0; i < CLEAN_AFTER + 2; i++) {
		desired[pixel] = desired[pixel] ? 0 : WHITE;
		dirty_tiles[ty][tx] = 1;
		assert(prepare(PREVIEW, desired, panel, &frame) == 1);
		acknowledge(PREVIEW, &frame, desired, panel);
	}
	assert(fast_changes[pixel] == CLEAN_AFTER && cleanup_pixels[ty][tx] == 1);
	assert(automatic_command(100000, 0, 1, 1, 1) == PREVIEW);
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
	assert(frame.pixels[pixel] == (panel[pixel] | SCRUB));
	assert(frame.pixels[pixel + 1] == KEEP);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(fast_changes[pixel] == 0 && cleanup_pixels[ty][tx] == 0 && !dirty_tiles[ty][tx]);

	clean_halo = 1;
	const size_t edge = (TILE - 1) * WIDTH + TILE - 1;
	fast_changes[edge] = CLEAN_AFTER;
	cleanup_pixels[0][0] = 1;
	fast_changes[edge + WIDTH] = 2;
	desired[edge + 1] = panel[edge + 1] = 0;
	assert(prepare(CLEAN, desired, panel, &frame) == 8);
	assert(frame.pixels[edge + 1] == KEEP);
	assert(frame.pixels[edge + WIDTH + 1] == (WHITE | SCRUB) && frame.tiles[1][1]);
	assert(frame.pixels[edge + WIDTH + 2] == KEEP && !frame.tiles[0][2]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(!cleanup_pixels[0][0] && !cleanup_pixels[1][0]);
	assert(!fast_changes[edge] && !fast_changes[edge + WIDTH]);

	dirty_tiles[ty][tx] = 1; /* Damage that reverted before the next capture. */
	assert(prepare(SETTLE, desired, panel, &frame) == 0 && !dirty_tiles[ty][tx]);
    /* Fast-mode semantics: no fake gray->A2 conversion, exact DU4 levels. */
    static struct shared_frame ff;
    static uint8_t fd[PIXELS], fp[PIXELS];
    memset(fd, WHITE, PIXELS);
    memset(fp, WHITE, PIXELS);
    memset(dirty_tiles, 0, sizeof(dirty_tiles));
    const size_t p = 3 * WIDTH + 4;
    fd[p] = 0; dirty_tiles[0][0] = 1;
    assert(prepare(PREVIEW, fd, fp, &ff) == 1);
    assert(a2_eligible(&ff, fp));
    fp[p] = 7;
    assert(!a2_eligible(&ff, fp));
    fp[p] = 0; fd[p] = WHITE;
    assert(prepare(PREVIEW, fd, fp, &ff) == 1);
    assert(a2_eligible(&ff, fp));
    fp[p] = WHITE; fd[p] = 9;
    assert(prepare(PREVIEW_DU4, fd, fp, &ff) == 1);
    assert(ff.pixels[p] == 10 && !a2_eligible(&ff, fp));
    acknowledge(PREVIEW_DU4, &ff, fd, fp);
    assert(fp[p] == 10 && fast_changes[p] == 1);
	for (unsigned int i = 0; i <= WHITE; i++) {
		assert(preview_level4(i) <= WHITE && preview_level4(i) % 5 == 0);
	}
	puts("E Ink preview, settle, bounded local cleanup and sparse updates passed");
	return 0;
}
