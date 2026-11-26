/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Small optional timer for the shell diagnostic; no device access. */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t ns(clockid_t id, int resolution)
{
    struct timespec t;
    if ((resolution ? clock_getres(id, &t) : clock_gettime(id, &t)) < 0) {
        perror("clock");
        exit(125);
    }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}

static uint64_t tv_us(struct timeval t)
{
    return (uint64_t)t.tv_sec * UINT64_C(1000000) + (uint64_t)t.tv_usec;
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "stamp")) {
        printf("%" PRIu64 " %" PRIu64 "\n",
               ns(CLOCK_BOOTTIME, 0), ns(CLOCK_MONOTONIC_RAW, 0));
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "resolution")) {
        printf("boottime_resolution_ns=%" PRIu64 "\nraw_resolution_ns=%" PRIu64 "\n",
               ns(CLOCK_BOOTTIME, 1), ns(CLOCK_MONOTONIC_RAW, 1));
        return 0;
    }
    if (argc < 3 || strcmp(argv[1], "run")) {
        fprintf(stderr, "Usage: pb626-diag-clock stamp|resolution|run COMMAND [ARGS...]\n");
        return 2;
    }
    uint64_t boot = ns(CLOCK_BOOTTIME, 0);
    uint64_t raw = ns(CLOCK_MONOTONIC_RAW, 0);
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 125;
    }
    if (!pid) {
        execvp(argv[2], argv + 2);
        perror("exec");
        _exit(127);
    }
    struct rusage ru;
    int status;
    pid_t got;
    do { got = wait4(pid, &status, 0, &ru); } while (got < 0 && errno == EINTR);
    if (got < 0) {
        perror("wait4");
        return 125;
    }
    uint64_t elapsed = ns(CLOCK_MONOTONIC_RAW, 0) - raw;
    uint64_t boot_elapsed = ns(CLOCK_BOOTTIME, 0) - boot;
    fprintf(stderr, "diag_time raw_elapsed_ns=%" PRIu64
            " boottime_elapsed_ns=%" PRIu64
            " child_user_us=%" PRIu64 " child_system_us=%" PRIu64
            " maxrss_kib=%ld\n",
            elapsed, boot_elapsed, tv_us(ru.ru_utime), tv_us(ru.ru_stime),
            ru.ru_maxrss);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}
