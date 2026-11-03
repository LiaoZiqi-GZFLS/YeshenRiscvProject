#!/usr/bin/env python3
"""C3 旁路算子的整数参考 —— MaxPool(2x2/s2) + Resize(x2 nearest) + Add(饱和) + Sigmoid(查表)。

用法:
    bypass_ref.py maxpool <C> <W> <H> --infile=<x.hex> [--mutate=topleft]
    bypass_ref.py resize  <C> <W> <H> --infile=<x.hex> [--mutate=bank|col]
    bypass_ref.py add     <C> <W> <H> --infile=<ab.hex> [--mutate=wrap]     # 交织流，见下
    bypass_ref.py sigmoid <C> <W> <H> --infile=<x.hex>  [--mutate=invert]
    bypass_ref.py <op>    <C> <W> <H> --gen=<x.hex>          # 写非平凡输入向量
    bypass_ref.py --genlut=<sigmoid_lut.hex>                 # 写 256 项查表 + 打 md5
    bypass_ref.py --lutfile=<sigmoid_lut.hex>                # 断言该文件 == 冻结公式
    bypass_ref.py --lutbin=<SigmoidUnit.v_toplevel_lut.bin>  # 断言 RTL 的表 == 冻结公式
    bypass_ref.py --selftest
输出: 一行输出张量 —— 十六进制字节（空格分隔），**流顺序**见下。

============================== 冻结口径（"硬件怎么算"的唯一真源） ==============================
* `MaxPool`：窗口 2x2 / stride 2，int8 **取最大**；**无量化**：激活值原样透传
  （不做 scale / zero-point、也不 clamp —— max 的结果必然是某个输入像素，天然在 int8 内）。
  输入 (C,W,H) ⇒ 输出 (C, W/2, H/2)；要求 **W、H 均为偶数**（本文件硬断言，奇数直接报错）。
* `Resize`：**x2 最近邻**：`out[c][2y+dy][2x+dx] = in[c][y][x]`（dy,dx ∈ {0,1}）。
  输入 (C,W,H) ⇒ 输出 (C, 2W, 2H)；**无插值、无量化**（逐位复制）。
  要求 **H 为偶数**（本文件硬断言；本单元按输入行对工作，理由见 rtl/ResizeUnit.scala 文件头）。
* `Add`（C3.7）：**两路 int8 逐点相加 + 饱和**（clamp 到 `[-128,127]`，**不回绕**）。
  `y = clamp8(a + b)`；**无量化**（两路同刻度）。形状不变 `(C,W,H) => (C,W,H)`，逐点、无几何结构
  ⇒ **对 W/H 的奇偶没有任何要求**（与 MaxPool/Resize 不同）。
  ★★ **两路输入的流布局（装置约定，与 rtl_test/BypassTb.v 的 `+OP=add` 一致）**：
    本算子**两输入**，而参考/装置的 `--infile` 只有**一条**流 ⇒ 按**列**交织：
    第 (row,col) 列占 `2*C` 个字节 = **A 的 C 个通道紧跟 B 的 C 个通道**：
        `idx = (row*W + col)*(2*C) + (0..C-1 => A, C..2*C-1 => B)`
    于是"字节下标 i 属于 A 路"⟺ `(i // C) % 2 == 0`（`split_add()` 就是这个判据）。
    ⚠ 这只是**取数约定**：描述符格式（C3.2 冻结）**只有一个 `SRC_ADDR`**，第二路的源**未定**
    （O1 开口项，见 reports/c3_descriptor_format.md §7 与 rtl/AddUnit.scala 文件头）。
    输入流长度 `2*C*W*H`；输出流长度 `C*W*H`（`add_ref` 的两个实参各 `C*W*H`）。
* `Sigmoid`（C3.7）：**int8 输入 = 定点 x（Q3.4，步长 1/16）** ⇒ **int8 输出（Q0.7，步长 1/128）**：
  `out = round(127 * sigmoid(x/16))`，实现为 **256 项查表** `lut[x + 128]`（地址 = x 的无符号偏移）。
  取整 = `floor(v + 0.5)`（**不是** Python `round()` 的银行家舍入），`v >= 0` ⇒ "四舍五入、.5 向上"。
  ★ 输出**恒在 [0,127]**（sigmoid ∈ (0,1) ⇒ `127*sigmoid ∈ (0,127)`）⇒ 本算子**没有饱和**逻辑，
    也**永远不会**是负数 —— 这是 `sigmoid_lut()` 可断言的强性质（自检里有）。
  ★ "Q3.4 / Q0.7" 是本计划的**冻结选择**（非 spec 值、非 YuNet 实测刻度）：真值属 **C4/M2 的量化器**，
    已记为 C4 开口项（与 `QUANT_SHIFT` 占位口径同级，见 reports/c3_descriptor_format.md §7 O4）。
  形状不变 `(C,W,H) => (C,W,H)`，逐点、无几何结构 ⇒ 对 W/H 的奇偶无要求。
* ★ **表的三个副本与它们之间的对账**（C3.7 的承重判据）：
    ① **RTL 侧**：`rtl/SigmoidUnit.scala` 的 `Mem(SInt(8), 256)` + `lutFormula()`（Scala 按同一条
       公式算）⇒ 生成的 `gen/SigmoidUnit.v` 里是
       `initial begin $readmemb("SigmoidUnit.v_toplevel_lut.bin", lut); end`
       （SpinalHDL 的 `Mem.init` 产物），**表在运行期从那个 .bin 文件载入**（可综合 = ROM 初值文件）。
    ② **本文件**：`sigmoid_lut()` 用同一条公式算 256 项；`--genlut=` 把它写成
       **`gen/sigmoid_lut.hex`**（256 行十六进制），md5 记进报告、**重生成两次必须逐字节一致**。
    ③ **装置**：`rtl_test/BypassTb.v` 用 `+LUTFILE=` **`$readmemh` 载入 ②**，自己算期望并逐字节比
       DUT 输出（打印 `LUT-XCHK`），并要求**跑满 256 个码点**（打印 `LUT-CODES`）。
  ⇒ 对账链：**①的 .bin  vs  ②的 .hex**（`--lutbin=`/`--lutfile=` 两条断言，256 项逐项）
     **+ ②  vs  装置的期望**（`--lutfile` 与 TB 的 `LUT-XCHK`）
     **+ ②  vs  RTL 的输出**（闸门的全码点正对照，`MISMATCH=0`）。任一侧改坏都发火。

============================== 展平/流顺序（参考与装置之间的接口） ==============================
* 输入 t 展平 = **[row][col][ci]** —— 就是装置喂 DUT 的顺序（行主序的列流：一拍一列、
  列内 C 个通道连续）。一维下标 = `(row*W + col)*C + ci`。
* 输出展平 = **[y][x][ci]**（maxpool，y/x 是输出行/列）或 **[Y][X][ci]**（resize）
  —— 也是 DUT 吐出的顺序（行主序的像素流：一拍一个输出像素、像素内 C 个通道连续）。
  maxpool 下标 = `(y*(W//2) + x)*C + ci`；resize 下标 = `(Y*(2W) + X)*C + ci`。
* ★ 注意这与 mac_ref 的 [ci][y][x] 不同：这里是**流的顺序**，不是张量存储顺序。
  两者的换算见 `to_tensor()` / `from_tensor()`（板级张量按 [c][y][x] 存放）。

============================== 突变体预测（负对照的"精确命中"靶子） ==============================
本文件另外给出**五个**突变体的参考，供闸门做"突变网表输出 == 突变预测值（精确命中）且
!= 黄金"的双重判据（只判 MISMATCH>0 太弱：任何改动都能让它 >0）：
* `maxpool_mut_topleft`：把 2x2 窗口改成**恒取左上角** ⇒ 输出 = 输入按块取 (even,even)。
  ⇒ 该突变体与黄金必然不同（黄金 = 块内最大值，且本文件的向量构造保证左上角必是块内最小值）。
* `resize_mut_bank`：把**行相位 dy 取反**（复刻行对的"上/下半"互换：`bank = 1-dy`）。
* `resize_mut_col`：把**列相位配对取反**（源列号最低位取反：`srcCol = (X>>1) ^ 1`）。
  ⚠ 口径说明（**这是本任务最容易被"混叠"糊住的地方，必须写清楚**）：纯最近邻 2x 里
  `out[c][2y+dy][2x+dx]=in[c][y][x]` 的 4 个槽**同值** ⇒ 把 (dy,dx) 字面地映射成 (1-dy,1-dx)
  是**功能恒等**（不可观测）。所以"相位反了"必须落在**相位选中了哪个源元素**上才有内容：
  dy 反 = 选中另一条行缓冲；dx 反 = 源列号的最低相位取反。两者都是硬件里真实存在的选择，
  且都必然改变输出（本文件的自检与闸门都对"黄金 != 两个突变体"做硬断言）。
* `add_mut_wrap`（C3.7）：把**饱和改成回绕**（`& 0xFF`，即丢掉第 9 位）。硬件里就是
  `rtl/AddUnit.scala` 的 clamp 选择器恒置 0（`clampHi/clampLo = 0` ⇒ 输出 = 低 8 位 = 回绕）。
  **前提**：向量上必须真的出现过 `a+b ∉ [-128,127]` 的点（否则饱和与回绕**输出完全相同** ⇒
  判据是橡皮章）⇒ 闸门与自检都硬断言"饱和点数 > 0"（`SAT_EVENTS`）；`127+127→127` 与
  `-128+-128→-128` 是自检钉死的两个点（回绕会给 `-2` 与 `0`）。
* `sigmoid_mut_invert`（C3.7）：把**查表地址取反**（`addr := -addr`，8 位二补数）—— 读到的其实是
  `lut[(-addr) mod 256] = lut[(-x) + 128] = round(127 * sigmoid(-x/16))`，即**把 x 换成 -x**。
  **前提**：表在 `x -> -x` 下**不对称**（否则不可观测）。自检断言"**254** 个码点变值、恰好
  **2** 个不动点（x=0 与 x=-128）"⇒ 这就是"这条负对照不是橡皮章"的**显式证据**（不是靠嘴说）。
"""

