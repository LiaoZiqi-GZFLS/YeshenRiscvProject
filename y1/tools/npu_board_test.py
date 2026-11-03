#!/usr/bin/env python3
"""npu_board_test.py -- 板上 NPU 端到端（MaxPool，无需权重）数值对账。

假设：NPU 的 28bit 地址 A 落到 DDR 的物理 0x80000000+A（即桥/DDR IP 只看低位偏移）。
  这套断言本身就是被测对象之一：若假设错，输出区会是未写过的 0/脏值 ⇒ MISMATCH。

几何：C=8, W=32, H=2  → 输入 512 B（128 word），MaxPool 2x2/s2 → 输出 C=8, W=16, H=1（128 B = 32 word）
NPU 地址：输入 0x00100000，输出 0x00200000，描述符表 0x00300000
CPU 侧（对应物理）：0x80100000 / 0x80200000 / 0x80300000
寄存器窗：CTRL=0xF000C000  STATUS=0xF000C004  DESC_ADDR=0xF000C034  DESC_COUNT=0xF000C038
"""
import serial, time, re, sys

PORT="COM7"; BAUD=115200
SRC_NPU=0x00100000; DST_NPU=0x00200000; TBL_NPU=0x00300000
SRC_PHY=0x80100000; DST_PHY=0x80200000; TBL_PHY=0x80300000
W,H,C=32,2,8
NW_IN=(W*H*C)//4          # 128
NW_OUT=((W//2)*(H//2)*C)//4   # 32

# 与板端写入完全同口径的黄金（word j = j*0x01010101，字节 = (j,j,j,j)）
def in_bytes():
    b=bytearray()
    for j in range(W*H*C//4):
        v=(j*0x01010101)&0xFFFFFFFF
        b+=bytes([(v>>(8*k))&0xFF for k in range(4)])
    return bytes(b)

def golden_out():
    ib=in_bytes(); ob=bytearray()
    for r in range(H//2):
        for x in range(W//2):
            for ch in range(C):
                m=max(ib[((r*2+dy)*W+(x*2+dx))*C+ch] for dy in (0,1) for dx in (0,1))
                ob.append(m)
    return bytes(ob)

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
    o=drain(t).decode('latin-1').replace('\r','')
    return o

s.write(b"\x03\x03\r\x11"); time.sleep(0.4); drain(0.8)
print("=== 1) 清场 ==="); print(slow("echo CLEAN_OK"))

print("=== 2) 写输入 512B 到物理 0x%08x（NPU 视作 0x%08x）===" % (SRC_PHY,SRC_NPU))
print(slow("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32 $((j*16843009)); A=$((A+4)); done; echo IN_DONE"%(SRC_PHY,NW_IN-1), t=6.0))

print("=== 3) 读回 3 个输入 word（证明写入落地）===")
print(slow("devmem 0x%08X 32"%SRC_PHY)); print(slow("devmem 0x%08X 32"%(SRC_PHY+4)))

print("=== 4) 写描述符表（9 word，含哨兵）到 0x%08x ==="%TBL_PHY)
# 冻结口径（照 run_nputop_sched_ab.sh 的 d2）：maxpool 的 IMG_W/IMG_H 是**输出**尺寸，
# IN_BYTES 是**输入**字节数（C*H*W = 8*2*32 = 512）。
tbl=[0x00000110,0x00010010,0x00080008,0x00000201,SRC_NPU,DST_NPU,0x00000200,0x00000000,0x000000FF]
for k,v in enumerate(tbl):
    slow("devmem 0x%08X 32 0x%08X"%(TBL_PHY+k*4,v), quiet=True)
print("  table written:", " ".join("0x%08X"%v for v in tbl))
print(slow("devmem 0x%08X 32"%TBL_PHY)); print(slow("devmem 0x%08X 32"%(TBL_PHY+32)))

print("=== 5) 预清输出区（写 0x55 便于看是否被 NPU 改过）===")
print(slow("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32 0x55555555; A=$((A+4)); done; echo DST_CLEARED"%(DST_PHY,NW_OUT-1), t=4.0))

print("=== 6) 起跑：DESC_ADDR / DESC_COUNT=1 / CTRL.start ===")
print(slow("devmem 0xF000C000 32 0x00000002"))   # soft_reset：清上一次的 errSticky（否则 STATUS 读到陈旧 err）
print(slow("devmem 0xF000C034 32 0x%08X"%TBL_NPU))
print(slow("devmem 0xF000C038 32 0x00000001"))
print(slow("devmem 0xF000C000 32 0x00000001"))

print("=== 7) 轮询 STATUS(0xF000C004) ===")
st=None
for i in range(40):
    o=slow("devmem 0xF000C004 32", t=1.5, quiet=True)
    m=re.findall(r"0x([0-9A-Fa-f]{8})", o)
    if m:
        st=int(m[-1],16)
        if i%4==0 or (st&0x3): print("   poll%d STATUS=0x%08X (done=%d err=%d)"%(i,st,st&1,(st>>1)&1))
    if st is not None and (st&0x3): break
    time.sleep(0.2)
print("  final STATUS=%s"%(("0x%08X"%st) if st is not None else "?"))
print(slow("devmem 0xF000C000 32")); print(slow("devmem 0xF000C004 32"))

print("=== 8) 读输出 32 word @0x%08x ==="%DST_PHY)
o=slow("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32; A=$((A+4)); done; echo OUT_DONE"%(DST_PHY,NW_OUT-1), t=6.0)
print(o)
words=[int(x,16) for x in re.findall(r"(?m)^0x([0-9A-Fa-f]{8})\s*$", o)]
got=bytearray()
for w in words[:NW_OUT]:
    got+=bytes([(w>>(8*k))&0xFF for k in range(4)])
gol=golden_out()
print("=== 9) 对账 ===")
print("  读到 word 数 =", len(words[:NW_OUT]), " 期望", NW_OUT)
if len(got)!=len(gol):
    print("  !! 长度不符 got=%d gol=%d"%(len(got),len(gol)))
else:
    bad=sum(1 for a,b in zip(got,gol) if a!=b)
    first=next((i for i,(a,b) in enumerate(zip(got,gol)) if a!=b), -1)
    print("  MISMATCH=%d FIRST_OFF=%d"%(bad,first))
    print("  got[:16] =", got[:16].hex())
    print("  gol[:16] =", gol[:16].hex())
    print("  got all-0x55 (未被写)? %s"%(all(x==0x55 for x in got)))
    print("  RESULT:", "PASS" if bad==0 else "FAIL")
s.close()
