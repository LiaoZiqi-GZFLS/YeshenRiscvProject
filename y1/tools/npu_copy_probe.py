#!/usr/bin/env python3
"""npu_copy_probe.py -- 判别实验：NPU 的 DDR 通路到底通不通？

走**遗留 C2 块拷贝**（DESC_COUNT==0 ⇒ `ddrMaster` 直接 src→dst），绕过调度器：
  IMG_W=4, IMG_H=1, C_IN=8 ⇒ len = 32 B（32 的倍数，合法最小）
  SRC(NPU)=0x00100000  DST(NPU)=0x00200000   ⇒ CPU 侧 0x80100000 / 0x80200000
判据：
  ① 先把 DST 物理区清成 0x55；② 起拷贝；③ 读 DST 物理区。
  - 若 DST 变成 SRC 的内容 ⇒ **NPU↔DDR 通**，之前 MaxPool 的 err 出在我的描述符/几何
  - 若 DST 仍 0x55 / 全 0 ⇒ **NPU 的地址到不了 DDR**（28bit 空间 vs 0x8000_0000 基址）
"""
import serial, time, re
PORT="COM7"; BAUD=115200
SRC_NPU=0x00100000; DST_NPU=0x00200000
SRC_PHY=0x80100000; DST_PHY=0x80200000
s=serial.Serial(PORT,BAUD,timeout=0.2); s.dtr=False; s.rts=False; time.sleep(0.3)
def drain(t=0.8):
    b=b""; t0=time.time()
    while time.time()-t0<t:
        d=s.read(4096)
        if d: b+=d
    return b
def slow(cmd, gap=0.010, t=3.0, quiet=False):
    if not quiet: print("  $ "+cmd)
    for ch in cmd+"\r":
        s.write(ch.encode()); time.sleep(gap)
    return drain(t).decode('latin-1').replace('\r','')
def vals(o):
    """只取独占一行的 0xXXXXXXXX（滤掉命令回显）"""
    return [int(m,16) for m in re.findall(r"(?m)^0x([0-9A-Fa-f]{8})\s*$", o)]

s.write(b"\x03\x03\r\x11"); time.sleep(0.4); drain(0.8)

print("=== 1) 在 SRC 物理区写 8 个已知 word（同 0x01010101 模式）===")
print(slow("A=0x%08X; for j in $(seq 1 8); do devmem $A 32 $((j*16843009)); A=$((A+4)); done; echo SRC_WR"%(SRC_PHY), t=4.0))
o=slow("devmem 0x%08X 32"%SRC_PHY); print("  SRC[0] =", o.strip().splitlines()[-1])
o=slow("devmem 0x%08X 32"%(SRC_PHY+4)); print("  SRC[1] =", o.strip().splitlines()[-1])

print("=== 2) 清 DST 物理区为 0x55（8 word）===")
print(slow("A=0x%08X; for j in $(seq 1 8); do devmem $A 32 0x55555555; A=$((A+4)); done; echo DST_WR"%(DST_PHY), t=4.0))
o=slow("devmem 0x%08X 32"%DST_PHY); print("  DST[0] 清后 =", o.strip().splitlines()[-1])

print("=== 3) 起遗留块拷贝：IMG_W=16 IMG_H=1 C_IN=8 ⇒ len=128（必须 %128==0，NpuTop 的 lenOk 仍按老口径）===")
print(slow("devmem 0xF000C034 32 0x00000000"))   # DESC_ADDR 顺手清 0
print(slow("devmem 0xF000C038 32 0x00000000"))   # DESC_COUNT=0 ⇒ 走遗留拷贝
print(slow("devmem 0xF000C008 32 0x00000010"))   # IMG_W=16
print(slow("devmem 0xF000C00C 32 0x00000001"))   # IMG_H=1
print(slow("devmem 0xF000C010 32 0x00000008"))   # C_IN=8
print(slow("devmem 0xF000C020 32 0x%08X"%SRC_NPU))  # SRC_ADDR
print(slow("devmem 0xF000C024 32 0x%08X"%DST_NPU))  # DST_ADDR
print(slow("devmem 0xF000C000 32 0x00000001"))   # CTRL.start

print("=== 4) 轮询 STATUS ===")
st=None
for i in range(30):
    o=slow("devmem 0xF000C004 32", t=1.5, quiet=True)
    v=vals(o)
    if v: st=v[-1]
    if st is not None and (st&0x3): print("   poll%d STATUS=0x%08X (done=%d err=%d)"%(i,st,st&1,(st>>1)&1)); break
    time.sleep(0.2)
print("  final STATUS=%s"%(("0x%08X"%st) if st is not None else "?"))

print("=== 5) 读 DST 物理区（4 word 足够判）===")
o=slow("A=0x%08X; for j in $(seq 1 4); do devmem $A 32; A=$((A+4)); done; echo DST_RD"%(DST_PHY), t=4.0)
print(o)
d=vals(o); print("  DST =", ["0x%08X"%x for x in d])
print("  判据：DST[0..3] 是否 == SRC 的 0x01010101/0x02020202/0x03030303/0x04040404 ?",
      " => ", "COPY_OK（NPU↔DDR 通）" if d[:4]==[0x01010101,0x02020202,0x03030303,0x04040404] else "NOT_COPIED（NPU 到不了 DDR 或未跑）")
print("  DST 是否仍是 0x55555555 ?", all(x==0x55555555 for x in d[:4]))
s.close()