import hashlib
import math
import sys

# Windows 控制台是 GBK：非 ASCII 直接写会炸；统一按 UTF-8 + 可替换字符输出。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OPS = ("maxpool", "resize", "add", "sigmoid")
MUTATES = {"maxpool": ("topleft",), "resize": ("bank", "col"),
           "add": ("wrap",), "sigmoid": ("invert",)}


# ------------------------------- 小工具 ---------------------------------------

def i8(v):
    """把整数按 8 位二补数解释进 [-128,127]。"""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def u8(v):
    """把整数截成无符号 8 位（= 硬件里那条 8 位总线的值）。"""
    return v & 0xFF


def clamp8(v):
    """**饱和**到 int8：clamp(v, -128, 127)。`Add` 的冻结口径就是它（不是回绕）。"""
    if v > 127:
        return 127
    if v < -128:
        return -128
    return v


def md5_file(path):
    """文件 md5（LUT 指纹用；二进制读，避免换行/编码干扰）。"""
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(65536), b""):
            h.update(blk)
    return h.hexdigest()


def hexstr(toks):
    """一个张量 = 一行 hex token（`& 0xFF` 取低 8 位 ⇒ 二进制补码）。"""
    return " ".join("%02x" % (v & 0xFF) for v in toks)


def load_hex(path):
    """每行一个（或空格分隔多个）十六进制字节 ⇒ int8 列表（= 装置喂/收的字节）。"""
    toks = open(path, encoding="utf-8", errors="replace").read().split()
    out = []
    for t in toks:
        try:
            out.append(i8(int(t, 16)))
        except ValueError:
            raise ValueError("不是十六进制字节: %r" % t)
    return out


