/* Event-driven monochrome running-window tabs for Matchbox/X11. */
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <errno.h>
#include <locale.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_CLIENTS 256
struct taskbar {
    Display *d;
    Window root, win, active, clients[MAX_CLIENTS], pressed;
    Atom list, active_atom, type, normal, state, skip, close, strut, partial, title, utf8;
    GC gc;
    XFontSet font;
    unsigned long black, white;
    int width, height, count, page, start_x, start_y, more_pressed;
    int hold_ms;
    uint64_t due;
    Time press_time;
};

static uint64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int xerror(Display *d, XErrorEvent *e)
{
    /* A listed client can vanish before its title or type is queried. */
    if (e->error_code != BadWindow) {
        char msg[128];
        XGetErrorText(d, e->error_code, msg, sizeof(msg));
        fprintf(stderr, "pb626-taskbar: %s\n", msg);
    }
    return 0;
}

static unsigned char *property(struct taskbar *t, Window w, Atom key,
                               Atom type, int format, unsigned long *n)
{
    Atom actual;
    int bits;
    unsigned long after;
    unsigned char *p = NULL;
    *n = 0;
    if (XGetWindowProperty(t->d, w, key, 0, 1024, False, type,
                           &actual, &bits, n, &after, &p) != Success ||
        actual != type || bits != format) {
        if (p) XFree(p);
        *n = 0;
        return NULL;
    }
    return p;
}

static int is_app(struct taskbar *t, Window w)
{
    if (w == t->win || w == t->root || !w) return 0;
    Window parent;
    if (XGetTransientForHint(t->d, w, &parent)) return 0;
    unsigned long n;
    unsigned long *a = (unsigned long *)property(t, w, t->type, XA_ATOM, 32, &n);
    int normal = !n || a[0] == t->normal;
    if (a) XFree(a);
    if (!normal) return 0;
    a = (unsigned long *)property(t, w, t->state, XA_ATOM, 32, &n);
    for (unsigned long i = 0; i < n; i++)
        if (a[i] == t->skip) normal = 0;
    if (a) XFree(a);
    return normal;
}

static void cancel_press(struct taskbar *t)
{
    t->pressed = None;
    t->more_pressed = 0;
    t->due = 0;
}

static int page_size(const struct taskbar *t)
{
    int capacity = t->width / 128;
    if (capacity < 2) capacity = 2;
    return t->count > capacity ? capacity - 1 : capacity;
}

static int tiles(const struct taskbar *t)
{
    int size = page_size(t), remaining = t->count - t->page * size;
    return (remaining < size ? remaining : size) + (t->count > size);
}

/* Return -1 for empty space, -2 for the page switch tile. */
static int hit(const struct taskbar *t, int x, int y)
{
    int n = tiles(t);
    if (n <= 0 || x < 0 || y < 0 || x >= t->width || y >= t->height) return -1;
    int i = ((x + 1) * n - 1) / t->width;
    if (t->count > page_size(t) && i == n - 1) return -2;
    return t->page * page_size(t) + i;
}

static void refresh(struct taskbar *t)
{
    unsigned long n;
    Window *p = (Window *)property(t, t->root, t->list, XA_WINDOW, 32, &n);
    Window next[MAX_CLIENTS];
    int count = 0;
    for (unsigned long i = 0; i < n && count < MAX_CLIENTS; i++) {
        if (!is_app(t, p[i])) continue;
        XSelectInput(t->d, p[i], PropertyChangeMask | StructureNotifyMask);
        next[count++] = p[i];
    }
    if (p) XFree(p);
    if (count != t->count || memcmp(next, t->clients, (size_t)count * sizeof(Window))) {
        cancel_press(t);
        for (int i = 0; i < t->count; i++) {
            int keep = 0;
            for (int j = 0; j < count; j++) if (t->clients[i] == next[j]) keep = 1;
            if (!keep) XSelectInput(t->d, t->clients[i], NoEventMask);
        }
        memcpy(t->clients, next, (size_t)count * sizeof(Window));
        t->count = count;
        if (t->page * page_size(t) >= count) t->page = 0;
    }
    p = (Window *)property(t, t->root, t->active_atom, XA_WINDOW, 32, &n);
    t->active = n ? p[0] : None;
    if (p) XFree(p);
}

