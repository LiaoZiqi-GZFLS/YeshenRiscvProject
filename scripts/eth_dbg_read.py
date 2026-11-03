#!/usr/bin/env python3
"""eth_dbg_read.py -- 读 `liteeth_wrap` 的只读观测窗（0xF000B000，6 个字）并解码成人话。

用法：python -u scripts/eth_dbg_read.py COM7 115200 [轮数]
  默认读两轮（间隔 ~2s）：**两轮一对比**就能看出"哪些计数在动"。

窗口定义（board/liteeth_wrap.v）：
  W0 = {rxCnt[31:24], txCnt[23:16], csrCnt[15:8], 4'b0, rxDvSeen, txEnSeen, rxcHi, rxcLo}
  W1 = sys 自由跑计数（两轮不同 => 窗口活着）
  W2 = 最后一次 CSR **写** {1'b0, addr[5:0], data[23:0], we}   （addr 是**字**号 => 字节 = ×4）
  W3 = 最后一次 CSR **读** {1'b0, addr[5:0], data[23:0], 0}
  W4 = {txBytes[31:16], rxBytes[15:0]}        GMII 上"发出/收到"的字节数
  W5 = {rxRunMax[31:24], txRunMax[23:16], 16'h0}  最长连续长度（上万 => 永不结束的帧）
"""
import re
import subprocess
import sys
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM7"
BAUD = sys.argv[2] if len(sys.argv) > 2 else "115200"
ROUNDS = int(sys.argv[3]) if len(sys.argv) > 3 else 2

CMD = ("printf 'DBG %s %s %s %s %s %s\\n' $(devmem 0xF000B000) $(devmem 0xF000B004) "
       "$(devmem 0xF000B008) $(devmem 0xF000B00C) $(devmem 0xF000B010) $(devmem 0xF000B014)")


def read_once():
    out = subprocess.run([sys.executable, "-u", "scripts/guest_cmd.py", PORT, BAUD, CMD],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    m = re.search(r"DBG\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})\s+"
                  r"0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})\s+0x([0-9A-Fa-f]{8})", out.stdout)
    if not m:
        print("!! ??????????????guest_cmd ?????")
        print(out.stdout[-600:])
        return None
    return [int(x, 16) for x in m.groups()]


def show(w):
    w0, w1, w2, w3, w4, w5 = w
    print("  W0=0x%08X  rxcLo=%d rxcHi=%d(%s)  txEnSeen=%d  rxDvSeen=%d  csrCnt=%d  txCnt=%d  rxCnt=%d"
          % (w0, w0 & 1, (w0 >> 1) & 1,
             "时钟在跳" if ((w0 >> 1) & 1) and (w0 & 1) else "时钟钉死",
             (w0 >> 2) & 1, (w0 >> 3) & 1, (w0 >> 8) & 0xFF, (w0 >> 16) & 0xFF, (w0 >> 24) & 0xFF))
    print("  W1=0x%08X (sys ???????? => ???)" % w1)
    print("  W2=0x%08X  last CSR W: word=%d(byte 0x%02X) data=0x%06X we=%d"
          % (w2, (w2 >> 25) & 0x3F, ((w2 >> 25) & 0x3F) * 4, (w2 >> 1) & 0xFFFFFF, w2 & 1))
    print("  W3=0x%08X  last CSR R: word=%d(byte 0x%02X) data=0x%06X"
          % (w3, (w3 >> 25) & 0x3F, ((w3 >> 25) & 0x3F) * 4, (w3 >> 1) & 0xFFFFFF))
    print("  W4=0x%08X  GMII txBytes=%d rxBytes=%d" % (w4, (w4 >> 16) & 0xFFFF, w4 & 0xFFFF))
    print("  W5=0x%08X  txRunMax=%d rxRunMax=%d  (>1000 => ????????)"
          % (w5, (w5 >> 16) & 0xFF, (w5 >> 24) & 0xFF))


prev = None
for i in range(ROUNDS):
    w = read_once()
    if w is None:
        break
    print("== ? %d ? ==" % (i + 1))
    show(w)
    if prev is not None:
        d = [b - a for a, b in zip(prev, w)]
        print("  DELTA = W0:%+d W1:%+d W2:%+d W3:%+d txBytes:%+d rxBytes:%+d W5:%+d"
              % (d[0], d[1], d[2], d[3], ((w[4]>>16)&0xFFFF)-((prev[4]>>16)&0xFFFF),
                 (w[4]&0xFFFF)-(prev[4]&0xFFFF), d[5]))
        print("  => txBytes ??/??? = MAC ?????rxBytes ?? = PHY ??????")
    prev = w
    if i + 1 < ROUNDS:
        time.sleep(2)
