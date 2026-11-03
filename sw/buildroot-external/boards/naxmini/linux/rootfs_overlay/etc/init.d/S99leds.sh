#!/bin/sh
# S99leds.sh -- 板载 LED 的软件诊断位（见 y1/reports/led_diag_spec.md）
#   led[3] = bit0 Linux 心跳（1 s 翻转；定住 = 内核挂）
#   led[4] = bit1 y1cam 进程在跑
#   led[5] = bit2 NPU busy（读 NPU CSR 0xF000C000 的 bit8）
#   led[6] = bit3 eth0 carrier=1
# 注意：rcS 是 `. S99leds.sh` 源进来执行的 => 死循环必须放后台子进程，否则 init 会停在这里
#
# ★★ 2026-10-30：本脚本只准碰 GPIO 的 bit0..3 ★★
#   同一个 GPIO 块（0xF000_2000）的 bit8..12 是 GT911 触摸的四根线
#   （8 SCL / 9 SDA / 10 RST / 11 INT / 12 KEY3，见 docs/reports/ctp-touch.md）。
#   老版本这里直接 `devmem 0xF0002008 32 0xFF` 写 DIRECTION、每秒又整字写 DATA_OUT，
#   ⇒ bit8..12 被清成 0 输入、RST/SCL/SDA 全高阻 ⇒ 触摸必挂（YeshenGuiTouch 当时是
#   整份删掉本脚本规避）。改成**读-改-写**，只碰 LED 那 4 位，两种镜像共用一份。
GPIO=0xF0002000
NPU=0xF000C000
LEDMASK=0xF
ALLBITS=0xFFFFFFFF
[ -c /dev/mem ] || exit 0
command -v devmem >/dev/null 2>&1 || exit 0
if [ -f /run/leds.pid ] && kill -0 "$(cat /run/leds.pid 2>/dev/null)" 2>/dev/null; then
  exit 0
fi

# 读一个 devmem 字；失败/非 0x 开头一律当 0（否则 $(( )) 会报错退出）
rd() {
  v=$(devmem "$1" 32 2>/dev/null)
  case "$v" in
    0x*) echo "$v" ;;
    *)   echo 0 ;;
  esac
}

d=$(rd $((GPIO + 8)))
devmem $((GPIO + 8)) 32 $(( (d | LEDMASK) & ALLBITS )) 2>/dev/null || exit 0

(
  while :; do
    # 2026-10-25 board: derive the 1 Hz toggle from uptime (loop period is ~2-3 s because of
    # the devmem round-trips, so a loop counter is NOT 1 Hz).
    hb=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    [ -n "$hb" ] || hb=0
    v=$((hb & 1))
    if [ -f /run/y1cam.pid ] && kill -0 "$(cat /run/y1cam.pid 2>/dev/null)" 2>/dev/null; then
      v=$((v | 2))
    fi
    # NPU busy：以前读的是 DATA_IN 的 bit8 —— 那一位现在归 CTP_SCL（I2C 时钟会跳），
    # 读它会伪装成"NPU 忙"。按注释本意直接读 NPU CSR 的 bit8。
    c=$(rd "$NPU")
    if [ $((c & 0x100)) -ne 0 ]; then v=$((v | 4)); fi
    # 2026-10-25 board: this driver keeps operstate at "unknown" even with the link up
    # (carrier=1) -> judge by carrier, else led6 never lights.
    if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ]; then
      v=$((v | 8))
    fi
    o=$(rd $((GPIO + 4)))
    devmem $((GPIO + 4)) 32 $(( (o & (~LEDMASK & ALLBITS)) | v )) >/dev/null 2>&1
    sleep 1
  done
) &
echo $! > /run/leds.pid
