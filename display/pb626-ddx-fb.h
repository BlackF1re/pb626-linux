/* SPDX-License-Identifier: MIT
 * Private, local ABI shared by the PB626 Dummy DDX and capture bridge.
 * Fixed-width native little-endian fields; pixels start at offset 4096.
 * The X server owns all writes. Read metadata/pixels only while holding
 * an X server grab, and keep the mapping read-only in the bridge.
 */
#ifndef PB626_DDX_FB_H
#define PB626_DDX_FB_H
#include <stdint.h>
#define PB626_DDX_FB_MAGIC 0x50424458u
#define PB626_DDX_FB_VERSION 1u
#define PB626_DDX_FB_OFFSET 4096u
#define PB626_DDX_FB_MAX (8u * 1024u * 1024u)
#define PB626_DDX_FB_PATH "/run/pb626-desktop/ddx-framebuffer"
struct pb626_ddx_fb {
    uint32_t magic, version, capacity;
    uint32_t width, height, stride, bpp, depth;
    uint32_t red, green, blue;
};
#endif
