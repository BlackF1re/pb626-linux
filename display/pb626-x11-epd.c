/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/XTest.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/file.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "pb626-epd.h"

enum { MENU_HOLD_US = 1000000, LAYOUT_QUIET_US = 180000, QUIET_US = 300000,
       MAX_PENDING_US = 850000,
       CLEAN_QUIET_US = 1200000, LARGE_CLEAN_QUIET_US = 5000000,
       LARGE_CLEAN_PIXELS = PIXELS / 16, CLEAN_AFTER = 8, MAX_REGIONS = 8 };
enum { KEYBOARD_SHOW = 1, KEYBOARD_HIDE, KEYBOARD_TOGGLE };

struct controls {
	int fallback, vertical, pointer_visible, clean_requested, keyboard_changed;
	uint64_t menu_pressed;
};

static void keyboard_command(Display *display, Window root, Atom command, long operation)
{
	XEvent event = { .xclient = {
		.type = ClientMessage, .window = root, .message_type = command,
		.format = 32, .data.l = { operation },
	} };
	XSendEvent(display, root, False, SubstructureNotifyMask, &event);
}

static void keyboard_focus(Display *display, Window root, Atom active, Atom command,
			   Window *previous, struct controls *controls)
{
	Atom type;
	int format;
	unsigned long count, after;
	unsigned char *value = NULL;
	if (XGetWindowProperty(display, root, active, 0, 1, False, XA_WINDOW,
			       &type, &format, &count, &after, &value) != Success)
		return;
	Window window = count && type == XA_WINDOW ? *(Window *)value : None;
	if (value)
		XFree(value);
	if (window == *previous)
		return;
	*previous = window;

	XClassHint hint = { 0 };
	if (window != None)
		XGetClassHint(display, window, &hint);
	const char *class = hint.res_class ? hint.res_class : "";
	int typing = !strcasecmp(class, "XTerm") || !strcasecmp(class, "NEdit");
	if (hint.res_name && !strcmp(hint.res_name, "pb626-monitor"))
		typing = 0;
	keyboard_command(display, root, command, typing ? KEYBOARD_SHOW : KEYBOARD_HIDE);
	controls->keyboard_changed = 1;
	if (hint.res_name)
		XFree(hint.res_name);
	if (hint.res_class)
		XFree(hint.res_class);
}

static int handle_x_error(Display *display, XErrorEvent *event)
{
	if (event->error_code != BadWindow) {
		char message[128];
		XGetErrorText(display, event->error_code, message, sizeof(message));
		fprintf(stderr, "pb626-x11-epd: %s\n", message);
	}
	return 0;
}

static int handle_buttons(Display *display, Window root, Atom keyboard, int fd,
			  struct controls *controls)
{
	int changed = 0;
	struct input_event event;
	while (read(fd, &event, sizeof(event)) == (ssize_t)sizeof(event)) {
		if (event.type != EV_KEY)
			continue;
		if (event.code == KEY_MENU) {
			uint64_t now = (uint64_t)event.input_event_sec * 1000000 +
				       event.input_event_usec;
			if (event.value == 1) {
				controls->menu_pressed = now;
			} else if (event.value == 0 && controls->menu_pressed) {
				if (now >= controls->menu_pressed + MENU_HOLD_US) {
					controls->clean_requested = 1;
					changed = 1;
				} else if (controls->fallback && controls->pointer_visible) {
					XTestFakeButtonEvent(display, 1, True, CurrentTime);
					XTestFakeButtonEvent(display, 1, False, CurrentTime);
				} else {
					KeyCode menu = XKeysymToKeycode(display, XK_Menu);
					if (menu) {
						XTestFakeKeyEvent(display, menu, True, CurrentTime);
						XTestFakeKeyEvent(display, menu, False, CurrentTime);
					}
				}
				controls->menu_pressed = 0;
			}
			continue;
		}
		switch (event.code) {
		case KEY_HOME:
			if (event.value == 1) {
				if (controls->fallback)
					controls->vertical = !controls->vertical;
				else {
					keyboard_command(display, root, keyboard, KEYBOARD_TOGGLE);
					controls->keyboard_changed = 1;
				}
				changed |= controls->pointer_visible;
			}
			break;
		case KEY_LEFT:
		case KEY_RIGHT: {
			if (!event.value)
				break;
			if (!controls->fallback) {
				KeyCode arrow = XKeysymToKeycode(display,
					event.code == KEY_LEFT ? XK_Left : XK_Right);
				if (arrow) {
					XTestFakeKeyEvent(display, arrow, True, CurrentTime);
					XTestFakeKeyEvent(display, arrow, False, CurrentTime);
				}
				break;
			}
			int step = event.value == 1 ? 12 : 28;
			if (event.code == KEY_LEFT)
				step = -step;
			XTestFakeRelativeMotionEvent(display, controls->vertical ? 0 : step,
						     controls->vertical ? step : 0, CurrentTime);
			controls->pointer_visible = 1;
			changed = 1;
			break;
		}
		}
	}
	return changed;
}

struct rect {
	int left, top, right, bottom;
};

static struct rect clipped(struct rect r, int halo)
{
	r.left = r.left > halo ? r.left - halo : 0;
	r.top = r.top > halo ? r.top - halo : 0;
	r.right = r.right < WIDTH - halo ? r.right + halo : WIDTH;
	r.bottom = r.bottom < HEIGHT - halo ? r.bottom + halo : HEIGHT;
	return r;
}

static int nonempty(struct rect r)
{
	return r.left < r.right && r.top < r.bottom;
}

