#!/bin/sh
#
# ★ 2026-10-02：P1 交付判据 marker。★ 2026-10-07：本工程改名 VEXIIYESHEN-OK
#   （沿用自 NaxYeshenLinux 的 NAXMINI-USPACE-OK，与核无关，纯命名）。
#
# 为什么落在 rcS 环节、而不是 /etc/profile：
#   /etc/profile 只有**交互登录成功**才会执行；inittab 的 getty 没有输入时永远停在
#   "login:" 提示上 ⇒ profile 永不执行（实测：一直跑到 max_cyc 停发都没出现）。
#   rcS 是 init 的 `::sysinit:` 环节，**先于 getty** 执行且不依赖任何输入，
#   是"内核已把 /init 从 initramfs 拉起来并跑通用户态"最可靠的落点。
#
# 为什么经 /dev/kmsg（= printk）、而不是直写 /dev/console：
#   本 SoC 的 16550 RTL **没有发送 FIFO**（TX 只有 1 字节 holding + 移位器），
#   却向驱动上报 16550A ⇒ 驱动按 fifo_size=16 盲写 UART_TX
#   （`serial8250_tx_chars()` 一口气写 16 字节、**不等 THRE**），RTL 只留最后那 1 字节
#   ⇒ tty 写路径（含 /dev/console）整段丢字符：实测 rcS 横幅与 getty 提示全糊。
#   而内核 **console 路径**（`serial8250_console_write()`）是**逐字节等 THRE**，
#   实测每字节严格 10368 拍、零空档 ⇒ 走 /dev/kmsg 进 printk，再由 console 路径发出。
#
# 注：rcS 对 `*.sh` 是「source 执行」，故本文件不依赖可执行位。
M="VEXIIYESHEN-OK"
[ -c /dev/kmsg ] || mknod /dev/kmsg c 1 11 2>/dev/null
printf '%s\n' "$M" > /dev/kmsg 2>/dev/null \
	|| printf '%s\n' "$M" > /dev/console 2>/dev/null
