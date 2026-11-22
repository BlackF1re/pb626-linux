/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { WIDTH = 758, HEIGHT = 1024, PIXELS = WIDTH * HEIGHT, FULL_INTERVAL = 24 };

static void move_pointer(Display *display, int fd, int *vertical)
{
	struct input_event event;
	while (read(fd, &event, sizeof(event)) == (ssize_t)sizeof(event)) {
		if (event.type != EV_KEY || !event.value)
			continue;
		switch (event.code) {
		case KEY_HOME:
			if (event.value == 1)
				*vertical = !*vertical;
			break;
		case KEY_MENU:
			if (event.value == 1) {
				XTestFakeButtonEvent(display, 1, True, CurrentTime);
				XTestFakeButtonEvent(display, 1, False, CurrentTime);
			}
			break;
		case KEY_LEFT:
		case KEY_RIGHT: {
			int step = event.value == 1 ? 12 : 28;
			if (event.code == KEY_LEFT)
				step = -step;
			XTestFakeRelativeMotionEvent(display, *vertical ? 0 : step,
						     *vertical ? step : 0, CurrentTime);
			break;
		}
		}
	}
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

static void capture(const XImage *image, uint8_t *frame)
{
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
			frame[y * WIDTH + x] = ((77 * r + 150 * g + 29 * b) * 15 + 32640) / 65280;
		}
	}
}

static int paint(const char *waveform, const char *mode, const char *path,
		 const uint8_t *frame)
{
	FILE *file = fopen(path, "wb");
	if (!file)
		return -1;
	int saved = fprintf(file, "P5\n%d %d\n15\n", WIDTH, HEIGHT) > 0 &&
		    fwrite(frame, 1, PIXELS, file) == PIXELS;
	if (fclose(file) || !saved)
		return -1;

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
	int buttons[2], button_count = 0, vertical = 0;
	const char *devices = getenv("PB626_BUTTON_DEVICES");
	char *paths = devices ? strdup(devices) : NULL;
	for (char *path = paths ? strtok(paths, " ") : NULL;
	     path && button_count < 2; path = strtok(NULL, " ")) {
		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd >= 0)
			buttons[button_count++] = fd;
	}
	free(paths);
	static uint8_t frame[PIXELS], previous[PIXELS];
	unsigned int partials = FULL_INTERVAL;
	unsigned int failures = 0;
	for (;;) {
		for (int i = 0; i < button_count; i++)
			move_pointer(display, buttons[i], &vertical);
		XImage *image = XGetImage(display, root, 0, 0, width, HEIGHT, AllPlanes, ZPixmap);
		if (!image)
			return EXIT_FAILURE;
		capture(image, frame);
		XDestroyImage(image);
		if (devices)
			draw_pointer(display, root, (width - WIDTH) / 2, vertical, frame);

		if (partials == FULL_INTERVAL || memcmp(frame, previous, PIXELS)) {
			const char *mode = partials == FULL_INTERVAL ? "full" : "partial";
			if (paint(argv[1], mode, argv[2], frame)) {
				if (++failures == 3) {
					fprintf(stderr, "pb626-x11-epd: the panel rejected three updates\n");
					return EXIT_FAILURE;
				}
				partials = FULL_INTERVAL;
				sleep(1);
			} else {
				failures = 0;
				memcpy(previous, frame, PIXELS);
				partials = partials == FULL_INTERVAL ? 0 : partials + 1;
			}
		}
		const struct timespec interval = { .tv_nsec = 250000000L };
		nanosleep(&interval, NULL);
	}
}