static struct rect united(struct rect a, struct rect b)
{
	if (!nonempty(a))
		return b;
	if (!nonempty(b))
		return a;
	return (struct rect) {
		a.left < b.left ? a.left : b.left, a.top < b.top ? a.top : b.top,
		a.right > b.right ? a.right : b.right, a.bottom > b.bottom ? a.bottom : b.bottom,
	};
}

static struct rect pointer_rect(Display *display, Window root, int offset)
{
	Window root_return, child;
	int x, y, window_x, window_y;
	unsigned int modifiers;
	if (!XQueryPointer(display, root, &root_return, &child,
			  &x, &y, &window_x, &window_y, &modifiers))
		return (struct rect){0};
	x -= offset;
	return (struct rect){ x - 5, y - 5, x + 6, y + 6 };
}

static uint8_t pointer_level(struct rect pointer, int vertical, int x, int y, uint8_t level)
{
	if (x < pointer.left || x >= pointer.right || y < pointer.top || y >= pointer.bottom)
		return level;
	int dx = x - pointer.left - 5, dy = y - pointer.top - 5;
	if ((vertical && abs(dx) <= 2) || (!vertical && abs(dy) <= 2))
		return abs(dx) <= 1 && abs(dy) <= 1 ? WHITE : 0;
	return level;
}

static unsigned int channel(unsigned long pixel, unsigned long mask)
{
	unsigned int shift = 0;
	if (!mask)
		return 0;
	while (!((mask >> shift) & 1))
		shift++;
	return ((pixel & mask) >> shift) * 255 / (mask >> shift);
}

enum gray_profile { GRAY_BALANCED, GRAY_UI, GRAY_PHOTO, GRAY_LEGACY };
enum { LUMA_STEPS = 4096 };
static enum gray_profile gray_profile;
static uint16_t linear_r[256], linear_g[256], linear_b[256];
static uint8_t gray_tone[256], luma_tone[LUMA_STEPS];
static uint8_t dirty_tiles[TILE_ROWS][TILE_COLS];

