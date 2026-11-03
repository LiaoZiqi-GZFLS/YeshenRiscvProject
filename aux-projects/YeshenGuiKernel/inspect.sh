#!/bin/bash
set -u
B="$HOME/vexii-build/buildroot/output/build"
echo "BUILD=$B"
ls -la "$B" 2>/dev/null | grep -i linux
echo "--- linux-dev"
ls -la "$B/linux-dev" 2>/dev/null | head -8
echo "--- config"
S="$B/linux-dev"
[ -f "$S/.config" ] && wc -l "$S/.config" && grep -E "CONFIG_(I2C|I2C_GPIO|GPIOLIB|GPIO_CDEV|INPUT_EVDEV|TOUCHSCREEN_GOODIX|KEYBOARD_GPIO_POLLED|UNIX98_PTYS|DEVTMPFS|OF)" "$S/.config" | head -30 || echo "no .config"
echo "--- image/dtb"
ls -l "$S/arch/riscv/boot/Image" "$S/arch/riscv/boot/dts" 2>/dev/null | head -10
echo "--- version"
[ -f "$S/Makefile" ] && head -5 "$S/Makefile"
echo "--- dts candidates"
find "$S/arch/riscv/boot/dts" -maxdepth 2 -type f 2>/dev/null | head -20
echo "--- toolchain"
ls -l "$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc" 2>/dev/null
echo "--- disk"
df -h "$HOME" | tail -1
