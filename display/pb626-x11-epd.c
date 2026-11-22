/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/keysym.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/XTest.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { WIDTH = 758, HEIGHT = 1024, PIXELS = WIDTH * HEIGHT };
enum { FULL_INTERVAL = 16, CLEAN_INTERVAL = 96, MENU_HOLD_US = 1000000 };
enum { KEYBOARD_SHOW = 1, KEYBOARD_HIDE, KEYBOARD_TOGGLE };

struct controls {
	int fallback, vertical, pointer_visible, clean_requested;
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
			   Window *previous)
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
				else
					keyboard_command(display, root, keyboard, KEYBOARD_TOGGLE);
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

static void draw_pointer(Display *display, Window root, int offset, int vertical,
			 uint8_t *frame)
{
	Window root_return, child;
	int x, y, window_x, window_y;
	unsigned int modifiers;
	if (!XQueryPointer(display, root, &root_return, &child,
			  &x, &y, &window_x, &window_y, &modifiers))
		return;
	x -= offset;
	for (int dy = -5; dy <= 5; dy++) {
		for (int dx = -5; dx <= 5; dx++) {
			if (x + dx < 0 || x + dx >= WIDTH || y + dy < 0 || y + dy >= HEIGHT)
				continue;
			if ((vertical && abs(dx) <= 2) || (!vertical && abs(dy) <= 2))
				frame[(y + dy) * WIDTH + x + dx] =
					abs(dx) <= 1 && abs(dy) <= 1 ? 15 : 0;
		}
	}
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

static uint8_t paper_level(unsigned int value, const uint8_t *pixel, int x, int y)
{
	if (value <= 33)
		return 0;
	if (value >= 222)
		return 15;

	unsigned int neighbors[] = {
		x > 0 ? pixel[-1] : value,
		x + 1 < WIDTH ? pixel[1] : value,
		y > 0 ? pixel[-WIDTH] : value,
		y + 1 < HEIGHT ? pixel[WIDTH] : value,
	};
	unsigned int darkest = value, lightest = value, sum = 0;
	for (size_t i = 0; i < sizeof(neighbors) / sizeof(neighbors[0]); i++) {
		unsigned int shade = neighbors[i];
		if (shade < darkest)
			darkest = shade;
		if (shade > lightest)
			lightest = shade;
		sum += shade;
	}

	/* Keep flat fills monochrome. Give high-contrast edges two intermediate
	 * levels, using the neighborhood to handle light lettering on dark fills.
	 */
	if (lightest - darkest < 64)
		return value < 180 ? 0 : 15;
	int dark_background = sum < 4 * 128;
	unsigned int shade = dark_background ? 255 - value : value;
	uint8_t level = shade < 157 ? 0 : shade < 194 ? 4 : shade < 222 ? 10 : 15;
	return dark_background ? 15 - level : level;
}

static void capture(const XImage *image, uint8_t *frame)
{
	static uint8_t lightness[PIXELS];
	int x_offset = (image->width - WIDTH) / 2;
	int rgbx = image->bits_per_pixel == 32 && image->byte_order == LSBFirst &&
		   image->red_mask == 0xff0000 && image->green_mask == 0xff00 &&
		   image->blue_mask == 0xff;
	for (int y = 0; y < HEIGHT; y++) {
		const uint8_t *row = (const uint8_t *)image->data + y * image->bytes_per_line;
		for (int x = 0; x < WIDTH; x++) {
			unsigned int r, g, b;
			if (rgbx) {
				const uint8_t *color = row + (x + x_offset) * 4;
				b = color[0];
				g = color[1];
				r = color[2];
			} else {
				unsigned long pixel = XGetPixel((XImage *)image, x + x_offset, y);
				r = channel(pixel, image->red_mask);
				g = channel(pixel, image->green_mask);
				b = channel(pixel, image->blue_mask);
			}
			/* Darken saturated colors to keep colored labels legible. */
			unsigned int low = r < g ? r : g;
			if (b < low)
				low = b;
			lightness[y * WIDTH + x] = (57 * r + 112 * g + 23 * b + 64 * low) >> 8;
		}
	}
	for (int y = 0; y < HEIGHT; y++)
		for (int x = 0; x < WIDTH; x++) {
			size_t offset = y * WIDTH + x;
			frame[offset] = paper_level(lightness[offset], lightness + offset, x, y);
		}
}

static int update_panel(const char *waveform, const char *mode, const char *path)
{
	pid_t pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execl("/usr/bin/pb626-epd", "pb626-epd", waveform, mode, path, (char *)NULL);
		_exit(127);
	}
	int status;
	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int paint(const char *waveform, const char *mode, const char *path,
		 const uint8_t *frame, int clean)
{
	FILE *file = fopen(path, "wb");
	if (!file)
		return -1;
	int saved = fprintf(file, "P5\n%d %d\n15\n", WIDTH, HEIGHT) > 0 &&
		    fwrite(frame, 1, PIXELS, file) == PIXELS;
	if (fclose(file) || !saved)
		return -1;

	if (clean && update_panel(waveform, "reset", NULL))
		return -1;
	return update_panel(waveform, mode, path);
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "Usage: pb626-x11-epd DEFAULT.WBF FRAME.pgm\n");
		return EXIT_FAILURE;
	}
	Display *display = XOpenDisplay(NULL);
	if (!display) {
		fprintf(stderr, "pb626-x11-epd: cannot connect to Xorg\n");
		return EXIT_FAILURE;
	}
	int screen = DefaultScreen(display);
	int width = DisplayWidth(display, screen);
	if (width < WIDTH || DisplayHeight(display, screen) != HEIGHT) {
		fprintf(stderr, "pb626-x11-epd: unexpected Xorg screen dimensions\n");
		return EXIT_FAILURE;
	}

	Window root = RootWindow(display, screen);
	XSetErrorHandler(handle_x_error);
	XSelectInput(display, root, PropertyChangeMask);
	Atom active = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
	Atom keyboard = XInternAtom(display, "_MB_IM_INVOKER_COMMAND", False);
	KeyCode toggle = XKeysymToKeycode(display, XK_F12);
	if (toggle)
		XGrabKey(display, toggle, AnyModifier, root, False, GrabModeAsync, GrabModeAsync);
	int damage_event, damage_error;
	Damage damage = XDamageQueryExtension(display, &damage_event, &damage_error) ?
			XDamageCreate(display, root, XDamageReportNonEmpty) : None;
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
	unsigned int partials = FULL_INTERVAL;
	unsigned int updates = 0;
	unsigned int failures = 0;
	int dirty = 1, focus_changed = 1, has_frame = 0;
	const struct timespec interval = { .tv_nsec = 250000000L };
	for (;;) {
		XEvent event;
		while (XPending(display)) {
			XNextEvent(display, &event);
			if (damage && event.type == damage_event + XDamageNotify)
				dirty = 1;
			else if (event.type == PropertyNotify && event.xproperty.atom == active)
				focus_changed = 1;
			else if (event.type == KeyPress && event.xkey.keycode == toggle)
				keyboard_command(display, root, keyboard, KEYBOARD_TOGGLE);
		}
		if (focus_changed) {
			keyboard_focus(display, root, active, keyboard, &previous_window);
			focus_changed = 0;
		}
		for (nfds_t i = 1; i < source_count; i++)
			if (sources[i].fd >= 0)
				dirty |= handle_buttons(display, root, keyboard, sources[i].fd, &controls);
		if (damage && !dirty) {
			XFlush(display);
			if (XPending(display))
				continue;
			if (poll(sources, source_count, -1) < 0) {
				if (errno == EINTR)
					continue;
				return EXIT_FAILURE;
			}
			const short disconnected = POLLERR | POLLHUP | POLLNVAL;
			if (sources[0].revents & disconnected)
				return EXIT_FAILURE;
			for (nfds_t i = 1; i < source_count; i++) {
				if (sources[i].revents & disconnected) {
					close(sources[i].fd);
					sources[i].fd = -1;
				}
			}
			continue;
		}
		if (damage)
			XDamageSubtract(display, damage, None, None);
		dirty = 0;
		XImage *image = XGetImage(display, root, 0, 0, width, HEIGHT, AllPlanes, ZPixmap);
		if (!image)
			return EXIT_FAILURE;
		capture(image, frame);
		XDestroyImage(image);
		if (controls.pointer_visible)
			draw_pointer(display, root, (width - WIDTH) / 2, controls.vertical, frame);

		unsigned int changed = 0;
		for (size_t i = 0; i < PIXELS; i++)
			changed += frame[i] != previous[i];
		int clean = controls.clean_requested || failures || updates >= CLEAN_INTERVAL - 1;
		if (controls.clean_requested || failures || !has_frame || changed) {
			int full = clean || partials >= FULL_INTERVAL || changed >= PIXELS / 4;
			if (paint(argv[1], full ? "full" : "partial", argv[2], frame, clean)) {
				if (++failures == 3) {
					fprintf(stderr, "pb626-x11-epd: the panel rejected three updates\n");
					return EXIT_FAILURE;
				}
				partials = FULL_INTERVAL;
				dirty = 1;
				sleep(1);
			} else {
				failures = 0;
				controls.clean_requested = 0;
				has_frame = 1;
				memcpy(previous, frame, PIXELS);
				partials = full ? 0 : partials + 1;
				updates = clean ? 0 : updates + 1;
			}
		}
		nanosleep(&interval, NULL);
	}
}