def dump_hex(path, toks):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join("%02x\n" % (v & 0xFF) for v in toks))


def to_tensor(stream, C, W, H):
    """[row][col][ci] ⇒ 张量 [ci][row][col]（板级布局；只给自检/守卫用）。"""
    assert len(stream) == C * W * H, "长度 %d != C*W*H = %d" % (len(stream), C * W * H)
    t = [0] * (C * W * H)
    for r in range(H):
        for c in range(W):
            for ci in range(C):
                t[(ci * H + r) * W + c] = stream[(r * W + c) * C + ci]
    return t


def from_tensor(tens, C, W, H):
    """[ci][row][col] ⇒ [row][col][ci]。"""
    st = [0] * (C * W * H)
    for r in range(H):
        for c in range(W):
            for ci in range(C):
                st[(r * W + c) * C + ci] = tens[(ci * H + r) * W + c]
    return st


# ------------------------------- 参考（黄金） ---------------------------------

def maxpool_ref(t, C, W, H):
    """2x2/stride2 int8 取最大。t/返回都是流顺序（见文件头）。"""
    if W < 2 or W % 2 or H % 2:
        raise ValueError("maxpool 要求 W>=2 且 W、H 均为偶数，得到 C=%d W=%d H=%d" % (C, W, H))
    if len(t) != C * W * H:
        raise ValueError("输入长度 %d != C*W*H = %d" % (len(t), C * W * H))
    ow, oh = W // 2, H // 2
    out = [0] * (C * ow * oh)
    for y in range(oh):
        for x in range(ow):
            for ci in range(C):
                m = t[((2 * y) * W + 2 * x) * C + ci]
                for dy in (0, 1):
                    for dx in (0, 1):
                        v = t[((2 * y + dy) * W + (2 * x + dx)) * C + ci]
                        if v > m:      # int8 有符号比较
                            m = v
                out[(y * ow + x) * C + ci] = m
    return out


def maxpool_mut_topleft(t, C, W, H):
    """突变体：2x2 窗口恒取**左上角** ⇒ 输出 = 输入按块取 (even,even)。"""
    if W % 2 or H % 2:
        raise ValueError("要求 W、H 均为偶数")
    ow, oh = W // 2, H // 2
    out = [0] * (C * ow * oh)
    for y in range(oh):
        for x in range(ow):
            for ci in range(C):
                out[(y * ow + x) * C + ci] = t[((2 * y) * W + 2 * x) * C + ci]
    return out


def resize2x_ref(t, C, W, H):
    """x2 最近邻上采样：out[c][2y+dy][2x+dx] = in[c][y][x]。"""
    if H % 2:
        raise ValueError("resize 要求 H 为偶数（本单元按输入行对工作），得到 H=%d" % H)
    if len(t) != C * W * H:
        raise ValueError("输入长度 %d != C*W*H = %d" % (len(t), C * W * H))
    OW, OH = 2 * W, 2 * H
    out = [0] * (C * OW * OH)
    for y in range(H):
        for x in range(W):
            for ci in range(C):
                v = t[(y * W + x) * C + ci]
                for dy in (0, 1):
                    for dx in (0, 1):
                        out[((2 * y + dy) * OW + (2 * x + dx)) * C + ci] = v
    return out


