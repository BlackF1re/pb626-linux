/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PB626_EPD_H
#define PB626_EPD_H

#include <stdint.h>
#include <time.h>

enum { WIDTH = 758, HEIGHT = 1024, PIXELS = WIDTH * HEIGHT, WHITE = 15 };
enum { KEEP = 255, SCRUB = 128 };
enum { TILE = 32, TILE_COLS = (WIDTH + TILE - 1) / TILE, TILE_ROWS = (HEIGHT + TILE - 1) / TILE };

struct shared_frame {
	uint8_t tiles[TILE_ROWS][TILE_COLS];
	uint8_t pixels[PIXELS];
};

static inline void tile_bounds(int tx, int ty, int *right, int *bottom)
{
	*right = tx + 1 == TILE_COLS ? WIDTH : (tx + 1) * TILE;
	*bottom = ty + 1 == TILE_ROWS ? HEIGHT : (ty + 1) * TILE;
}
enum command { PREVIEW = 'D', PREVIEW_A2 = 'A', PREVIEW_DU4 = '4',
               SETTLE = 'L', CLEAN = 'G', RESET = 'R' };
/* Stock DU4 targets only 0, 5, 10 and 15. */
static inline uint8_t preview_level4(uint8_t target)
{
    return (uint8_t)(((unsigned int)target + 2) / 5 * 5);
}

static inline uint64_t now_us(void)
{
	struct timespec time;
	clock_gettime(CLOCK_MONOTONIC, &time);
	return (uint64_t)time.tv_sec * 1000000 + time.tv_nsec / 1000;
}

static inline uint8_t paper_level(unsigned int value, unsigned int contrast, int x, int y)
{
	static const uint8_t bayer[4][4] = {
		{ 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 },
	};
	unsigned int scaled = value * WHITE;
	unsigned int threshold = 127;

	/* Round fine edges to the closest level to avoid cutting holes in strokes.
	 * Keep dither fixed to the panel, including across adjacent damage regions.
	 */
	if (contrast < 48)
		threshold = bayer[y & 3][x & 3] * 16 + 8;
	return (scaled + threshold) / 255;
}

static inline uint8_t preview_level(uint8_t target, uint8_t previous)
{
	/* Apply a dead band to fast previews of near-midpoint luminance. */
	unsigned int threshold = previous == 0 ? 9 : previous == WHITE ? 7 : 8;
	return target < threshold ? 0 : WHITE;
}

#endif
