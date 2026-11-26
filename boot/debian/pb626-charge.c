/* SPDX-License-Identifier: MIT
 * Native charger-only target: read kernel telemetry, render a binary battery
 * using the existing E Ink worker, and let systemd own boot/poweroff.
 * No raw PMIC writes, no X11, no changes to charging parameters. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <linux/netlink.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { W = 758, H = 1024, SAMPLE_MS = 15000, CONFIRM_MS = 1000 };
static uint8_t image[W * H];
static const char normal_marker[] = "/run/pb626-normal-boot";
static const char charge_marker[] = "/run/pb626-charge-mode";
static const char qualified[] = "/etc/pb626/charge-qualified";
static const char next_boot[] = "/var/lib/pb626/normal-next-boot";
static const char battery[] = "/sys/class/power_supply/axp20x-battery";

static int read_text(const char *path, char *out, size_t size)
{
    FILE *f = fopen(path, "re");
    if (!f)
        return -1;
    int ok = fgets(out, size, f) != NULL;
    fclose(f);
    if (!ok)
        return -1;
    out[strcspn(out, "\r\n")] = 0;
    return 0;
}

static int read_pmic(const char *attr, char *out, size_t size)
{
    char pattern[128];
    snprintf(pattern, sizeof(pattern), "/sys/bus/i2c/devices/*/%s", attr);
    glob_t paths = {0};
    int ret = -1;
    if (!glob(pattern, 0, NULL, &paths) && paths.gl_pathc == 1)
        ret = read_text(paths.gl_pathv[0], out, size);
    globfree(&paths);
    return ret;
}

static int parse_percent(const char *s)
{
    char *end;
    if (!*s || strspn(s, "0123456789") != strlen(s))
        return -1;
    errno = 0;
    long n = strtol(s, &end, 10);
    return !errno && !*end && n >= 0 && n <= 100 ? (int)n : -1;
}

static int external_present(void)
{
    char s[32];
    if (read_pmic("pb626_external_present", s, sizeof(s)))
        return -1;
    if (!strcmp(s, "0")) return 0;
    if (!strcmp(s, "1")) return 1;
    return -1;
}

static int capacity(void)
{
    char path[128], s[32];
    snprintf(path, sizeof(path), "%s/present", battery);
    if (read_text(path, s, sizeof(s)) || strcmp(s, "1"))
        return -1;
    snprintf(path, sizeof(path), "%s/capacity", battery);
    return read_text(path, s, sizeof(s)) ? -1 : parse_percent(s);
}

static int make_marker(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    return close(fd);
}

