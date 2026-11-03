#!/usr/bin/env python3
"""conv_unit_ref.py —— C3.8 `UnitExec`（单单元：DDR -> FusionBuf -> Conv3x3Slice -> DDR）的 Python 参考。

**复用 `mac_ref.py`**（逐字 import，不另写一套卷积）：算术口径与 `mac_ref` **完全同源**——
3x3 / padding=1 / stride=1 / int32 累加 / requant `y = max(-128, min(127, acc >> 6))`（**算术**右移）。
真源：`tools/mac_ref.py` 的模块 docstring（本文件不再复述，只引用）。

============================== 与 mac_ref 的唯一区别：**DDR 张量布局** ==============================
`mac_ref` 的张量布局是通道主序 `[ci][y][x]`（那是"参考与装置之间的接口"里给 `Conv3x3Tb` 用的）。
但 `UnitExec` 的通路是 **DDR(RD, 8 B/拍) -> FusionBuf(一个"字" = 一个像素的 C 个通道) -> Conv3x3Slice**：
`DdrMaster` 的 RD 流一拍就是 **8 B**，而本单元的 `C_IN = 8` ⇒ **一拍正好 = 一个像素的 8 个通道**。
要让"一拍一列"直接喂进 `FusionBuf`（其字 = 一列 C 个通道），DDR 上的激活**必须**是
    **NHWC（channel-last）= [y][x][ci]**：像素 (y,x) 的 C 个通道**连续**排在 8 个字节里。
否则（若用 `[ci][y][x]`）一个像素的 8 个通道会相隔 `H*W` 字节，RD 的连续字节流凑不出一列，
就需要一个转置引擎——本任务（S2）不做那件事。

所以本脚本在**同一套 mac_ref 算术**之上，只多做一件事：**布局置换**
    X_ddr  = permute_chw_to_nhwc(x_mac_ref)     # [ci][y][x] -> [y][x][ci]
    Y_ddr  = permute_chw_to_nhwc(y_mac_ref)     # [co][y][x] -> [y][x][co]
它是**纯置换**（同一个多重集，逐元素 1:1），可逆、可自检（见 --selftest 的 round-trip）。

============================== 权重与"偏置"（冻结口径） ==============================
`wgt.hex` = **整层权重** NENTRY = C_OUT * (C_IN/GROUP) * 9 字节（dense/GROUP=1 时 = 8*8*9 = 576），
展平顺序 = `GroupMask.weightAddr(co,ci,ky,kx) = co*PER_GROUP*9 + ci_local*9 + ky*3 + kx`
（与 `mac_ref` 的 W 展平、`WeightStore` 的装载地址、`GroupedMacArray` **逐字一致**）。
★ **没有偏置字段**：`mac_ref` 的 `conv_core` 没有 bias 项，`WeightStore`/`Conv3x3Slice` 也**没有** bias
端口 ⇒ 本网这一档的 bias **结构性 = 0**（计划里"权重与偏置"的"偏置"落成"不存在"，不是被漏掉）。
硬塞一个 bias 会让硬件与参考对不上（硬件无处加它）——所以 `wgt.hex` 就是 576 字节权重，一个不多。

============================== 输出格式（供装置/$readmemh 直接吃） ==============================
每行一个十六进制字节（`%02x`）：
    wgt.hex : NENTRY 行（整层权重，[co][ci_local][ky][kx]）
    x.hex   : C_IN*H*W 行（NHWC 激活）
    y.hex   : C_OUT*H*W 行（NHWC 黄金输出）

用法：
    conv_unit_ref.py --gen <outdir> [--cin 8] [--cout 8] [--h 4] [--w 64] [--seed 20251009]
    conv_unit_ref.py --selftest
"""
import os
import sys
import hashlib
import random

# 真源参考：本文件**复用**它，不另写一套卷积算术。
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import mac_ref  # noqa: E402  （复用 conv_core / requant / conv3x3 / 展平顺序）

