/* Single-request TCP transport for the RAM-only recovery. No arbitrary shell.
 * Only the fixed USB link peer is accepted. The dispatcher validates operations.
 * EOF is an explicit end of request; status is appended after child completion.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef PB626_NET_ADDR
#define PB626_NET_ADDR "169.254.62.1"
#define PB626_NET_PEER "169.254.62.2"
#define PB626_NET_DEV "usb0"
#define PB626_NET_PORT 6262
#define PB626_DISPATCH "/usr/libexec/pb626-net-dispatch.sh"
#endif
static int valid(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z') || c == '-' || c == '_' || c == '.' || c == '/';
}
static void handle(int fd) {
    char line[512], *args[20], *save = NULL, *t;
    size_t n = 0;
    int ac = 2, status = 1, w;
    pid_t pid;
    struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv))) return;
    for (;;) {
        unsigned char ch;
        ssize_t r = read(fd, &ch, 1);
        if (r < 0 && errno == EINTR) continue;
        if (r != 1 || n == sizeof(line)-1) return;
        if (ch == '\n') break;
        if (ch != ' ' && !valid(ch)) return;
        line[n++] = (char)ch;
    }
    line[n] = 0;
    t = strtok_r(line, " ", &save);
    if (!t || strcmp(t, "PB626/1")) return;
    args[0] = "/bin/sh"; args[1] = PB626_DISPATCH;
    while ((t = strtok_r(NULL, " ", &save))) {
        if (ac == (int)(sizeof(args)/sizeof(args[0]))-1) return;
        args[ac++] = t;
    }
    args[ac] = NULL;
    if (ac == 2) return;
    pid = fork();
    if (pid == 0) {
        signal(SIGPIPE, SIG_DFL);
        if (dup2(fd, 0) < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) _exit(126);
        if (fd > 2) close(fd);
        if (setenv("PB626_TCP", "1", 1)) _exit(126);
        execv(args[0], args);
        _exit(127);
    }
    if (pid > 0) {
        pid_t rc;
        do { rc = waitpid(pid, &w, 0); } while (rc < 0 && errno == EINTR);
        if (rc == pid && WIFEXITED(w)) status = WEXITSTATUS(w);
    }
    (void)dprintf(fd, "\nPB626_STATUS %d\n", status);
}
int main(void) {
    struct sockaddr_in addr = { .sin_family = AF_INET }, peer;
    int yes = 1, fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    signal(SIGPIPE, SIG_IGN);
    if (fd < 0) { perror("socket"); return 1; }
    addr.sin_port = htons(PB626_NET_PORT);
    if (inet_pton(AF_INET, PB626_NET_ADDR, &addr.sin_addr) != 1 ||
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) ||
        (*PB626_NET_DEV && setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, PB626_NET_DEV,
                                     sizeof(PB626_NET_DEV))) ||
        bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 2)) {
        perror("PB626 TCP bind"); return 1;
    }
    for (;;) {
        socklen_t len = sizeof(peer);
        int client = accept4(fd, (struct sockaddr *)&peer, &len, SOCK_CLOEXEC);
        if (client < 0) { if (errno == EINTR) continue; perror("accept"); return 1; }
        char ip[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip)) &&
            !strcmp(ip, PB626_NET_PEER)) handle(client);
        close(client);
    }
}
