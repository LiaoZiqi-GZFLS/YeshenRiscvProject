/* touch_scan.c -- minimal /dev/mem I2C scanner for the GT911 on YeshenGui.
 *
 * SCL is push-pull (the J26 panel has no SCL pull-up); SDA is open-drain.
 * Build static with the Buildroot RV32 toolchain and run on the board:
 *     touch_scan            scan 0x08..0x77, then read GT911 ID at 0x5D/0x14
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define GPIO_BASE 0xF0002000u
#define R_IN   0x00
#define R_OUT  0x04
#define R_DIR  0x08

static volatile uint32_t *g;

static uint32_t rd(int off) { return g[off / 4]; }
static void wr(int off, uint32_t v) { g[off / 4] = v; }
static void dly(void) { for (volatile int i = 0; i < 500; i++) { } }

static void scl(int v)
{
    uint32_t o = rd(R_OUT) & ~(1u << 8);
    if (v) o |= 1u << 8;
    wr(R_OUT, o);
    wr(R_DIR, rd(R_DIR) | (1u << 8));
    dly();
}

static void sda(int released)
{
    uint32_t o = rd(R_OUT) & ~(1u << 9);
    uint32_t d = rd(R_DIR);
    if (released) {
        o |= 1u << 9;
        d &= ~(1u << 9);
    } else {
        d |= 1u << 9;
    }
    wr(R_OUT, o);
    wr(R_DIR, d);
    dly();
}

static int sda_val(void) { return (int)((rd(R_IN) >> 9) & 1u); }

static void i2c_start(void)
{
    sda(1);
    scl(1);
    sda(0);
    scl(0);
}

static void i2c_stop(void)
{
    sda(0);
    scl(1);
    sda(1);
    dly();
}

static void i2c_bit(int bit)
{
    sda(bit ? 1 : 0);
    scl(1);
    scl(0);
}

static int i2c_read_bit(void)
{
    int v;
    sda(1);
    scl(1);
    v = sda_val();
    scl(0);
    return v;
}

static int i2c_write(uint8_t b)
{
    for (int i = 7; i >= 0; i--) i2c_bit((b >> i) & 1);
    return i2c_read_bit();          /* 0 = ACK */
}

static uint8_t i2c_read(int ack)
{
    uint8_t b = 0;
    for (int i = 7; i >= 0; i--) b = (uint8_t)((b << 1) | i2c_read_bit());
    i2c_bit(ack ? 0 : 1);
    return b;
}

static int read_id(uint8_t addr, uint8_t out[2])
{
    int ack;
    i2c_start();
    ack = i2c_write((uint8_t)(addr << 1));
    if (ack) { i2c_stop(); return -1; }
    ack = i2c_write(0x81);
    if (ack) { i2c_stop(); return -2; }
    ack = i2c_write(0x40);
    if (ack) { i2c_stop(); return -3; }
    i2c_start();
    ack = i2c_write((uint8_t)((addr << 1) | 1));
    if (ack) { i2c_stop(); return -4; }
    out[0] = i2c_read(1);
    out[1] = i2c_read(0);
    i2c_stop();
    return 0;
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    g = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GPIO_BASE);
    if (g == MAP_FAILED) { perror("mmap"); return 1; }

    printf("GPIO before in=%08x out=%08x dir=%08x\n",
           rd(R_IN), rd(R_OUT), rd(R_DIR));
    wr(R_OUT, rd(R_OUT) | (1u << 8) | (1u << 9));
    wr(R_DIR, (rd(R_DIR) | (1u << 8)) & ~(1u << 9));
    dly();
    printf("GPIO idle   in=%08x out=%08x dir=%08x\n",
           rd(R_IN), rd(R_OUT), rd(R_DIR));

    for (int a = 0x08; a < 0x78; a++) {
        i2c_start();
        int ack = i2c_write((uint8_t)(a << 1));
        i2c_stop();
        if (ack == 0) printf("ACK 0x%02x\n", a);
    }

    uint8_t id[2];
    int r5 = read_id(0x5d, id);
    printf("ID@5d rc=%d %02x%02x\n", r5, id[0], id[1]);
    int r14 = read_id(0x14, id);
    printf("ID@14 rc=%d %02x%02x\n", r14, id[0], id[1]);

    scl(1);
    sda(1);
    printf("GPIO after  in=%08x out=%08x dir=%08x\n",
           rd(R_IN), rd(R_OUT), rd(R_DIR));
    return 0;
}