static void draw(struct taskbar *t)
{
    XSetForeground(t->d, t->gc, t->white);
    XFillRectangle(t->d, t->win, t->gc, 0, 0, t->width, t->height);
    int n = tiles(t);
    for (int i = 0; i < n; i++) {
        int x = i * t->width / n, end = (i + 1) * t->width / n;
        int index = t->page * page_size(t) + i;
        int more = t->count > page_size(t) && i == n - 1;
        int active = !more && t->clients[index] == t->active;
        XSetForeground(t->d, t->gc, t->black);
        if (active) XFillRectangle(t->d, t->win, t->gc, x, 0, end - x, t->height);
        else XDrawRectangle(t->d, t->win, t->gc, x, 0, end - x - 1, t->height - 1);
        XSetForeground(t->d, t->gc, active ? t->white : t->black);
        unsigned long len = 0;
        unsigned char *name = more ? NULL : property(t, t->clients[index], t->title, t->utf8, 8, &len);
        char *legacy = NULL;
        if (!more && !len) XFetchName(t->d, t->clients[index], &legacy);
        const char *label = more ? "More >" : len ? (char *)name : legacy ? legacy : "Application";
        if (!len || more) len = strlen(label);
        XRectangle clip = {(short)(x + 5), 1, (unsigned short)(end - x - 10), (unsigned short)(t->height - 2)};
        XSetClipRectangles(t->d, t->gc, 0, 0, &clip, 1, Unsorted);
        if (t->font) {
            XFontSetExtents *ext = XExtentsOfFontSet(t->font);
            int baseline = (t->height - ext->max_logical_extent.height) / 2 - ext->max_logical_extent.y;
            Xutf8DrawString(t->d, t->win, t->font, t->gc, x + 5, baseline, label, (int)len);
        } else XDrawString(t->d, t->win, t->gc, x + 5, t->height / 2 + 5, label, (int)len);
        XSetClipMask(t->d, t->gc, None);
        if (name) XFree(name);
        if (legacy) XFree(legacy);
    }
    XSetForeground(t->d, t->gc, t->black);
    XDrawLine(t->d, t->win, t->gc, 0, t->height - 1, t->width - 1, t->height - 1);
    XFlush(t->d);
}

static void request(struct taskbar *t, Window w, Atom command, Time stamp)
{
    /* Recheck the live list before sending a request; never signal a PID. */
    refresh(t);
    int found = 0;
    for (int i = 0; i < t->count; i++) if (t->clients[i] == w) found = 1;
    if (!found) return;
    XEvent e = {.xclient = {.type = ClientMessage, .display = t->d, .window = w,
                           .message_type = command, .format = 32}};
    e.xclient.data.l[0] = command == t->close ? stamp : 2;
    e.xclient.data.l[1] = command == t->close ? 2 : stamp;
    XSendEvent(t->d, t->root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
    XFlush(t->d);
}

static int same_tile(struct taskbar *t, int x, int y)
{
    int i = hit(t, x, y);
    return abs(x - t->start_x) <= 16 && abs(y - t->start_y) <= 16 &&
           ((t->more_pressed && i == -2) || (t->pressed && i >= 0 && t->clients[i] == t->pressed));
}

static void reserve(struct taskbar *t)
{
    unsigned long values[12] = {0, 0, (unsigned long)t->height, 0, 0, 0, 0, 0, 0, (unsigned long)t->width - 1, 0, 0};
    XChangeProperty(t->d, t->win, t->strut, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)values, 4);
    XChangeProperty(t->d, t->win, t->partial, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)values, 12);
}

static int setting(const char *value, int def, int min, int max)
{
    if (!value || !*value) return def;
    char *end;
    long n = strtol(value, &end, 10);
    return *end || n < min || n > max ? def : (int)n;
}

