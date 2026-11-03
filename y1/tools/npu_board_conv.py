#!/usr/bin/env python3
"""npu_board_conv.py -- 板上 NPU 端到端 **conv3x3 dense（带权重）** 数值对账。

权重经 AxiLite 信箱逐字节灌进 slice0 的 WeightStore（576 B）。
权重取 shell 可算的短式：w(k) = (k % 5) - 2  （k=0..575 = WeightStore 展平地址）
  展平地址 k = co*72 + ci*9 + ky*3 + kx（GroupMask.weightAddr，GROUP=1）
输入：C=8, W=32, H=2 ⇒ 512 B（NHWC）；输出同尺寸 512 B。
描述符：conv3x3 plain，PAD=1/STRIDE=1，QUANT_SHIFT=6（必须 == 网表展开期 SHIFT，否则响亮 err）。
地址：NPU 0x00100000/0x00200000/0x00300000 ↔ 物理 0x80100000/0x80200000/0x80300000。

★ 本轮修：板端长循环要**等它的完成标记**，不能用固定 drain —— 否则主机先走、会话错位。
"""
import serial, time, re, sys
PORT="COM7"; BAUD=115200
SRC_NPU=0x00100000; DST_NPU=0x00200000; TBL_NPU=0x00300000
SRC_PHY=0x80100000; DST_PHY=0x80200000; TBL_PHY=0x80300000
W,H,C,SHIFT=32,2,8,6
NTOT=W*H*C; NW=NTOT//4

def in_bytes():
    b=bytearray()
    for j in range(NW):
        v=(j*0x01010101)&0xFFFFFFFF
        b+=bytes([(v>>(8*k))&0xFF for k in range(4)])
    return bytes(b)
def wgt(addr): return (addr%5)-2
def golden():
    ib=in_bytes()
    def x(r,c,ci):
        if r<0 or r>=H or c<0 or c>=W: return 0
        return ib[(r*W+c)*C+ci]
    ob=bytearray()
    for r in range(H):
        for c in range(W):
            for co in range(C):
                acc=0
                for ci in range(C):
                    for ky in range(3):
                        for kx in range(3):
                            acc+=x(r+ky-1,c+kx-1,ci)*wgt(co*72+ci*9+ky*3+kx)
                ob.append(max(-128,min(127,acc>>SHIFT))&0xFF)
    return bytes(ob)

s=serial.Serial(PORT,BAUD,timeout=0.2); s.dtr=False; s.rts=False; time.sleep(0.3)
def send(cmd, gap=0.008):
    for ch in cmd+"\r":
        s.write(ch.encode()); time.sleep(gap)
def read_all(secs):
    b=b""; t0=time.time()
    while time.time()-t0<secs:
        d=s.read(4096)
        if d:
            b+=d
            if b"@FIN@" in b: break
    return b.decode('latin-1').replace('\r','')
def run_wait(cmd, tok, secs):
    """发一条命令 + `B=<tok>; echo "X${B}X"`，等 `X<tok>X`。
       用 ${B} 拼标记 ⇒ **回显里是字面 `X${B}X`**，只有真输出才是 `X<tok>X`（不会被回显骗）。"""
    print("  $ "+cmd, flush=True)
    send(cmd + '; B=%s; echo "X${B}X"' % tok)
    want=("X%sX"%tok).encode()
    b=b""; t0=time.time()
    while time.time()-t0<secs:
        d=s.read(4096)
        if d:
            b+=d
            if want in b: break
    txt=b.decode('latin-1').replace('\r','')
    print("    -> tok %s : %s"%(tok, want.decode() in txt))
    return txt
def short(cmd, t=2.5):
    send(cmd); return read_all(t)
def ownline(txt): return [int(x,16) for x in re.findall(r"(?m)^0x([0-9A-Fa-f]{8})\s*$", txt)]

s.write(b"\x03\x03\r\x11"); time.sleep(0.4); read_all(0.8)
print("=== 清场 ==="); print(short("echo READY").strip().splitlines()[-2:])
print("=== 清 errSticky ==="); short("devmem 0xF000C000 32 0x00000002")

print("=== 灌 576 B 权重（等 WGT_DONE）===")
run_wait("for k in $(seq 0 575); do devmem 0xF000C040 32 $k; devmem 0xF000C044 32 $(( (k%5-2)&255 )); devmem 0xF000C048 32 1; done", "FINW", 420)

print("=== 写输入 512 B（等 SRC 完成）===")
run_wait("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32 $((j*16843009)); A=$((A+4)); done"%(SRC_PHY,NW-1), "FINS", 240)

print("=== 清输出区（等 DST 完成）===")
run_wait("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32 0x55555555; A=$((A+4)); done"%(DST_PHY,NW-1), "FIND", 240)

print("=== 写描述符表 ===")
tbl=[0x00000101,0x00020020,0x00080008,0x00001101,SRC_NPU,DST_NPU,512,0x00000006,0x000000FF]
for k,v in enumerate(tbl): short("devmem 0x%08X 32 0x%08X"%(TBL_PHY+k*4,v), 1.2)
short("devmem 0xF000C034 32 0x%08X"%TBL_NPU, 1.2)
short("devmem 0xF000C038 32 0x00000001", 1.2)
print("  table:", " ".join("0x%08X"%v for v in tbl))

print("=== 起跑 + 轮询 STATUS ===")
short("devmem 0xF000C000 32 0x00000001")
st=None
for i in range(80):
    v=ownline(short("devmem 0xF000C004 32", 1.2))
    if v:
        st=v[-1]
        if i%10==0 or (st&0x3): print("   poll%d STATUS=0x%08X"%(i,st))
    if st is not None and (st&0x3): break
    time.sleep(0.15)
print("  final STATUS=%s"%(("0x%08X"%st) if st is not None else "?"))

print("=== 读输出 128 word（等 OUT_DONE）===")
o=run_wait("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32; A=$((A+4)); done"%(DST_PHY,NW-1), "FINO", 300)
words=ownline(o)
got=bytearray()
for w in words[:NW]: got+=bytes([(w>>(8*k))&0xFF for k in range(4)])
gol=golden()
print("=== 对账 ===")
print("  word 数 = %d（期望 %d）"%(len(words[:NW]),NW))
if len(got)!=len(gol):
    print("  !! 长度不符 got=%d gol=%d"%(len(got),len(gol)))
else:
    bad=sum(1 for a,b in zip(got,gol) if a!=b)
    first=next((i for i,(a,b) in enumerate(zip(got,gol)) if a!=b), -1)
    print("  MISMATCH=%d FIRST_OFF=%d"%(bad,first))
    print("  got[:24] =", got[:24].hex())
    print("  gol[:24] =", gol[:24].hex())
    print("  got 全0x55(没被写)? %s"%(all(x==0x55 for x in got)))
    print("  RESULT:", "PASS" if bad==0 else "FAIL")
s.close()