static double srgb_decode(double v)
{
	return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

static double gray_encode(double y, int lightness)
{
	if (lightness)
		return y <= 216.0 / 24389 ? y * (24389.0 / 2700) : (116 * cbrt(y) - 16) / 100;
	return y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055;
}

static void setup_gray(enum gray_profile selected, int lightness, double gamma)
{
	gray_profile = selected;
	if (selected == GRAY_LEGACY)
		return;
	for (int i = 0; i < 256; i++) {
		double v = i / 255.0, y = srgb_decode(v);
		double scaled = y * ((LUMA_STEPS - 1) * 16);
		linear_r[i] = scaled * 0.2126 + 0.5;
		linear_g[i] = scaled * 0.7152 + 0.5;
		linear_b[i] = scaled * 0.0722 + 0.5;
		gray_tone[i] = 255 * pow(lightness ? gray_encode(y, 1) : v, 1 / gamma) + 0.5;
	}
	for (int i = 0; i < LUMA_STEPS; i++)
		luma_tone[i] = 255 * pow(gray_encode(i / (LUMA_STEPS - 1.0), lightness),
					       1 / gamma) + 0.5;
}

static inline uint8_t gray_value(unsigned int r, unsigned int g, unsigned int b)
{
	if (gray_profile == GRAY_LEGACY) {
		unsigned int low = r < g ? r : g;
		if (b < low)
			low = b;
		return (57 * r + 112 * g + 23 * b + 64 * low) >> 8;
	}
	if (r == g && g == b)
		return gray_tone[r];
	return luma_tone[(linear_r[r] + linear_g[g] + linear_b[b] + 8) >> 4];
}

/* A toroidal void-and-cluster rank mask (Gaussian sigma 1.5). Keep the
 * phase fixed in panel coordinates so separate XDamage grabs agree.
 */
static const uint8_t blue_noise[16][16] = {
	{ 172,  74, 194,  93, 171, 238, 185,  95, 249, 117, 203, 243,  33, 218,  84,  21 },
	{ 130,   9, 225,  53, 131,  72,  22, 139,  44, 157,  61,  91, 168, 190,  48, 253 },
	{  96, 184, 114, 153,   1, 212, 161, 231,  85,  10, 226, 135,   0, 107, 146, 202 },
	{ 228,  42,  69, 244, 187, 104,  40, 120, 192, 174, 113, 197,  43, 235,  65,  25 },
	{  82, 165, 206,  26, 143,  78, 254,  62, 217,  32,  58, 250,  87, 179, 122, 150 },
	{ 241,   7, 123,  98,  50, 199, 167,  13, 148,  81, 133,  20, 154, 211,  17, 195 },
	{  57, 138, 221, 182, 233,  24, 126, 227, 103, 205, 169, 223,  64, 100,  41, 109 },
	{ 159,  90,  34,  70, 115, 152,  86,  56, 186,   3, 119,  37, 145, 245, 173, 219 },
	{  14, 252, 170, 201,   5, 242, 178,  31, 248,  73, 234, 181,  80,   8, 128,  75 },
	{ 209, 121,  52, 142, 102,  60, 210, 136, 112, 155,  47,  97, 196, 230,  54, 188 },
	{  38,  94, 229,  27, 220, 164,  15,  92, 200,  19, 214, 125,  30, 156, 101, 144 },
	{ 183,  67, 158, 193,  77, 127,  46, 232,  63, 175, 141, 255,  66, 215,  23, 246 },
	{   2, 239, 132,  11, 105, 251, 189, 149, 108,  39,  83,   6, 111, 177,  79, 118 },
	{ 166,  89,  49, 213, 176,  35,  88,   4, 216, 240, 191, 160, 208,  45, 137, 224 },
	{  36, 204, 116, 151,  68, 222, 134, 163,  76, 129,  55,  99, 237,  12, 198,  59 },
	{ 236, 140,  29, 247,  16, 110,  51, 207,  28, 180,  18, 147,  71, 124, 162, 106 },
};

static inline uint8_t quantize_reference(unsigned int value, unsigned int contrast, int x, int y)
{
	if (gray_profile == GRAY_UI)
		return (value * WHITE + 127) / 255;
	if (gray_profile == GRAY_PHOTO && contrast < 48) {
		unsigned int threshold = blue_noise[y & 15][x & 15];
		/* Use the 256 rank midpoints; even rank 255 is below one full step. */
		return (value * WHITE * 256 + threshold * 255 + 127) / (255 * 256);
	}
	return paper_level(value, contrast, x, y);
}

/* Cache the exact reference mapping in screen phase order. Each position
 * needs one byte lookup, and strong edges retain the nearest gray level.
 */
static uint8_t quant_table[16][16][256], nearest_level[256];
static int quant_reference;

static void setup_quantization(void)
{
	quant_reference = getenv("PB626_EPD_QUANT_REFERENCE") != NULL;
	if (quant_reference)
		return;
	int period = gray_profile == GRAY_PHOTO ? 16 : 4;
	for (int v = 0; v < 256; v++) {
		nearest_level[v] = quantize_reference(v, 48, 0, 0);
		if (gray_profile != GRAY_UI)
			for (int y = 0; y < period; y++)
				for (int x = 0; x < period; x++)
					quant_table[y][x][v] = quantize_reference(v, 0, x, y);
	}
}

static inline uint8_t quantize(unsigned int value, unsigned int contrast, int x, int y)
{
	if (quant_reference)
		return quantize_reference(value, contrast, x, y);
	if (contrast >= 48 || gray_profile == GRAY_UI)
		return nearest_level[value];
	unsigned int mask = gray_profile == GRAY_PHOTO ? 15 : 3;
	return quant_table[y & mask][x & mask][value];
}

static int shm_attach_error;

static int mark_shm_error(Display *display, XErrorEvent *event)
{
	(void)display;
	(void)event;
	shm_attach_error = 1;
	return 0;
}

static void setup_shm(Display *display, XShmSegmentInfo *shm)
{
	if (!XShmQueryExtension(display))
		return;
	int screen = DefaultScreen(display);
	XImage *image = XShmCreateImage(display, DefaultVisual(display, screen),
				       DefaultDepth(display, screen), ZPixmap, NULL,
				       shm, WIDTH, HEIGHT);
	if (!image)
		return;
	int id = shmget(IPC_PRIVATE, (size_t)image->bytes_per_line * HEIGHT, IPC_CREAT | 0600);
	XDestroyImage(image);
	if (id < 0)
		return;
	char *address = shmat(id, NULL, 0);
	if (address != (void *)-1) {
		*shm = (XShmSegmentInfo){ .shmid = id, .shmaddr = address };
		XSync(display, False);
		XSetErrorHandler(mark_shm_error);
		Bool attached = XShmAttach(display, shm);
		XSync(display, False);
		XSetErrorHandler(handle_x_error);
		if (!attached || shm_attach_error) {
			shmdt(address);
			shm->shmaddr = NULL;
		}
	}
	/* Keep the segment only for as long as the bridge or Xorg has it mapped. */
	shmctl(id, IPC_RMID, NULL);
}

static XImage *read_image(Display *display, Window root, int x, int y, int width, int height,
			  XShmSegmentInfo *shm)
{
	if (shm->shmaddr) {
		int screen = DefaultScreen(display);
		XImage *image = XShmCreateImage(display, DefaultVisual(display, screen),
					       DefaultDepth(display, screen), ZPixmap,
					       shm->shmaddr, shm, width, height);
		if (image) {
			if (XShmGetImage(display, root, image, x, y, AllPlanes))
				return image;
			XDestroyImage(image);
		}
	}
	return XGetImage(display, root, x, y, width, height, AllPlanes, ZPixmap);
}

struct capture_stats {
	uint64_t read_us, quant_us;
	unsigned int pixels, changed;
};

static int capture(Display *display, Window root, int offset, struct rect dirty,
		   uint8_t *frame, struct rect pointer, int vertical, struct capture_stats *stats,
		   XShmSegmentInfo *shm)
{
	static uint8_t lightness[PIXELS];
	int uses_contrast = gray_profile != GRAY_UI;
	int draw_pointer = nonempty(pointer);
	struct rect area = clipped(dirty, uses_contrast);
	struct rect read_area = clipped(area, uses_contrast);
	uint64_t start = now_us();
	XImage *image = read_image(display, root, read_area.left + offset, read_area.top,
				  read_area.right - read_area.left, read_area.bottom - read_area.top,
				  shm);
	if (!image)
		return -1;
	stats->read_us += now_us() - start;
	start = now_us();
	int rgbx = image->bits_per_pixel == 32 && image->byte_order == LSBFirst &&
		   image->red_mask == 0xff0000 && image->green_mask == 0xff00 &&
		   image->blue_mask == 0xff;
	for (int y = read_area.top; y < read_area.bottom; y++) {
		const uint8_t *row = (const uint8_t *)image->data +
				     (y - read_area.top) * image->bytes_per_line;
		for (int x = read_area.left; x < read_area.right; x++) {
			int column = x - read_area.left;
			unsigned int r, g, b;
			if (rgbx) {
				const uint8_t *color = row + column * 4;
				b = color[0];
				g = color[1];
				r = color[2];
			} else {
				unsigned long pixel = XGetPixel(image, column, y - read_area.top);
				r = channel(pixel, image->red_mask);
				g = channel(pixel, image->green_mask);
				b = channel(pixel, image->blue_mask);
			}
			lightness[y * WIDTH + x] = gray_value(r, g, b);
		}
	}
	XDestroyImage(image);
	for (int y = area.top; y < area.bottom; y++)
		for (int x = area.left; x < area.right; x++) {
			const uint8_t *pixel = lightness + y * WIDTH + x;
			unsigned int value = *pixel;
			uint8_t next = value / 17;
			/* Exact levels are independent of the contrast and dither thresholds. */
			if (value != 17u * next) {
				unsigned int contrast = 0;
				if (uses_contrast) {
					unsigned int lx = x > 0 ? pixel[-1] : value;
					unsigned int rx = x + 1 < WIDTH ? pixel[1] : value;
					unsigned int ty = y > 0 ? pixel[-WIDTH] : value;
					unsigned int by = y + 1 < HEIGHT ? pixel[WIDTH] : value;
					contrast = abs((int)value - (int)lx) + abs((int)value - (int)rx) +
						   abs((int)value - (int)ty) + abs((int)value - (int)by);
				}
				next = quantize(value, contrast, x, y);
			}
			uint8_t *output = frame + y * WIDTH + x;
			if (draw_pointer)
				next = pointer_level(pointer, vertical, x, y, next);
			if (*output != next) {
				stats->changed++;
				dirty_tiles[y / TILE][x / TILE] = 1;
				*output = next;
			}
		}
	stats->quant_us += now_us() - start;
	stats->pixels += (area.right - area.left) * (area.bottom - area.top);
	return 0;
}

static int damage_regions(Display *display, Damage damage, XserverRegion region, int offset,
			  struct rect areas[MAX_REGIONS])
{
	uint8_t tiles[TILE_ROWS][TILE_COLS] = {{0}};
	int count = 0;
	XDamageSubtract(display, damage, None, region);
	XRectangle *rectangles = XFixesFetchRegion(display, region, &count);
	for (int i = 0; i < count; i++) {
		XRectangle r = rectangles[i];
		struct rect area = clipped((struct rect){
			r.x - offset, r.y, r.x - offset + r.width, r.y + r.height,
		}, 0);
		if (!nonempty(area))
			continue;
		for (int y = area.top / TILE; y <= (area.bottom - 1) / TILE; y++)
			memset(tiles[y] + area.left / TILE, 1,
			       (area.right - 1) / TILE - area.left / TILE + 1);
	}
	if (rectangles)
		XFree(rectangles);

	int used = 0;
	struct rect bounds = {0};
	for (int y = 0; y < TILE_ROWS; y++)
		for (int x = 0; x < TILE_COLS;) {
			int start = x++;
			if (!tiles[y][start])
				continue;
			while (x < TILE_COLS && tiles[y][x])
				x++;
			struct rect area = clipped((struct rect){
				start * TILE, y * TILE, x * TILE, (y + 1) * TILE,
			}, 0);
			bounds = united(bounds, area);
			if (used > MAX_REGIONS)
				continue;
			int merged = 0;
			for (int i = 0; i < used; i++)
				if (areas[i].bottom == area.top && areas[i].left == area.left &&
				    areas[i].right == area.right) {
					areas[i].bottom = area.bottom;
					merged = 1;
					break;
				}
			if (!merged) {
				if (used < MAX_REGIONS)
					areas[used] = area;
				used++;
			}
		}
	if (used > MAX_REGIONS) {
		areas[0] = bounds;
		return 1;
	}
	return used;
}

struct worker {
	int socket;
	pid_t pid;
	struct shared_frame *frame;
};

static int start_worker(struct worker *worker, const char *waveform)
{
	int sockets[2];
	char path[] = "/run/pb626-epd-frame.XXXXXX";
	int fd = mkstemp(path);
	if (fd < 0)
		return -1;
	int unlinked = unlink(path);
	if (unlinked || ftruncate(fd, sizeof(struct shared_frame))) {
		close(fd);
		return -1;
	}
	struct shared_frame *frame = mmap(NULL, sizeof(*frame), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (frame == MAP_FAILED || socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) {
		if (frame != MAP_FAILED)
			munmap(frame, sizeof(*frame));
		close(fd);
		return -1;
	}

	pid_t pid = fork();
	if (pid == 0) {
		close(sockets[0]);
		if (dup2(sockets[1], STDIN_FILENO) < 0 || dup2(sockets[1], STDOUT_FILENO) < 0)
			_exit(127);
		close(sockets[1]);
		char number[16];
		snprintf(number, sizeof(number), "%d", fd);
		execl("/usr/bin/pb626-epd", "pb626-epd", waveform, "serve", number, (char *)NULL);
		_exit(127);
	}
	close(fd);
	close(sockets[1]);
	if (pid < 0) {
		close(sockets[0]);
		munmap(frame, sizeof(*frame));
		return -1;
	}
	*worker = (struct worker){ .socket = sockets[0], .pid = pid, .frame = frame };
	return 0;
}

static void stop_worker(struct worker *worker)
{
	close(worker->socket);
	while (waitpid(worker->pid, NULL, 0) < 0 && errno == EINTR)
		;
	munmap(worker->frame, sizeof(*worker->frame));
}

static int send_command(const struct worker *worker, uint8_t command)
{
	ssize_t done;
	do {
		done = send(worker->socket, &command, 1, MSG_NOSIGNAL);
	} while (done < 0 && errno == EINTR);
	return done == 1 ? 0 : -1;
}

static int await_ack(const struct worker *worker, uint8_t command)
{
	ssize_t done;
	uint8_t ack;
	do {
		done = read(worker->socket, &ack, 1);
	} while (done < 0 && errno == EINTR);
	return done == 1 && ack == command ? 0 : -1;
}

static int submit(const struct worker *worker, uint8_t command)
{
	return send_command(worker, command) || await_ack(worker, command) ? -1 : 0;
}

/* A2 has only exact 0->15 / 15->0 transitions at every stock temperature.
 * Check the committed source levels; preview pixels outside selected tiles
 * may hold stale values in the shared frame.
 */
static int a2_eligible(const struct shared_frame *frame, const uint8_t *panel)
{
    unsigned int changes = 0;
    for (int ty = 0; ty < TILE_ROWS; ty++)
        for (int tx = 0; tx < TILE_COLS; tx++) {
            if (!frame->tiles[ty][tx])
                continue;
            int right, bottom;
            tile_bounds(tx, ty, &right, &bottom);
            for (int y = ty * TILE; y < bottom; y++)
                for (int x = tx * TILE; x < right; x++) {
                    size_t i = y * WIDTH + x;
                    uint8_t sample = frame->pixels[i];
                    if (sample == KEEP)
                        continue;
                    unsigned int old = panel[i], level = sample & WHITE;
                    if ((sample & SCRUB) ||
                        !((old == 0 && level == WHITE) || (old == WHITE && level == 0)))
                        return 0;
                    changes++;
                }
        }
    return changes != 0;
}

enum fast_profile { FAST_DU, FAST_A2, FAST_DU4, FAST_AUTO };

/* Count completed fast transitions. This budget does not model reflectance. */
static uint8_t fast_changes[PIXELS];
static uint16_t cleanup_pixels[TILE_ROWS][TILE_COLS];
static int clean_halo = 1;

static int cleanup_near_tile(int tx, int ty)
{
	if (!clean_halo)
		return cleanup_pixels[ty][tx] != 0;
	for (int y = ty ? ty - 1 : ty; y <= ty + 1 && y < TILE_ROWS; y++)
		for (int x = tx ? tx - 1 : tx; x <= tx + 1 && x < TILE_COLS; x++)
			if (cleanup_pixels[y][x])
				return 1;
	return 0;
}

static int needs_scrub(const uint8_t *panel, int x, int y)
{
	size_t pixel = y * WIDTH + x;
	if (fast_changes[pixel] == CLEAN_AFTER)
		return 1;
	if (!clean_halo)
		return 0;

	/* The reference chart showed a residual outline just beyond the changed
	 * pixels. Include a one-pixel border on the same shade of paper.
	 */
	for (int ny = y ? y - 1 : y; ny <= y + 1 && ny < HEIGHT; ny++)
		for (int nx = x ? x - 1 : x; nx <= x + 1 && nx < WIDTH; nx++) {
			size_t neighbor = ny * WIDTH + nx;
			if (fast_changes[neighbor] == CLEAN_AFTER && panel[neighbor] == panel[pixel])
				return 1;
		}
	return 0;
}

static uint64_t cleanup_delay(unsigned int cleanup_count)
{
	return cleanup_count >= LARGE_CLEAN_PIXELS ? LARGE_CLEAN_QUIET_US : CLEAN_QUIET_US;
}

static uint8_t automatic_command(uint64_t idle_us, int capture_pending, int captured,
				 int different, unsigned int cleanup_count)
{
	if (!capture_pending) {
		if (different && idle_us >= QUIET_US)
			return SETTLE;
		if (!different && cleanup_count && idle_us >= cleanup_delay(cleanup_count))
			return CLEAN;
	}
	return captured && different ? PREVIEW : 0;
}

static unsigned int prepare(uint8_t command, const uint8_t *desired, const uint8_t *panel,
			    struct shared_frame *frame)
{
	unsigned int changes = 0;
	if (command == RESET) {
		memset(frame->tiles, 1, sizeof(frame->tiles));
		for (size_t i = 0; i < PIXELS; i++)
			frame->pixels[i] = desired[i] | SCRUB;
		return PIXELS;
	}
	memset(frame->tiles, 0, sizeof(frame->tiles));
	for (int ty = 0; ty < TILE_ROWS; ty++)
		for (int tx = 0; tx < TILE_COLS; tx++) {
			if (command == CLEAN ? !cleanup_near_tile(tx, ty) : !dirty_tiles[ty][tx])
				continue;
			int right, bottom, differs = 0;
			tile_bounds(tx, ty, &right, &bottom);
			for (int y = ty * TILE; y < bottom; y++)
				for (int x = tx * TILE; x < right; x++) {
					size_t i = y * WIDTH + x;
					uint8_t target = desired[i], old = panel[i];
					int scrub = command == CLEAN && target == old && needs_scrub(panel, x, y);
					uint8_t level = target;
					differs |= target != old;
					if (command == PREVIEW || command == PREVIEW_A2)
                        level = abs(target - old) >= 3 ? preview_level(target, old) : old;
                    else if (command == PREVIEW_DU4)
                        level = preview_level4(target);
					if (scrub || (command != CLEAN && level != old)) {
						frame->pixels[i] = level | (scrub ? SCRUB : 0);
						frame->tiles[ty][tx] = 1;
						changes++;
					} else {
						frame->pixels[i] = KEEP;
					}
				}
			if (!differs)
				dirty_tiles[ty][tx] = 0;
		}
	return changes;
}

static void acknowledge(uint8_t command, const struct shared_frame *frame,
			const uint8_t *desired, uint8_t *panel)
{
	if (command == RESET) {
		memset(fast_changes, 0, sizeof(fast_changes));
		memset(cleanup_pixels, 0, sizeof(cleanup_pixels));
		memset(dirty_tiles, 0, sizeof(dirty_tiles));
		memcpy(panel, desired, PIXELS);
		return;
	}
	for (int ty = 0; ty < TILE_ROWS; ty++)
		for (int tx = 0; tx < TILE_COLS; tx++) {
			if (!frame->tiles[ty][tx])
				continue;
			int right, bottom;
			tile_bounds(tx, ty, &right, &bottom);
			int differs = 0;
			for (int y = ty * TILE; y < bottom; y++)
				for (int x = tx * TILE; x < right; x++) {
					size_t i = y * WIDTH + x;
					uint8_t sample = frame->pixels[i];
					if (sample == KEEP) {
						differs |= panel[i] != desired[i];
						continue;
					}
					uint8_t level = sample & WHITE;
					differs |= level != desired[i];
					if (sample & SCRUB) {
						if (fast_changes[i] == CLEAN_AFTER)
							cleanup_pixels[ty][tx]--;
						fast_changes[i] = 0;
					} else if ((command == PREVIEW || command == PREVIEW_A2 ||
                             command == PREVIEW_DU4) && panel[i] != level &&
                             fast_changes[i] < CLEAN_AFTER) {
						if (++fast_changes[i] == CLEAN_AFTER)
							cleanup_pixels[ty][tx]++;
					}
					panel[i] = level;
				}
			dirty_tiles[ty][tx] = differs;
		}
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "Usage: pb626-x11-epd DEFAULT.WBF READY\n");
		return EXIT_FAILURE;
	}
	static const char *const profiles[] = {"balanced", "ui", "photo", "legacy"};
	const char *gray = getenv("PB626_EPD_GRAY_PROFILE");
	enum gray_profile selected = GRAY_BALANCED;
	if (gray) {
		for (; selected < sizeof(profiles) / sizeof(profiles[0]); selected++)
			if (!strcmp(gray, profiles[selected]))
				break;
		if (selected == sizeof(profiles) / sizeof(profiles[0])) {
			fprintf(stderr, "pb626-x11-epd: unknown gray profile %s\n", gray);
			return EXIT_FAILURE;
		}
	}
	const char *tone = getenv("PB626_EPD_TONE");
	int lightness = tone && !strcmp(tone, "cie-lstar");
	if (tone && !lightness && strcmp(tone, "srgb")) {
		fprintf(stderr, "pb626-x11-epd: unknown tone %s\n", tone);
		return EXIT_FAILURE;
	}
	const char *gamma_arg = getenv("PB626_EPD_GAMMA");
	double gamma = 1.0;
	if (gamma_arg) {
		char *end;
		gamma = strtod(gamma_arg, &end);
		if (*end || !(gamma >= 0.5 && gamma <= 2.0)) {
			fprintf(stderr, "pb626-x11-epd: gamma must be between 0.5 and 2.0\n");
			return EXIT_FAILURE;
		}
	}
    const char *fast = getenv("PB626_EPD_FAST_MODE");
    enum fast_profile fast_mode = FAST_DU;
    if (fast && strcmp(fast, "du")) {
        if (!strcmp(fast, "a2"))
            fast_mode = FAST_A2;
        else if (!strcmp(fast, "du4"))
            fast_mode = FAST_DU4;
        else if (!strcmp(fast, "auto"))
            fast_mode = FAST_AUTO;
        else {
            fprintf(stderr, "pb626-x11-epd: fast mode must be du, a2, or du4\n");
            return EXIT_FAILURE;
        }
    }
	/* Native startup overlaps INIT with Xorg. The session marker is
	 * a generic handoff, not a GUI/application readiness condition. */
	int lock_fd = open("/run/pb626-epd.lock", O_CREAT | O_RDWR, 0600);
	if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB) < 0)
		return EXIT_FAILURE;
	struct worker worker;
	if (start_worker(&worker, argv[1]))
		return EXIT_FAILURE;
	unlink(argv[2]);
	int profile = getenv("PB626_EPD_PROFILE") != NULL;
	int init_sent = 0;
	const char *marker = getenv("PB626_EPD_SESSION_STARTED");
	if (marker) {
		if (profile)
			fprintf(stderr, "preclear: INIT begin mono_us=%llu\n", (unsigned long long)now_us());
		init_sent = send_command(&worker, INIT_PANEL) == 0;
	}
	setup_gray(selected, lightness, gamma);
	setup_quantization();
	if (marker) {
		uint64_t deadline = now_us() + 15000000ULL;
		while (access(marker, F_OK) && now_us() < deadline)
			nanosleep(&(struct timespec){ .tv_nsec = 20000000L }, NULL);
		if (access(marker, F_OK)) {
			stop_worker(&worker);
			return EXIT_FAILURE;
		}
	}
	Display *display = XOpenDisplay(NULL);
	if (!display) {
		fprintf(stderr, "pb626-x11-epd: cannot connect to Xorg\n");
		stop_worker(&worker);
		return EXIT_FAILURE;
	}
	int screen = DefaultScreen(display);
	int width = DisplayWidth(display, screen);
	if (width < WIDTH || DisplayHeight(display, screen) != HEIGHT) {
		fprintf(stderr, "pb626-x11-epd: unexpected Xorg screen dimensions\n");
		stop_worker(&worker);
		return EXIT_FAILURE;
	}

	Window root = RootWindow(display, screen);
	XSetErrorHandler(handle_x_error);
	XSelectInput(display, root, PropertyChangeMask);
	/* Matchbox excludes the input toolbar and panel from this property. */
	Atom active = XInternAtom(display, "_MB_CURRENT_APP_WINDOW", False);
	Atom keyboard = XInternAtom(display, "_MB_IM_INVOKER_COMMAND", False);
	KeyCode toggle = XKeysymToKeycode(display, XK_F12);
	if (toggle)
		XGrabKey(display, toggle, AnyModifier, root, False, GrabModeAsync, GrabModeAsync);
	int damage_event, damage_error;
	int fixes_event, fixes_error;
	Damage damage = XDamageQueryExtension(display, &damage_event, &damage_error) &&
			XFixesQueryExtension(display, &fixes_event, &fixes_error) ?
			XDamageCreate(display, root, XDamageReportNonEmpty) : None;
	XserverRegion region = damage ? XFixesCreateRegion(display, NULL, 0) : None;
	Window previous_window = None;
	struct controls controls = { .fallback = getenv("PB626_POINTER_FALLBACK") != NULL };
	struct pollfd sources[3] = {{ .fd = ConnectionNumber(display), .events = POLLIN }};
	nfds_t source_count = 1;
	const char *devices = getenv("PB626_BUTTON_DEVICES");
	char *paths = devices ? strdup(devices) : NULL;
	for (char *path = paths ? strtok(paths, " ") : NULL;
	     path && source_count < sizeof(sources) / sizeof(sources[0]); path = strtok(NULL, " ")) {
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd >= 0)
			sources[source_count++] = (struct pollfd){ .fd = fd, .events = POLLIN };
	}
	free(paths);
	static uint8_t frame[PIXELS], previous[PIXELS];
	const struct rect full = {0, 0, WIDTH, HEIGHT};
	struct rect pointer = {0};
	const char *halo = getenv("PB626_EPD_CLEAN_HALO");
	clean_halo = !halo || strcmp(halo, "0");
	XShmSegmentInfo shm = {0};
	setup_shm(display, &shm);
	int precleared = init_sent && await_ack(&worker, INIT_PANEL) == 0;
	if (marker && profile)
		fprintf(stderr, "preclear: %s mono_us=%llu\n",
			precleared ? "INIT_ACK" : "FALLBACK_RESET", (unsigned long long)now_us());
	if (marker && !precleared) {
		stop_worker(&worker);
		if (start_worker(&worker, argv[1]))
			return EXIT_FAILURE;
	}
	if (profile)
		fprintf(stderr, "x11-epd: capture=%s gray=%s tone=%s gamma=%.2f fast=%s\n",
                shm.shmaddr ? "MIT-SHM" : "XGetImage", profiles[selected],
                lightness ? "cie-lstar" : "srgb", gamma,
                fast_mode == FAST_A2 ? "a2" : fast_mode == FAST_DU4 ? "du4" :
                fast_mode == FAST_AUTO ? "auto" : "du");
	int offset = (width - WIDTH) / 2;
	unsigned int failures = 0;
	int dirty = 1, focus_changed = 1, has_frame = 0, pending = 0;
	unsigned int cleanup_count = 0;
	uint64_t last_damage = 0, pending_since = 0, next_capture = 0, layout_until = 0;
	uint64_t damage_seen = 0;

	for (;;) {
		XEvent event;
		while (XPending(display)) {
			XNextEvent(display, &event);
			if (damage && event.type == damage_event + XDamageNotify) {
				if (profile && !damage_seen)
					damage_seen = now_us();
				dirty = 1;
			} else if (event.type == PropertyNotify && event.xproperty.atom == active)
				focus_changed = 1;
			else if (event.type == KeyPress && event.xkey.keycode == toggle) {
				keyboard_command(display, root, keyboard, KEYBOARD_TOGGLE);
				controls.keyboard_changed = 1;
			}
		}
		if (focus_changed) {
			keyboard_focus(display, root, active, keyboard, &previous_window, &controls);
			focus_changed = 0;
		}
		int pointer_changed = 0;
		for (nfds_t i = 1; i < source_count; i++)
			if (sources[i].fd >= 0)
				pointer_changed |= handle_buttons(display, root, keyboard, sources[i].fd, &controls);
		uint64_t now = now_us();
		if (controls.keyboard_changed) {
			XFlush(display);
			layout_until = now + LAYOUT_QUIET_US;
			controls.keyboard_changed = 0;
		}
		if (pointer_changed) {
			/* Retain the old cursor rectangle across the layout debounce. */
			dirty = 1;
		}
		/* Force a fresh grab on a manual reset, including after a failed update. */
		if (!has_frame || controls.clean_requested)
			dirty = 1;

		struct capture_stats stats = {0};
		uint64_t capture_start = now, damage_wait = 0, ack = 0;
		int captured = 0;
		if ((dirty || !damage) && now >= next_capture && now >= layout_until) {
			struct rect areas[MAX_REGIONS];
			int count = damage ? damage_regions(display, damage, region, offset, areas) : 0;
			if (!has_frame || !damage || controls.clean_requested) {
				areas[0] = full;
				count = 1;
			}
			if (controls.pointer_visible) {
				struct rect next = pointer_rect(display, root, offset);
				struct rect area = clipped(united(pointer, next), 0);
				if (nonempty(area) && count < MAX_REGIONS)
					areas[count++] = area;
				else if (nonempty(area))
					areas[0] = united(areas[0], area);
				pointer = next;
			}
			for (int i = 0; i < count; i++)
				if (capture(display, root, offset, areas[i], frame, pointer, controls.vertical, &stats, &shm))
					goto failed;
			captured = count != 0;
			if (damage_seen)
				damage_wait = capture_start - damage_seen;
			damage_seen = 0;
			dirty = 0;
			now = now_us();
			next_capture = now + (damage ? 16000 : 250000);
		}

		if (!has_frame && !captured)
			goto wait_input;
		int different = 0;
		cleanup_count = 0;
		for (int y = 0; y < TILE_ROWS; y++)
			for (int x = 0; x < TILE_COLS; x++) {
				different |= dirty_tiles[y][x];
				cleanup_count += cleanup_pixels[y][x];
			}
		if (stats.changed)
			last_damage = now;
		if (different) {
			if (!pending)
				pending_since = now;
			pending = 1;
		} else {
			pending = 0;
		}

		uint8_t command = captured && (!has_frame || controls.clean_requested) ? RESET :
            automatic_command(now - last_damage, dirty || now < layout_until,
                              captured, different, cleanup_count);
        if (command == PREVIEW && fast_mode == FAST_DU4)
            command = PREVIEW_DU4;

		uint64_t prepare_start = now_us();
		unsigned int changes = command ? prepare(command, frame, previous, worker.frame) : 0;
		/* Gray-only activity may have no useful DU transitions. Bound its
		 * wait without interrupting motion that DU can still show.
		 */
		if (!changes && (command == PREVIEW || command == PREVIEW_DU4) &&
            now >= pending_since + MAX_PENDING_US) {
			command = SETTLE;
			changes = prepare(command, frame, previous, worker.frame);
		}
		/* A2 only when every changed pixel is an exact binary transition. */
        if (changes && command == PREVIEW && (fast_mode == FAST_A2 || fast_mode == FAST_AUTO) &&
            a2_eligible(worker.frame, previous))
            command = PREVIEW_A2;
        uint64_t submit_start = now_us();
		if (changes) {
			uint8_t wire = command;
			if (precleared && !has_frame && command == RESET && !controls.clean_requested)
				wire = CLEAN;
			precleared = 0;
			if (profile && !has_frame)
				fprintf(stderr, "preclear: first wire=%c mono_us=%llu\n", wire, (unsigned long long)now_us());
			if (submit(&worker, wire)) {
				stop_worker(&worker);
				if (++failures >= 3)
					return EXIT_FAILURE;
				has_frame = 0;
				controls.clean_requested = 1;
				sleep(1);
				if (start_worker(&worker, argv[1]))
					return EXIT_FAILURE;
				continue;
			}
			if (profile)
				ack = now_us();
			acknowledge(command, worker.frame, frame, previous);
			if (!has_frame) {
				FILE *ready = fopen(argv[2], "w");
				if (!ready)
					goto failed;
				fputs("ready\n", ready);
				if (fclose(ready))
					goto failed;
			}
			has_frame = 1;
			failures = 0;
			controls.clean_requested = 0;
			/* Bound gray-only starvation from the last visible progress. */
			pending_since = now_us();
		}
		if (profile && (captured || changes))
			fprintf(stderr, "x11-epd: mode=%c read_px=%u change_px=%u xget_us=%llu quant_us=%llu prepare_us=%llu ipc_update_us=%llu total_us=%llu capture_mono_us=%llu damage_wait_us=%llu ack_mono_us=%llu\n",
				command ? command : '-', stats.pixels, changes,
				(unsigned long long)stats.read_us, (unsigned long long)stats.quant_us,
				(unsigned long long)(submit_start - prepare_start),
				(unsigned long long)(changes ? now_us() - submit_start : 0),
				(unsigned long long)(now_us() - capture_start),
				(unsigned long long)capture_start, (unsigned long long)damage_wait,
				(unsigned long long)ack);
		if (changes || command == SETTLE)
			continue; /* Discard intermediate frames and consume accumulated damage. */

wait_input:
		now = now_us();
		uint64_t deadline = UINT64_MAX;
		if (dirty || !damage)
			deadline = next_capture > layout_until ? next_capture : layout_until;
		if ((pending || cleanup_count) && has_frame && !dirty) {
			uint64_t settle = last_damage + (pending ? QUIET_US : cleanup_delay(cleanup_count));
			if (settle < layout_until)
				settle = layout_until;
			if (settle < deadline)
				deadline = settle;
		}
		XFlush(display);
		if (XPending(display))
			continue;
		int timeout = deadline == UINT64_MAX ? -1 :
			      deadline <= now ? 0 : (int)((deadline - now + 999) / 1000);
		if (poll(sources, source_count, timeout) < 0) {
			if (errno == EINTR)
				continue;
			goto failed;
		}
		const short disconnected = POLLERR | POLLHUP | POLLNVAL;
		if (sources[0].revents & disconnected)
			goto failed;
		for (nfds_t i = 1; i < source_count; i++) {
			if (sources[i].revents & disconnected) {
				close(sources[i].fd);
				sources[i].fd = -1;
			}
		}
	}

failed:
	stop_worker(&worker);
	return EXIT_FAILURE;
}