static int command(const char *program, char *const args[])
{
    pid_t child = fork();
    if (child < 0) return -1;
    if (!child) {
        execv(program, args);
        _exit(127);
    }
    int status;
    while (waitpid(child, &status, 0) < 0)
        if (errno != EINTR) return -1;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int systemctl(const char *verb, const char *unit)
{
    char *args[] = {"/usr/bin/systemctl", "--no-block", (char *)verb, (char *)unit, NULL};
    return command(args[0], args);
}

static int select_normal(void)
{
    if (make_marker(normal_marker))
        return -1;
    if (unlink(charge_marker) && errno != ENOENT)
        return -1;
    return systemctl("start", "multi-user.target");
}

/* Unknown is not a reason to prevent a normal boot. Qualification and
 * the hardware-reported source are BOTH mandatory. */
static bool choose_charger(bool enabled, bool force_normal, const char *source)
{
    return enabled && !force_normal && !strcmp(source, "external");
}

static bool cmdline_normal(void)
{
    char line[4096];
    if (read_text("/proc/cmdline", line, sizeof(line)))
        return false;
    char *save = NULL;
    for (char *w = strtok_r(line, " ", &save); w; w = strtok_r(NULL, " ", &save))
        if (!strcmp(w, "pb626.charge=off") ||
            !strcmp(w, "systemd.unit=multi-user.target") ||
            !strcmp(w, "systemd.unit=rescue.target"))
            return true;
    return false;
}

static int select_boot(void)
{
    bool force = cmdline_normal() || access(normal_marker, F_OK) == 0;
    /* A normal, explicit reboot must not re-enter charge mode if the
     * PMIC retains its original startup-source bit across a warm reset. */
    if (access(next_boot, F_OK) == 0) {
        force = true;
        if (unlink(next_boot))
            perror("consume normal-next-boot");
    }
    bool enabled = access(qualified, F_OK) == 0;
    char source[32] = "unknown";
    if (enabled && !force)
        for (int i = 0; i < 20; i++) {
            if (!read_pmic("pb626_boot_source", source, sizeof(source)))
                break;
            struct timespec delay = {0, 100000000};
            nanosleep(&delay, NULL);
        }
    if (!choose_charger(enabled, force, source)) {
        fprintf(stderr, "PB626 boot: normal (PMIC source=%s, qualified=%d)\n", source, enabled);
        return select_normal();
    }
    if (make_marker(charge_marker))
        return -1;
    fprintf(stderr, "PB626 boot: charge-only, external PMIC startup\n");
    return systemctl("start", "pb626-charge.target");
}

static void rect(int x, int y, int w, int h, uint8_t color)
{
    assert(x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= W && y + h <= H);
    for (int row = y; row < y + h; row++)
        memset(image + row * W + x, color, (size_t)w);
}

/* Seven-segment digits, no font library or X server required. */
static void digit(int x, int y, int n)
{
    static const uint8_t bits[] = {0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
    unsigned int mask = n < 0 ? 0x40 : bits[n];
    const int a[7][4] = {{12,0,52,12},{64,12,12,48},{64,72,12,48},
                        {12,120,52,12},{0,72,12,48},{0,12,12,48},{12,60,52,12}};
    for (int i = 0; i < 7; i++)
        if (mask & (1u << i))
            rect(x + a[i][0], y + a[i][1], a[i][2], a[i][3], 0);
}

static void battery_image(int percent)
{
    memset(image, 255, sizeof(image));
    rect(85, 280, 540, 300, 0);
    rect(103, 298, 504, 264, 255);
    rect(625, 375, 48, 110, 0);
    if (percent >= 0)
        rect(113, 308, 484 * percent / 100, 244, 0);
    int digits = percent == 100 ? 3 : percent >= 10 || percent < 0 ? 2 : 1;
    int width = digits * 92 + 86;
    int x = (W - width) / 2;
    if (percent < 0) {
        digit(x, 660, -1);
        digit(x + 92, 660, -1);
    } else {
        if (digits == 3) digit(x, 660, 1);
        if (digits >= 2) digit(x + (digits - 2) * 92, 660, percent / 10 % 10);
        digit(x + (digits - 1) * 92, 660, percent % 10);
    }
    x += digits * 92;
    rect(x, 664, 26, 26, 0);
    rect(x + 60, 762, 26, 26, 0);
    for (int i = 0; i < 108; i++)
        rect(x + 72 - i * 66 / 108, 676 + i, 12, 1, 0);
}

static int render(int percent, bool full)
{
    battery_image(percent);
    char path[] = "/run/pb626-charge.XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    FILE *f = fdopen(fd, "wb");
    if (!f) {
        close(fd);
        unlink(path);
        return -1;
    }
    int ok = fprintf(f, "P5\n%d %d\n255\n", W, H) > 0 &&
        fwrite(image, 1, sizeof(image), f) == sizeof(image);
    if (fclose(f)) ok = 0;
    char *args[] = {"/usr/bin/pb626-epd", "/lib/firmware/pb626/default.wbf",
        full ? "full" : "partial", path, NULL};
    int ret = ok ? command(args[0], args) : -1;
    if (ret && ok && !full) {
        /* The chosen factory waveform can reject a transition in partial
         * mode. Reacquire the panel through the ordinary full-quality
         * recovery path instead of abandoning the charging session. */
        args[2] = "full";
        ret = command(args[0], args);
    }
    unlink(path);
    return ret;
}

static int power_key(void)
{
    glob_t g = {0};
    int found = -1;
    if (!glob("/dev/input/event*", 0, NULL, &g))
        for (size_t i = 0; i < g.gl_pathc; i++) {
            int fd = open(g.gl_pathv[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            if (fd < 0) continue;
            char name[128] = {0};
            if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
                !strcmp(name, "axp20x-pek") && found < 0) {
                found = fd;
            } else {
                close(fd);
            }
        }
    globfree(&g);
    return found;
}

static int uevents(void)
{
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK,
                    NETLINK_KOBJECT_UEVENT);
    if (fd < 0) return -1;
    struct sockaddr_nl addr = {.nl_family = AF_NETLINK, .nl_groups = 1};
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr))) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Notifications are hints; only fresh kernel telemetry drives decisions. */
static bool power_event(int fd)
{
    char buf[8192];
    bool found = false;
    for (;;) {
        struct sockaddr_nl addr = {0};
        socklen_t len = sizeof(addr);
        ssize_t n = recvfrom(fd, buf, sizeof(buf), 0, (struct sockaddr *)&addr, &len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == ENOBUFS) found = true;
            break;
        }
        if (addr.nl_pid != 0) continue;
        for (ssize_t i = 0; i < n;) {
            size_t l = strnlen(buf + i, (size_t)(n - i));
            if (l == strlen("SUBSYSTEM=power_supply") &&
                !memcmp(buf + i, "SUBSYSTEM=power_supply", l))
                found = true;
            i += (ssize_t)l + 1;
        }
    }
    return found;
}

