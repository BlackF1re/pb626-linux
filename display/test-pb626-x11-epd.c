/* SPDX-License-Identifier: GPL-2.0-or-later */
#define main pb626_x11_epd_main
#include "pb626-x11-epd.c"
#undef main

#include <assert.h>

int main(void)
{
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
	assert(automatic_command(QUIET_US, 0, 0, 1, 1) == SETTLE);
	assert(automatic_command(CLEAN_QUIET_US - 1, 0, 0, 0, 1) == 0);
	assert(automatic_command(CLEAN_QUIET_US, 1, 0, 0, 1) == 0);
	assert(automatic_command(CLEAN_QUIET_US, 0, 0, 0, 1) == CLEAN);
	assert(prepare(CLEAN, desired, panel, &frame) == 1);
	assert(frame.pixels[pixel] == (panel[pixel] | SCRUB));
	assert(frame.pixels[pixel + 1] == KEEP);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(fast_changes[pixel] == 0 && cleanup_pixels[ty][tx] == 0 && !dirty_tiles[ty][tx]);

	dirty_tiles[ty][tx] = 1; /* Damage that reverted before the next capture. */
	assert(prepare(SETTLE, desired, panel, &frame) == 0 && !dirty_tiles[ty][tx]);
	puts("E Ink preview, settle, bounded local cleanup and sparse updates passed");
	return 0;
}
