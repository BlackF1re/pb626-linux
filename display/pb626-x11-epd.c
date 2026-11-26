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
#include <X11/extensions/Xrandr.h>
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
#include <sys/un.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "pb626-epd.h"
#include "pb626-ddx-fb.h"
#include "pb626-sleep.h"
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

enum { MENU_HOLD_US = 1000000, LAYOUT_QUIET_US = 180000, QUIET_US = 300000,
       MAX_PENDING_US = 850000,
       CLEAN_QUIET_US = 1200000, LARGE_CLEAN_QUIET_US = 5000000,
       LARGE_CLEAN_PIXELS = PIXELS / 16, CLEAN_AFTER = 8, MAX_REGIONS = 8 };
enum { KEYBOARD_SHOW = 1, KEYBOARD_HIDE, KEYBOARD_TOGGLE };

/* Native power-key lock is an accidental-input lock, not authentication. */
static int screen_locked;

static enum pb_rotation capture_rotation;
static int capture_y_offset;

static int screen_geometry(Display *display, Window root, int *offset)
{
	XWindowAttributes a;
	if (!XGetWindowAttributes(display, root, &a))
		return -1;
	Rotation rr = RR_Rotate_0;
	int have_rotation = 0, major = 1, minor = 3;
	if (XRRQueryVersion(display, &major, &minor) && (major > 1 || minor >= 3)) {
		XRRScreenResources *res = XRRGetScreenResourcesCurrent(display, root);
		if (res) {
			for (int i = 0; i < res->ncrtc; i++) {
				XRRCrtcInfo *ci = XRRGetCrtcInfo(display, res, res->crtcs[i]);
				if (!ci) continue;
				if (ci->mode != None && ci->noutput) {
					rr = ci->rotation;
					have_rotation = 1;
					XRRFreeCrtcInfo(ci);
					break;
				}
				XRRFreeCrtcInfo(ci);
			}
			XRRFreeScreenResources(res);
		}
	}
	if (rr & (RR_Reflect_X | RR_Reflect_Y))
		return -1;
	enum pb_rotation r = PB_ROT_0;
	if (rr & RR_Rotate_90) r = PB_ROT_90;
	else if (rr & RR_Rotate_180) r = PB_ROT_180;
	else if (rr & RR_Rotate_270) r = PB_ROT_270;
	else if (!have_rotation && a.width > a.height) r = PB_ROT_90;
	int w = logical_width(r), h = logical_height(r);
	if (a.width < w || a.width > w + 2 || a.height < h || a.height > h + 2)
		return -1;
	capture_rotation = r;
	*offset = (a.width - w) / 2;
	capture_y_offset = (a.height - h) / 2;
	return 0;
}

static int power_action(const char *action, const char *arg)
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (!pid) {
		if (arg)
			execl("/usr/sbin/pb626-admin", "pb626-admin", action, arg, (char *)NULL);
		else
			execl("/usr/sbin/pb626-admin", "pb626-admin", action, (char *)NULL);
		_exit(127);
	}
	int status;
	while (waitpid(pid, &status, 0) < 0)
		if (errno != EINTR)
			return -1;
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

enum power_policy { POWER_LOCK, POWER_S2IDLE, POWER_IGNORE, POWER_OFF };
static enum power_policy power_policy(void)
{
	char value[32];
	FILE *file = fopen("/var/lib/pb626/power-key", "r");
	if (!file)
		return POWER_LOCK;
	int got = fscanf(file, "%31s", value);
	fclose(file);
	if (got != 1)
		return POWER_LOCK;
	if (!strcmp(value, "s2idle")) return POWER_S2IDLE;
	if (!strcmp(value, "ignore")) return POWER_IGNORE;
	if (!strcmp(value, "poweroff")) return POWER_OFF;
	return POWER_LOCK;
}

static int grab_lock(Display *d, Window root)
{
	if (XGrabKeyboard(d, root, False, GrabModeAsync, GrabModeAsync, CurrentTime) != GrabSuccess)
		return -1;
	if (XGrabPointer(d, root, False, ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
			 GrabModeAsync, GrabModeAsync, None, None, CurrentTime) != GrabSuccess) {
		XUngrabKeyboard(d, CurrentTime);
		XFlush(d);
		return -1;
	}
	XFlush(d);
	return 0;
}

static void release_lock(Display *d)
{
	XUngrabPointer(d, CurrentTime);
	XUngrabKeyboard(d, CurrentTime);
	XFlush(d);
}

/* A complete short press/release toggles. Repeats and orphan releases
 * cannot initiate a sleep operation. */
static int power_press(int fd, uint64_t *pressed)
{
	struct input_event e;
	int count = 0;
	while (read(fd, &e, sizeof(e)) == (ssize_t)sizeof(e)) {
		if (e.type != EV_KEY || e.code != KEY_POWER)
			continue;
		uint64_t when = (uint64_t)e.input_event_sec * 1000000 + e.input_event_usec;
		if (e.value == 1)
			*pressed = when ? when : 1;
		else if (e.value == 0) {
			if (*pressed && when >= *pressed && when - *pressed < 1500000)
				count++;
			*pressed = 0;
		}
	}
	return count;
}

enum { BUTTON_KEYS = 4, BUTTON_GESTURES = 3, DOUBLE_US = 350000 };
enum gesture { SHORT_PRESS, LONG_PRESS, DOUBLE_PRESS };
struct button_binding {
	char action[BUTTON_GESTURES][24];
	uint64_t pressed, deadline;
	int down, second, pending;
};

struct controls {
	int custom_buttons;
	struct button_binding bindings[BUTTON_KEYS];
	int fallback, vertical, pointer_visible, clean_requested, keyboard_changed;
	int page_keys, home_key, menu_escape;
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

static int valid_button_action(const char *name)
{
	static const char *const allowed[] = {
		"none", "Left", "Right", "Up", "Down", "Page_Up", "Page_Down",
		"Home", "End", "Escape", "Return", "BackSpace", "Tab", "space", "Menu",
		"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
		"keyboard", "refresh", "light-toggle",
	};
	for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++)
		if (!strcmp(name, allowed[i])) return 1;
	return 0;
}

static int load_button_bindings(struct controls *controls)
{
	FILE *f = fopen("/var/lib/pb626/button-bindings", "r");
	if (!f) return 0;
	int valid = 1;
	for (int i = 0; i < BUTTON_KEYS; i++)
		for (int j = 0; j < BUTTON_GESTURES; j++) {
			char *a = controls->bindings[i].action[j];
			if (fscanf(f, "%23s", a) != 1 || !valid_button_action(a))
				valid = 0;
		}
	char extra[2];
	if (fscanf(f, "%1s", extra) != EOF) valid = 0;
	fclose(f);
	if (!valid) fprintf(stderr, "pb626: invalid button bindings; using legacy defaults\n");
	return valid;
}

