#!/bin/sh
# S99y1cam.sh —— YuNet 自启（2026-10-30 起**默认不开**）
#
# GUI 镜像里人脸检测由相机应用按需拉起（Detect faces），退出相机视图时停掉；
# 这里保留一个可选入口，只有 /etc/y1cam.autostart 存在时才在开机时常驻：
#
#   touch /etc/y1cam.autostart   # 然后重启
#
# 该 SoC 的 16550 没有发送 FIFO，诊断日志走 /dev/kmsg。
[ -f /etc/y1cam.autostart ] || exit 0
[ -c /dev/kmsg ] || mknod /dev/kmsg c 1 11 2>/dev/null
if [ -x /root/y1/y1cam ]; then
	/root/y1/y1cam --loop --quiet >/dev/null 2>&1 &
	echo $! > /run/y1cam.pid 2>/dev/null
	printf 'Y1CAM-BOOT pid=%s\n' "$(cat /run/y1cam.pid 2>/dev/null)" > /dev/kmsg 2>/dev/null
else
	printf 'Y1CAM-BOOT missing /root/y1/y1cam\n' > /dev/kmsg 2>/dev/null
fi
