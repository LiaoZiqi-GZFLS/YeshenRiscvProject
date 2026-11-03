set -uo pipefail
export PATH=/home/lazybones/vexii-build/buildroot/output/host/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export ARCH=riscv CROSS_COMPILE=riscv32-buildroot-linux-uclibc-
export KBUILD_BUILD_TIMESTAMP='2026-11-01 00:00:00' KBUILD_BUILD_USER=yeshen KBUILD_BUILD_HOST=pangu676
cd /home/lazybones/lx618/linux-6.18.60 || exit 2
MARCH=rv32imac_zicsr_zifencei_zacas_zabha_zbb_zbs
make -j8 KCFLAGS="-march=$MARCH" KAFLAGS="-march=$MARCH" Image 2>&1 | tail -8
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "KERNEL_BUILD_FAIL rc=$rc"; exit 5; }
cp -f arch/riscv/boot/Image /mnt/d/code/PDS/VexiiYeshenLinux/sw/images/Image.618.zbb
md5sum /mnt/d/code/PDS/VexiiYeshenLinux/sw/images/Image.618.zbb /mnt/d/code/PDS/VexiiYeshenLinux/sw/images/Image.618
printf 'ZBB_SAFE_STRINGS='; strings arch/riscv/boot/Image | grep -c "Zbb"
echo KERNEL_ZBB_DONE