# Windows 控制台是 GBK；非 ASCII 直接写会炸，统一换成可替换字符。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 与 mac_ref 同口径的默认向量参数（dense 8->8；几何取 S2 的冻结用例）。
DEF_CIN, DEF_COUT, DEF_H, DEF_W = 8, 8, 4, 64
DEF_SEED = 20251009
SHIFT = mac_ref.SHIFT  # = 6（夹具口径；RTL 侧 = Conv3x3Slice 的 SHIFT 常量）


def permute_chw_nhwc(flat, C, H, W):
    """[c][h][w] -> [h][w][c]（纯置换；C*H*W 个元素，1:1 到自身）。"""
    assert len(flat) == C * H * W, "长度 %d != C*H*W = %d" % (len(flat), C * H * W)
    out = [0] * len(flat)
    for c in range(C):
        for h in range(H):
            for w in range(W):
                out[(h * W + w) * C + c] = flat[(c * H + h) * W + w]
    return out


def unpermute_nhwc_chw(flat, C, H, W):
    """[h][w][c] -> [c][h][w]（上面那个置换的**逆**；注意它不是自逆，别拿同一个函数当逆用）。"""
    assert len(flat) == C * H * W, "长度 %d != C*H*W = %d" % (len(flat), C * H * W)
    out = [0] * len(flat)
    for h in range(H):
        for w in range(W):
            for c in range(C):
                out[(c * H + h) * W + w] = flat[(h * W + w) * C + c]
    return out


def i8(v):
    """按 int8 二补数重解释（0..255 -> -128..127）。★ 负对照 B 的关键：权重**文件里**是字节
    （`0xfd`），硬件读进 `SInt(8)` 就是 **-3**；而 Python 里 `2 ^ 0xFF == 253` 是个**正整数**。
    预测必须先把字节重解释成 int8，否则预测会拿 +253 去算、与硬件差十万八千里。"""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def requant_shift(acc, shift):
    """按下移 `shift` 位 + clamp 的量化（`mac_ref.requant` 泛化到任意 shift；shift=SHIFT 时逐值相同）。
    负对照 A 的**预测值**就是它（`shift=5`）。"""
    return max(-128, min(127, acc >> shift))


def naive_nhwc(x, wt, CIN, COUT, H, W, shift=SHIFT):
    """**本文件独立写的**朴素 3x3 dense 卷积（NHWC 原生，三重循环），与 mac_ref 的黄金交叉对账用。
    口径：pad=1 / stride=1 / int32 累加 / `max(-128,min(127,acc>>shift))`（算术右移，与 mac_ref 同）。"""
    out = [0] * (COUT * H * W)
    for co in range(COUT):
        for y in range(H):
            for xo in range(W):
                acc = 0
                for ci in range(CIN):
                    wbase = (co * CIN + ci) * 9
                    for ky in range(3):
                        iy = y + ky - 1
                        if iy < 0 or iy >= H:
                            continue
                        for kx in range(3):
                            ix = xo + kx - 1
                            if ix < 0 or ix >= W:
                                continue
                            acc += wt[wbase + ky * 3 + kx] * x[(iy * W + ix) * CIN + ci]
                out[(y * W + xo) * COUT + co] = requant_shift(acc, shift)
    return out


def build(cin=DEF_CIN, cout=DEF_COUT, h=DEF_H, w=DEF_W, seed=DEF_SEED, shift=SHIFT, woverride=None):
    """返回 (wt, x_chw, x_ddr, y_ddr)：整层权重 / mac_ref 的通道主序激活 / NHWC 激活 / NHWC 黄金输出。
    权重与累加**完全复用 mac_ref.conv3x3("dense", ...)**（同 seed ⇒ 同向量）；`shift` 只改 requant 的
    下移位数（负对照 A 的预测值）；`woverride` 可换成"被改过一个字节"的权重（负对照 B 的预测值）。"""
    if cin != cout:
        raise ValueError("S2 的 UnitExec 固定 C_IN == C_OUT == 8（一块 8x8 阵列）")
    x_chw, wt, acc = mac_ref.conv3x3("dense", cin, cout, h, w, seed)
    if woverride is not None:
        wt = list(woverride)
        acc = mac_ref.conv_core(1, cin, cout, h, w, x_chw, wt)
    y_chw = [requant_shift(a, shift) for a in acc]
    x_ddr = permute_chw_nhwc(x_chw, cin, h, w)
    y_ddr = permute_chw_nhwc(y_chw, cout, h, w)
    return wt, x_chw, x_ddr, y_ddr


