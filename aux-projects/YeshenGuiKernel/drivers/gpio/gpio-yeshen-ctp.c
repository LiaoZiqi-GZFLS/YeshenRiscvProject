// SPDX-License-Identifier: GPL-2.0
/*
 * Yeshen CTP GPIO controller (Phase R touch).
 *
 * A 13-line GPIO block at 0xF0002000:
 *   bits 0..7  = board LEDs (already driven by the existing /dev/mem code)
 *   bit 8      = CTP_SCL (open-drain)
 *   bit 9      = CTP_SDA (open-drain)
 *   bit 10     = CTP_RST (push-pull, active low)
 *   bit 11     = CTP_INT (input)
 *   bit 12     = KEY3 (input)
 *
 * Registers (same as the SoC GPIOController): DATA_IN 0x00, DATA_OUT 0x04,
 * DIRECTION 0x08 (0=input, 1=output). The board top implements the I2C lines
 * as open-drain: output 0 drives low, output 1 releases (external pull-up).
 */
#include <linux/gpio/driver.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/pinctrl/pinconf-generic.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>

#define YG_DATA_IN  0x00
#define YG_DATA_OUT 0x04
#define YG_DIR      0x08
#define YG_NGPIO    13

struct yeshen_gpio {
    void __iomem *base;
    struct gpio_chip gc;
    spinlock_t lock;
};

static int yg_get(struct gpio_chip *gc, unsigned int off)
{
    struct yeshen_gpio *g = gpiochip_get_data(gc);

    /* The IOB does not loop a driven output back into DATA_IN, and the J26
     * panel has no SCL pull-up. i2c-algo-bit polls SCL high after releasing
     * it, so report the driven value for SCL while it is an output. SDA must
     * keep reading the pad to see the slave ACK (it is open-drain). */
    if (off == 8 && (readl(g->base + YG_DIR) & BIT(8)))
        return !!(readl(g->base + YG_DATA_OUT) & BIT(8));
    return !!(readl(g->base + YG_DATA_IN) & BIT(off));
}

static void yg_set(struct gpio_chip *gc, unsigned int off, int val)
{
    struct yeshen_gpio *g = gpiochip_get_data(gc);
    unsigned long flags;
    u32 v;

    spin_lock_irqsave(&g->lock, flags);
    v = readl(g->base + YG_DATA_OUT);
    if (val)
        v |= BIT(off);
    else
        v &= ~BIT(off);
    writel(v, g->base + YG_DATA_OUT);
    spin_unlock_irqrestore(&g->lock, flags);
}

static int yg_dir_in(struct gpio_chip *gc, unsigned int off)
{
    struct yeshen_gpio *g = gpiochip_get_data(gc);
    unsigned long flags;
    u32 v;

    spin_lock_irqsave(&g->lock, flags);
    v = readl(g->base + YG_DIR);
    v &= ~BIT(off);
    writel(v, g->base + YG_DIR);
    spin_unlock_irqrestore(&g->lock, flags);
    return 0;
}

static int yg_dir_out(struct gpio_chip *gc, unsigned int off, int val)
{
    struct yeshen_gpio *g = gpiochip_get_data(gc);
    unsigned long flags;
    u32 v;

    /* Drive the data bit before enabling the output so an open-drain line
     * does not glitch low when the direction changes. */
    spin_lock_irqsave(&g->lock, flags);
    v = readl(g->base + YG_DATA_OUT);
    if (val)
        v |= BIT(off);
    else
        v &= ~BIT(off);
    writel(v, g->base + YG_DATA_OUT);
    v = readl(g->base + YG_DIR);
    v |= BIT(off);
    writel(v, g->base + YG_DIR);
    spin_unlock_irqrestore(&g->lock, flags);
    return 0;
}

static int yg_set_config(struct gpio_chip *gc, unsigned int off,
                         unsigned long config)
{
    (void)gc;
    (void)off;
    if (pinconf_to_config_param(config) == PIN_CONFIG_DRIVE_OPEN_DRAIN)
        return 0;
    return -ENOTSUPP;
}

static int yg_probe(struct platform_device *pdev)
{
    struct yeshen_gpio *g;
    struct resource *res;

    g = devm_kzalloc(&pdev->dev, sizeof(*g), GFP_KERNEL);
    if (!g)
        return -ENOMEM;

    res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
    g->base = devm_ioremap_resource(&pdev->dev, res);
    if (IS_ERR(g->base))
        return PTR_ERR(g->base);

    /* The board top drives ctp_rst from DATA_OUT[10] even while the line is
     * configured as input, so release the GT911 before i2c-gpio/goodix probe
     * (a reset-low panel never ACKs). */
    writel(readl(g->base + YG_DATA_OUT) | BIT(10), g->base + YG_DATA_OUT);
    writel(readl(g->base + YG_DIR) & ~BIT(10), g->base + YG_DIR);

    spin_lock_init(&g->lock);
    g->gc.label = "yeshen-ctp-gpio";
    g->gc.parent = &pdev->dev;
    g->gc.owner = THIS_MODULE;
    g->gc.base = -1;
    g->gc.ngpio = YG_NGPIO;
    g->gc.get = yg_get;
    g->gc.set = yg_set;
    g->gc.direction_input = yg_dir_in;
    g->gc.direction_output = yg_dir_out;
    g->gc.set_config = yg_set_config;
    g->gc.of_node = pdev->dev.of_node;

    return devm_gpiochip_add_data(&pdev->dev, &g->gc, g);
}

static const struct of_device_id yg_of_match[] = {
    { .compatible = "yeshen,ctp-gpio" },
    { }
};
MODULE_DEVICE_TABLE(of, yg_of_match);

static struct platform_driver yg_driver = {
    .probe = yg_probe,
    .driver = {
        .name = "yeshen-ctp-gpio",
        .of_match_table = yg_of_match,
    },
};
module_platform_driver(yg_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Yeshen CTP GPIO controller");
