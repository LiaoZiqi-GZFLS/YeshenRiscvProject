/*
 * mini_libc.c -- the handful of libc/libm symbols CoreMark needs, so the build needs neither
 * newlib nor glibc (the riscv64-unknown-elf toolchain here ships libgcc only).
 *
 * memcpy/memset/memmove/memcmp are emitted by the compiler for aggregate copies/initialisers;
 * modf is the only libm function cvt.c reaches for (via ee_printf's %f).
 * modf is written in terms of a truncating (long long) cast, which is exact for the magnitudes
 * CoreMark prints (a score and a MHz ratio); it would lose precision past 2^63.
 */
#include <stddef.h>
#include <math.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    while (n--) {
        if (*x != *y) return (int)*x - (int)*y;
        x++; y++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

double modf(double x, double *iptr)
{
    long long i = (long long)x;
    *iptr = (double)i;
    return x - (double)i;
}