static int binding_index(unsigned int key)
{
	switch (key) {
	case KEY_LEFT: return 0;
	case KEY_RIGHT: return 1;
	case KEY_HOME: return 2;
	case KEY_MENU: return 3;
	default: return -1;
	}
}

static int dispatch_binding(Display *d, Window root, Atom keyboard,
			    struct controls *controls, const char *action)
{
	if (!strcmp(action, "none")) return 0;
	if (!strcmp(action, "refresh")) {
		controls->clean_requested = 1;
		return 1;
	}
	if (!strcmp(action, "keyboard")) {
		keyboard_command(d, root, keyboard, KEYBOARD_TOGGLE);
		controls->keyboard_changed = 1;
	} else if (!strcmp(action, "light-toggle")) {
		(void)power_action("light-toggle", NULL);
	} else {
		KeyCode key = XKeysymToKeycode(d, XStringToKeysym(action));
		if (key) {
			XTestFakeKeyEvent(d, key, True, CurrentTime);
			XTestFakeKeyEvent(d, key, False, CurrentTime);
		}
	}
	XFlush(d);
	return 0;
}

/* No click delay unless a double action is configured. Durations use
 * the original evdev timestamps; expiry uses the bridge's monotonic clock.
 * A key with only a short action retains ordinary key-repeat behaviour. */
static int binding_event(Display *d, Window root, Atom keyboard,
			 struct controls *controls, struct button_binding *b,
			 const struct input_event *e)
{
	uint64_t now = now_us();
	uint64_t stamp = (uint64_t)e->input_event_sec * 1000000 + e->input_event_usec;
	int changed = 0, has_long = strcmp(b->action[LONG_PRESS], "none") != 0;
	int has_double = strcmp(b->action[DOUBLE_PRESS], "none") != 0;
	if (e->value == 1 && b->pending && now >= b->deadline) {
		changed |= dispatch_binding(d, root, keyboard, controls, b->action[SHORT_PRESS]);
		b->pending = 0;
	}
	if (!has_long && !has_double) {
		if (e->value == 1 || (e->value == 2 &&
		    XStringToKeysym(b->action[SHORT_PRESS]) != NoSymbol))
			changed |= dispatch_binding(d, root, keyboard, controls, b->action[SHORT_PRESS]);
		return changed;
	}
	if (e->value == 1) {
		if (!b->down) {
			b->down = 1;
			b->pressed = stamp;
			b->second = b->pending;
		}
	} else if (e->value == 0 && b->down) {
		b->down = 0;
		if (has_long && stamp >= b->pressed && stamp - b->pressed >= MENU_HOLD_US) {
			if (b->second)
				changed |= dispatch_binding(d, root, keyboard, controls, b->action[SHORT_PRESS]);
			b->pending = 0;
			changed |= dispatch_binding(d, root, keyboard, controls, b->action[LONG_PRESS]);
		} else if (has_double && b->second) {
			b->pending = 0;
			changed |= dispatch_binding(d, root, keyboard, controls, b->action[DOUBLE_PRESS]);
		} else if (has_double) {
			b->pending = 1;
			b->deadline = now + DOUBLE_US;
		} else {
			changed |= dispatch_binding(d, root, keyboard, controls, b->action[SHORT_PRESS]);
		}
		b->second = 0;
	}
	return changed;
}

static int flush_bindings(Display *d, Window root, Atom keyboard,
			  struct controls *controls, uint64_t now)
{
	int changed = 0;
	for (int i = 0; i < BUTTON_KEYS; i++) {
		struct button_binding *b = &controls->bindings[i];
		if (screen_locked) {
			b->down = b->pending = b->second = 0;
		} else if (b->pending && !b->down && now >= b->deadline) {
			b->pending = 0;
			changed |= dispatch_binding(d, root, keyboard, controls, b->action[SHORT_PRESS]);
		}
	}
	return changed;
}
static uint64_t binding_deadline(const struct controls *controls)
{
	uint64_t deadline = UINT64_MAX;
	if (screen_locked) return deadline;
	for (int i = 0; i < BUTTON_KEYS; i++) {
		const struct button_binding *b = &controls->bindings[i];
		if (b->pending && !b->down && b->deadline < deadline) deadline = b->deadline;
	}
	return deadline;
}