static int64_t now_ms(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t))
        return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

enum action { WAIT, DRAW_FULL, DRAW_PARTIAL, POWER_OFF, BOOT_NORMAL, TELEMETRY_ERROR };
struct charge_state {
    int last, updates, failures;
    int64_t absent_since, next;
    bool armed;
};

/* All decisions use actual PMIC presence, not the uevent's payload.
 * Two absent samples separated by one second are required. A reconnect
 * or unknown sample cancels the decision. A missing gauge does not
 * mean a missing battery or an unplug. */
static enum action sample(struct charge_state *s, int64_t now, int present, int level)
{
    if (present < 0) {
        s->absent_since = -1;
        s->next = now + CONFIRM_MS;
        return ++s->failures >= 3 ? TELEMETRY_ERROR : WAIT;
    }
    s->failures = 0;
    if (!present) {
        if (s->absent_since < 0) s->absent_since = now;
        s->next = s->absent_since + CONFIRM_MS;
        return now >= s->next ? POWER_OFF : WAIT;
    }
    s->absent_since = -1;
    s->next = now + SAMPLE_MS;
    if (level == s->last) return WAIT;
    return s->updates % 10 == 0 ? DRAW_FULL : DRAW_PARTIAL;
}

static enum action key_action(struct charge_state *s, int value)
{
    if (value == 0) s->armed = true;
    if (value == 1 && s->armed) {
        s->armed = false;
        return BOOT_NORMAL;
    }
    return WAIT;
}

