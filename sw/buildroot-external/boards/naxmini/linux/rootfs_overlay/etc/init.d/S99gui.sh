#!/bin/sh
# S99gui.sh —— 开机进入桌面（2026-10-30 起默认开启）
#
# 标记文件 /etc/y1gui.autostart 存在且 /root/gui/yshell 可执行时启动。
# 启动参数：
#   --no-uart   不打开 /dev/ttyS0（getty 还占着它，抢字节会让串口登录打字丢失）
#   不带 --demo 正常桌面；键盘只剩触屏 + KEY4
#
# ⚠️ 必须 `setsid ... </dev/null`：`nohup ... &` 会收到 SIGTTOU 停住
#    （YeshenGuiTouch 上板实测，state=T 且没有 `YGUI-FB-OK`）。
#
# yshell 来源：YeshenGui 仓 `GUI_VARIANT=mainline`（GUI_CTRL 偏移 0x09C），
# 只能配主线 RTL（带 GUI_READ_SRC 的比特流）。
if [ -f /etc/y1gui.autostart ] && [ -x /root/gui/yshell ]; then
    setsid /root/gui/yshell --no-uart </dev/null >/tmp/gui.log 2>&1 &
    echo "YGUI-AUTOSTART pid=$!" >/dev/kmsg 2>/dev/null
fi
