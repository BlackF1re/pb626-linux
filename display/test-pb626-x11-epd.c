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

	for (int i = 0; i < GHOST_LIMIT; i++) {
		desired[pixel] = desired[pixel] ? 0 : WHITE;
		dirty_tiles[ty][tx] = 1;
		assert(prepare(PREVIEW, desired, panel, &frame) == 1);
		acknowledge(PREVIEW, &frame, desired, panel);
	}
	assert(history[ty][tx].stress >= GHOST_LIMIT);
	assert(prepare(CLEAN, desired, panel, &frame) == TILE * TILE);
	assert(frame.pixels[pixel] & SCRUB);
	assert(frame.tiles[ty][tx] && !frame.tiles[0][0]);
	acknowledge(CLEAN, &frame, desired, panel);
	assert(history[ty][tx].stress == 0 && !dirty_tiles[ty][tx]);

	dirty_tiles[ty][tx] = 1; /* Damage that reverted before the next capture. */
	assert(prepare(SETTLE, desired, panel, &frame) == 0 && !dirty_tiles[ty][tx]);
	puts("E Ink preview, settle, bounded local cleanup and sparse updates passed");
	return 0;
}
