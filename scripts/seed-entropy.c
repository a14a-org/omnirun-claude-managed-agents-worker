/*
 * seed-entropy: Credit entropy to the kernel CRNG pool.
 *
 * Firecracker VMs boot with near-zero entropy, causing Node.js (and
 * anything calling getrandom()) to block indefinitely. This small
 * static binary injects 512 bytes of pseudo-random data via the
 * RNDADDENTROPY ioctl, which credits the pool and unblocks CRNG.
 *
 * Compile: gcc -static -O2 -o seed-entropy seed-entropy.c
 */

#include <fcntl.h>
#include <linux/random.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define ENTROPY_BYTES 512
#define ENTROPY_BITS  (ENTROPY_BYTES * 8)

int main(void) {
    int urand_fd, rand_fd;

    /* Open /dev/urandom for reading (non-blocking, available even when
       CRNG is not fully initialized — returns best-effort random data). */
    urand_fd = open("/dev/urandom", O_RDONLY);
    if (urand_fd < 0) {
        perror("open /dev/urandom");
        return 1;
    }

    /* Open /dev/random for the RNDADDENTROPY ioctl. The ioctl must be
       performed on /dev/random (not /dev/urandom) to reliably credit
       entropy to the kernel CRNG pool on all kernel versions. */
    rand_fd = open("/dev/random", O_WRONLY);
    if (rand_fd < 0) {
        perror("open /dev/random");
        close(urand_fd);
        return 1;
    }

    /* Allocate the struct expected by RNDADDENTROPY:
       struct rand_pool_info { int entropy_count; int buf_size; __u32 buf[]; }
    */
    size_t total = sizeof(int) * 2 + ENTROPY_BYTES;
    char *pool = calloc(1, total);
    if (!pool) {
        perror("calloc");
        close(urand_fd);
        close(rand_fd);
        return 1;
    }

    /* Fill buf from /dev/urandom. After snapshot restore this data may be
       low-quality, but the host-side entropy injection (seedGuestEntropy)
       primes /dev/urandom before this runs. Even without that, crediting
       any data unblocks getrandom() — the security trade-off is acceptable
       for short-lived sandbox VMs. */
    unsigned char *buf = (unsigned char *)(pool + sizeof(int) * 2);
    ssize_t n = read(urand_fd, buf, ENTROPY_BYTES);
    close(urand_fd);

    if (n < ENTROPY_BYTES) {
        /* Fallback: XOR in monotonic clock + pid for extra variation */
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        unsigned int seed = (unsigned int)(ts.tv_nsec ^ getpid());
        srand(seed);
        for (int i = (n > 0 ? (int)n : 0); i < ENTROPY_BYTES; i++) {
            buf[i] = (unsigned char)(rand() & 0xFF);
        }
    }

    /* Set entropy_count and buf_size */
    ((int *)pool)[0] = ENTROPY_BITS;
    ((int *)pool)[1] = ENTROPY_BYTES;

    if (ioctl(rand_fd, RNDADDENTROPY, pool) < 0) {
        perror("ioctl RNDADDENTROPY");
        free(pool);
        close(rand_fd);
        return 1;
    }

    free(pool);
    close(rand_fd);
    return 0;
}
