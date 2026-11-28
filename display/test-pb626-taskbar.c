/* Xvfb integration test: act as the WM and check actual EWMH requests. */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/extensions/XTest.h>
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

static pid_t child;
static void cleanup(void)
{
    if (child > 0) {
        kill(child, SIGTERM);
        waitpid(child, NULL, 0);
    }
}
static void sleep_ms(int ms)
{
    struct timespec t = {ms / 1000, ms % 1000 * 1000000L};
    nanosleep(&t, NULL);
}
static int get_request(Display *d, Atom type, Window w, int limit)
{
    for (int i = 0; i < limit; i++) {
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type == ClientMessage && e.xclient.message_type == type && e.xclient.window == w)
                return 1;
        }
        sleep_ms(10);
    }
    return 0;
}
static void press(Display *d, int x, int y)
{
    XTestFakeMotionEvent(d, -1, x, y, CurrentTime);
    XTestFakeButtonEvent(d, 1, True, CurrentTime);
    XSync(d, False);
}
static void release(Display *d)
{
    XTestFakeButtonEvent(d, 1, False, CurrentTime);
    XSync(d, False);
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    Display *d = XOpenDisplay(NULL);
    assert(d);
    Window root = DefaultRootWindow(d);
    Atom type = XInternAtom(d, "_NET_WM_WINDOW_TYPE", False);
    Atom normal = XInternAtom(d, "_NET_WM_WINDOW_TYPE_NORMAL", False);
    Atom dock = XInternAtom(d, "_NET_WM_WINDOW_TYPE_DOCK", False);
    Atom list = XInternAtom(d, "_NET_CLIENT_LIST", False);
    Atom activate = XInternAtom(d, "_NET_ACTIVE_WINDOW", False);
    Atom close = XInternAtom(d, "_NET_CLOSE_WINDOW", False);
    Window a = XCreateSimpleWindow(d, root, 0, 100, 100, 100, 0, 0, 0);
    Window b = XCreateSimpleWindow(d, root, 100, 100, 100, 100, 0, 0, 0);
    Window c = XCreateSimpleWindow(d, root, 200, 100, 100, 100, 0, 0, 0);
    XChangeProperty(d, a, type, XA_ATOM, 32, PropModeReplace, (unsigned char *)&normal, 1);
    XChangeProperty(d, b, type, XA_ATOM, 32, PropModeReplace, (unsigned char *)&normal, 1);
    XChangeProperty(d, c, type, XA_ATOM, 32, PropModeReplace, (unsigned char *)&dock, 1);
    Window ws[] = {a, b, c};
    XChangeProperty(d, root, list, XA_WINDOW, 32, PropModeReplace, (unsigned char *)ws, 3);
    XStoreName(d, a, "Editor");
    XStoreName(d, b, "Reader");
    XSelectInput(d, root, SubstructureNotifyMask);
    XSync(d, False);
    assert(setenv("PB626_BUTTON_HOLD_MS", "300", 1) == 0);
    assert(setenv("PB626_TASKBAR_SIZE", "48", 1) == 0);
    child = fork();
    assert(child >= 0);
    if (!child) {
        execl(argv[1], argv[1], (char *)NULL);
        _exit(127);
    }
    atexit(cleanup);
    /* Wait for the actual panel to map (including under armhf emulation). */
    int mapped = 0;
    for (int i = 0; i < 200 && !mapped; i++) {
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type == MapNotify) mapped = 1;
        }
        if (!mapped) sleep_ms(10);
    }
    assert(mapped);
    sleep_ms(200);
    press(d, 100, 20); sleep_ms(80); release(d);
    assert(get_request(d, activate, a, 100));
    press(d, 600, 20);
    assert(get_request(d, close, b, 100));
    release(d);
    assert(!get_request(d, activate, b, 30));
    press(d, 100, 20);
    XTestFakeMotionEvent(d, -1, 200, 20, CurrentTime);
    XSync(d, False); sleep_ms(500); release(d);
    assert(!get_request(d, close, a, 30));
    assert(!get_request(d, activate, a, 30));
    press(d, 100, 20);
    Window ws2[] = {b, c};
    XChangeProperty(d, root, list, XA_WINDOW, 32, PropModeReplace, (unsigned char *)ws2, 2);
    XSync(d, False); sleep_ms(500); release(d);
    assert(!get_request(d, close, a, 30));
    assert(!get_request(d, close, b, 30));
    XCloseDisplay(d);
    puts("Taskbar click/hold/motion/list-change checks passed");
    return 0;
}