static int handle_buttons(Display *display, Window root, Atom keyboard, int fd,
			  struct controls *controls)
{
	int changed = 0;
	struct input_event event;
	while (read(fd, &event, sizeof(event)) == (ssize_t)sizeof(event)) {
		if (event.type != EV_KEY || screen_locked)
			continue;
		/* A physical key is activity even when it only sends a client message. */
		if (event.value)
			XResetScreenSaver(display);
		if (controls->custom_buttons && !controls->fallback) {
			int i = binding_index(event.code);
			if (i >= 0)
				changed |= binding_event(display, root, keyboard, controls, &controls->bindings[i], &event);
			continue;
		}
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
					KeyCode menu = XKeysymToKeycode(display, controls->menu_escape ? XK_Escape : XK_Menu);
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
				else if (controls->home_key) {
					KeyCode home = XKeysymToKeycode(display, XK_Home);
					if (home) {
						XTestFakeKeyEvent(display, home, True, CurrentTime);
						XTestFakeKeyEvent(display, home, False, CurrentTime);
					}
				} else {
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
					controls->page_keys ? (event.code == KEY_LEFT ? XK_Page_Up : XK_Page_Down) :
					(event.code == KEY_LEFT ? XK_Left : XK_Right));
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
	int w = logical_width(capture_rotation), h = logical_height(capture_rotation);
	r.right = r.right < w - halo ? r.right + halo : w;
	r.bottom = r.bottom < h - halo ? r.bottom + halo : h;
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
	y -= capture_y_offset;
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

enum gray_profile { GRAY_BALANCED, GRAY_UI, GRAY_PHOTO, GRAY_LEGACY, GRAY_MONO };
enum { LUMA_STEPS = 4096 };
static enum gray_profile gray_profile;
static uint16_t linear_r[256], linear_g[256], linear_b[256];
static uint8_t gray_tone[256], luma_tone[LUMA_STEPS];
#if defined(__ARM_NEON)
static int gray_tone_identity;
#endif
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
#if defined(__ARM_NEON)
	gray_tone_identity = 1;
#endif
	if (selected == GRAY_LEGACY)
		return;
	for (int i = 0; i < 256; i++) {
		double v = i / 255.0, y = srgb_decode(v);
		double scaled = y * ((LUMA_STEPS - 1) * 16);
		linear_r[i] = scaled * 0.2126 + 0.5;
		linear_g[i] = scaled * 0.7152 + 0.5;
		linear_b[i] = scaled * 0.0722 + 0.5;
		gray_tone[i] = 255 * pow(lightness ? gray_encode(y, 1) : v, 1 / gamma) + 0.5;
#if defined(__ARM_NEON)
		if (gray_tone[i] != i)
			gray_tone_identity = 0;
#endif
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
	if (gray_profile == GRAY_MONO)
		return value >= 128 ? WHITE : 0;
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
		if (gray_profile != GRAY_UI && gray_profile != GRAY_MONO)
			for (int y = 0; y < period; y++)
				for (int x = 0; x < period; x++)
					quant_table[y][x][v] = quantize_reference(v, 0, x, y);
	}
}

static inline uint8_t quantize(unsigned int value, unsigned int contrast, int x, int y)
{
	if (quant_reference)
		return quantize_reference(value, contrast, x, y);
	if (contrast >= 48 || gray_profile == GRAY_UI || gray_profile == GRAY_MONO)
		return nearest_level[value];
	unsigned int mask = gray_profile == GRAY_PHOTO ? 15 : 3;
	return quant_table[y & mask][x & mask][value];
}

/* Exact L1 contrast: 4 unsigned byte differences, widened to 16 bits.
 * Scalar boundaries/tails preserve the existing quantization and dither. */
static void contrast_row(const uint8_t *row, const uint8_t *above,
			 const uint8_t *below, uint16_t *out, int left, int right, int width)
{
	int x = left;
	for (; x < right && x == 0; x++) {
		int v = row[x];
		out[x] = abs(v - row[width > 1 ? 1 : 0]) +
			 abs(v - above[x]) + abs(v - below[x]);
	}
#if defined(__ARM_NEON)
	for (; x + 8 <= right && x + 8 < width; x += 8) {
		uint8x8_t v = vld1_u8(row + x);
		uint16x8_t sum = vaddl_u8(vabd_u8(v, vld1_u8(row + x - 1)),
					 vabd_u8(v, vld1_u8(row + x + 1)));
		sum = vaddw_u8(sum, vabd_u8(v, vld1_u8(above + x)));
		sum = vaddw_u8(sum, vabd_u8(v, vld1_u8(below + x)));
		vst1q_u16(out + x, sum);
	}
#endif
	for (; x < right; x++) {
		int v = row[x];
		out[x] = abs(v - row[x ? x-1 : x]) +
			 abs(v - row[x+1 < width ? x+1 : x]) +
			 abs(v - above[x]) + abs(v - below[x]);
	}
}

/* Strips have a one-row contrast halo on both sides. */
enum { CAPTURE_ROWS = 128, CAPTURE_READ_ROWS = CAPTURE_ROWS + 2 };

static inline uint8_t rgb565_gray(unsigned int pixel)
{
	return gray_value(((pixel >> 11) & 31) * 255 / 31,
			  ((pixel >> 5) & 63) * 255 / 63,
			  (pixel & 31) * 255 / 31);
}

/* In a typical UI many adjacent pixels are pure black/white or neutral.
 * SIMD handles only mathematically exact cases, with the existing color
 * conversion as fallback. Load bytes (not potentially unaligned uint16_t)
 * and keep scalar tails so partial XDamage strips need no padding. */
static void rgb565_gray_row(const uint8_t *src, uint8_t *dst, int count)
{
	int x = 0;
#if defined(__ARM_NEON)
	for (; x + 8 <= count; x += 8) {
		uint16x8_t words = vreinterpretq_u16_u8(vld1q_u8(src + 2 * x));
		uint16x8_t binary = vorrq_u16(vceqq_u16(words, vdupq_n_u16(0)),
					      vceqq_u16(words, vdupq_n_u16(0xffff)));
		uint64x2_t mask = vreinterpretq_u64_u16(binary);
		if (vgetq_lane_u64(mask, 0) == UINT64_MAX &&
		    vgetq_lane_u64(mask, 1) == UINT64_MAX) {
			vst1_u8(dst + x, vshrn_n_u16(words, 8));
		} else {
			for (int i = x; i < x + 8; i++)
				dst[i] = rgb565_gray(src[2 * i] | ((unsigned int)src[2 * i + 1] << 8));
		}
	}
#endif
	for (; x < count; x++)
		dst[x] = rgb565_gray(src[2 * x] | ((unsigned int)src[2 * x + 1] << 8));
}

static void rgbx_gray_row(const uint8_t *src, uint8_t *dst, int count)
{
	int x = 0;
#if defined(__ARM_NEON)
	if (gray_tone_identity)
		for (; x + 8 <= count; x += 8) {
			uint8x8x4_t bgrx = vld4_u8(src + 4 * x);
			uint8x8_t neutral = vand_u8(vceq_u8(bgrx.val[0], bgrx.val[1]),
						  vceq_u8(bgrx.val[1], bgrx.val[2]));
			if (vget_lane_u64(vreinterpret_u64_u8(neutral), 0) == UINT64_MAX)
				vst1_u8(dst + x, bgrx.val[0]);
			else
				for (int i = x; i < x + 8; i++)
					dst[i] = gray_value(src[4 * i + 2], src[4 * i + 1], src[4 * i]);
		}
#endif
	for (; x < count; x++)
		dst[x] = gray_value(src[4 * x + 2], src[4 * x + 1], src[4 * x]);
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
				       shm, HEIGHT, CAPTURE_READ_ROWS);
	if (!image)
		return;
	int id = shmget(IPC_PRIVATE, (size_t)image->bytes_per_line * CAPTURE_READ_ROWS, IPC_CREAT | 0600);
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

/* Read-only view of the private DDX's existing root framebuffer. No
 * direct write, DMA ownership, or new full-screen buffer in the bridge. */
static const struct pb626_ddx_fb *ddx_fb;
static size_t ddx_size;

static int ddx_layout(const struct pb626_ddx_fb *h, size_t size,
		      int x, int y, int width, int height)
{
	if (size < PB626_DDX_FB_OFFSET ||
	    h->magic != PB626_DDX_FB_MAGIC || h->version != PB626_DDX_FB_VERSION ||
	    h->capacity > PB626_DDX_FB_MAX || h->capacity != size - PB626_DDX_FB_OFFSET ||
	    !h->width || !h->height || !h->stride || (h->stride & 3) ||
	    !((h->depth == 16 && h->bpp == 16 &&
	       h->red == 0xf800 && h->green == 0x07e0 && h->blue == 0x001f) ||
	      (h->depth == 24 && h->bpp == 32 &&
	       h->red == 0xff0000 && h->green == 0xff00 && h->blue == 0xff)))
		return 0;
	if ((uint64_t)h->width * (h->bpp / 8) > h->stride ||
	    (uint64_t)h->height * h->stride > h->capacity ||
	    x < 0 || y < 0 || width <= 0 || height <= 0 ||
	    (uint64_t)x + width > h->width || (uint64_t)y + height > h->height)
		return 0;
	return 1;
}

static void setup_ddx(void)
{
	const char *enabled = getenv("PB626_DDX_SHARED");
	if (!enabled || strcmp(enabled, "1"))
		return;
	int fd = open(PB626_DDX_FB_PATH, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0)
		return;
	struct stat st;
	if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == 0 &&
	    !(st.st_mode & 077) && st.st_size > PB626_DDX_FB_OFFSET &&
	    st.st_size <= PB626_DDX_FB_OFFSET + PB626_DDX_FB_MAX) {
		void *map = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
		if (map != MAP_FAILED) {
			ddx_fb = map;
			ddx_size = st.st_size;
		}
	}
	close(fd);
}

