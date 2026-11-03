#!/bin/bash
# Build the touch kernel in an independent copy of the shared Buildroot kernel
# source. Never writes the shared buildroot or VexiiYeshenLinux.
set -euo pipefail

PROJ=/mnt/d/code/PDS/YeshenGuiKernel
SRC=$HOME/vexii-build/buildroot/output/build/linux-dev
DST=$HOME/vexii-gui-build/linux-touch
CROSS=$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-
LOG=$PROJ/out/kernel_build.log
mkdir -p "$PROJ/out" "$(dirname "$DST")"
exec > >(tee "$LOG") 2>&1

echo "KERNEL_TOUCH_START $(date)"
if [ ! -f "$DST/Makefile" ]; then
    echo "copying kernel source (source-only snapshot)..."
    mkdir -p "$DST"
    rsync -a \
        --exclude='.git' --exclude='*.o' --exclude='*.a' --exclude='*.cmd' \
        --exclude='*.d' --exclude='*.dtb' --exclude='Image' --exclude='/vmlinux' \
        --exclude='*.ko' --exclude='.tmp*' \
        "$SRC/" "$DST/"
fi

cp "$PROJ/config/kernel_base.config" "$DST/.config"
cp "$PROJ/dts/linux_touch.dts" "$DST/arch/riscv/boot/dts/linux.dts"
cp "$PROJ/drivers/gpio/gpio-yeshen-ctp.c" "$DST/drivers/gpio/"

grep -q "GPIO_YESHEN_CTP" "$DST/drivers/gpio/Kconfig" || cat >> "$DST/drivers/gpio/Kconfig" <<'EOF'

config GPIO_YESHEN_CTP
    tristate "Yeshen CTP GPIO controller"
    depends on OF_GPIO
    help
      GPIO controller for the GT911 CTP lines (YeshenGui touch variant).
EOF
grep -q "gpio-yeshen-ctp" "$DST/drivers/gpio/Makefile" || \
    echo 'obj-$(CONFIG_GPIO_YESHEN_CTP) += gpio-yeshen-ctp.o' >> "$DST/drivers/gpio/Makefile"

cd "$DST"
for c in I2C I2C_GPIO I2C_CHARDEV GPIOLIB GPIO_CDEV OF_GPIO INPUT_EVDEV INPUT_TOUCHSCREEN \
         TOUCHSCREEN_GOODIX INPUT_KEYBOARD KEYBOARD_GPIO_POLLED GPIO_YESHEN_CTP; do
    scripts/config --enable "$c"
done
make ARCH=riscv CROSS_COMPILE="$CROSS" olddefconfig
grep -E "CONFIG_(I2C|I2C_GPIO|I2C_CHARDEV|GPIOLIB|GPIO_CDEV|OF_GPIO|INPUT_EVDEV|INPUT_TOUCHSCREEN|TOUCHSCREEN_GOODIX|INPUT_KEYBOARD|KEYBOARD_GPIO_POLLED|GPIO_YESHEN_CTP)=" .config

make ARCH=riscv CROSS_COMPILE="$CROSS" -j4 Image

# The kernel's in-tree dtb target does not cover the Buildroot custom DTS in
# this tree; use the exact cpp+dtc recipe from .linux.dtb.cmd instead.
/usr/bin/gcc -O2 -E -nostdinc -I./scripts/dtc/include-prefixes -undef -D__DTS__ \
    -x assembler-with-cpp -o arch/riscv/boot/dts/.linux.dtb.dts.tmp \
    arch/riscv/boot/dts/linux.dts
./scripts/dtc/dtc -O dtb -o arch/riscv/boot/dts/linux.dtb -b 0 \
    -i arch/riscv/boot/dts -i ./scripts/dtc/include-prefixes \
    -Wno-interrupt_provider -Wno-unit_address_vs_reg -Wno-unit_address_format \
    -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-graph_child_address \
    -Wno-simple_bus_reg -Wno-unique_unit_address -Wno-pci_device_reg \
    arch/riscv/boot/dts/.linux.dtb.dts.tmp
cp arch/riscv/boot/Image "$PROJ/out/Image.touch"
cp arch/riscv/boot/dts/linux.dtb "$PROJ/out/linux_touch.dtb"
( cd "$PROJ/out" && sha256sum Image.touch linux_touch.dtb && stat -c '%n %s' Image.touch linux_touch.dtb )
echo "KERNEL_TOUCH_DONE $(date)"
