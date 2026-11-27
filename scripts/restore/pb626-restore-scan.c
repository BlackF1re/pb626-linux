// SPDX-License-Identifier: GPL-2.0-or-later
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <linux/if_alg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define BLOCK_SIZE (4 * 1024 * 1024)
#define HASH_INPUT (64 * 1024)
#define SHA256_SIZE 32

static void fail(const char *message)
{
    perror(message);
    exit(EXIT_FAILURE);
}

static int hash_session(int algorithm)
{
    int session = accept(algorithm, NULL, NULL);

    if (session < 0)
        fail("AF_ALG accept");
    return session;
}

static void read_exact(int fd, unsigned char *buffer, size_t length)
{
    while (length) {
        ssize_t count = read(fd, buffer, length);

        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0) {
            if (!count)
                errno = EIO;
            fail("Short read from image device");
        }
        buffer += count;
        length -= count;
    }
}

static void hash_block(int session, const unsigned char *buffer, size_t length, bool last_block)
{
    for (size_t offset = 0; offset < length; offset += HASH_INPUT) {
        size_t bytes = length - offset < HASH_INPUT ? length - offset : HASH_INPUT;
        int flags = last_block && offset + bytes == length ? 0 : MSG_MORE;
        ssize_t count;

        do {
            count = send(session, buffer + offset, bytes, flags);
        } while (count < 0 && errno == EINTR);
        if (count < 0 || (size_t)count != bytes) {
            if (count >= 0)
                errno = EIO;
            fail("AF_ALG send");
        }
    }
}

static void print_digest(int session)
{
    unsigned char digest[SHA256_SIZE];
    ssize_t count;

    do {
        count = read(session, digest, sizeof(digest));
    } while (count < 0 && errno == EINTR);
    if (count != sizeof(digest)) {
        if (count >= 0)
            errno = EIO;
        fail("AF_ALG digest");
    }
    for (size_t i = 0; i < sizeof(digest); i++)
        printf("%02x", digest[i]);
    putchar('\n');
}

int main(int argc, char **argv)
{
    const struct sockaddr_alg address = {
        .salg_family = AF_ALG,
        .salg_type = "hash",
        .salg_name = "sha256",
    };
    char *end;

    if ((argc != 4 && argc != 5) || (strcmp(argv[1], "scan") && strcmp(argv[1], "verify"))) {
        fprintf(stderr, "Usage: %s scan|verify device blocks [last-block-bytes]\n", argv[0]);
        return EXIT_FAILURE;
    }
    long blocks = strtol(argv[3], &end, 10);
    if (*end || blocks < 1 || blocks > (argc == 5 ? 262144 : 1864)) {
        fprintf(stderr, "Invalid block count\n");
        return EXIT_FAILURE;
    }
    long tail = BLOCK_SIZE;
    if (argc == 5) {
        tail = strtol(argv[4], &end, 10);
        if (*end || tail < 512 || tail > BLOCK_SIZE || tail % 512) {
            fprintf(stderr, "Invalid final block length\n");
            return EXIT_FAILURE;
        }
    }
    bool scan = !strcmp(argv[1], "scan");

    int disk = open(argv[2], O_RDONLY | O_CLOEXEC);
    if (disk < 0)
        fail("open image device");
    int algorithm = socket(AF_ALG, SOCK_SEQPACKET, 0);
    if (algorithm < 0)
        fail("AF_ALG socket");
    if (bind(algorithm, (const struct sockaddr *)&address, sizeof(address)) < 0)
        fail("AF_ALG bind sha256");
    int session = hash_session(algorithm);
    unsigned char *buffer = aligned_alloc(4096, BLOCK_SIZE);
    if (!buffer)
        fail("Allocate block buffer");

    setvbuf(stdout, NULL, _IOLBF, 0);
    for (long index = 0; index < blocks; index++) {
        size_t length = index + 1 == blocks ? (size_t)tail : BLOCK_SIZE;
        read_exact(disk, buffer, length);
        hash_block(session, buffer, length, scan || index + 1 == blocks);
        if (scan) {
            printf("BLOCK %ld ", index);
            print_digest(session);
        } else if ((index + 1) % 8 == 0 || index + 1 == blocks) {
            printf("PROGRESS %ld\n", index + 1);
        }
    }
    if (!scan) {
        fputs("SHA256 ", stdout);
        print_digest(session);
    }
    free(buffer);
    close(session);
    close(algorithm);
    close(disk);
    return EXIT_SUCCESS;
}