int main(void)
{
    setlocale(LC_CTYPE, "");
    struct taskbar t = {0};
    t.height = setting(getenv("PB626_TASKBAR_SIZE"), 48, 32, 72);
    t.hold_ms = setting(getenv("PB626_BUTTON_HOLD_MS"), 1000, 300, 2000);
    t.d = XOpenDisplay(NULL);
    if (!t.d) return 1;
    XSetErrorHandler(xerror);
    int s = DefaultScreen(t.d);
    t.root = RootWindow(t.d, s);
    t.width = DisplayWidth(t.d, s);
    t.white = WhitePixel(t.d, s); t.black = BlackPixel(t.d, s);
    t.win = XCreateSimpleWindow(t.d, t.root, 0, 0, t.width, t.height, 0, t.black, t.white);
    t.gc = XCreateGC(t.d, t.win, 0, NULL);
    char **missing, *def;
    int missing_count;
    t.font = XCreateFontSet(t.d, "-*-*-bold-r-normal--20-*-*-*-*-*-*-*,fixed", &missing, &missing_count, &def);
    if (missing) XFreeStringList(missing);
    t.list = XInternAtom(t.d, "_NET_CLIENT_LIST", False);
    t.active_atom = XInternAtom(t.d, "_NET_ACTIVE_WINDOW", False);
    t.type = XInternAtom(t.d, "_NET_WM_WINDOW_TYPE", False);
    t.normal = XInternAtom(t.d, "_NET_WM_WINDOW_TYPE_NORMAL", False);
    t.state = XInternAtom(t.d, "_NET_WM_STATE", False);
    t.skip = XInternAtom(t.d, "_NET_WM_STATE_SKIP_TASKBAR", False);
    t.close = XInternAtom(t.d, "_NET_CLOSE_WINDOW", False);
    t.strut = XInternAtom(t.d, "_NET_WM_STRUT", False);
    t.partial = XInternAtom(t.d, "_NET_WM_STRUT_PARTIAL", False);
    t.title = XInternAtom(t.d, "_NET_WM_NAME", False);
    t.utf8 = XInternAtom(t.d, "UTF8_STRING", False);
    Atom dock = XInternAtom(t.d, "_NET_WM_WINDOW_TYPE_DOCK", False);
    XChangeProperty(t.d, t.win, t.type, XA_ATOM, 32, PropModeReplace, (unsigned char *)&dock, 1);
    XStoreName(t.d, t.win, "PB626 Running Applications");
    XWMHints hints = {.flags = InputHint, .input = False};
    XSetWMHints(t.d, t.win, &hints);
    reserve(&t);
    XSelectInput(t.d, t.root, PropertyChangeMask | StructureNotifyMask);
    XSelectInput(t.d, t.win, ExposureMask | StructureNotifyMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | LeaveWindowMask);
    XMapWindow(t.d, t.win);
    refresh(&t);
    draw(&t);
    for (;;) {
        int redraw = 0;
        while (XPending(t.d)) {
            XEvent e;
            XNextEvent(t.d, &e);
            if (e.type == Expose && e.xexpose.count == 0) redraw = 1;
            else if (e.type == PropertyNotify) {
                Atom a = e.xproperty.atom;
                if (a == t.list || a == t.active_atom || a == t.title || a == XA_WM_NAME || a == t.type || a == t.state) {
                    refresh(&t); redraw = 1;
                }
            } else if (e.type == DestroyNotify && e.xdestroywindow.window != t.win) {
                refresh(&t); redraw = 1;
            } else if (e.type == ConfigureNotify && e.xconfigure.window == t.root && e.xconfigure.width != t.width) {
                t.width = e.xconfigure.width; t.page = 0; cancel_press(&t);
                XMoveResizeWindow(t.d, t.win, 0, 0, t.width, t.height);
                reserve(&t); redraw = 1;
            } else if (e.type == ButtonPress && e.xbutton.button == Button1) {
                cancel_press(&t);
                int i = hit(&t, e.xbutton.x, e.xbutton.y);
                t.start_x = e.xbutton.x; t.start_y = e.xbutton.y; t.press_time = e.xbutton.time;
                if (i >= 0) {t.pressed = t.clients[i]; t.due = now_ms() + t.hold_ms;}
                else if (i == -2) t.more_pressed = 1;
            } else if (e.type == MotionNotify && !same_tile(&t, e.xmotion.x, e.xmotion.y)) cancel_press(&t);
            else if (e.type == LeaveNotify || e.type == UnmapNotify) cancel_press(&t);
            else if (e.type == ButtonRelease && e.xbutton.button == Button1) {
                if (same_tile(&t, e.xbutton.x, e.xbutton.y)) {
                    if (t.more_pressed) {
                        t.page = (t.page + 1) % ((t.count + page_size(&t) - 1) / page_size(&t));
                        redraw = 1;
                    } else if ((uint32_t)(e.xbutton.time - t.press_time) >= (uint32_t)t.hold_ms) {
                        request(&t, t.pressed, t.close, e.xbutton.time);
                    } else request(&t, t.pressed, t.active_atom, e.xbutton.time);
                }
                cancel_press(&t);
            }
        }
        uint64_t now = now_ms();
        if (t.due && now >= t.due) {
            Window root, child;
            int rx, ry, x, y;
            unsigned int mask;
            if (XQueryPointer(t.d, t.win, &root, &child, &rx, &ry, &x, &y, &mask) &&
                (mask & Button1Mask) && same_tile(&t, x, y)) request(&t, t.pressed, t.close, t.press_time);
            cancel_press(&t);
        }
        if (redraw) draw(&t);
        struct pollfd fd = {.fd = ConnectionNumber(t.d), .events = POLLIN};
        int timeout = t.due ? (t.due > now ? (int)(t.due - now) : 0) : -1;
        /* Xlib requests above can queue events while reading their replies. */
        if (XPending(t.d)) continue;
        if (poll(&fd, 1, timeout) < 0 && errno != EINTR) break;
        if (fd.revents & (POLLERR | POLLHUP | POLLNVAL)) break;
    }
    XCloseDisplay(t.d);
    return 0;
}