static XImage *ddx_image(Display *display, int x, int y, int width, int height)
{
	if (!ddx_fb || ImageByteOrder(display) != LSBFirst)
		return NULL;
	/* Serialize against software rendering and RandR resize; hold the
	 * grab only for a bounded strip, never across scanout or worker IPC. */
	XGrabServer(display);
	XSync(display, False);
	const struct pb626_ddx_fb *h = ddx_fb;
	int screen = DefaultScreen(display);
	Visual *visual = DefaultVisual(display, screen);
	if (ddx_layout(h, ddx_size, x, y, width, height) &&
	    h->width == (unsigned int)DisplayWidth(display, screen) &&
	    h->height == (unsigned int)DisplayHeight(display, screen) &&
	    h->depth == (unsigned int)DefaultDepth(display, screen) &&
	    visual->red_mask == h->red && visual->green_mask == h->green &&
	    visual->blue_mask == h->blue) {
		const char *pixels = (const char *)h + PB626_DDX_FB_OFFSET;
		XImage *image = XCreateImage(display, visual, h->depth, ZPixmap, 0,
					    (char *)pixels + (size_t)y * h->stride + x * (h->bpp / 8),
					    width, height, 32, h->stride);
		if (image) {
			if (image->bits_per_pixel == (int)h->bpp)
				return image;
			image->data = NULL;
			XDestroyImage(image);
		}
	}
	XUngrabServer(display);
	XFlush(display);
	return NULL;
}

static void finish_image(Display *display, XImage *image, int mapped)
{
	if (mapped)
		image->data = NULL; /* Xlib must not free the mapped storage. */
	XDestroyImage(image);
	if (mapped) {
		XUngrabServer(display);
		XFlush(display);
	}
}