def dump_bytes(path, toks):
    """每行一个 `%02x`（装置 $readmemh 直接吃）。"""
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % (v & 0xFF) for v in toks))


# --------------------------- ★ C3.9b：融合对（1x1 -> 3x3）的金参考 ---------------------------
# 本节的**唯一用处**是 C3.9b 的闸门 `run_fuse_ab.sh`：把"头(1x1) -> 尾(3x3)"两段串起来。
# ★ 为什么"1x1"用"只有中心抽头的 3x3"来表达：`Conv3x3Slice` 的算术是 3x3/pad=1/stride=1，
#   **没有** 1x1 档；而 pad=1/stride=1 的 3x3 在**中心抽头之外全为 0** 时，正好等于一个 1x1 conv
#   （同一套 `(C,W,H)` 形状、同一套 `>>SHIFT`+clamp）。所以这是"把 1x1 落成本网表能跑的**测试实现**"，
#   **不是**说 RTL 里有一个 1x1 单元。RTL 侧不假定任何权重取值 —— 中心抽头只出现在**夹具**里。
# 两段之间的中间张量在 DDR 上就是 NHWC（`[y][x][c]`）——与头的输出/尾的输入**同一套布局**。

def centre_tap(wt, CIN, COUT):
    """把整层 3x3 权重里**非中心抽头**全部置 0 ⇒ 功能上就是一个 1x1 conv（见上）。
    布局 = `mac_ref` 的 W 展平 `[co][ci_local][ky][kx]`；中心 = ky=1,kx=1 ⇒ 组内偏移 4。"""
    out = [0] * len(wt)
    assert len(wt) == COUT * CIN * 9, "权重长度 %d != %d" % (len(wt), COUT * CIN * 9)
    for co in range(COUT):
        for ci in range(CIN):
            out[(co * CIN + ci) * 9 + 4] = wt[(co * CIN + ci) * 9 + 4]
    return out


def pair_two_stage(x_chw, wt_head, wt_tail, CIN, COUT, H, W, shift=SHIFT):
    """**mac_ref 算术**的两段链（头 -> 尾），返回 `(mid_ddr, final_ddr)`（两段都是 NHWC）。
    口径与 `build` 逐字相同：`mac_ref.conv_core` 累加 -> `>>shift` + clamp。
    中间张量**真的**被物化成一个 NHWC 数组（= "中间张量落 DDR" 的那张）。"""
    y1_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, x_chw, wt_head)]
    mid_ddr = permute_chw_nhwc(y1_chw, COUT, H, W)
    mid_chw = unpermute_nhwc_chw(mid_ddr, COUT, H, W)      # 尾按 mac_ref 的通道主序吃
    y2_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, mid_chw, wt_tail)]
    final_ddr = permute_chw_nhwc(y2_chw, COUT, H, W)
    return mid_ddr, final_ddr


def pair_stepwise_naive(x_ddr, wt_head, wt_tail, CIN, COUT, H, W, shift=SHIFT):
    """**独立第二实现**的同一件事（"分两步、中间张量落 DDR"）：两次 `naive_nhwc`（NHWC 原生三重循环），
    与 `pair_two_stage` 是**完全不同的代码路径**（一个走 `mac_ref.conv_core` + 布局置换，一个走朴素循环）
    ⇒ 两者逐字节相同才说明口径没漂。"""
    mid_ddr = naive_nhwc(x_ddr, wt_head, CIN, COUT, H, W, shift)
    final_ddr = naive_nhwc(mid_ddr, wt_tail, CIN, COUT, H, W, shift)
    return mid_ddr, final_ddr