static int run_charge(void)
{
    if (access(charge_marker, F_OK) || access(normal_marker, F_OK) == 0)
        return -1;
    int key = power_key(), events = uevents();
    /* Do not strand the user in a target with no power-button path. */
    if (key < 0 || events < 0)
        return -1;
    unsigned long pressed[(KEY_MAX / (8 * sizeof(unsigned long))) + 1] = {0};
    struct charge_state s = { .last = -2, .absent_since = -1 };
    if (ioctl(key, EVIOCGKEY(sizeof(pressed)), pressed) < 0)
        return -1;
    s.armed = !(pressed[KEY_POWER / (8 * sizeof(unsigned long))] &
                (1ul << (KEY_POWER % (8 * sizeof(unsigned long)))));
    struct pollfd p[] = {{key, POLLIN, 0}, {events, POLLIN, 0}};
    for (;;) {
        int64_t wait = s.next - now_ms();
        int ret = poll(p, 2, wait > 0 ? (int)wait : 0);
        if (ret < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (p[0].revents & (POLLERR | POLLHUP | POLLNVAL) ||
            p[1].revents & (POLLERR | POLLHUP | POLLNVAL))
            return -1;
        if (p[0].revents & POLLIN) {
            struct input_event e;
            while (read(key, &e, sizeof(e)) == sizeof(e)) {
                if (e.type != EV_KEY || e.code != KEY_POWER) continue;
                if (key_action(&s, e.value) == BOOT_NORMAL) {
                    close(key); close(events);
                    /* No reboot, no reliance on the PMIC startup bit again. */
                    return select_normal();
                }
            }
        }
        if ((p[1].revents & POLLIN) && power_event(events))
            s.next = 0;
        int64_t now = now_ms();
        if (now < s.next) continue;
        int present = external_present();
        int level = present == 1 ? capacity() : -1;
        enum action act = sample(&s, now, present, level);
        if (act == POWER_OFF) {
            /* Check again immediately before committing to shutdown.
             * Existing poweroff-screen restores the configured image. */
            int final = external_present();
            if (final != 0) {
                s.absent_since = -1;
                s.next = 0;
                continue;
            }
            close(key); close(events);
            return systemctl("poweroff", NULL);
        }
        if (act == TELEMETRY_ERROR) {
            fprintf(stderr, "PB626 charge: repeated PMIC read failure; normal boot fallback\n");
            return -1;
        }
        if (act == DRAW_FULL || act == DRAW_PARTIAL) {
            if (render(level, act == DRAW_FULL))
                return -1;
            s.last = level;
            s.updates++;
            /* An unplug may have happened during the physical scan. */
            s.next = 0;
        }
    }
}

static void self_test(void)
{
    assert(parse_percent("0") == 0 && parse_percent("100") == 100);
    assert(parse_percent("101") == -1 && parse_percent("-1") == -1 &&
           parse_percent("5x") == -1 && parse_percent("") == -1);
    assert(choose_charger(true, false, "external"));
    assert(!choose_charger(false, false, "external"));
    assert(!choose_charger(true, true, "external"));
    assert(!choose_charger(true, false, "nonexternal"));
    assert(!choose_charger(true, false, "unknown"));
    for (int n = -1; n <= 100; n++) {
        battery_image(n);
        assert(image[0] == 255 && image[280 * W + 85] == 0);
        unsigned int black = 0;
        for (int x = 113; x < 597; x++)
            black += image[400 * W + x] == 0;
        assert(black == (unsigned int)(n < 0 ? 0 : 484 * n / 100));
        for (size_t i = 0; i < sizeof(image); i++)
            assert(image[i] == 0 || image[i] == 255);
    }
    struct charge_state s = { .last = -2, .absent_since = -1, .armed = true };
    assert(sample(&s, 0, 1, 0) == DRAW_FULL);
    s.last = 0; s.updates = 1;
    assert(sample(&s, 10, 1, 0) == WAIT && s.next == 15010);
    assert(sample(&s, 100, 1, 1) == DRAW_PARTIAL);
    assert(sample(&s, 1000, 0, -1) == WAIT && s.next == 2000);
    assert(sample(&s, 1500, 0, -1) == WAIT);
    assert(sample(&s, 1999, 1, 1) == DRAW_PARTIAL);
    assert(sample(&s, 2100, 0, -1) == WAIT);
    assert(sample(&s, 3100, 0, -1) == POWER_OFF);
    assert(sample(&s, 3101, -1, -1) == WAIT && s.absent_since == -1);
    assert(sample(&s, 4101, -1, -1) == WAIT);
    assert(sample(&s, 5101, -1, -1) == TELEMETRY_ERROR);
    assert(sample(&s, 5200, 1, -1) == DRAW_PARTIAL && s.failures == 0);
    s.last = -1; s.updates = 10;
    assert(sample(&s, 5300, 1, 100) == DRAW_FULL);
    assert(key_action(&s, 2) == WAIT);
    assert(key_action(&s, 1) == BOOT_NORMAL);
    assert(key_action(&s, 1) == WAIT);
    assert(key_action(&s, 0) == WAIT);
    assert(key_action(&s, 1) == BOOT_NORMAL);
    puts("PB626 charger transitions, unplug/reconnect, faults, key and 0..100% bitmap tests passed");
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "--self-test")) { self_test(); return 0; }
    if (!strcmp(argv[1], "probe")) {
        char source[32] = "unknown";
        if (read_pmic("pb626_boot_source", source, sizeof(source)))
            strcpy(source, "unknown");
        int key = power_key();
        printf("boot_source=%s\nexternal_present=%d\ncapacity=%d\npek_available=%d\nqualified=%d\n",
               source, external_present(), capacity(), key >= 0, access(qualified, F_OK) == 0);
        if (key >= 0) close(key);
        return 0;
    }
    if (!strcmp(argv[1], "select")) return select_boot() ? 1 : 0;
    if (!strcmp(argv[1], "normal")) return select_normal() ? 1 : 0;
    if (!strcmp(argv[1], "run")) return run_charge() ? 1 : 0;
    if (!strcmp(argv[1], "reboot-marker")) {
        if (access(qualified, F_OK)) return 0;
        int ret = make_marker(next_boot);
        if (!ret) sync();
        return ret ? 1 : 0;
    }
    return 2;
}
