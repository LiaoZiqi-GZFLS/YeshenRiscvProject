/* gpio_sample.c -- count SCL/SDA edges on the CTP GPIO block for a short
 * window. Used to see whether the kernel i2c-gpio really toggles the bus.
 *     gpio_sample [millions_of_reads]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define GPIO_BASE 0xF0002000u
#define R_IN 0x00
#define R_OUT 0x04
#define R_DIR 0x08

int main(int argc, char **argv)
{
    long n = argc > 1 ? atol(argv[1]) : 2000000;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    volatile uint32_t *g = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, GPIO_BASE);
    if (g == MAP_FAILED) { perror("mmap"); return 1; }

    int scl_edges = 0, sda_edges = 0;
    int oscl_edges = 0, osda_edges = 0;
    uint32_t prev = g[R_IN / 4];
    uint32_t oprev = g[R_OUT / 4];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long i = 0; i < n; i++) {
        uint32_t v = g[R_IN / 4];
        uint32_t o = g[R_OUT / 4];
        scl_edges += ((v ^ prev) >> 8) & 1;
        sda_edges += ((v ^ prev) >> 9) & 1;
        oscl_edges += ((o ^ oprev) >> 8) & 1;
        osda_edges += ((o ^ oprev) >> 9) & 1;
        prev = v;
        oprev = o;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1000.0 +
                (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("GPIO_SAMPLE %.1fms in_scl=%d in_sda=%d out_scl=%d out_sda=%d in=%08x out=%08x dir=%08x\n",
           ms, scl_edges, sda_edges, oscl_edges, osda_edges,
           g[R_IN / 4], g[R_OUT / 4], g[R_DIR / 4]);
    return 0;
}