static XImage *read_image(Display *display, Window root, int x, int y, int width, int height,
			  XShmSegmentInfo *shm, int *mapped)
{
	*mapped = 0;
	XImage *direct = ddx_image(display, x, y, width, height);
	if (direct) {
		*mapped = 1;
		return direct;
	}
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
	static uint8_t lightness[3][HEIGHT];
	uint16_t contrast[HEIGHT];
	const int w = logical_width(capture_rotation), h = logical_height(capture_rotation);
	int uses_contrast = gray_profile != GRAY_UI && gray_profile != GRAY_MONO;
	int draw_pointer = nonempty(pointer);
	struct rect area = clipped(dirty, uses_contrast);
	if (!nonempty(area))
		return 0;
	for (int top = area.top; top < area.bottom; top += CAPTURE_ROWS) {
		struct rect strip = area;
		strip.top = top;
		strip.bottom = top + CAPTURE_ROWS < area.bottom ? top + CAPTURE_ROWS : area.bottom;
		struct rect read_area = clipped(strip, uses_contrast);
		uint64_t start = now_us();
		int mapped;
		XImage *image = read_image(display, root, read_area.left + offset, read_area.top + capture_y_offset,
					  read_area.right - read_area.left, read_area.bottom - read_area.top,
					  shm, &mapped);
		if (!image)
			return -1;
		stats->read_us += now_us() - start;
		start = now_us();
		int rgbx = image->bits_per_pixel == 32 && image->byte_order == LSBFirst &&
			   image->red_mask == 0xff0000 && image->green_mask == 0xff00 &&
			   image->blue_mask == 0xff;
		int rgb565 = image->bits_per_pixel == 16 && image->byte_order == LSBFirst &&
			     image->red_mask == 0xf800 && image->green_mask == 0x07e0 &&
			     image->blue_mask == 0x001f;
		/* Decode each input row once into a three-row rolling luminance
		 * window. Quantize only when the next contrast row is available. */
		for (int y = read_area.top; y <= read_area.bottom; y++) {
			if (y < read_area.bottom) {
			const uint8_t *row = (const uint8_t *)image->data +
					     (y - read_area.top) * image->bytes_per_line;
			uint8_t *dest = lightness[y % 3];
			int count = read_area.right - read_area.left;
			if (rgb565)
				rgb565_gray_row(row, dest + read_area.left, count);
			else if (rgbx)
				rgbx_gray_row(row, dest + read_area.left, count);
			else for (int x = read_area.left; x < read_area.right; x++) {
				int column = x - read_area.left;
				unsigned long pixel = XGetPixel(image, column, y - read_area.top);
				dest[x] = gray_value(channel(pixel, image->red_mask),
						     channel(pixel, image->green_mask),
						     channel(pixel, image->blue_mask));
			}
			}
			int output_y = y - 1;
			if (output_y < strip.top || output_y >= strip.bottom)
				continue;
			if (uses_contrast) {
				const uint8_t *row = lightness[output_y % 3];
				contrast_row(row, output_y ? lightness[(output_y - 1) % 3] : row,
					     output_y + 1 < h ? lightness[(output_y + 1) % 3] : row,
					     contrast, strip.left, strip.right, w);
			}
			for (int x = strip.left; x < strip.right; x++) {
				const uint8_t *pixel = lightness[output_y % 3] + x;
				unsigned int value = *pixel;
				uint8_t next = value / 17;
				if (gray_profile == GRAY_MONO)
					next = value >= 128 ? WHITE : 0;
				else if (value != 17u * next) {
					size_t i = panel_index(capture_rotation, x, output_y);
					next = quantize(value, uses_contrast ? contrast[x] : 0, (int)(i % WIDTH), (int)(i / WIDTH));
				}
				size_t i = panel_index(capture_rotation, x, output_y);
				if (draw_pointer && !screen_locked)
					next = pointer_level(pointer, vertical, x, output_y, next);
				if (nibble_get(frame, i) != next) {
					stats->changed++;
					dirty_tiles[(i / WIDTH) / TILE][(i % WIDTH) / TILE] = 1;
					nibble_set(frame, i, next);
				}
			}
		}
		finish_image(display, image, mapped);
		stats->quant_us += now_us() - start;
	}
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
	uint64_t deadline;
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

enum { ACK_TIMEOUT_MS = 45000, EXIT_GRACE_MS = 1000, TERM_GRACE_MS = 2000, KILL_GRACE_MS = 2000 };

static int wait_child(pid_t pid, unsigned int timeout_ms)
{
	uint64_t deadline = now_us() + (uint64_t)timeout_ms * 1000;
	for (;;) {
		pid_t done = waitpid(pid, NULL, WNOHANG);
		if (done == pid || (done < 0 && errno == ECHILD))
			return 0;
		if (done < 0 && errno != EINTR)
			return -1;
		if (now_us() >= deadline)
			return -1;
		nanosleep(&(struct timespec){ .tv_nsec = 20000000L }, NULL);
	}
}

static int stop_worker(struct worker *worker)
{
	close(worker->socket);
	int result = wait_child(worker->pid, EXIT_GRACE_MS);
	if (result) {
		kill(worker->pid, SIGTERM);
		result = wait_child(worker->pid, TERM_GRACE_MS);
	}
	if (result) {
		kill(worker->pid, SIGKILL);
		result = wait_child(worker->pid, KILL_GRACE_MS);
	}
	munmap(worker->frame, sizeof(*worker->frame));
	if (result)
		fprintf(stderr, "pb626-x11-epd: worker cannot be reaped; refusing another panel owner\n");
	return result;
}

static int socket_ready(int fd, short events, uint64_t deadline)
{
	struct pollfd p = { .fd = fd, .events = events };
	for (;;) {
		uint64_t now = now_us();
		if (now >= deadline) {
			errno = ETIMEDOUT;
			return -1;
		}
		int ready = poll(&p, 1, (int)((deadline - now + 999) / 1000));
		if (ready < 0 && errno == EINTR)
			continue;
		if (ready > 0 && (p.revents & events))
			return 0;
		errno = ready == 0 ? ETIMEDOUT : EIO;
		return -1;
	}
}

static int send_command(struct worker *worker, uint8_t command)
{
	worker->deadline = now_us() + (uint64_t)ACK_TIMEOUT_MS * 1000;
	for (;;) {
		if (socket_ready(worker->socket, POLLOUT, worker->deadline))
			return -1;
		ssize_t done = send(worker->socket, &command, 1, MSG_NOSIGNAL | MSG_DONTWAIT);
		if (done < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
			continue;
		return done == 1 ? 0 : -1;
	}
}

static int await_ack(const struct worker *worker, uint8_t command)
{
	for (;;) {
		if (socket_ready(worker->socket, POLLIN, worker->deadline)) {
			fprintf(stderr, "pb626-x11-epd: ACK %c failed: %s\n", command, strerror(errno));
			return -1;
		}
		uint8_t ack;
		ssize_t done = recv(worker->socket, &ack, 1, MSG_DONTWAIT);
		if (done < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
			continue;
		return done == 1 && ack == command ? 0 : -1;
	}
}

static int submit(struct worker *worker, uint8_t command)
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
                    unsigned int old = nibble_get(panel, i), level = sample & WHITE;
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
static uint8_t fast_changes[PACKED_PIXELS];
_Static_assert(CLEAN_AFTER <= 15, "ghosting counter fits a nibble");
static uint16_t cleanup_pixels[TILE_ROWS][TILE_COLS];
static int clean_halo = 1;
enum halo_filter { HALO_NONE, HALO_HQ, HALO_SHADOW };
static enum halo_filter cleanup_filter;
static unsigned int shadow_stage;

/* Factory-inspired white->white pulse suppression, only for the optional
 * same-level halo. Never skip a changed pixel or a mandatory scrub.
 * Anchor the Shadow mask in physical panel coordinates, not the damage
 * rectangle, so overlapping XDamage regions cannot move the pattern. */
static int halo_allowed(const uint8_t *panel, int x, int y,
			enum halo_filter filter, unsigned int stage)
{
	if (filter == HALO_NONE || nibble_get(panel, y * WIDTH + x) != WHITE)
		return 1;
	if (filter == HALO_HQ) {
		/* No assumptions about the stock driver's padded border. */
		if (!x || x == WIDTH - 1 || !y || y == HEIGHT - 1)
			return 1;
		size_t i = y * WIDTH + x;
		return nibble_get(panel, i - 1) != WHITE ||
		       nibble_get(panel, i + 1) != WHITE ||
		       nibble_get(panel, i - WIDTH) != WHITE ||
		       nibble_get(panel, i + WIDTH) != WHITE;
	}
	/* The stock LUT is gate-major, with alternating mask bytes on
	 * one row and all FF on the other. It shifts the alternating
	 * mask by one byte per eight sources and per pair of gates. */
	unsigned int gate = WIDTH - 1 - x, source = y;
	return (gate & 1) == ((stage >> 1) & 1) &&
	       ((source ^ (source / 8) ^ (gate / 2) ^ stage) & 1);
}

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
	if (nibble_get(fast_changes, pixel) == CLEAN_AFTER)
		return 1;
	if (!clean_halo || !halo_allowed(panel, x, y, cleanup_filter, shadow_stage))
		return 0;

	/* The reference chart showed a residual outline just beyond the changed
	 * pixels. Include a one-pixel border on the same shade of paper.
	 */
	for (int ny = y ? y - 1 : y; ny <= y + 1 && ny < HEIGHT; ny++)
		for (int nx = x ? x - 1 : x; nx <= x + 1 && nx < WIDTH; nx++) {
			size_t neighbor = ny * WIDTH + nx;
			if (nibble_get(fast_changes, neighbor) == CLEAN_AFTER && nibble_get(panel, neighbor) == nibble_get(panel, pixel))
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

/* A continuous stream of fast ACKs must not indefinitely starve gray
 * pixels. A completed binary preview clears the pending age, while an
 * incomplete preview keeps the age of the unresolved frame. */
static uint8_t bound_preview(uint8_t command, uint64_t age_us)
{
	if ((command == PREVIEW || command == PREVIEW_DU4) && age_us >= MAX_PENDING_US)
		return SETTLE;
	return command;
}

static int dirty_tiles_pending(void)
{
	for (int y = 0; y < TILE_ROWS; y++)
		for (int x = 0; x < TILE_COLS; x++)
			if (dirty_tiles[y][x])
				return 1;
	return 0;
}

/* The factory DU4 supports arbitrary old levels but only four targets.
 * Use it automatically only when it can represent every changed target
 * exactly, including at least one nonbinary level. Unchanged gray
 * pixels in a dirty tile must never be approximated. */
static int exact_du4_candidate(const uint8_t *desired, const uint8_t *panel)
{
	int gray = 0;
	for (int ty = 0; ty < TILE_ROWS; ty++)
		for (int tx = 0; tx < TILE_COLS; tx++) {
			if (!dirty_tiles[ty][tx])
				continue;
			int right, bottom;
			tile_bounds(tx, ty, &right, &bottom);
			for (int y = ty * TILE; y < bottom; y++)
				for (int x = tx * TILE; x < right; x++) {
					size_t i = y * WIDTH + x;
					unsigned int target = nibble_get(desired, i);
					if (target == nibble_get(panel, i))
						continue;
					if (target % 5)
						return 0;
					gray |= target != 0 && target != WHITE;
				}
		}
	return gray;
}

static unsigned int prepare(uint8_t command, const uint8_t *desired, const uint8_t *panel,
			    struct shared_frame *frame)
{
	unsigned int changes = 0;
	if (command == RESET) {
		memset(frame->tiles, 1, sizeof(frame->tiles));
		for (size_t i = 0; i < PIXELS; i++)
			frame->pixels[i] = nibble_get(desired, i) | SCRUB;
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
					uint8_t target = nibble_get(desired, i), old = nibble_get(panel, i);
					int scrub = command == CLEAN && target == old && needs_scrub(panel, x, y);
					uint8_t level = target;
					differs |= target != old;
					if (command == PREVIEW || command == PREVIEW_A2)
                        level = abs(target - old) >= 3 ? preview_level(target, old) : old;
                    else if (command == PREVIEW_DU4)
                        level = target != old ? preview_level4(target) : old;
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
		memcpy(panel, desired, PACKED_PIXELS);
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
						differs |= nibble_get(panel, i) != nibble_get(desired, i);
						continue;
					}
					uint8_t level = sample & WHITE;
					differs |= level != nibble_get(desired, i);
					if (sample & SCRUB) {
						if (nibble_get(fast_changes, i) == CLEAN_AFTER)
							cleanup_pixels[ty][tx]--;
						nibble_set(fast_changes, i, 0);
					} else if ((command == PREVIEW || command == PREVIEW_A2 ||
                             command == PREVIEW_DU4) && nibble_get(panel, i) != level &&
                             nibble_get(fast_changes, i) < CLEAN_AFTER) {
						nibble_set(fast_changes, i, nibble_get(fast_changes, i) + 1);
						if (nibble_get(fast_changes, i) == CLEAN_AFTER)
							cleanup_pixels[ty][tx]++;
					}
					nibble_set(panel, i, level);
				}
			dirty_tiles[ty][tx] = differs;
		}
	if (command == CLEAN && cleanup_filter == HALO_SHADOW)
		shadow_stage = (shadow_stage + 1) & 3;
}

/* Root-only socket in the existing root-owned runtime directory. The
 * same binary provides a bounded systemd client; no new resident daemon. */
#define SLEEP_SOCKET "/run/pb626-desktop/sleep.sock"
enum { SLEEP_IPC_MS = 110000 };
static int sleep_listener(void)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX, .sun_path = SLEEP_SOCKET };
	int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0) return -1;
	unlink(SLEEP_SOCKET);
	if (bind(fd, (struct sockaddr *)&address, sizeof(address)) ||
	    chmod(SLEEP_SOCKET, 0600) || listen(fd, 2)) {
		close(fd);
		unlink(SLEEP_SOCKET);
		return -1;
	}
	return fd;
}
static int sleep_client(uint8_t request)
{
	struct sockaddr_un address = { .sun_family = AF_UNIX, .sun_path = SLEEP_SOCKET };
	int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (fd < 0) return EXIT_FAILURE;
	uint8_t reply = 0;
	int result = connect(fd, (struct sockaddr *)&address, sizeof(address)) ||
		     send(fd, &request, 1, MSG_NOSIGNAL) != 1 ||
		     socket_ready(fd, POLLIN, now_us() + (uint64_t)SLEEP_IPC_MS * 1000) ||
		     recv(fd, &reply, 1, MSG_DONTWAIT) != 1 || reply != request;
	close(fd);
	if (result) fprintf(stderr, "pb626: sleep IPC %c failed or timed out\n", request);
	return result ? EXIT_FAILURE : EXIT_SUCCESS;
}
static void sleep_reply(int *fd, uint8_t reply)
{
	if (*fd < 0) return;
	(void)send(*fd, &reply, 1, MSG_NOSIGNAL | MSG_DONTWAIT);
	close(*fd);
	*fd = -1;
}
static int sleep_request(int listener, uint8_t *request)
{
	int fd = accept(listener, NULL, NULL);
	if (fd < 0) return -1;
	if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
	    socket_ready(fd, POLLIN, now_us() + 1000000ULL) ||
	    recv(fd, request, 1, MSG_DONTWAIT) != 1) {
		close(fd);
		return -1;
	}
	return fd;
}
static void prepare_sleep_frame(struct shared_frame *frame, const uint8_t *panel,
				enum pb_rotation rotation)
{
	const char *path = logical_width(rotation) > logical_height(rotation) ?
		"/lib/firmware/pb626/sleep-landscape.pb" : "/lib/firmware/pb626/sleep-portrait.pb";
	uint8_t *bitmap = NULL;
	size_t size = 0;
	FILE *f = fopen(path, "rb");
	if (f) {
		if (!fseek(f, 0, SEEK_END)) {
			long length = ftell(f);
			if (length > 0 && length <= 500000 && !fseek(f, 0, SEEK_SET)) {
				bitmap = malloc((size_t)length);
				if (bitmap && fread(bitmap, 1, (size_t)length, f) == (size_t)length)
					size = (size_t)length;
			}
		}
		fclose(f);
	}
	if (!sleep_bitmap_valid(bitmap, size, rotation))
		fprintf(stderr, "pb626: stock sleep bitmap unavailable (%s); using blur only\n", path);
	memset(frame->tiles, 1, sizeof(frame->tiles));
	sleep_compose(panel, frame->pixels, bitmap, size, rotation);
	free(bitmap);
}
static void acknowledge_sleep_frame(const struct shared_frame *frame, uint8_t *panel)
{
	for (size_t i = 0; i < PIXELS; i++)
		nibble_set(panel, i, frame->pixels[i]);
	memset(fast_changes, 0, sizeof(fast_changes));
	memset(cleanup_pixels, 0, sizeof(cleanup_pixels));
	memset(dirty_tiles, 0, sizeof(dirty_tiles));
}