def resize_mut_bank(t, C, W, H):
    """突变体：行相位 dy 取反（bank = 1 - dy）。

    正常：输出行 4t+g（g=Y%4）复刻输入行 2t + (g//2)；突变：复刻输入行 2t + (1 - g//2)。
    """
    if H % 2:
        raise ValueError("要求 H 为偶数")
    OW, OH = 2 * W, 2 * H
    out = [0] * (C * OW * OH)
    for Y in range(OH):
        t_ = Y // 4
        src_r = 2 * t_ + (1 - ((Y % 4) // 2))
        for X in range(OW):
            src_c = X // 2
            for ci in range(C):
                out[(Y * OW + X) * C + ci] = t[(src_r * W + src_c) * C + ci]
    return out


def resize_mut_col(t, C, W, H):
    """突变体：列相位配对取反（源列号最低位取反：srcCol = (X//2) ^ 1）。

    ⚠ W 必须偶数：否则 (W-1)^1 会越界。
    """
    if W % 2 or H % 2:
        raise ValueError("要求 W、H 均为偶数（本突变体的源列号取反需要）")
    OW, OH = 2 * W, 2 * H
    out = [0] * (C * OW * OH)
    for Y in range(OH):
        src_r = Y // 2
        for X in range(OW):
            src_c = (X // 2) ^ 1
            for ci in range(C):
                out[(Y * OW + X) * C + ci] = t[(src_r * W + src_c) * C + ci]
    return out


# ------------------------------- C3.7：Add（两路饱和加） -----------------------

def split_add(t, C, W, H):
    """把**按列交织**的双路流拆成 (a, b) 两条流（各 C*W*H 字节）。

    布局（装置约定，见文件头）：`idx = (row*W + col)*(2*C) + (0..C-1 => A, C..2*C-1 => B)`
    ⇒ "字节下标 i 属于 A 路" ⟺ `(i // C) % 2 == 0`（按 C 个通道一组交替）。
    """
    if len(t) != 2 * C * W * H:
        raise ValueError("add 的交织流长度 %d != 2*C*W*H = %d" % (len(t), 2 * C * W * H))
    a = [t[i] for i in range(len(t)) if (i // C) % 2 == 0]
    b = [t[i] for i in range(len(t)) if (i // C) % 2 == 1]
    return a, b


def interleave_add(a, b, C, W, H):
    """`split_add` 的逆：两条流按列交织成装置喂 DUT 的一条流。"""
    if len(a) != C * W * H or len(b) != C * W * H:
        raise ValueError("两路长度必须各为 C*W*H = %d（得到 %d / %d）" % (C * W * H, len(a), len(b)))
    out = [0] * (2 * C * W * H)
    for col in range(W * H):
        for ci in range(C):
            out[col * 2 * C + ci] = a[col * C + ci]
            out[col * 2 * C + C + ci] = b[col * C + ci]
    return out


def add_ref(a, b, C, W, H):
    """**黄金**：两路 int8 逐点相加 + **饱和**到 [-128,127]（clamp8，**不回绕**）。"""
    if len(a) != C * W * H or len(b) != C * W * H:
        raise ValueError("add_ref 要求两路长度各为 C*W*H = %d（得到 %d / %d）"
                         % (C * W * H, len(a), len(b)))
    return [clamp8(x + y) for x, y in zip(a, b)]


def add_mut_wrap(a, b, C, W, H):
    """突变体：**回绕**（`& 0xFF`，即丢掉 9 位和的最高位）—— 硬件里的 clamp=0。"""
    if len(a) != C * W * H or len(b) != C * W * H:
        raise ValueError("add_mut_wrap 要求两路长度各为 C*W*H = %d" % (C * W * H))
    return [i8(x + y) for x, y in zip(a, b)]


def add_sat_events(a, b):
    """向量上"真的发生饱和"的点数（0 ⇒ 饱和/回绕不可区分 ⇒ 负对照是橡皮章）。"""
    return sum(1 for x, y in zip(a, b) if not (-128 <= x + y <= 127))


# ------------------------------- C3.7：Sigmoid（Q3.4 -> Q0.7 查表） -----------------

def sigmoid_lut():
    """**冻结**的 256 项表（int8，值 ∈ [0,127]）：

        `lut[k] = floor(127 * sigmoid((k - 128) / 16) + 0.5)`，k = 0..255
        （地址 k = x + 128；`sigmoid(z) = 1 / (1 + exp(-z))`）

    与 `rtl/SigmoidUnit.scala::SigmoidUnit.lutFormula/lutInit` 是**同一条公式**（两侧必须逐项相等，
    由 `--lutfile`/`--lutbin` 与闸门的全码点正对照共同钉住）。
    取整 = `floor(v + 0.5)`（**不是** Python 的 `round()` 银行家舍入）。
    """
    return [int(math.floor(127.0 / (1.0 + math.exp(-(k - 128) / 16.0)) + 0.5)) for k in range(256)]


def sigmoid_ref(t, C, W, H):
    """**黄金**：查表。地址 = `x + 128`（mod 256）；输入/输出各 C*W*H 字节。"""
    if len(t) != C * W * H:
        raise ValueError("sigmoid 输入长度 %d != C*W*H = %d" % (len(t), C * W * H))
    lut = sigmoid_lut()
    return [lut[u8(v + 128)] for v in t]


def sigmoid_mut_invert(t, C, W, H):
    """突变体：**查表地址取反**（8 位二补数取负）⇒ 读到 `lut[(-addr) mod 256]`。

    `(-(v+128)) mod 256 == ((-v) + 128) mod 256` ⇒ 等价于**把输入换成 -x**：
    输出 = `round(127 * sigmoid(-x/16))`。`x = 0` 与 `x = -128` 是**不动点**（其余 254 个码点都变）。
    """
    if len(t) != C * W * H:
        raise ValueError("sigmoid 输入长度 %d != C*W*H = %d" % (len(t), C * W * H))
    lut = sigmoid_lut()
    return [lut[u8(-(v + 128))] for v in t]


def lut_hex_lines():
    """`gen/sigmoid_lut.hex` 的内容（每行一个十六进制字节，LF 结尾）。"""
    return "".join("%02x\n" % v for v in sigmoid_lut())


def write_lut(path):
    """把冻结的表写成 `path`（十六进制，256 行）并返回 (字节数, md5)。"""
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(lut_hex_lines())
    return 256, md5_file(path)


def read_lut_hex(path):
    """读回 `--genlut` 写的那份十六进制表（必须是 256 个 int8 token）。"""
    toks = open(path, encoding="utf-8", errors="replace").read().split()
    if len(toks) != 256:
        raise ValueError("%s 有 %d 个 token（期望 256）" % (path, len(toks)))
    return [i8(int(t, 16)) for t in toks]


def read_lut_bin(path):
    """读 SpinalHDL `Mem.init` 产的 `$readmemb` 初值文件：256 行，每行 8 个二进制字符。"""
    lines = [ln.strip() for ln in open(path, encoding="utf-8", errors="replace").read().splitlines()
             if ln.strip()]
    if len(lines) != 256:
        raise ValueError("%s 有 %d 行（期望 256）" % (path, len(lines)))
    return [i8(int(ln, 2)) for ln in lines]


def lut_mismatch(vals):
    """把一份"读回来的 256 项表"与冻结公式逐项比，返回 (列表, 不符项数)。"""
    gold = sigmoid_lut()
    return [i for i in range(256) if vals[i] != gold[i]], sum(1 for i in range(256) if vals[i] != gold[i])


# ------------------------------- 非平凡向量 -----------------------------------

def nontrivial(C, W, H):
    """非平凡输入向量（流顺序 [row][col][ci]）。

    骨架 = `(i*131+7) & 0xFF` 的 int8 解释（伪随机），再按 **2x2 块**构造：
    块内四个角**两两不同**、且"局部极大"落在哪个角**逐块轮转**（hot = 块号 % 4）：
        hot 角拿  [64, 119]，其余三角拿 [-128+ph, -88+ph, -48+ph]（都 < 64，互不相同）
    ⇒（a）窗口最大值 = hot 角，且 hot 逐块变化 ⇒ **黄金不等于任何单一"整块平移"子采样**
           —— 这是**防混叠**的关键：窗口取错任何一个角都必然在输出里显形；
      （b）块内四个值两两不同 ⇒ 相邻行、相邻列必然不同 ⇒ Resize 的 dy/dx 相位错了必然变值；
      （c）低位跟骨架走 ⇒ 不是"只跟块号有关"的死图案。
    """
    if W % 2 or H % 2:
        raise ValueError("需要 W、H 均为偶数，得到 W=%d H=%d" % (W, H))
    W2 = W // 2
    t = [0] * (C * W * H)
    for r in range(H):
        for c in range(W):
            blk = ((r // 2) * W2 + (c // 2)) * C
            corner = (r % 2) * 2 + (c % 2)          # 0=(even,even) 1=(even,odd) 2=(odd,even) 3=(odd,odd)
            for ci in range(C):
                i = (r * W + c) * C + ci
                k = blk + ci
                ph = (k * 41 + 13) % 56             # 0..55
                hot = k % 4                         # 本块的局部极大落在哪个角
                if corner == hot:
                    v = 64 + ph
                else:
                    idx = sum(1 for kk in range(corner) if kk != hot)   # 其余三角按角号升序
                    v = [-128 + ph, -88 + ph, -48 + ph][idx]
                v += i8(i * 131 + 7) & 1
                assert -128 <= v <= 127, "注入值越界: %d" % v
                t[i] = v
    return t


def add_nontrivial(C, W, H):
    """**Add 的双路非平凡向量**（返回装置用的**按列交织**流）。

    两路骨架不同（`i*131+7` 与 `i*211+29`）⇒ `a != b`（否则"加法"退化成 ×2，判据没意义）；
    前四个点**注入边界/饱和**：`(127,127)`、`(-128,-128)`、`(100,100)`、`(-100,-100)`。
    """
    a = [0] * (C * W * H)
    b = [0] * (C * W * H)
    inj = [(127, 127), (-128, -128), (100, 100), (-100, -100)]
    for r in range(H):
        for c in range(W):
            for ci in range(C):
                i = (r * W + c) * C + ci
                if i < len(inj):
                    a[i], b[i] = inj[i]
                else:
                    a[i] = i8(i * 131 + 7)
                    b[i] = i8(i * 211 + 29)
    return interleave_add(a, b, C, W, H)


def sigmoid_sweep(C, W, H):
    """**Sigmoid 的码点扫描向量**：长度 `C*W*H`，前 256 个位置是 **0..255 的一个排列**
    （`(j*97+13) mod 256`，97 与 256 互素 ⇒ 前 256 个值恰好覆盖全部码点，每个一次）。"""
    n = C * W * H
    if n < 256:
        raise ValueError("sigmoid 扫描向量要覆盖 256 个码点，C*W*H = %d < 256" % n)
    return [i8(j * 97 + 13) for j in range(n)]


def corner_subsamples(t, C, W, H):
    """输入按 2x2 块的四个角各自子采样（展平 [y][x][ci]）⇒ 返回 (TL, TR, BL, BR)。"""
    ow, oh = W // 2, H // 2
    outs = [[0] * (C * ow * oh) for _ in range(4)]
    for y in range(oh):
        for x in range(ow):
            for ci in range(C):
                k = (y * ow + x) * C + ci
                outs[0][k] = t[((2 * y) * W + 2 * x) * C + ci]
                outs[1][k] = t[((2 * y) * W + 2 * x + 1) * C + ci]
                outs[2][k] = t[((2 * y + 1) * W + 2 * x) * C + ci]
                outs[3][k] = t[((2 * y + 1) * W + 2 * x + 1) * C + ci]
    return outs


# ------------------------------- 自测 -----------------------------------------

FAILS = []


def chk(cond, msg):
    if cond:
        print("  PASS  " + msg)
    else:
        print("  FAIL  " + msg)
        FAILS.append(msg)


def naive_maxpool(t, C, W, H):
    """独立写的朴素实现（张量 [ci][row][col] 视角，三重循环 + 显式比较），
    刻意**不**复用上面的流顺序代码 —— 用来交叉检验 maxpool_ref。"""
    tt = to_tensor(t, C, W, H)
    ow, oh = W // 2, H // 2
    res = [0] * (C * oh * ow)
    for ci in range(C):
        for y in range(oh):
            for x in range(ow):
                best = tt[(ci * H + 2 * y) * W + 2 * x]
                for dy in (0, 1):
                    for dx in (0, 1):
                        cand = tt[(ci * H + 2 * y + dy) * W + 2 * x + dx]
                        if cand > best:
                            best = cand
                res[(ci * oh + y) * ow + x] = best
    return from_tensor(res, C, ow, oh)


def naive_resize2x(t, C, W, H):
    """独立写的朴素最近邻（逐输出像素回查源像素），交叉检验 resize2x_ref。"""
    OW, OH = 2 * W, 2 * H
    res = [0] * (C * OW * OH)
    for Y in range(OH):
        for X in range(OW):
            for ci in range(C):
                src_y, src_x = Y // 2, X // 2
                res[(Y * OW + X) * C + ci] = t[(src_y * W + src_x) * C + ci]
    return res


def naive_add(a, b, C, W, H):
    """独立写的朴素饱和加（张量 [ci][row][col] 视角 + 显式 if/else，**不复用 clamp8**），
    且**先**把两条流各自搬进张量再相加 —— 用来交叉检验 add_ref 的流顺序/打包。"""
    ta, tb = to_tensor(a, C, W, H), to_tensor(b, C, W, H)
    res = [0] * (C * W * H)
    for ci in range(C):
        for r in range(H):
            for c in range(W):
                s = ta[(ci * H + r) * W + c] + tb[(ci * H + r) * W + c]
                if s > 127:
                    s = 127
                elif s < -128:
                    s = -128
                res[(ci * H + r) * W + c] = s
    return from_tensor(res, C, W, H)


def naive_sigmoid_by_lut(t, C, W, H):
    """独立写的查表（逐元素、`% 256` 取址 + 现场建表），交叉检验 sigmoid_ref 的**流顺序/取址**。

    ⚠ 它**不是**"公式的独立实现"（同一台数学库、同一条公式）——sigmoid 的**真正**独立对账是
    文件级的：`gen/sigmoid_lut.hex`（Python 侧）vs `gen/SigmoidUnit.v_toplevel_lut.bin`（RTL 侧）
    vs 装置 `$readmemh` 载入 .hex 后的全 256 码点逐字节比。这里只钉"表用对了、地址没串"。
    """
    tab = [sigmoid_lut()[k] for k in range(256)]
    out = [0] * (C * W * H)
    for i in range(C * W * H):
        out[i] = tab[(t[i] + 128) % 256]
    return out


def selftest():
    print("[selftest] 用例 1：与**独立写的朴素三重循环**逐点一致（两个算子、两个形状）")
    for (C, W, H) in ((1, 2, 2), (3, 4, 4), (2, 6, 4)):
        t = nontrivial(C, W, H)
        chk(maxpool_ref(t, C, W, H) == naive_maxpool(t, C, W, H),
            "maxpool_ref == 朴素实现  (C=%d W=%d H=%d)" % (C, W, H))
        chk(resize2x_ref(t, C, W, H) == naive_resize2x(t, C, W, H),
            "resize2x_ref == 朴素实现 (C=%d W=%d H=%d)" % (C, W, H))

    print("[selftest] 用例 2：MaxPool 无量化（透传）+ 输出非常数 + 防混叠")
    C, W, H = 3, 4, 4
    t = nontrivial(C, W, H)
    mp = maxpool_ref(t, C, W, H)
    chk(len(set(mp)) > 1, "maxpool 输出不是常数（防退化）")
    chk(len(set(t)) > 1, "输入不是常数")
    chk(set(mp) <= set(t), "maxpool 的每个输出值都在输入值集合里（取最大 = 透传，**没有**发明 scale）")
    chk(all(-128 <= v <= 127 for v in mp), "输出全在 int8 范围内")
    # 防混叠：局部极大逐块轮转 ⇒ 黄金**不等于任何** 单一整块平移子采样（窗口取错角必然显形）
    TL, TR, BL, BR = corner_subsamples(t, C, W, H)
    chk(len({tuple(TL), tuple(TR), tuple(BL), tuple(BR)}) == 4, "四个角子采样两两不同")
    chk(mp != TL and mp != TR and mp != BL and mp != BR,
        "黄金 != 左上/右上/左下/右下 四个整块平移（防混叠：取错任何一个角都会显形）")
    hits = [sum(1 for a, b in zip(mp, s) if a == b) for s in (TL, TR, BL, BR)]
    chk(all(0 < h < len(mp) for h in hits),
        "黄金与每个角子采样都是'部分相同、部分不同'（四个角都被真用到）：命中 %s" % hits)

    print("[selftest] 用例 3：Resize 无插值（逐位复制）+ 输出非常数 + 相位突变体可观测")
    rz = resize2x_ref(t, C, W, H)
    chk(len(set(rz)) > 1, "resize 输出不是常数（防退化）")
    chk(set(rz) <= set(t), "resize 的每个输出值都在输入值集合里（逐位复制，**没有**插值/量化）")
    from collections import Counter
    chk(Counter(rz) == Counter({v: 4 * n for v, n in Counter(t).items()}),
        "每个输入像素在输出里恰好出现 4 次（x2 同行列各复制一次）")
    chk(len(rz) == 4 * len(t), "输出长度 = 4 x 输入长度")
    mb = resize_mut_bank(t, C, W, H)
    mc = resize_mut_col(t, C, W, H)
    chk(mb != rz, "行相位取反(bank=1-dy) 与黄金不同 ⇒ 负对照 B(dy) 可观测")
    chk(mc != rz, "列相位取反(srcCol=(X>>1)^1) 与黄金不同 ⇒ 负对照 B(dx) 可观测")
    chk(len(mb) == len(rz) and len(mc) == len(rz), "两个突变体输出长度与黄金一致（只错值、不缺数据）")

    print("[selftest] 用例 4：MaxPool 左上角突变体可观测（负对照 A 的前提）")
    mt = maxpool_mut_topleft(t, C, W, H)
    chk(mt == TL, "左上角突变体 == 左上角子采样（口径对得上）")
    chk(mt != mp, "左上角突变体与黄金不同 ⇒ 负对照 A 可观测")

    print("[selftest] 用例 5：奇数维度必须**响亮失败**（不静默）")
    for (fn, args, name) in ((maxpool_ref, (nontrivial(1, 4, 4), 1, 3, 4), "maxpool W 奇"),
                             (maxpool_ref, (nontrivial(1, 4, 4), 1, 4, 3), "maxpool H 奇"),
                             (resize2x_ref, (nontrivial(1, 4, 4), 1, 4, 3), "resize H 奇"),
                             (add_ref, (nontrivial(1, 4, 4), nontrivial(1, 4, 4), 1, 3, 4), "add 长度不符"),
                             (sigmoid_ref, (nontrivial(1, 4, 4), 1, 3, 4), "sigmoid 长度不符")):
        try:
            fn(*args)
            chk(False, "%s 竟然没报错" % name)
        except ValueError:
            chk(True, "%s ⇒ 抛 ValueError（响亮失败）" % name)

    print("[selftest] 用例 6：Add **饱和 != 回绕**（两条口径在真实向量上必然分岔）")
    C, W, H = 3, 4, 4
    st = add_nontrivial(C, W, H)
    a, b = split_add(st, C, W, H)
    chk(len(st) == 2 * C * W * H, "交织流长度 = 2*C*W*H（两路各 C*W*H）")
    chk(a != b, "两路输入**不相等**（否则加法退化成 ×2，判据没意义）")
    chk(interleave_add(a, b, C, W, H) == st, "split_add / interleave_add 互为逆（交织约定自洽）")
    ga = add_ref(a, b, C, W, H)
    chk(ga == naive_add(a, b, C, W, H), "add_ref == 独立朴素实现（张量视角 + 显式 if/else）")
    # 冻结的饱和点（plan Step 2 点名）
    chk(add_ref([127], [127], 1, 1, 1) == [127], "饱和点：127 + 127 -> 127（不是 -2）")
    chk(add_ref([-128], [-128], 1, 1, 1) == [-128], "-128 + -128 -> -128（不是 0）")
    chk(add_ref([100], [100], 1, 1, 1) == [127] and add_ref([-100], [-100], 1, 1, 1) == [-128],
        "100+100 -> 127 / -100+-100 -> -128（一般的越界也饱和）")
    chk(add_ref([127], [-128], 1, 1, 1) == [-1] and add_ref([0], [0], 1, 1, 1) == [0],
        "未越界的点原样透传（饱和逻辑不会误伤正常值）")
    se = add_sat_events(a, b)
    print("  INFO  SAT_EVENTS=%d（本向量上越界 = 真的发生饱和的点数）" % se)
    chk(se > 0, "向量上真有饱和点（SAT_EVENTS=%d > 0）⇒ '饱和 vs 回绕'这条判据不是橡皮章" % se)
    mw = add_mut_wrap(a, b, C, W, H)
    chk(mw != ga, "回绕突变体 != 黄金 ⇒ 负对照 A 可观测")
    chk(all(mw[i] == ga[i] for i in range(len(ga)) if -128 <= a[i] + b[i] <= 127)
        and all(mw[i] != ga[i] for i in range(len(ga)) if not (-128 <= a[i] + b[i] <= 127)),
        "回绕突变体**只在越界点上**与黄金不同（%d 个点）⇒ 位置/数量都对得上，不是乱改" % se)

    print("[selftest] 用例 7：Sigmoid 表（Q3.4 -> Q0.7）与地址取反负对照")
    lut = sigmoid_lut()
    chk(len(lut) == 256, "表深 256")
    chk(lut == sigmoid_lut(), "表两次求值逐项相同（进程内确定性）")
    chk(all(0 <= v <= 127 for v in lut), "表值全在 [0,127]（sigmoid ∈ (0,1) ⇒ 无饱和、无负数）")
    chk(all(lut[i] <= lut[i + 1] for i in range(255)), "表**单调不减**（sigmoid 单调）")
    chk(lut[128] == 64, "表中点：x = 0 -> 64（= round(127 * 0.5)，plan Step 2 点名）")
    chk(lut[0] == 0 and lut[255] == 127, "端点：x = -128 -> 0、x = 127 -> 127（不溢出 int8）")
    C, W, H = 2, 4, 32
    sv = sigmoid_sweep(C, W, H)
    chk(len(set(sv)) == 256, "扫描向量覆盖**全部 256 个码点**（len(set)=%d）" % len(set(sv)))
    chk(sigmoid_ref(sv, C, W, H) == naive_sigmoid_by_lut(sv, C, W, H),
        "sigmoid_ref == 独立写的查表（取址/流顺序对得上）")
    chk(sigmoid_ref(sv, C, W, H) == [lut[(v + 128) % 256] for v in sv], "= 沿冻结地址约定查表")
    mi = sigmoid_mut_invert(sv, C, W, H)
    gg = sigmoid_ref(sv, C, W, H)
    chk(mi != gg, "地址取反突变体 != 黄金 ⇒ 负对照 B 可观测")
    diffcodes = sorted({sv[i] for i in range(len(gg)) if gg[i] != mi[i]})
    fixedcodes = [x for x in range(-128, 128) if lut[(x + 128) % 256] == lut[((-x) + 128) % 256]]
    print("  INFO  地址取反后有 %d/256 个码点变值；不动点 = %s" % (len(diffcodes), fixedcodes))
    chk(len(diffcodes) == 254, "恰好 **254** 个码点变值（表在 x -> -x 下**不对称**）")
    chk(fixedcodes == [-128, 0], "恰好 2 个不动点且就是 x = -128 与 x = 0 ⇒ 负对照不是橡皮章（其余全变）")

    if FAILS:
        print("SELFTEST: FAIL (%d)" % len(FAILS))
        return 1
    print("SELFTEST: PASS")
    return 0


# ------------------------------- 入口 -----------------------------------------

USAGE = """usage:
  bypass_ref.py maxpool <C> <W> <H> --infile=<x.hex> [--mutate=topleft]
  bypass_ref.py resize  <C> <W> <H> --infile=<x.hex> [--mutate=bank|col]
  bypass_ref.py add     <C> <W> <H> --infile=<ab.hex> [--mutate=wrap]     # 按列交织 [A(C),B(C)]
  bypass_ref.py sigmoid <C> <W> <H> --infile=<x.hex>  [--mutate=invert]
  bypass_ref.py <op>    <C> <W> <H> --gen=<x.hex>
  bypass_ref.py --genlut=<sigmoid_lut.hex>                # 写 256 项表（+ md5）
  bypass_ref.py --lutfile=<sigmoid_lut.hex>               # 断言该文件 == 冻结公式
  bypass_ref.py --lutbin=<SigmoidUnit.v_toplevel_lut.bin> # 断言 RTL 的 Mem 初值 == 冻结公式
  bypass_ref.py --selftest
"""


def main(argv):
    if "--selftest" in argv[1:]:
        return selftest()

    # ---- 三个纯表作业（不带 C/W/H）----
    for a in argv[1:]:
        if a.startswith("--genlut="):
            path = a.split("=", 1)[1]
            n, h = write_lut(path)
            print("LUT: %d 项 -> %s" % (n, path))
            print("SIG_LUT_MD5=%s" % h)
            return 0
        if a.startswith("--lutfile=") or a.startswith("--lutbin="):
            binmode = a.startswith("--lutbin=")
            path = a.split("=", 1)[1]
            try:
                vals = read_lut_bin(path) if binmode else read_lut_hex(path)
            except (OSError, ValueError) as e:
                print("FATAL: 读不了 %s: %s" % (path, e))
                return 3
            bad, nbad = lut_mismatch(vals)
            tag = "SIG_LUT_RTLBIN" if binmode else "SIG_LUT_FILE"
            print("%s: %s（256 项）与冻结公式逐项比：不符 %d 项%s"
                  % (tag, path, nbad, "" if nbad == 0 else " -> %s" % bad[:12]))
            print("%s_OK=%d" % (tag, 1 if nbad == 0 else 0))
            return 0 if nbad == 0 else 3

    if len(argv) < 5:
        print(USAGE)
        return 2
    op = argv[1]
    if op not in OPS:
        print("FATAL: 未知算子 %r（只有 %s）" % (op, " | ".join(OPS)))
        return 2
    try:
        C, W, H = int(argv[2]), int(argv[3]), int(argv[4])
    except ValueError:
        print("FATAL: C/W/H 必须是整数")
        return 2
    infile = genfile = None
    mutate = None
    for a in argv[5:]:
        if a.startswith("--infile="):
            infile = a.split("=", 1)[1]
        elif a.startswith("--gen="):
            genfile = a.split("=", 1)[1]
        elif a.startswith("--mutate="):
            mutate = a.split("=", 1)[1]
        else:
            print("FATAL: 不认识的参数 %r\n%s" % (a, USAGE))
            return 2
    if mutate is not None and mutate not in MUTATES.get(op, ()):
        print("FATAL: %s 没有突变体 %r（只有 %s）"
              % (op, mutate, " | ".join(MUTATES.get(op, ()))))
        return 2
    if min(C, W, H) <= 0:
        print("FATAL: C/W/H 必须为正")
        return 2

    # --gen：写非平凡输入向量（供闸门/装置用）——add 写**交织流**、sigmoid 写**码点扫描流**
    if genfile is not None:
        try:
            if op == "add":
                t = add_nontrivial(C, W, H)
            elif op == "sigmoid":
                t = sigmoid_sweep(C, W, H)
            else:
                t = nontrivial(C, W, H)
        except ValueError as e:
            print("FATAL: %s" % e)
            return 3
        dump_hex(genfile, t)
        print("VEC: 非平凡输入 %d 字节 -> %s（op=%s C=%d W=%d H=%d）" % (len(t), genfile, op, C, W, H))
        return 0

    if infile is None:
        print("FATAL: 缺 --infile= 或 --gen=\n%s" % USAGE)
        return 2
    try:
        t = load_hex(infile)
    except (OSError, ValueError) as e:
        print("FATAL: 读不了输入向量 %s: %s" % (infile, e))
        return 2

    try:
        if op == "maxpool":
            out = maxpool_mut_topleft(t, C, W, H) if mutate == "topleft" else maxpool_ref(t, C, W, H)
        elif op == "resize":
            if mutate == "bank":
                out = resize_mut_bank(t, C, W, H)
            elif mutate == "col":
                out = resize_mut_col(t, C, W, H)
            else:
                out = resize2x_ref(t, C, W, H)
        elif op == "add":
            a, b = split_add(t, C, W, H)
            out = add_mut_wrap(a, b, C, W, H) if mutate == "wrap" else add_ref(a, b, C, W, H)
        else:                                     # sigmoid
            out = sigmoid_mut_invert(t, C, W, H) if mutate == "invert" else sigmoid_ref(t, C, W, H)
    except ValueError as e:
        print("FATAL: %s" % e)
        return 3

    print(hexstr(out))
    print("# dims op=%s%s C=%d W=%d H=%d | in=%d out=%d | 非平凡=%s"
          % (op, "" if mutate is None else ("/mut=%s" % mutate), C, W, H,
             len(t), len(out), "是" if len(set(out)) > 1 else "否(常数!)"),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
