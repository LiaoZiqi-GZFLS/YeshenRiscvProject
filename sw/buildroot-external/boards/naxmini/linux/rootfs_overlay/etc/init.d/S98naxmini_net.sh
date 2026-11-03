#!/bin/sh
#
# ★ 2026-10-06：LiteEth 网卡上电后**自动起 eth0**（静态地址），便于板上直接 ping/tcp 验证。
#
# 为什么需要它：内核起来后网卡默认是 DOWN 且无地址，`udhcpc` 又要等 DHCP 服务器（实验室不一定有）
# ⇒ 为了"上电就能被 ping 到"这条判据，这里直接给一个静态地址。
#
# 地址口径**沿用本工程以太网装载器时代**的那一组（见 scripts/eth_load_images.py 的
# `--src 192.168.1.105` / `--dst 192.168.1.11`、scripts/udp_echo_test.py 的 192.168.1.110）：
#   板 = 192.168.1.110/24，主机面向板的网卡 = 192.168.1.105/24。
#   MAC 由 DT 固定成 02:00:00:00:00:01（见 linux_raw.dts 的 local-mac-address）——
#   刻意**不同于**厂家栈时代的 11:11:11:11:11:11，这样一抓包就能分辨是哪个栈在发包。
#
# ⚠️ 本脚本对"网卡没起来"是**无副作用**的：`ip` 不在 / `$IF` 不存在 都只是安静跳过，
#    不会拖住 rcS 后面的启动（`|| true`）。要换地址直接改下面的 IP/IF。
IF=eth0
IP=192.168.1.110
MASK=24
GW=192.168.1.1

[ -e "/sys/class/net/$IF" ] || exit 0

# busybox 的 `ip` 有 link/addr 子命令；个别配置里只有 ifconfig ⇒ 两条路都试。
if command -v ip >/dev/null 2>&1; then
	ip link set "$IF" up         2>/dev/null || true
	ip addr add "$IP/$MASK" dev "$IF" 2>/dev/null || true
	ip route add default via "$GW" 2>/dev/null || true
elif command -v ifconfig >/dev/null 2>&1; then
	ifconfig "$IF" "$IP" netmask 255.255.255.0 up 2>/dev/null || true
fi

# 报文走 kmsg（= printk → console 路径），理由同 S99naxmini_marker.sh：
# 16550 的 tty 写路径会丢字符，console 路径才是逐字节等 THRE 的。
[ -c /dev/kmsg ] || mknod /dev/kmsg c 1 11 2>/dev/null
{
	printf 'NAXMINI-NET: %s ' "$IF"
	if command -v ip >/dev/null 2>&1; then
		ip -o addr show dev "$IF" 2>/dev/null | tr -s ' ' | cut -d' ' -f4
	else
		ifconfig "$IF" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'
	fi
} > /dev/kmsg 2>/dev/null || true

exit 0