int main(int argc, char **argv)
{
	if (argc == 2 && !strcmp(argv[1], "--sleep-prepare")) return sleep_client('P');
	if (argc == 2 && !strcmp(argv[1], "--sleep-resume")) return sleep_client('R');
	if (argc != 3) {
		fprintf(stderr, "Usage: pb626-x11-epd DEFAULT.WBF READY\n");
		return EXIT_FAILURE;
	}
	static const char *const profiles[] = {"balanced", "ui", "photo", "legacy", "mono"};
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
            fprintf(stderr, "pb626-x11-epd: fast mode must be du, auto, a2, or du4\n");
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
	Window root = RootWindow(display, screen);
	int offset = 0;
	if (screen_geometry(display, root, &offset)) {
		fprintf(stderr, "pb626-x11-epd: unexpected Xorg dimensions or rotation\n");
		stop_worker(&worker);
		return EXIT_FAILURE;
	}
	enum pb_rotation panel_rotation = capture_rotation;
	XSetErrorHandler(handle_x_error);
	XSelectInput(display, root, PropertyChangeMask | StructureNotifyMask);
	int randr_event, randr_error;
	int randr = XRRQueryExtension(display, &randr_event, &randr_error);
	if (randr)
		XRRSelectInput(display, root, RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask | RROutputChangeNotifyMask);
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
	const char *keys = getenv("PB626_BUTTONS");
	const char *home = getenv("PB626_HOME_KEY");
	const char *menu = getenv("PB626_MENU_KEY");
	struct controls controls = {
		.fallback = getenv("PB626_POINTER_FALLBACK") != NULL,
		.page_keys = keys && !strcmp(keys, "pages"),
		.home_key = home && !strcmp(home, "home"),
		.menu_escape = menu && !strcmp(menu, "escape"),
	};
	controls.custom_buttons = load_button_bindings(&controls);
	struct pollfd sources[8] = {{ .fd = ConnectionNumber(display), .events = POLLIN }};
	nfds_t source_count = 1;
	const char *devices = getenv("PB626_BUTTON_DEVICES");
	char *paths = devices ? strdup(devices) : NULL;
	for (char *path = paths ? strtok(paths, " ") : NULL;
	     path && source_count + 2 < sizeof(sources) / sizeof(sources[0]); path = strtok(NULL, " ")) {
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd >= 0)
			sources[source_count++] = (struct pollfd){ .fd = fd, .events = POLLIN };
	}
	free(paths);
	nfds_t power_index = 0;
	const char *power_device = getenv("PB626_POWER_DEVICE");
	if (power_device && source_count < sizeof(sources) / sizeof(sources[0])) {
		int fd = open(power_device, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd >= 0) {
			power_index = source_count;
			sources[source_count++] = (struct pollfd){ .fd = fd, .events = POLLIN };
		}
	}
	uint64_t power_pressed = 0;
	int lock_pending = 0, system_sleep = 0;
	int sleep_fd = -1, geometry_changed = 0;
	nfds_t sleep_index = 0;
	if (getenv("PB626_SYSTEM_SLEEP")) {
		int fd = sleep_listener();
		if (fd < 0) goto failed;
		sleep_index = source_count;
		sources[source_count++] = (struct pollfd){ .fd = fd, .events = POLLIN };
	}
	static uint8_t frame[PACKED_PIXELS], previous[PACKED_PIXELS];
	struct rect full = {0, 0, logical_width(capture_rotation), logical_height(capture_rotation)};
	struct rect pointer = {0};
	const char *halo = getenv("PB626_EPD_CLEAN_HALO");
	clean_halo = !halo || strcmp(halo, "0");
	const char *filter = getenv("PB626_EPD_HALO_FILTER");
	if (filter && strcmp(filter, "none")) {
		if (access("/etc/pb626/halo-filter-qualified", F_OK)) {
			fprintf(stderr, "pb626: ignoring unqualified halo filter\n");
		} else if (!strcmp(filter, "hq")) {
			cleanup_filter = HALO_HQ;
		} else if (!strcmp(filter, "shadow")) {
			cleanup_filter = HALO_SHADOW;
		} else {
			fprintf(stderr, "pb626: unknown halo filter; using unfiltered cleanup\n");
		}
	}
	XShmSegmentInfo shm = {0};
	setup_ddx();
	if (!ddx_fb)
		setup_shm(display, &shm);
	int precleared = init_sent && await_ack(&worker, INIT_PANEL) == 0;
	if (marker && profile)
		fprintf(stderr, "preclear: %s mono_us=%llu\n",
			precleared ? "INIT_ACK" : "FALLBACK_RESET", (unsigned long long)now_us());
	if (marker && !precleared) {
		if (stop_worker(&worker))
			return EXIT_FAILURE;
		if (start_worker(&worker, argv[1]))
			return EXIT_FAILURE;
	}
	if (profile)
		fprintf(stderr, "x11-epd: capture=%s gray=%s tone=%s gamma=%.2f fast=%s\n",
                ddx_fb ? "DDX-map (with XGetImage fallback)" :
                shm.shmaddr ? "MIT-SHM" : "XGetImage", profiles[selected],
                lightness ? "cie-lstar" : "srgb", gamma,
                fast_mode == FAST_A2 ? "a2" : fast_mode == FAST_DU4 ? "du4" :
                fast_mode == FAST_AUTO ? "auto" : "du");
	/* Reallocation under memory pressure needs physical qualification.
	 * No new polling timer when this experiment is disabled. */
	const int release_idle = access("/etc/pb626/dma-release-qualified", F_OK) == 0;
	const uint64_t dma_idle_us = 30000000;
	uint64_t last_update = now_us();
	int queue_released = 0;
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
				if (!screen_locked || lock_pending) dirty = 1;
			} else if (event.type == ConfigureNotify ||
				   (randr && (event.type == randr_event + RRScreenChangeNotify ||
					      event.type == randr_event + RRNotify))) {
				if (randr && event.type == randr_event + RRScreenChangeNotify)
					XRRUpdateConfiguration(&event);
				geometry_changed = 1;
			} else if (event.type == PropertyNotify && event.xproperty.atom == active)
				focus_changed = 1;
			else if (!screen_locked && event.type == KeyPress && event.xkey.keycode == toggle) {
				keyboard_command(display, root, keyboard, KEYBOARD_TOGGLE);
				controls.keyboard_changed = 1;
			}
		}
		if (focus_changed && !screen_locked) {
			keyboard_focus(display, root, active, keyboard, &previous_window, &controls);
			focus_changed = 0;
		}
		if (sleep_index && sources[sleep_index].fd >= 0) {
			uint8_t request = 0;
			int client = sleep_request(sources[sleep_index].fd, &request);
			if (client >= 0) {
				if (sleep_fd >= 0) {
					sleep_reply(&client, 0);
				} else if (request == 'P' && has_frame &&
					   (screen_locked || !grab_lock(display, root))) {
					system_sleep = 1;
					/* Consume button edges preceding the system transaction.
					 * A release after wake without a new press cannot toggle. */
					if (power_index && sources[power_index].fd >= 0)
						(void)power_press(sources[power_index].fd, &power_pressed);
					power_pressed = 0;
					if (!screen_locked) {
						screen_locked = 1;
						lock_pending = 1;
						controls.menu_pressed = 0;
					}
					if (lock_pending)
						sleep_fd = client;
					else {
						if (release_idle && !queue_released) {
							if (submit(&worker, RELEASE_QUEUE)) {
								sleep_reply(&client, 0);
								goto failed;
							}
							queue_released = 1;
						}
						sleep_reply(&client, power_action("lock-indicator", "sleep") ? 0 : 'P');
					}
				} else if (request == 'R') {
					if (system_sleep) {
						system_sleep = 0;
						screen_locked = 0;
						release_lock(display);
						XResetScreenSaver(display);
						if (power_index && sources[power_index].fd >= 0)
							(void)power_press(sources[power_index].fd, &power_pressed);
						power_pressed = 0;
						focus_changed = 1;
						lock_pending = dirty = 1;
						geometry_changed = 1;
						next_capture = layout_until = 0;
						sleep_fd = client;
					} else {
						sleep_reply(&client, 'R');
					}
				} else {
					sleep_reply(&client, 0);
				}
			}
		}
		if (power_index && sources[power_index].fd >= 0) {
			int presses = power_press(sources[power_index].fd, &power_pressed);
			if ((presses & 1) && !system_sleep && has_frame) {
				enum power_policy policy = power_policy();
				if (screen_locked) {
					screen_locked = 0;
					release_lock(display);
					XResetScreenSaver(display);
					geometry_changed = 1;
					focus_changed = 1;
					lock_pending = dirty = 1;
				} else if (policy == POWER_OFF) {
					(void)power_action("poweroff", NULL);
				} else if (policy == POWER_S2IDLE) {
					/* systemd's required prepare unit owns the lock/filter
					 * transaction. A refused request does not lock X11. */
					if (power_action("suspend", NULL))
						fprintf(stderr, "pb626: system suspend request refused\n");
				} else if (policy == POWER_LOCK && !grab_lock(display, root)) {
					screen_locked = 1;
					controls.menu_pressed = 0;
					lock_pending = dirty = 1;
				}
				if (lock_pending)
					next_capture = layout_until = 0;
			}
		}
		int pointer_changed = 0;
		for (nfds_t i = 1; i < source_count; i++)
			if (i != power_index && i != sleep_index && sources[i].fd >= 0)
				pointer_changed |= handle_buttons(display, root, keyboard, sources[i].fd, &controls);
		if (controls.custom_buttons && !controls.fallback)
			pointer_changed |= flush_bindings(display, root, keyboard, &controls, now_us());
		if (screen_locked && lock_pending && has_frame) {
			/* Filter the last acknowledged physical frame, not X11.
			 * One GC16 update; RESET would run INIT. */
			prepare_sleep_frame(worker.frame, previous, panel_rotation);
			if (submit(&worker, CLEAN)) {
				sleep_reply(&sleep_fd, 0);
				goto failed;
			}
			acknowledge_sleep_frame(worker.frame, previous);
			last_update = now_us();
			queue_released = 0;
			if (release_idle && system_sleep) {
				if (submit(&worker, RELEASE_QUEUE)) {
					sleep_reply(&sleep_fd, 0);
					goto failed;
				}
				queue_released = 1;
			}
			lock_pending = dirty = pending = cleanup_count = 0;
			controls.clean_requested = 0;
			int indicator_error = power_action("lock-indicator", system_sleep ? "sleep" : "locked");
			if (indicator_error && system_sleep) {
				/* Reject preparation. ExecStopPost will restore X11;
				 * the PM core must not suspend on a failed preparation. */
				sleep_reply(&sleep_fd, 0);
			} else {
				sleep_reply(&sleep_fd, 'P');
			}
		}
		if (!screen_locked && geometry_changed) {
			enum pb_rotation old = capture_rotation;
			int old_x = offset, old_y = capture_y_offset;
			if (screen_geometry(display, root, &offset))
				goto failed;
			full = (struct rect){0, 0, logical_width(capture_rotation), logical_height(capture_rotation)};
			if (old != capture_rotation || old_x != offset || old_y != capture_y_offset) {
				lock_pending = dirty = 1;
				next_capture = layout_until = 0;
				pointer = (struct rect){0};
			}
			geometry_changed = 0;
		}
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
		if (screen_locked && !lock_pending) {
			dirty = pending = cleanup_count = 0;
			goto wait_input;
		}
		if ((dirty || !damage) && now >= next_capture && now >= layout_until) {
			struct rect areas[MAX_REGIONS];
			int count = 0;
			if (damage && capture_rotation == PB_ROT_0 && !capture_y_offset)
				count = damage_regions(display, damage, region, offset, areas);
			else if (damage)
				XDamageSubtract(display, damage, None, None);
			if (!has_frame || !damage || controls.clean_requested || lock_pending ||
			    capture_rotation != PB_ROT_0 || capture_y_offset) {
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

		uint8_t command = captured && (!has_frame || controls.clean_requested || lock_pending) ? RESET :
            automatic_command(now - last_damage, dirty || now < layout_until,
                              captured, different, cleanup_count);
        if (command == PREVIEW &&
            (fast_mode == FAST_DU4 ||
             (fast_mode == FAST_AUTO && exact_du4_candidate(frame, previous))))
            command = PREVIEW_DU4;

		command = bound_preview(command, pending ? now - pending_since : 0);
		uint64_t prepare_start = now_us();
		unsigned int changes = command ? prepare(command, frame, previous, worker.frame) : 0;
		/* A2 only when every changed pixel is an exact binary transition. */
        if (changes && command == PREVIEW && (fast_mode == FAST_A2 || fast_mode == FAST_AUTO) &&
            a2_eligible(worker.frame, previous))
            command = PREVIEW_A2;
        uint64_t submit_start = now_us();
		if (changes) {
			uint8_t wire = command;
			if (lock_pending && has_frame && command == RESET && !controls.clean_requested) {
				/* Rebuild actual X11 frame using known sleep history. */
				wire = CLEAN;
				for (size_t i = 0; i < PIXELS; i++)
					worker.frame->pixels[i] &= WHITE;
			}
			if (precleared && !has_frame && command == RESET && !controls.clean_requested)
				wire = CLEAN;
			precleared = 0;
			if (profile && !has_frame)
				fprintf(stderr, "preclear: first wire=%c mono_us=%llu\n", wire, (unsigned long long)now_us());
			if (submit(&worker, wire)) {
				sleep_reply(&sleep_fd, 0);
				unlink(argv[2]);
				if (stop_worker(&worker))
					return EXIT_FAILURE;
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
			last_update = now_us();
			queue_released = 0;
			panel_rotation = capture_rotation;
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
			/* ACK is progress, but only a fully resolved frame clears
			 * the starvation deadline. Binary-only motion remains fast. */
			pending = dirty_tiles_pending();
			if (!pending)
				pending_since = 0;
		}
		if (lock_pending && captured && command == RESET && !screen_locked) {
			lock_pending = 0;
			int indicator_error = power_action("lock-indicator", "awake");
			sleep_reply(&sleep_fd, indicator_error ? 0 : 'R');
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
		if (release_idle && has_frame && !queue_released && !dirty && !pending &&
		    !cleanup_count && !lock_pending && damage) {
			uint64_t release_due = last_update + dma_idle_us;
			if (now >= release_due) {
				if (submit(&worker, RELEASE_QUEUE))
					goto failed;
				queue_released = 1;
			} else {
				deadline = release_due;
			}
		}
		if ((!screen_locked || lock_pending) && (dirty || !damage)) {
			uint64_t capture_due = next_capture > layout_until ? next_capture : layout_until;
			if (capture_due < deadline) deadline = capture_due;
		}
		if ((pending || cleanup_count) && has_frame && !dirty) {
			uint64_t settle = last_damage + (pending ? QUIET_US : cleanup_delay(cleanup_count));
			if (settle < layout_until)
				settle = layout_until;
			if (settle < deadline)
				deadline = settle;
		}
		if (controls.custom_buttons && !controls.fallback) {
			uint64_t keys_due = binding_deadline(&controls);
			if (keys_due < deadline) deadline = keys_due;
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
	sleep_reply(&sleep_fd, 0);
	if (sleep_index) unlink(SLEEP_SOCKET);
	unlink(argv[2]);
	stop_worker(&worker);
	return EXIT_FAILURE;
}