# --------------------------- ★ C3.10a：单元序列 FSM（LayerSched）的黄金链 ---------------------------
# 本节的**唯一用处**是 C3.10a 的闸门 `run_sched_ab.sh`：一张**两项**描述符表，两项都是 conv：
#   项 0：**plain conv**（`FLAGS.bit0=1`）—— `UnitExec` 走 S2 档，读 `SRC_ADDR`(A0) 写 `DST_ADDR`(A1)；
#   项 1：**融合对**（`FLAGS=0b10`，`bit0=0 & bit1=1`）—— `UnitExec` 走 C3.9b 融合对档，**一个 `go`**
#         同时跑头/尾两个切片：头 = 3x3(wt_head) 读 A1 -> **片上**中间张量 -> 尾 = 1x1(wt_tail) -> A2。
#   ⇒ DDR 上只有 A0 -> A1 -> A2 三个张量；**中间张量结构性不落 DDR**（与 C3.9b 同一条纪律）。
# 三项算两次卷积（项 0 一次、项 1 的头/尾各一次）。`wt_tail` 用"只有中心抽头"的 3x3 表达 1x1
# （`centre_tap`；理由同 C3.9b —— `Conv3x3Slice` 没有 1x1 档，pad=1/stride=1 的中心抽头 3x3 ≡ 1x1）。
# `sched_chain`（mac_ref 算术）与 `sched_chain_naive`（独立朴素 NHWC 实现）必须**逐字节相同**。

def sched_chain(x_chw, wt_head, wt_tail, CIN, COUT, H, W, shift=SHIFT):
    """**mac_ref 算术**的三次卷积链，返回 `(a1_ddr, mid_ddr, a2_ddr)`（都是 NHWC）。
    口径与 `pair_two_stage`/`build` 逐字相同：`mac_ref.conv_core` 累加 -> `>>shift` + clamp。
    中间张量 `mid_ddr` 在**参考里**物化（便于交叉对账），但在**硬件上**它落在片上、不落 DDR。"""
    a1_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, x_chw, wt_head)]
    a1_ddr = permute_chw_nhwc(a1_chw, COUT, H, W)
    a1_chw2 = unpermute_nhwc_chw(a1_ddr, COUT, H, W)          # 项 1 的头按 mac_ref 的通道主序吃
    mid_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, a1_chw2, wt_head)]
    mid_ddr = permute_chw_nhwc(mid_chw, COUT, H, W)
    mid_chw2 = unpermute_nhwc_chw(mid_ddr, COUT, H, W)        # 项 1 的尾按 mac_ref 的通道主序吃
    a2_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, mid_chw2, wt_tail)]
    a2_ddr = permute_chw_nhwc(a2_chw, COUT, H, W)
    return a1_ddr, mid_ddr, a2_ddr


def sched_chain_naive(x_ddr, wt_head, wt_tail, CIN, COUT, H, W, shift=SHIFT):
    """**独立第二实现**：三次 `naive_nhwc`（NHWC 原生三重循环）串起来，与 `sched_chain` 交叉对账。
    两条路径的代码完全不同（一个走 `mac_ref.conv_core` + 布局置换，一个走朴素循环）
    ⇒ 逐字节相同才说明口径没漂。"""
    a1_ddr = naive_nhwc(x_ddr, wt_head, CIN, COUT, H, W, shift)
    mid_ddr = naive_nhwc(a1_ddr, wt_head, CIN, COUT, H, W, shift)
    a2_ddr = naive_nhwc(mid_ddr, wt_tail, CIN, COUT, H, W, shift)
    return a1_ddr, mid_ddr, a2_ddr


# --------------------------- ★ A-1a：L 切片片上融合链的黄金 ---------------------------
# 本节的**唯一用处**是 A-1a 的闸门 `run_chain_ab.sh`：把 **L 个** conv 段串成一条**链**，
# 中间张量在**参考里**物化（便于交叉对账），但在**硬件上**它们落在**片上**（`UnitExec` 的中间缓冲）、
# **不落 DDR**。口径与 `build`/`pair_two_stage`/`sched_chain` **逐字相同**：
#   `mac_ref.conv_core` 累加 -> `>>shift` + clamp（每段相同），段间布局置换 = NHWC（= DDR 上的布局）。
# ★ "1x1" 仍用"只有中心抽头的 3x3"表达（`centre_tap`；理由同 C3.9b：`Conv3x3Slice` 没有 1x1 档）。

