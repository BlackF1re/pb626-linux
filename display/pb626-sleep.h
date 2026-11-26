/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef PB626_SLEEP_H
#define PB626_SLEEP_H
#include "pb626-epd.h"

/* Logical coordinates -> native portrait panel. RandR left = PB_ROT_90. */
enum pb_rotation { PB_ROT_0, PB_ROT_90, PB_ROT_180, PB_ROT_270 };
static inline int logical_width(enum pb_rotation r)
{
	return r == PB_ROT_90 || r == PB_ROT_270 ? HEIGHT : WIDTH;
}
static inline int logical_height(enum pb_rotation r)
{
	return r == PB_ROT_90 || r == PB_ROT_270 ? WIDTH : HEIGHT;
}
static inline size_t panel_index(enum pb_rotation r, int x, int y)
{
	switch (r) {
	case PB_ROT_90: return (size_t)x * WIDTH + WIDTH - 1 - y;
	case PB_ROT_180: return (size_t)(HEIGHT - 1 - y) * WIDTH + WIDTH - 1 - x;
	case PB_ROT_270: return (size_t)(HEIGHT - 1 - x) * WIDTH + y;
	default: return (size_t)y * WIDTH + x;
	}
}
static inline unsigned int sleep_le16(const uint8_t *p)
{
	return (unsigned int)p[0] | (unsigned int)p[1] << 8;
}
static inline int sleep_bitmap_valid(const uint8_t *b, size_t size, enum pb_rotation r)
{
	int w = logical_width(r), h = logical_height(r);
	unsigned int stride = (w / 2 + 3) & ~3u;
	return b && size == 8 + (stride + (w + 7) / 8) * (size_t)h &&
	       sleep_le16(b) == (unsigned int)w &&
	       sleep_le16(b + 2) == (unsigned int)h &&
	       sleep_le16(b + 4) == 0x8004 && sleep_le16(b + 6) == stride;
}
static inline int sleep_reflect(int i, int n)
{
	return i < 0 ? -i : i >= n ? 2 * n - 2 - i : i;
}
/* taskmgr: DimArea(WHITE), nibble swap, GaussianBlur(3x3, sigma=5,
 * reflect-101), swap back, truncate to 4bpp. Fixed-point [85,86,85]/256
 * matches the OpenCV 4.x reference; 2.4.13 rounding is unqualified.
 * Keep src immutable and packed; write directly to the worker's IPC
 * frame. The original bitmap has a separate MSB-first opaque mask. */
static inline void sleep_compose(const uint8_t *src, uint8_t *dst,
				 const uint8_t *bitmap, size_t size, enum pb_rotation r)
{
	const int w = logical_width(r), h = logical_height(r);
	const unsigned int stride = (w / 2 + 3) & ~3u, mask_stride = (w + 7) / 8;
	const uint8_t *pixels = NULL, *mask = NULL;
	if (sleep_bitmap_valid(bitmap, size, r)) {
		pixels = bitmap + 8;
		mask = pixels + stride * h;
	}
	static const unsigned int k[] = {85, 86, 85};
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			size_t i = panel_index(r, x, y);
			if (mask && (mask[y * mask_stride + x / 8] & (0x80u >> (x & 7)))) {
				dst[i] = (pixels[y * stride + x / 2] >> ((x & 1) ? 0 : 4)) & WHITE;
				continue;
			}
			unsigned int sum = 0;
			for (int dy = -1; dy <= 1; dy++) {
				int sy = sleep_reflect(y + dy, h);
				for (int dx = -1; dx <= 1; dx++) {
					int sx = sleep_reflect((x ^ 1) + dx, w) ^ 1;
					unsigned int v = ((sx + sy) & 1) ?
						nibble_get(src, panel_index(r, sx, sy)) : WHITE;
					sum += (v << 4) * k[dx + 1] * k[dy + 1];
				}
			}
			dst[i] = (uint8_t)(((sum + 32768) >> 16) >> 4);
		}
}
#endif