def scale_wt(wt, s):
    """把整层权重乘 `s` 并 clamp 到 int8（段间放大以抵消每段 `>>6` 的衰减；见闸门的非退化前提）。"""
    if s == 1:
        return list(wt)
    return [max(-128, min(127, v * s)) for v in wt]


def chain_l(x_chw, wts, CIN, COUT, H, W, shift=SHIFT):
    """**mac_ref 算术**的 L 段链（`wts = [wt0, ..., wt_{L-1}]`）。
    返回 `(mids, fin)`：`mids` = 第 0..L-2 段的输出（NHWC，长度 L-1，**片上**中间张量）、
    `fin` = 最后一段的输出（NHWC = 最终张量）。每段：`conv_core` 累加 -> `>>shift` + clamp。"""
    assert len(wts) >= 1, "链至少一段"
    cur_chw = x_chw
    mids = []
    fin_ddr = None
    for k, wt in enumerate(wts):
        y_chw = [requant_shift(a, shift) for a in mac_ref.conv_core(1, CIN, COUT, H, W, cur_chw, wt)]
        y_ddr = permute_chw_nhwc(y_chw, COUT, H, W)
        if k < len(wts) - 1:
            mids.append(y_ddr)
            cur_chw = unpermute_nhwc_chw(y_ddr, COUT, H, W)   # 下一段按 mac_ref 的通道主序吃
        else:
            fin_ddr = y_ddr
    return mids, fin_ddr


def chain_l_naive(x_ddr, wts, CIN, COUT, H, W, shift=SHIFT):
    """**独立第二实现**：L 次 `naive_nhwc`（NHWC 原生三重循环）串起来，与 `chain_l` 交叉对账
    （一个走 `mac_ref.conv_core` + 布局置换，一个走朴素循环 ⇒ 逐字节相同才说明口径没漂）。"""
    cur = x_ddr
    mids = []
    for k, wt in enumerate(wts):
        y = naive_nhwc(cur, wt, CIN, COUT, H, W, shift)
        if k < len(wts) - 1:
            mids.append(y)
        cur = y
    return mids, cur


def md5_of(path):
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


# ------------------------------- 自测 -----------------------------------------

FAILS = []


def chk(cond, msg):
    if cond:
        print("  PASS  " + msg)
    else:
        print("  FAIL  " + msg)
        FAILS.append(msg)


def selftest():
    print("[conv_unit_ref] selftest（复用 mac_ref 算术 + 布局置换 + 独立朴素实现交叉对账）")

    # 0) requant 口径（与 mac_ref 同一句）：算术右移 + clamp。
    chk(mac_ref.requant(-1) == -1, "requant(-1) == -1（>>6 是**算术**右移，不是逻辑）")
    chk(mac_ref.requant(-64) == -1, "requant(-64) == -1（floor(-1) ）")
    chk(mac_ref.requant(127 * 64) == 127 and mac_ref.requant(-128 * 64) == -128,
        "requant 上/下 clamp 到 +127/-128")
    chk(mac_ref.requant(10 ** 9) == 127 and mac_ref.requant(-(10 ** 9)) == -128,
        "requant 大数照样 clamp（不会越出 int8）")

    # 1) 置换是 1:1 且可逆（逆置换还原原序）。
    C, H, W = 2, 3, 4
    flat = list(range(C * H * W))
    nh = permute_chw_nhwc(flat, C, H, W)
    chk(sorted(nh) == sorted(flat), "置换保持多重集（1:1）")
    chk(nh != flat, "置换真的动了顺序（不是恒等）")
    chk(unpermute_nhwc_chw(nh, C, H, W) == flat, "逆置换还原原序（permute 不是自逆，逆是另一个函数）")
    # 手工核对一个点：c=1,h=2,w=3 -> 原 idx=(1*3+2)*4+3=23；新 idx=(2*4+3)*2+1=23。同值落位对。
    chk(nh[(2 * W + 3) * C + 1] == (1 * H + 2) * W + 3, "置换落位手工核对（c1y2x3）")

    # 2) 几何 + 独立实现交叉对账（S2 冻结用例）。
    cin, cout, h, w, seed = DEF_CIN, DEF_COUT, DEF_H, DEF_W, DEF_SEED
    wt, x_chw, x_ddr, y_ddr = build(cin, cout, h, w, seed)
    chk(len(wt) == cout * cin * 9 == 576, "wgt 长度 = C_OUT*(C_IN/GROUP)*9 = 576，得到 %d" % len(wt))
    chk(len(x_ddr) == cin * h * w == 2048, "x 长度 = C_IN*H*W = 2048，得到 %d" % len(x_ddr))
    chk(len(y_ddr) == cout * h * w == 2048, "y 长度 = C_OUT*H*W = 2048，得到 %d" % len(y_ddr))
    chk(unpermute_nhwc_chw(x_ddr, cin, h, w) == x_chw, "x_ddr 逆置换回通道主序 == mac_ref 原始 X")

    naive = naive_nhwc(x_ddr, wt, cin, cout, h, w)
    diff = sum(1 for a, b in zip(naive, y_ddr) if a != b)
    chk(diff == 0, "独立朴素 NHWC 实现 == mac_ref 派生的黄金（逐元素 0 差，得到 %d）" % diff)

    # 3) 非退化：输入非常数、黄金非常数、且**不是**"被 clamp 糊成常数"。
    chk(len(set(x_ddr)) > 1, "输入非常数")
    chk(len(set(y_ddr)) > 1, "黄金非常数")
    nclamp = sum(1 for v in y_ddr if v in (127, -128))
    chk(nclamp < len(y_ddr), "黄金不是整片 clamp（clamp 点 = %d < %d）" % (nclamp, len(y_ddr)))

    # 4) 判据分辨度前提：把 SHIFT 6 改成 5 会**大面积**改变黄金（负对照 A 的前提）。
    y_shift5 = [max(-128, min(127, a >> (SHIFT - 1)))
                for a in mac_ref.conv_core(1, cin, cout, h, w, x_chw, wt)]
    nd = sum(1 for a, b in zip(y_ddr, permute_chw_nhwc(y_shift5, cout, h, w)) if a != b)
    chk(nd > 0, "SHIFT 6->5 会让黄金变值（差 %d/%d 个字节）⇒ 负对照 A 有牙" % (nd, len(y_ddr)))

    # 5) 权重翻转一个字节 ⇒ 黄金必然变值（负对照 B 的前提）。
    wbad = list(wt)
    wbad[len(wbad) // 3] = i8(wbad[len(wbad) // 3] ^ 0xFF)   # 重解释成 int8（硬件读的就是 int8）
    y_bad_chw = [mac_ref.requant(a) for a in mac_ref.conv_core(1, cin, cout, h, w, x_chw, wbad)]
    y_bad = permute_chw_nhwc(y_bad_chw, cout, h, w)
    nd2 = sum(1 for a, b in zip(y_ddr, y_bad) if a != b)
    chk(nd2 > 0, "权重翻一个字节会让黄金变值（差 %d/%d 个字节）⇒ 负对照 B 有牙" % (nd2, len(y_ddr)))

    # 6) ★ C3.9b 融合对（头 = 中心抽头 3x3 ≡ 1x1；尾 = 普通 3x3）：
    #    · `centre_tap` 真的只留中心抽头、且中心的取值**没变**（不是把权重清零）；
    #    · 两条**完全独立**的实现（mac_ref 链 vs 朴素 NHWC 链）逐字节相同；
    #    · 中间张量与最终张量都非退化（非常数、不是全 0）。
    wt_head = centre_tap(wt, cin, cout)
    off_nz = sum(1 for co in range(cout) for ci in range(cin) for k in range(9)
                 if k != 4 and wt_head[(co * cin + ci) * 9 + k] != 0)
    chk(off_nz == 0, "centre_tap：非中心抽头全为 0（得到 %d 个非 0）" % off_nz)
    ctr_kept = all(wt_head[(co * cin + ci) * 9 + 4] == wt[(co * cin + ci) * 9 + 4]
                   for co in range(cout) for ci in range(cin))
    chk(ctr_kept, "centre_tap：中心抽头逐值保留（不是把权重清零）")
    chk(sum(1 for v in wt_head if v != 0) > 0, "centre_tap：中心抽头里确实有权重")
    mid_a, fin_a = pair_two_stage(x_chw, wt_head, wt, cin, cout, h, w, SHIFT)
    mid_b, fin_b = pair_stepwise_naive(x_ddr, wt_head, wt, cin, cout, h, w, SHIFT)
    d_mid = sum(1 for a, b in zip(mid_a, mid_b) if a != b)
    d_fin = sum(1 for a, b in zip(fin_a, fin_b) if a != b)
    chk(d_mid == 0 and d_fin == 0,
        "融合对：mac_ref 链 == 朴素 NHWC 链（中间差 %d、最终差 %d）" % (d_mid, d_fin))
    chk(len(set(mid_a)) > 1, "中间张量非常数")
    chk(len(set(fin_a)) > 1, "最终张量非常数")
    chk(sum(1 for v in fin_a if v != 0) > 0, "最终张量不是全 0")
    # 非退化：把尾权重也换成中心抽头（= 两个 1x1）会让最终张量变值 ⇒ 判据对"尾真的是 3x3"有分辨度。
    _, fin_11 = pair_two_stage(x_chw, wt_head, centre_tap(wt, cin, cout), cin, cout, h, w, SHIFT)
    d_11 = sum(1 for a, b in zip(fin_a, fin_11) if a != b)
    chk(d_11 > 0, "尾的 3x3 非中心抽头确实起作用（尾换 1x1 会让最终张量变值：差 %d）" % d_11)

    # 7) ★ C3.10a 单元序列 FSM（LayerSched）的黄金链：项0 plain 3x3 + 项1 融合对(3x3 -> 1x1)。
    #    · 两条**完全独立**的实现（mac_ref 链 vs 朴素 NHWC 链）逐字节相同；
    #    · 三个张量都非退化（非常数、不是全 0、不是整片 clamp）；
    #    · 第二次 3x3（尾的输入 = 头的输出）与"整片 clamp"无关 ⇒ 判据有分辨率。
    wt_tail = centre_tap(wt, cin, cout)
    a1_a, mid_a, a2_a = sched_chain(x_chw, wt, wt_tail, cin, cout, h, w, SHIFT)
    a1_b, mid_b, a2_b = sched_chain_naive(x_ddr, wt, wt_tail, cin, cout, h, w, SHIFT)
    d_a1 = sum(1 for x, y in zip(a1_a, a1_b) if x != y)
    d_mid = sum(1 for x, y in zip(mid_a, mid_b) if x != y)
    d_a2 = sum(1 for x, y in zip(a2_a, a2_b) if x != y)
    chk(d_a1 == 0 and d_mid == 0 and d_a2 == 0,
        "调度链：mac_ref 链 == 朴素 NHWC 链（A1 差 %d、MID 差 %d、A2 差 %d）" % (d_a1, d_mid, d_a2))
    for nm, t in (("A1", a1_a), ("MID", mid_a), ("A2", a2_a)):
        chk(len(set(t)) > 1, "%s 非常数" % nm)
        chk(sum(1 for v in t if v != 0) > 0, "%s 不是全 0" % nm)
        ncl = sum(1 for v in t if v in (127, -128))
        chk(ncl < len(t), "%s 不是整片 clamp（clamp 点 %d < %d）" % (nm, ncl, len(t)))
    # 非退化：把尾权重也换成普通 3x3（= 尾不是 1x1）会让 A2 变值 ⇒ 判据对"尾的 1x1"有分辨度。
    _, _, a2_full = sched_chain(x_chw, wt, wt, cin, cout, h, w, SHIFT)
    chk(sum(1 for x, y in zip(a2_a, a2_full) if x != y) > 0,
        "尾的 1x1（中心抽头）确实起作用（换成普通 3x3 会让 A2 变值）")

    # 8) ★ A-1a L 切片链（L=4：3x3 -> 1x1(中心) -> 3x3 -> 1x1(中心)）：两条**完全独立**的实现逐字节相同。
    #    · 三个中间张量与最终张量都非退化（非常数、不是全 0、不是整片 clamp）；
    #    · 段间放大（scale_wt）抵消每段 >>6 的衰减；断言最终张量有分辨率。
    w123 = [wt, centre_tap(wt, cin, cout), wt, centre_tap(wt, cin, cout)]
    wts4 = [scale_wt(w, s) for w, s in zip(w123, [4, 4, 4, 1])]
    mids_a, fin_a = chain_l(x_chw, wts4, cin, cout, h, w, SHIFT)
    mids_b, fin_b = chain_l_naive(x_ddr, wts4, cin, cout, h, w, SHIFT)
    d_mids = [sum(1 for p, q in zip(m, n) if p != q) for m, n in zip(mids_a, mids_b)]
    d_fin = sum(1 for p, q in zip(fin_a, fin_b) if p != q)
    chk(len(mids_a) == 3 and all(d == 0 for d in d_mids) and d_fin == 0,
        "L=4 链：mac_ref 链 == 朴素 NHWC 链（中间差 %s、最终差 %d）" % (d_mids, d_fin))
    for nm, t in [("mid0", mids_a[0]), ("mid1", mids_a[1]), ("mid2", mids_a[2]), ("fin", fin_a)]:
        chk(len(set(t)) >= 8, "L=4 链 %s 有分辨率（distinct=%d >= 8）" % (nm, len(set(t))))
        chk(sum(1 for v in t if v != 0) >= len(t) // 4, "L=4 链 %s 非 0 字节 >= 1/4" % nm)
        ncl = sum(1 for v in t if v in (127, -128))
        chk(ncl < len(t), "L=4 链 %s 不是整片 clamp（clamp 点 %d < %d）" % (nm, ncl, len(t)))

    if FAILS:
        print("SELFTEST: FAIL (%d)" % len(FAILS))
        return 1
    print("SELFTEST: PASS")
    return 0


# ------------------------------- --gen ----------------------------------------

def do_gen(outdir, cin, cout, h, w, seed):
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    wt, x_chw, x_ddr, y_ddr = build(cin, cout, h, w, seed)
    p_w = os.path.join(outdir, "wgt.hex")
    p_x = os.path.join(outdir, "x.hex")
    p_y = os.path.join(outdir, "y.hex")
    dump_bytes(p_w, wt)
    dump_bytes(p_x, x_ddr)
    dump_bytes(p_y, y_ddr)
    nclamp = sum(1 for v in y_ddr if v in (127, -128))
    print("GEN_GEOM mode=dense C_IN=%d C_OUT=%d H=%d W=%d GROUP=1 SHIFT=%d seed=%d" % (cin, cout, h, w, SHIFT, seed))
    print("GEN wgt=%s (%d B md5=%s)" % (p_w, len(wt), md5_of(p_w)))
    print("GEN x  =%s (%d B md5=%s)" % (p_x, len(x_ddr), md5_of(p_x)))
    print("GEN y  =%s (%d B md5=%s)" % (p_y, len(y_ddr), md5_of(p_y)))
    print("GEN_Y clamp@127/-128 = %d/%d" % (sum(1 for v in y_ddr if v == 127),
                                            sum(1 for v in y_ddr if v == -128)))
    return 0


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        return selftest()
    if "--gen" not in args:
        print(__doc__)
        return 2
    i = args.index("--gen")
    if i + 1 >= len(args):
        print("FATAL: --gen 需要一个输出目录", file=sys.stderr)
        return 2
    outdir = args[i + 1]

    def opt(name, dflt):
        if name in args:
            return int(args[args.index(name) + 1])
        return dflt

    cin = opt("--cin", DEF_CIN)
    cout = opt("--cout", DEF_COUT)
    h = opt("--h", DEF_H)
    w = opt("--w", DEF_W)
    seed = opt("--seed", DEF_SEED)
    if min(cin, cout, h, w) <= 0:
        print("FATAL: 维度必须为正", file=sys.stderr)
        return 2
    if (cin * h * w) % 128 != 0:
        # 不是硬错，但提示：S2/S3/S4 的几何都取 IN_BYTES = C*H*W 是 128 的整数倍（TB 会断言）。
        print("WARN: IN_BYTES=%d 不是 128 的整数倍（S2 的 TB 会 $fatal）" % (cin * h * w), file=sys.stderr)
    return do_gen(outdir, cin, cout, h, w, seed)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
