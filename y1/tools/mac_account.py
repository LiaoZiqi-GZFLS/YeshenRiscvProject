#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P0：YuNet 逐层 MAC 账 + 双侧天花板（算力 / 带宽）—— 离线，只读冻结输入。

背景（spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5-P0）
------------------------------------------------------------------
本项目带宽侧有账（`ddr_traffic.py`/`bypass_traffic.py` 冻结模型），**从未做过逐层 MAC 账**
⇒ "算力侧帧率天花板"一直只是示意（旧 spec 的 344 M-MAC / 18.6 fps @100MHz 无逐层表背书）。
本工具把它补上：逐单元 MAC（67 个真单元全表）+ 两个意义上的算力天花板，并把带宽侧
（冻结模型 + 实测放大锚点）与算力侧并列，回答"哪一侧是紧的"。

输入（权威，只读）
------------------
  · `y1/gen/desc.bin`    —— 67 条载荷描述符（8 字/项）+ 哨兵（68 项 = 2176 B）；
                            字打包（`y1/tools/desc_table.py` 冻结口径）：
                              w0 = TYPE | FLAGS<<8          （其余位 0）
                              w1 = IMG_W | IMG_H<<16
                              w2 = C_IN  | C_OUT<<16
                              w3 = GROUP | STRIDE<<8 | PAD<<12
                              w4 = SRC_ADDR  w5 = DST_ADDR  w6 = IN_BYTES
                              w7 = QUANT_SHIFT | LAYER_ID<<8
                            TYPE：0x01 conv3x3 / 0x02 conv1x1 / 0x03 depthwise /
                                  0x10 maxpool / 0x11 resize / 0x12 concat / 0x13 add /
                                  0x14 sigmoid / 0xFF 哨兵
                            ★ 链（FLAGS head/middle/tail）：`IMG_W/IMG_H/C_IN/C_OUT/GROUP`
                              被**链首几何覆盖**（desc_table.py 冻结口径）⇒ 逐单元**真实几何**
                              取自 `wgt_index.json` 的 `own` 字段（下表对每个 plain/head 项
                              断言两者一致；对 middle/tail 项断言 desc = 链首覆盖值）。
                              ★★ A2（2026-10-16）：真表**宽 run 已全部拆成 plain** ⇒ 本表 67 项
                              逐项走"plain/head ⇒ desc == own"那一条（middle/tail 分支留给未来的窄链）。
  · `y1/gen/wgt_index.json` —— 逐单元 `own`（真几何）、`in_bytes`（真输入张量字节）、
                            `aligned_bytes`/`offset`（权重段）、flags/type 名。

MAC 口径（本工具定义，逐项可复算）
---------------------------------
  MACs(单元) = H_out · W_out · C_out · (C_in / GROUP) · taps
  taps 从单元 TYPE 派生（不假设）：conv3x3 → 9；depthwise（3×3 深度）→ 9；conv1x1 → 1。
  非 MAC 算子（maxpool / resize / add / sigmoid）**不进 MAC 合计**，另表列元素数。

算力天花板（"拍"的定义与出处，★ 读 RTL 的还是假设的都写明）
------------------------------------------------------------
  · `MAC_PER_BEAT = 64`（8 co × 8 ci）—— **读 RTL**：`y1/rtl/MacArray.scala`（8×8 真瓦片、
    64 个乘法器个个有用，`run_macarray_ab.sh` 判据把住）。
  · `NPU_CLK = 50 MHz` —— **读报告**：`y1/reports/npu_clock.md`（板级约束钟 50.000 MHz；
    PnR 实测可闭合到 54.142 MHz，本项目按 50 记账）。
  · 理想式：`beats_ideal = total_MACs / 64`、`t = beats / 50e6`（spec §5-P0 指定式）。
  · 多趟（eff）路径式：真表**每一个** conv/dw 单元都走宽路多趟
    （`narrowShape = C_in==C_out==GROUP==8 且非 dw`，真表无此形状 ⇒ `isWide` 恒真；
    见 `UnitExec.scala:1382-1395`）。切片对**每个输出像素**恒跑 9 拍 tap 相位
    （`Conv3x3Slice.scala` ph=1..9，与核大小无关；1×1 的其余 8 抽头权重为 0）
    ⇒ `beats_issued = 9 · nPasses · H_out · W_out`，
    `nPasses = nCi·nCo`（dense）/ `nCo`（dw 对角趟），`nCi=ceil(C_in/8)`、`nCo=ceil(C_out/8)`
    （`UnitExec.scala` 宽路趟编排：wSt FSM / `nCi` / `nCo` / 对角趟）。
    —— 这一档就是 spec §5-P0 "eff（多趟）路径每 MAC 的拍数比 1×1 理想多就建模"的落点：
    1×1 单元（taps=1）多花 **9×**；dw 多花 **8×**（对角掩码 8/64 有用）；C 不足 8 的块多花
    ceil 舍入倍；dense 3×3 双满块恰 == 理想（1×）。
  · 单切片每像素的**墙钟**节拍 = 1 收列 + 9 tap + 1 出数 = 11 拍（`Conv3x3Slice` FSM），
    本工具只作注记，不并入 beats 口径。

带宽侧（本工具只做锚点搬运 + 三档场景，不改冻结工具）
------------------------------------------------------
  · 冻结模型两个已知数（`tools/ddr_traffic.py` 原样调用，本工具**不重实现**）：
    baseline = 31,942,400 B/帧；fuse_both = 12,576,000 B/帧。
    本工具用**自己的译码**（desc.bin + wgt_index.json）独立复算这两个数（下 §CHECK），
    差异 **必须为 0**；desc 表里 C_in=1 折档平面的 32 B 对齐补位（+32 B，2 个单元）单列。
  · 旁路算子流量 = 冻结 `tools/bypass_traffic.py` 的 6,945,600 B/帧（原样调用）。
  · 场景 (a)-(e)：见 `scenarios()` 的逐项注释；所有放大因子来自实测锚点
    （23.3× / 2.9× / 4.4×，出处写在常量旁）。

============================== ★★ P0b（2026-10-16）：按类归因 + 反事实（本片追加） ==============================
P0 只报了一个总数（issued 45,075,600 拍 / 1.11 fps）与两条"点名"。**要下"先修哪一条"的决定，
需要每条浪费的价签**：所以本片把 issued 拍按 **类**（`1×1` / `depthwise` / `dense 3×3`）拆开，
再给两档反事实（A：1×1 只发 1 拍/像素/趟；B：dw 用满阵列）与"理想 → A+B"的差，外加**时钟敏感表**。

  · 类归属（= desc TYPE，非估计）：`conv1x1` → `1x1`；`depthwise` → `dw`；`conv3x3` → `dense3x3`。
  · 反事实 A（**读 RTL + 读 blob**）：真 blob 的 1×1 单元**每个 (co,ci) 的 9 槽里只有槽 0 非零**
    （本片实测重扫；出处 `y1_convert.py` L604 "1×1 核 → 单抽头落在 (ky,kx)=(0,0)"），
    而切片的拍序是 ph=1 → `tapK=0`（先发槽 0）⇒ **"只发 1 拍"= 只留第 1 拍、其余 8 拍权重恒 0
    直接不发** ⇒ 数值**逐字节不变**、**不需要**动权重布局（这是"跳拍"档）。若改成"只留中心拍
    （槽 4）"，必须同时把权重从槽 0 搬到槽 4（blob 重生成 + 装载映射改动）—— **拍数/帧率
    两档相同**，差的是改动面（见打印注记）。
  · 反事实 B（**modeled，且本片给结构性警示**）：dw 的 issued 拍 = `9·nCo·H·W`（对角趟），
    每拍只有 8/64 个 (co,ci) 有用 ⇒ 8.1×。"用满阵列"口径 = issued → ideal（`MACs/64`）
    ⇒ 8.1× → 1×。★ 诚实警示：**当前切片/阵列的 x 总线是"按 ci 通道索引的一条共享列"**
    （`arrX(ci)=colWin(kx)(ci)(ky)`），dw 的 64 槽里只有对角 8 槽是"行 r 吃自己通道"；
    要让一拍填满 64 个有用乘，需要**数据通路改动**（每行 x 路由 / tap 向量化），
    **不是**微序列能变出来的 ⇒ B 是"上界/目标"口径，**可行性属开口测量**（报告 §P0b-3）。
    B 的分组映射照旧按 co-block：`C_out=64 ⇒ 8 趟`、`C_out=10 ⇒ 2 趟（末趟 2 通道尾块）`、
    `C_out=4 ⇒ 1 趟` —— 与今日 `nCo = ceil(C_out/8)` 的趟结构**同一个**（变的只是每拍利用率）。
  · 时钟敏感表（**敏感度，不是测量**）：`fps = npu_clk ÷ beats`，给 50/60/75/100 MHz 四档；
    0.71 档（tile halo 重喂）与 11 拍/像素墙钟注记**不**参与本表（口径与 P0 一致）。

★★ 切片 A（NPU v2 §4.6-5，2026-10-16）：**1×1 只发 1 个 tap-beat 已落 RTL**（`Conv3x3Slice.X1SKIP`；
  闸门 `tools/run_x1skip_ab.sh` 实测 9.00×、数值逐字节不变）⇒ 本工具新增**自下而上**的实计账
  `IMPL_A_BEATS = Σ_单元 taps_eff(类)·passes·H·W`（1×1 类 = 1 拍）与 `FPS_COMPUTE_IMPL_A`：
  它必须与 `CF A`（自上而下）**逐位相等**（CHECK `impl_a_eq_cf_a`）并与 P0b 价签
  **13,920,400**（= 3.5919 fps @50 MHz，CHECK `impl_a_tag_p0b`）一致 —— 这就是"切片 A 的 fps
  重新签发"的判据（Gap 注记：`CF A` 的收益里包含宽链成员，宽链引擎（T-S3f）未落地前，那部分
  在硬件上仍会 `go` 那一刻响亮 err ⇒ **单单元 1×1 的收益已实测拿到，链内 1×1 的收益等 T-S3f**）。

用法
----
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --selftest      # 自检（闸门用）
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py                 # 全表 + 天花板 + 类账 + 反事实
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --scenarios     # 五档逐帧流量
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --perturb 20:C_OUT:8   # 负对照注入（几何）
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --perturb-taps dw:3    # 负对照注入（类抽头数）
    PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --emit-table OUT.txt

退出码：0 = 自检全过 / 1 = 有 CHECK 失败 / 3 = 输入或环境错误。
（`--perturb` / `--perturb-taps` 只改内存里的副本，绝不回写 `gen/`。）
"""
import argparse
import hashlib
import io
import json
import os
import struct
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
DESC_BIN = os.path.join(Y1, "gen", "desc.bin")
WGT_INDEX = os.path.join(Y1, "gen", "wgt_index.json")
BLOB_BIN = os.path.join(Y1, "gen", "wgt_blob.bin")   # ★ P0b：反事实 A 的前提（只读；见 blob_slot0_check）

# ============================ 常量（出处逐条） ============================
MAC_PER_BEAT = 64              # RTL: y1/rtl/MacArray.scala（8 co × 8 ci 真瓦片）
NPU_CLK_HZ = 50_000_000        # reports/npu_clock.md：50.000 MHz（PnR 实测 54.14）
SLICE_TAP_BEATS = 9            # RTL: y1/rtl/Conv3x3Slice.scala（ph=1..9，每像素恒 9 拍）
SLICE_CYC_PER_PIX = 11         # RTL: 同上（1 收列 + 9 tap + 1 出数）；注记用
DDR_BYTES_PER_S = 275.9e6      # 冻结 ddr_traffic.py 的 DDR_MBPS（partA/ddr_path_ceiling.md
                               # 静态桥路模型 32 B/116 ns；fps_bandwidth 分母，与冻结模型同口径）
W_MAX = 34                     # 板级网表行宽（reports/c4b：真实几何决定 WIDTH=34）
HT_TILE = 32                   # 板级网表 tile 高 IMG_H_MAX=32（同上）
TILE_W_S1 = W_MAX - 2          # s=1 tile 输出宽 32（UnitExec WT1 = WIDTH-2）
TILE_W_S2 = (W_MAX - 2) // 2   # s=2 tile 输出宽 16（UnitExec WT2）
BAND_F = 2_382_784.0 / 2_367_488.0   # = 1.00646：实测 band/对齐余量（见下两锚点）

# ---- 实测锚点（只搬运，不发明） ----
MEAS_C64_40X40 = (102_400, 2_382_784)   # c64_40x40 输入 102,400 B → 实测 RD 2,382,784 B
                                        # (74,462 AR 突发 × 32 B)；c4b_tiling_s2.md §11.5
MEAS_DW64_40X40 = (102_400, 296_896)    # dw64_40x40 同口径：2.9×（对角趟省 nCi 扇出）
ADD_MEAS_TENSOR = 102_400               # Add_44 的 A 张量（40×40×64）
ADD_MEAS_RD = 450_560                   # 实测 Add 整算子 RD（ts3e_gate_green.txt：MEM rd=450560,
                                        # bursts=19200）⇒ 4.4×；Add_50 同因子按张量缩放（modeled）
ADD_SRC2_TENSOR = 409_600               # Add_50 的 A 张量（80×80×64）

# ---- 冻结模型的既有数（cross-check 用；闸门会另行**调用**冻结工具复现） ----
FROZEN_BASELINE_B = 31_942_400          # ddr_traffic.py baseline TOTAL_BYTES
FROZEN_FUSED_B = 12_576_000             # ddr_traffic.py fuse_both TOTAL_BYTES
FROZEN_BYPASS_B = 6_945_600             # bypass_traffic.py BYPASS_BYTES
ALIGN32_PAD_B = 32                      # desc 表对 2 个 C_in=1 折档平面的 32 B 补位（已核名）

CONV_TYPES = ("conv3x3", "conv1x1", "depthwise")
NONMAC_TYPES = ("maxpool", "resize", "add", "sigmoid")
TAPS_BY_TYPE = {"conv3x3": 9, "depthwise": 9, "conv1x1": 1}

# ---- ★ P0b：按类归因 + 反事实 + 时钟敏感 ----
# 类 = desc TYPE 的 1:1 映射（不是估计）；三类的并集 == 全部 conv 类单元（CHECK 断言）。
CLASS_BY_TYPE = {"conv1x1": "1x1", "depthwise": "dw", "conv3x3": "dense3x3"}
CF_CLASSES = ("1x1", "dw", "dense3x3")     # 打印/断言顺序
CF_A_TAPS = 1                              # 反事实 A：1×1 类的抽头拍数（9 → 1）
CLK_SENS_MHZ = (50, 60, 75, 100)           # 时钟敏感档（50 = 现行板级钟，见 npu_clock.md）
CLK_PNR_ACHIEVED_MHZ = 54.142              # 敏感度注记用：PnR 实测可闭合频率（非本工具判据）

TYPE_BY_CODE = {0x01: "conv3x3", 0x02: "conv1x1", 0x03: "depthwise", 0x10: "maxpool",
                0x11: "resize", 0x12: "concat", 0x13: "add", 0x14: "sigmoid", 0xFF: "sentinel"}
FLAGS_BY_BITS = {0: "head", 1: "plain", 2: "middle", 3: "tail"}


def align32(n):
    return (n + 31) // 32 * 32


def cdiv(a, b):
    return -(-a // b)


def _p(out, *a):
    print(*a, file=out)




# ============================ 输入解码 ============================
class DescItem(object):
    __slots__ = ("idx", "w", "type_code", "flags", "img_w", "img_h", "c_in", "c_out",
                 "group", "stride", "pad", "src", "dst", "in_bytes", "qshift", "layer_id")

    def __init__(self, idx, w):
        self.idx = idx
        self.w = list(w)
        self.type_code = w[0] & 0xFF
        self.flags = (w[0] >> 8) & 0xFF
        self.img_w = w[1] & 0xFFFF
        self.img_h = (w[1] >> 16) & 0xFFFF
        self.c_in = w[2] & 0xFFFF
        self.c_out = (w[2] >> 16) & 0xFFFF
        self.group = w[3] & 0xFF
        self.stride = (w[3] >> 8) & 0xF
        self.pad = (w[3] >> 12) & 0xF
        self.src = w[4]
        self.dst = w[5]
        self.in_bytes = w[6]
        self.qshift = w[7] & 0xFF
        self.layer_id = (w[7] >> 8) & 0xFF

    @property
    def type_name(self):
        return TYPE_BY_CODE.get(self.type_code, "0x%02X?" % self.type_code)

    @property
    def flags_name(self):
        return FLAGS_BY_BITS.get(self.flags & 0x03, "?") if self.type_code != 0xFF else "sentinel"

    @property
    def stride_eff(self):
        return self.stride if self.stride else 1


def decode_desc_bin(path):
    """解 desc.bin：哨兵唯一、载荷 = 前 67 项。返回 (payload, sentinel, raw_bytes)。"""
    raw = open(path, "rb").read()
    if len(raw) % 32:
        raise SystemExit("desc.bin 长度 %d 不是 32 B 整数倍" % len(raw))
    items = [DescItem(i, struct.unpack_from("<8I", raw, i * 32)) for i in range(len(raw) // 32)]
    sents = [it for it in items if it.type_code == 0xFF]
    if len(sents) != 1 or items[-1].type_code != 0xFF:
        raise SystemExit("desc.bin 哨兵不唯一或不在表尾")
    payload = items[:-1]
    for it in payload:
        if it.type_code not in TYPE_BY_CODE or it.type_code == 0xFF:
            raise SystemExit("desc.bin 载荷含非法 TYPE=0x%02X @%d" % (it.type_code, it.idx))
    return payload, sents[0], raw


def load_wgt_units(path):
    with io.open(path, encoding="utf-8") as f:
        d = json.load(f)
    units = d["units"]
    if len(units) != len([u for u in units]):  # 恒真，保接口
        raise SystemExit("wgt_index.json units 异常")
    return d, units


# ============================ 逐单元账 ============================
class Unit(object):
    """一个真单元的账：own 真几何（wgt_index）+ desc 表字段（desc.bin）+ 派生量。"""

    def __init__(self, desc, wu, perturb=None):
        self.desc = desc
        self.name = wu["name"]
        self.wtype = wu["type"]
        self.flags_name = wu["flags_name"]
        self.in_bytes = wu["in_bytes"]           # 真输入张量字节（desc IN_BYTES 同源）
        own = dict(wu["own"])
        if perturb and perturb["idx"] == desc.idx:
            own[perturb["field"]] = own[perturb["field"]] + perturb["delta"]
        self.own = own
        self.taps = TAPS_BY_TYPE.get(self.wtype, 0)
        self.is_conv = self.wtype in CONV_TYPES
        self.is_dw = self.wtype == "depthwise"
        self.stride = desc.stride_eff
        self.H = own["IMG_H"]
        self.W = own["IMG_W"]
        self.C_in = own["C_IN"]
        self.C_out = own["C_OUT"]
        self.GROUP = own["GROUP"]
        # ---- MACs（口径见文件头）----
        if self.is_conv and self.taps:
            if self.GROUP <= 0 or self.C_in % self.GROUP:
                raise SystemExit("单元 %d GROUP=%d 不整除 C_in=%d" % (desc.idx, self.GROUP, self.C_in))
            self.macs = self.H * self.W * self.C_out * (self.C_in // self.GROUP) * self.taps
        else:
            self.macs = 0
        # ---- 多趟（eff）路径的"拍" ----
        self.nCi = cdiv(self.C_in, 8)
        self.nCo = cdiv(self.C_out, 8)
        self.passes = (self.nCo if self.is_dw else self.nCi * self.nCo) if self.is_conv else 0
        self.issued_beats = SLICE_TAP_BEATS * self.passes * self.H * self.W if self.is_conv else 0
        self.ideal_beats_frac = (self.macs / float(MAC_PER_BEAT)) if self.is_conv else 0.0
        # ---- 内存侧真张量 ----
        self.out_exact = self.C_out * self.H * self.W
        if self.wtype == "resize":
            self.in_exact = self.C_in * (self.H // 2) * (self.W // 2)   # 2× 升采样
        else:
            self.in_exact = self.C_in * (self.stride * self.H) * (self.stride * self.W)
        # desc IN_BYTES 与真张量的关系：C_in==1 折档 +32 B 对齐（其余逐字节相等）
        if self.wtype == "resize":
            self.in_bytes_rule = (self.in_bytes == self.in_exact)
        else:
            self.in_bytes_rule = (self.in_bytes == self.in_exact) or \
                                 (self.C_in == 1 and self.in_bytes == align32(self.in_exact))
        self.align_pad = self.in_bytes - self.in_exact
        # ---- 带宽场景用：宽路读模型 ----
        self.in_w = self.stride * self.W
        self.tiled = self.in_w > W_MAX
        # 每趟每列的字节 = 本 ci-block 的通道数（Npl = min(8, C_in-8*cib)，求和 = C_in）
        self.col_bytes = self.C_in
        if self.tiled:
            tw = TILE_W_S1 if self.stride == 1 else TILE_W_S2
            self.n_tiles = cdiv(self.W, tw) * cdiv(self.H, HT_TILE)
            self.win = (self.stride * tw + 2) * (self.stride * HT_TILE + 2)
        else:
            self.n_tiles = 1
            self.win = self.in_w * self.stride * self.H  # 非 tiled：整平面一读
        self.nco_eff = 1 if self.is_dw else self.nCo     # 对角趟无 co 重读

    # 逐场景的"该单元一次输入读"的模型字节（只对 DDR 读侧单元有意义）
    def reads(self, nco_eff, band_f):
        if self.tiled:
            return int(nco_eff * self.n_tiles * self.win * self.col_bytes * band_f)
        return nco_eff * self.stride * self.H * self.stride * self.W * self.col_bytes

    def reads_a(self):
        return self.reads(self.nco_eff, BAND_F)          # v1 as-is

    def reads_b(self):
        return self.reads(1, BAND_F)                     # + 窗口片上留住（杀 nCo 重读）

    def reads_c(self):
        return self.reads(1, 1.0)                        # + 平面 32B 补齐（杀 band/对齐余量）


def parse_perturb(spec):
    if not spec:
        return None
    idx_s, field, delta_s = spec.split(":")
    return {"idx": int(idx_s), "field": field, "delta": int(delta_s)}


# ============================ ★ P0b：反事实 A 的 blob 前提（只读） ============================
def blob_slot0_check():
    """读 `gen/wgt_blob.bin`（只读）证反事实 A 的两条前提：

    ① blob 的 md5 == `wgt_index.json` 记录的 md5（输入互证，与 desc.bin 同一手法）；
    ② **1×1 单元的非零权重只在 9 槽的第 0 槽**（= `(ky,kx)=(0,0)`，出处 `y1_convert.py` 权重落盘段），
       也就是切片 9 拍走序里的**第 1 拍**（ph=1 → `tapK=0`）⇒ "1×1 只发 1 拍"（跳拍档）**数值逐字节
       不变**且**不需要**动权重布局；若改成"只留中心拍（槽 4）"，blob 与装载映射都要动（见报告 §P0b-2）。
    ③ 对照组：dw 单元的权重**散布在 ≥2 个槽**（防"布局被改成对 dw 也单槽"这种静默前提失效）。
    返回 (md5_ok, slot0_ok, dw_slots_ok, detail_str)。
    """
    with io.open(WGT_INDEX, encoding="utf-8") as f:
        widx = json.load(f)
    rec = widx["blob"]
    raw = open(BLOB_BIN, "rb").read()
    md5_ok = (hashlib.md5(raw).hexdigest() == rec["md5"])
    x1_units = [u for u in widx["units"] if u["type"] == "conv1x1" and u.get("weight")]
    dw_units = [u for u in widx["units"] if u["type"] == "depthwise" and u.get("weight")]
    slot0_ok = True
    x1_nonzero = 0
    bad = []
    for u in x1_units:
        w = u["weight"]
        seg = raw[w["offset"]:w["offset"] + w["nbytes"]]
        for i, b in enumerate(seg):
            if b:
                x1_nonzero += 1
                if i % 9 != 0:
                    slot0_ok = False
                    bad.append("%d:%s@slot%d" % (u["idx"], u["name"], i % 9))
    dw_slots_ok = True
    for u in dw_units:
        w = u["weight"]
        seg = raw[w["offset"]:w["offset"] + w["nbytes"]]
        slots = set(i % 9 for i, b in enumerate(seg) if b)
        if len(slots) < 2:
            dw_slots_ok = False
    detail = "blob md5=%s(记录=%s)；1×1 单元 %d 个、非零权重 %d 个**全部在槽 0**%s；dw 单元权重散布 ≥2 槽=%s" % (
        hashlib.md5(raw).hexdigest()[:8], rec["md5"][:8], len(x1_units), x1_nonzero,
        ("" if slot0_ok else "——违例: " + ",".join(bad[:6])), dw_slots_ok)
    return md5_ok, slot0_ok, dw_slots_ok, detail


def build_units(perturb=None):
    payload, sentinel, raw = decode_desc_bin(DESC_BIN)
    _, wus = load_wgt_units(WGT_INDEX)
    if len(payload) != len(wus):
        raise SystemExit("desc 载荷 %d 项 != wgt_index %d 项" % (len(payload), len(wus)))
    units = [Unit(payload[i], wus[i], perturb) for i in range(len(payload))]
    return units, payload, wus, raw


# ============================ 自查 ============================
def checks(units, payload, wus, verbose=True):
    """所有 CHECK 都拿外部冻结数/第二真源比；返回 (ok, lines)。"""
    lines = []
    ok = True

    def chk(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        lines.append("CHECK %-46s %s%s" % (name, "PASS" if cond else "FAIL",
                                           ("  " + detail) if detail else ""))

    chk("payload_count_67", len(units) == 67, "67 项")
    chk("sentinel_unique", True, "在 decode 里断言")

    # 1) desc 与 wgt_index 的逐项一致性（两个独立文件对同一单元的口径）
    name_ok = type_ok = flag_ok = inb_ok = ge_ok = 1
    for u in units:
        d = u.desc
        name_ok &= (u.desc.type_name == u.wtype)
        type_ok &= (d.flags_name == u.flags_name)
        inb_ok &= (d.in_bytes == u.in_bytes)
        if u.flags_name in ("plain", "head"):   # 链首几何覆盖只对 middle/tail 生效
            ge_ok &= (d.img_w == u.own["IMG_W"] and d.img_h == u.own["IMG_H"] and
                      d.c_in == u.own["C_IN"] and d.c_out == u.own["C_OUT"])
    chk("desc_type_eq_wgt_type", name_ok)
    chk("desc_flags_eq_wgt_flags", type_ok)
    chk("desc_in_bytes_eq_wgt_in_bytes", inb_ok)
    chk("plain_head_geom_eq_own", ge_ok, "链首覆盖仅 middle/tail")

    # 2) in_bytes 派生规则（stride=2 输入 = s·H × s·W；C_in=1 折档 align32）
    rule_ok = all(u.in_bytes_rule for u in units)
    pads = [u for u in units if u.align_pad]
    pad_conv = sum(u.align_pad for u in pads if u.is_conv)
    chk("in_bytes_derivation_rule", rule_ok,
        "补位单元=%s（conv 侧合计=%d B）"
        % (",".join("%d:%s(+%d)" % (u.desc.idx, u.name, u.align_pad) for u in pads), pad_conv))
    chk("align32_pad_conv_side_32B", pad_conv == ALIGN32_PAD_B,
        "bypass 侧另有 Sigmoid_101/125 各 +16 B（不进出 unfused 对比）")

    # 3) MAC 合计：旧 spec 的示意数 344,224,000（首次有逐层表背书）
    total_macs = sum(u.macs for u in units)
    chk("total_macs_eq_344224000", total_macs == 344_224_000, "%d" % total_macs)

    # 4) 冻结流量两锚点（本工具用自己的译码复算；闸门另**调用**冻结工具复现）
    #    ★★ A2（2026-10-16，spec §5.0）后：真表**宽 run 已拆成 plain**（`y1_convert.py` 的 de-fuse）
    #    ⇒ **按-flag 译码**（下面 `fus_exact`）等于"逐层往返"（baseline 31,942,400）；
    #    冻结模型的两个锚点（baseline / fuse_both）仍由闸门**现跑冻结工具**复现（正对照 A 不动）。
    unf_exact = sum(u.in_exact + u.out_exact for u in units if u.is_conv)
    fus_exact = sum((u.in_exact if u.flags_name in ("head", "plain") else 0) +
                    (u.out_exact if u.flags_name in ("plain", "tail") else 0)
                    for u in units if u.is_conv)
    unf_table = sum(u.in_bytes + u.out_exact for u in units if u.is_conv)
    chk("decoded_unfused_eq_frozen_31942400", unf_exact == FROZEN_BASELINE_B, "%d" % unf_exact)
    chk("decoded_flags_eq_defused_frozen_31942400_A2", fus_exact == FROZEN_BASELINE_B,
        "%d（A2 拆融合后按-flag 译码 == 冻结 baseline；fuse_both=%d 由闸门现跑冻结工具复现）"
        % (fus_exact, FROZEN_FUSED_B))
    chk("decoded_table_eq_frozen_plus_32B", unf_table == FROZEN_BASELINE_B + ALIGN32_PAD_B,
        "%d (= 冻结 %d + %d)" % (unf_table, FROZEN_BASELINE_B, ALIGN32_PAD_B))

    # 5) 读放大模型的锚点标定（两个实测作业：模型 ≤ 实测 ≤ 模型×1.01）
    cal = []
    for name, (tensor, meas) in (("c64_40x40", MEAS_C64_40X40), ("dw64_40x40", MEAS_DW64_40X40)):
        if name == "c64_40x40":
            model = 64 * 4 * 34 * 34 * 8      # 64 趟 × 4 tile × 34×34 窗 × 8 ch/趟
        else:
            model = 8 * 4 * 34 * 34 * 8       # 对角 8 趟
        cal.append((name, model, meas, model <= meas <= model * 1.01))
    chk("read_amp_model_calibrated_on_measured", all(c[3] for c in cal),
        "; ".join("%s model=%d meas=%d" % (c[0], c[1], c[2]) for c in cal))
    chk("measured_amp_16x_23x", abs(MEAS_C64_40X40[1] / float(MEAS_C64_40X40[0]) - 23.27) < 0.1,
        "%.2fx" % (MEAS_C64_40X40[1] / float(MEAS_C64_40X40[0])))

    # 6) 逐单元理想拍 == MACs/64（dense 满块恒等；1×1/dw 只作对照，不参与本 CHECK）
    dense_ok = True
    for u in units:
        if u.is_conv and not u.is_dw and u.taps == 9 and \
           u.C_in % 8 == 0 and u.C_out % 8 == 0:
            dense_ok &= (u.issued_beats == u.macs // MAC_PER_BEAT)
    chk("dense_fullblock_issued_eq_ideal", dense_ok)
    # 1×1 与 dw 的"多花"倍率断言（spec §5-P0 明写要求建模）
    x1 = [u for u in units if u.wtype == "conv1x1" and u.C_in % 8 == 0 and u.C_out % 8 == 0]
    x1_ok = all(u.issued_beats == 9 * (u.macs // MAC_PER_BEAT) for u in x1)
    dw8 = [u for u in units if u.is_dw and u.C_in % 8 == 0]
    dw_ok = all(u.issued_beats == 8 * (u.macs // MAC_PER_BEAT) for u in dw8)
    chk("conv1x1_issues_9x_beats_of_ideal", x1_ok, "%d 个 1×1 满块单元" % len(x1))
    chk("depthwise_issues_8x_beats_of_ideal", dw_ok, "%d 个 dw 满块单元" % len(dw8))
    cc = ceilings(units)
    chk("issued_tiled_ge_issued", cc["issued_tiled_beats"] >= cc["issued_beats"],
        "tiled=%d ≥ issued=%d" % (cc["issued_tiled_beats"], cc["issued_beats"]))
    # 真表无"窄形状"（C_in==C_out==8 ∧ GROUP==1 ∧ 非 dw）⇒ 全部走宽路多趟（UnitExec isWide 恒真）
    narrow = [u for u in units if u.is_conv and u.C_in == 8 and u.C_out == 8 and
              u.GROUP == 1 and not u.is_dw]
    chk("no_narrow_shape_units_all_wide", len(narrow) == 0,
        "窄形状单元 %d 个 ⇒ 真表全部走宽路多趟" % len(narrow))

    # 6b) ★ P0b：类账自洽（三类并集 == 全部 conv 单元） + 反事实恒等式
    cs = class_split(units)
    n_cls = sum(cs[c]["n"] for c in CF_CLASSES)
    n_conv = sum(1 for u in units if u.is_conv)
    chk("class_split_covers_all_conv", n_cls == n_conv,
        "三类单元数 %d == conv 单元数 %d（类型 → 类 1:1）" % (n_cls, n_conv))
    chk("class_issued_split_sums_to_total", cs["_total"]["issued"] == cc["issued_beats"],
        "Σ类 issued=%d == 总 issued=%d" % (cs["_total"]["issued"], cc["issued_beats"]))
    chk("class_macs_split_sums_to_total", cs["_total"]["macs"] == cc["total_macs"],
        "Σ类 MACs=%d == 344,224,000" % cs["_total"]["macs"])
    chk("class_ideal_split_sums_to_total", abs(cs["_total"]["ideal"] - cc["ideal_beats"]) < 1e-6,
        "Σ类 ideal=%.1f == MACs/64=%.1f" % (cs["_total"]["ideal"], cc["ideal_beats"]))
    cf = counterfactuals(units)
    a_pred = cc["issued_beats"] - (SLICE_TAP_BEATS - CF_A_TAPS) * cs["1x1"]["passes_hw"]
    chk("cf_a_eq_predicted", abs(cf["A"] - a_pred) < 1e-6,
        "A=%d == issued − 8·Σ_1x1(passes·H·W)=%d（跳拍档：只留槽 0 那一拍）"
        % (cf["A"], a_pred))
    b_pred = cc["issued_beats"] - cs["dw"]["issued"] + cs["dw"]["ideal"]
    chk("cf_b_dw_eq_ideal", abs(cf["B"] - b_pred) < 1e-6,
        "B=%.1f == issued − dw_issued + dw_ideal（%d → %.1f 拍）"
        % (cf["B"], cs["dw"]["issued"], cs["dw"]["ideal"]))
    chk("cf_a_gt_ideal_and_lt_issued", cf["ideal"] < cf["A"] < cf["issued"],
        "ideal=%.1f < A=%.1f < issued=%.1f" % (cf["ideal"], cf["A"], cf["issued"]))
    # 6d) ★ 切片 A（NPU v2 §4.6-5）**落 RTL 后**的实计账：自下而上逐单元加总（与 CF A 两条独立路径）
    impl_a = impl_a_beats(units)
    chk("impl_a_eq_cf_a", abs(impl_a - cf["A"]) < 1e-6,
        "IMPL_A=%d == CF A=%.1f（逐单元加总 vs 自上而下减节省）" % (impl_a, cf["A"]))
    chk("impl_a_tag_p0b", impl_a == 13920400,
        "P0b 价签：切片 A 落 RTL ⇒ beats=%d（价签 13,920,400 ⇒ %.4f fps @50 MHz）"
        % (impl_a, NPU_CLK_HZ / float(impl_a)))
    chk("cf_ab_gt_ideal_lt_a", cf["ideal"] < cf["AB"] < cf["A"],
        "ideal=%.1f < A+B=%.1f < A=%.1f" % (cf["ideal"], cf["AB"], cf["A"]))
    # 反事实 A 的"槽 0 = 第一拍"前提：每个 1×1 单元的 issued 必须恰 9·passes·HW（无例外形状）
    x1_all = [u for u in units if u.wtype == "conv1x1"]
    chk("cf_a_assumption_all_1x1_walk_9", all(u.issued_beats == SLICE_TAP_BEATS * u.passes * u.H * u.W
                                              for u in x1_all),
        "%d 个 1×1 单元全部按 9 拍/像素/趟计" % len(x1_all))
    # 6c) ★ P0b：反事实 A 的 **blob 前提**（只读 gen/wgt_blob.bin；见 blob_slot0_check）
    try:
        md5_ok, slot0_ok, dw_slots_ok, bdetail = blob_slot0_check()
    except (IOError, OSError, KeyError, ValueError) as e:
        md5_ok = slot0_ok = dw_slots_ok = False
        bdetail = "blob 读不出：%r" % (e,)
    chk("blob_md5_eq_wgt_index_record", md5_ok, bdetail)
    chk("cf_a_1x1_nonzero_only_slot0", slot0_ok,
        "1×1 非零权重全部落在槽 0（= 拍序第 1 拍）⇒ 跳拍档数值不变、无需动布局")
    chk("cf_b_dw_scattered_slots_control", dw_slots_ok,
        "dw 权重散布 ≥2 槽（对照组：防布局被改成对 dw 也单槽）")

    # 7) 场景单调性（b ≤ a、c ≤ b、e ≤ d）——防表错
    scen = scenarios(units)
    chk("scenarios_monotone", scen["B"] <= scen["A"] and scen["C"] <= scen["B"] and
        scen["E"] <= scen["D"],
        "A=%.4f B=%.4f C=%.4f E=%.4f MB" % (scen["A"] / 1e6, scen["B"] / 1e6,
                                            scen["C"] / 1e6, scen["E"] / 1e6))

    if verbose:
        for ln in lines:
            print(ln)
    metrics = {"unfused_exact": unf_exact, "fused_exact": fus_exact,
               "unfused_table": unf_table, "total_macs": total_macs}
    return ok, lines, metrics


# ============================ 天花板 ============================
def ceilings(units):
    total_macs = sum(u.macs for u in units)
    ideal_beats = total_macs / float(MAC_PER_BEAT)
    issued_beats = sum(u.issued_beats for u in units)
    # 第三档：把 tile 的 halo 重喂也算上（切片对**每个被喂列**跑 9 拍，不只保留像素）
    issued_tiled_beats = 0
    for u in units:
        if not u.is_conv:
            continue
        cols = (u.n_tiles * u.win) if u.tiled else (u.stride * u.H * u.stride * u.W)
        issued_tiled_beats += SLICE_TAP_BEATS * u.passes * cols
    return {
        "total_macs": total_macs,
        "ideal_beats": ideal_beats,
        "issued_beats": issued_beats,
        "issued_tiled_beats": issued_tiled_beats,
        "t_ideal_s": ideal_beats / NPU_CLK_HZ,
        "t_issued_s": issued_beats / NPU_CLK_HZ,
        "t_issued_tiled_s": issued_tiled_beats / NPU_CLK_HZ,
        "fps_ideal": NPU_CLK_HZ / ideal_beats,
        "fps_issued": NPU_CLK_HZ / issued_beats,
        "fps_issued_tiled": NPU_CLK_HZ / issued_tiled_beats,
        "wall_issued_s": issued_beats * (SLICE_CYC_PER_PIX / float(SLICE_TAP_BEATS)) / NPU_CLK_HZ,
    }


# ============================ ★ P0b：按类归因 + 反事实 ============================
def class_of(u):
    """单元类 = desc TYPE 的 1:1 映射；非 conv 单元返回 None（不进类账）。"""
    return CLASS_BY_TYPE.get(u.wtype)


def parse_tap_override(spec):
    """`--perturb-taps CLASS:TAPS`（可逗号分隔多项）：把某类的抽头拍数换成 TAPS（闸门负对照用）。

    语义（本工具明写）：issued(类) = TAPS · Σ_{类}(passes·H·W)。**只改内存里的模型**，绝不回写
    `gen/`（与 `--perturb` 同一条纪律）。BASELINE（不注入）时三类都用 `SLICE_TAP_BEATS=9`。
    """
    if not spec:
        return {}
    out = {}
    for part in spec.split(","):
        cls, taps = part.split(":")
        cls = cls.strip()
        if cls not in CF_CLASSES:
            raise SystemExit("ENV_ERROR --perturb-taps 类名 %r 不在 %s" % (cls, CF_CLASSES))
        out[cls] = int(taps)
    return out


def class_split(units, tap_override=None):
    """把 issued 拍与有用 MACs 按类拆开（P0b §1）。

    - `macs`  = Σ 有用 MAC（口径与 P0 全表同式：H·W·C_out·(C_in/GROUP)·taps）。
    - `ideal` = macs / 64（spec 指定式，可能带 .5 ⇒ 用 float；总和对 64 整除）。
    - `issued`= Σ taps_eff · passes · H·W，`taps_eff` 默认 9；`tap_override` 可把某类换掉
      （负对照：类的抽头数被改 ⇒ 该类的 issued 归属必须按预测量移动）。
    - `waste` = issued / ideal（"多花倍率"；>1 = 浪费）。
    - `top`   = 该类按**绝对 issued 拍**排序的前 3 个单元（谁贵看绝对值，不看倍率）。
    """
    tap_override = tap_override or {}
    acc = {c: {"n": 0, "macs": 0, "ideal": 0.0, "issued": 0, "passes_hw": 0,
               "units": []} for c in CF_CLASSES}
    for u in units:
        c = class_of(u)
        if c is None:
            continue
        taps_eff = tap_override.get(c, SLICE_TAP_BEATS)
        issued = taps_eff * u.passes * u.H * u.W
        a = acc[c]
        a["n"] += 1
        a["macs"] += u.macs
        a["ideal"] += u.macs / float(MAC_PER_BEAT)
        a["issued"] += issued
        a["passes_hw"] += u.passes * u.H * u.W      # = issued /9（基准口径的"趟×像素"）
        a["units"].append({"u": u, "issued": issued, "taps_eff": taps_eff})
    for c in CF_CLASSES:
        a = acc[c]
        a["waste"] = (a["issued"] / a["ideal"]) if a["ideal"] else 0.0
        a["top"] = sorted(a["units"], key=lambda x: -x["issued"])[:3]
        del a["units"]
    acc["_total"] = {
        "n": sum(acc[c]["n"] for c in CF_CLASSES),
        "macs": sum(acc[c]["macs"] for c in CF_CLASSES),
        "ideal": sum(acc[c]["ideal"] for c in CF_CLASSES),
        "issued": sum(acc[c]["issued"] for c in CF_CLASSES),
        "passes_hw": sum(acc[c]["passes_hw"] for c in CF_CLASSES),
    }
    return acc


def impl_a_beats(units, a_taps=CF_A_TAPS):
    """★ 切片 A **落 RTL 之后**的 issued 拍（**自下而上**的实计口径，不是"从总数减掉节省"）。

    与 `counterfactuals()["A"]` 是**两条独立路径**：那边 = `Σ全部 − 8·Σ_1x1(passes·H·W)`（自上而下），
    这边 = `Σ_单元 taps_eff(类)·passes·H·W`（逐单元加总，1×1 类用 `a_taps`）——两者必须**逐位相等**
    （CHECK `impl_a_eq_cf_a`；闸门 `run_mac_account_ab.sh` 再按 UNIT 行第三条路径复算）。

    口径（与 RTL 逐条对齐；见 `rtl/Conv3x3Slice.scala` 文件尾「slice A」+ `tools/run_x1skip_ab.sh`）：
      · 1×1（`desc TYPE=0x02`）⇒ 1 拍/像素/趟（`X1SKIP` 的 `ph:=10` 跳拍，**实测 9.00×**）；
      · 其余 conv 类 ⇒ 仍 9 拍/像素/趟（3×3 与 dw 的相位一字未动）；
      · 非 conv 单元不进本账（与 P0/P0b 同口径）。
    """
    beats = 0
    for u in units:
        if not u.is_conv:
            continue
        taps = a_taps if class_of(u) == "1x1" else SLICE_TAP_BEATS
        beats += taps * u.passes * u.H * u.W
    return beats


def counterfactuals(units, a_taps=CF_A_TAPS, tap_override=None):
    """反事实 A / B / A+B 的拍数与 fps（P0b §2-§4；口径见文件头 P0b 一节）。

      A  = 1×1 类：9 拍/像素/趟 → `a_taps` 拍（基准：1 拍 = 只留槽 0 那一拍；见文件头）。
      B  = dw 类：issued → ideal（= MACs/64，"用满阵列"的上界口径，modeled；见文件头警示）。
      A+B = 两者同时。
    返回拍数（float，B 可带 .5）+ 相对 issued 的净删拍数。**不含** tile halo 重喂（与 P0 同口径）。
    """
    cs = class_split(units, tap_override=tap_override)
    tot = cs["_total"]["issued"]
    x1 = cs["1x1"]
    dw = cs["dw"]
    # 基准（可能已被 --perturb-taps 改过）下 1×1 类每"趟×像素"的拍数：
    x1_taps_base = tap_override.get("1x1", SLICE_TAP_BEATS) if tap_override else SLICE_TAP_BEATS
    a_beats = float(tot - (x1_taps_base - a_taps) * x1["passes_hw"])
    b_beats = float(tot - dw["issued"] + dw["ideal"])
    ab_beats = float(a_beats - dw["issued"] + dw["ideal"])
    ideal = cs["_total"]["ideal"]
    return {
        "taps_base": x1_taps_base,
        "a_taps": a_taps,
        "issued": float(tot),
        "A": a_beats, "B": b_beats, "AB": ab_beats, "ideal": ideal,
        "A_removed": float(tot) - a_beats,
        "B_removed": float(dw["issued"]) - dw["ideal"],
        "AB_removed": float(tot) - ab_beats,
        "cs": cs,
    }


def clock_sensitivity(cf):
    """时钟敏感表（**敏感度，不是测量**）：每档 `fps = clk ÷ beats`，对 4 条曲线（issued/A/B/AB）+ ideal。"""
    rows = []
    for mhz in CLK_SENS_MHZ:
        hz = mhz * 1e6
        rows.append({
            "mhz": mhz,
            "issued": hz / cf["issued"],
            "A": hz / cf["A"],
            "B": hz / cf["B"],
            "AB": hz / cf["AB"],
            "ideal": hz / cf["ideal"],
        })
    return rows


# ============================ 流量场景 (a)-(e) ============================
def scenarios(units):
    """五档逐帧流量（口径见文件头 + 报告 §场景）：

       base0 = 冻结 fuse_both 12,576,000（conv 激活，只算一次的中/尾链内张量）
             + 冻结 bypass_traffic 6,945,600（旁路算子自身激活 IO）      = 19,521,600
       (a) v1 as-is      = base0 + Σ_DDR读conv (reads_a - in_exact) + Add 实测放大增量
       (b) +窗口片上留住 = base0 + Σ      (reads_b - in_exact) + 同上   （杀 nCo 重读）
       (c) +平面 32B 补齐= base0 + Σ      (reads_c - in_exact) + 同上   （杀 band/对齐余量）
       (d) +NC8HW 分块布局= (c) 字节不变（请求数 ÷4 —— 单独报，见 report）
       (e) +Add 单趟化   = (d) - Add 放大增量归零（4.4× → 2.0×）
      同口径的"add 增量"= (4.4-2.0)×(102,400+409,600) = 1,228,800 B（Add_44 实测因子 + Add_50 按张量缩放）
    """
    base0 = FROZEN_FUSED_B + FROZEN_BYPASS_B
    add_meas = ADD_MEAS_RD + int(round(ADD_MEAS_RD * ADD_SRC2_TENSOR / float(ADD_MEAS_TENSOR)))
    add_ideal = 2 * (ADD_MEAS_TENSOR + ADD_SRC2_TENSOR)
    add_delta = add_meas - add_ideal

    ddr_units = [u for u in units if u.is_conv and u.flags_name in ("head", "plain")]

    def conv_delta(reader):
        tot = 0
        for u in ddr_units:
            r = reader(u)
            tot += r - u.in_exact
        return tot

    a_delta = conv_delta(Unit.reads_a)
    b_delta = conv_delta(Unit.reads_b)
    c_delta = conv_delta(Unit.reads_c)

    A = base0 + a_delta + add_delta
    B = base0 + b_delta + add_delta
    C = base0 + c_delta + add_delta
    D = C
    E = D - add_delta
    return {"BASE0": base0, "ADD_DELTA": add_delta,
            "CONV_DELTA_A": a_delta, "CONV_DELTA_B": b_delta, "CONV_DELTA_C": c_delta,
            "A": A, "B": B, "C": C, "D": D, "E": E}


def burst_stats(units):
    """逐帧请求/突发数（32 B 粒度，与冻结口径一致；d 档请求 ÷4 是设计声明，标注 modeled）。"""
    s = scenarios(units)
    out = {}
    for k in "ABCDE":
        out[k] = (s[k] + 31) // 32
    out["D_requests"] = cdiv(out["C"], 4)
    return out


# ============================ 打印 ============================
def print_table(units, out=sys.stdout):
    _p(out, "== 逐单元 MAC 表（67 项；几何 = wgt_index own；taps 由 TYPE 派生）==")
    hdr = ("idx  %-9s %-9s %-6s %4s %4s %5s %4s %4s %5s %13s %13s"
           % ("name", "type", "flags", "C_in", "C_out", "GROUP", "H", "W", "taps", "MACs", "cum"))
    _p(out, hdr)
    _p(out, "-" * len(hdr))
    cum = 0
    for u in units:
        if u.is_conv:
            cum += u.macs
            _p(out, "%3d  %-9s %-9s %-6s %4d %4d %5d %4d %4d %5d %13d %13d"
                  % (u.desc.idx, u.name, u.wtype, u.flags_name, u.C_in, u.C_out, u.GROUP,
                     u.H, u.W, u.taps, u.macs, cum))
        else:
            _p(out, "%3d  %-9s %-9s %-6s %4d %4d %5d %4d %4d %5s %13s %13s"
                  % (u.desc.idx, u.name, u.wtype, u.flags_name, u.C_in, u.C_out, u.GROUP,
                     u.H, u.W, "-", "(non-MAC)", "(non-MAC)"))
    _p(out, "-" * len(hdr))
    _p(out, "MAC_TOTAL=%d（%d 个 conv/dw 单元；非 MAC 算子不计入）" % (cum, sum(1 for u in units if u.is_conv)))

    _p(out, )
    _p(out, "== 非 MAC 算子（跳过/旁路；元素数单列，不并入 MAC）==")
    _p(out, "%-4s %-9s %-9s %10s %12s %12s" % ("idx", "name", "type", "elements", "in_bytes", "per_elem"))
    for u in units:
        if u.is_conv:
            continue
        _p(out, "%-4d %-9s %-9s %10d %12d %12s"
              % (u.desc.idx, u.name, u.wtype, u.out_exact, u.in_bytes,
                 "2-src" if u.wtype == "add" else ("max(4)" if u.wtype == "maxpool" else "-")))
    nn = [u for u in units if not u.is_conv]
    _p(out, "NONMAC_ELEMS_TOTAL=%d（maxpool %d / resize %d / add %d / sigmoid %d）"
          % (sum(u.out_exact for u in nn),
             sum(u.out_exact for u in nn if u.wtype == "maxpool"),
             sum(u.out_exact for u in nn if u.wtype == "resize"),
             sum(u.out_exact for u in nn if u.wtype == "add"),
             sum(u.out_exact for u in nn if u.wtype == "sigmoid")))


def print_ceilings(units, out=sys.stdout):
    c = ceilings(units)
    _p(out, )
    _p(out, "== 算力天花板（64 MAC/拍 @50 MHz）==")
    _p(out, "常量出处：MAC_PER_BEAT=64 读 RTL（MacArray.scala 8×8）；NPU_CLK=50 MHz 读报告（npu_clock.md）；")
    _p(out, "          SLICE_TAP_BEATS=9 读 RTL（Conv3x3Slice.ph=1..9，每像素恒 9 拍）；")
    _p(out, "          nPasses=nCi·nCo / nCo(dw) 读 RTL（UnitExec 宽路趟编排）。")
    _p(out, "TOTAL_MACS=%d" % c["total_macs"])
    _p(out, "BEATS_IDEAL=%d（= 总 MACs ÷ 64，spec 指定式）" % c["ideal_beats"])
    _p(out, "T_COMPUTE_IDEAL_S=%.4f  FPS_COMPUTE_IDEAL=%.2f" % (c["t_ideal_s"], c["fps_ideal"]))
    _p(out, "BEATS_ISSUED=%d（eff/多趟路径：9 拍/像素/趟 × nPasses × 像素）" % c["issued_beats"])
    _p(out, "T_COMPUTE_ISSUED_S=%.4f  FPS_COMPUTE_ISSUED=%.2f" % (c["t_issued_s"], c["fps_issued"]))
    _p(out, "BEATS_ISSUED_TILED=%d（再含 tile halo 重喂：9 拍/被喂列/趟）" % c["issued_tiled_beats"])
    _p(out, "T_COMPUTE_ISSUED_TILED_S=%.4f  FPS_COMPUTE_ISSUED_TILED=%.2f"
          % (c["t_issued_tiled_s"], c["fps_issued_tiled"]))
    _p(out, "注记：单切片每像素墙钟 = 11 拍（1 收列 + 9 tap + 1 出数）⇒ 单阵列墙钟上界 %.3f s/帧"
          % c["wall_issued_s"])


def emit_class_lines(cs, out=sys.stdout):
    """机器可读的类账行（闸门按 UNIT 行独立复算后比对；ideal 用 milli-beats 保整数）。"""
    for c in CF_CLASSES:
        _p(out, "CLASS %s n=%d macs=%d ideal_milli=%d issued=%d"
           % (c, cs[c]["n"], cs[c]["macs"], int(round(cs[c]["ideal"] * 1000)), cs[c]["issued"]))


def emit_cf_lines(cf, out=sys.stdout):
    """机器可读的反事实行（A 恒整数；B/AB 可带 .5 ⇒ 打印 %.1f）。"""
    _p(out, "CF A_BEATS=%d B_BEATS=%.1f AB_BEATS=%.1f A_TAPS=%d ISSUED_BEATS=%d"
       % (cf["A"], cf["B"], cf["AB"], cf["a_taps"], cf["issued"]))


def print_classes(units, tap_override=None, out=sys.stdout):
    """P0b §1：按类归因（issued 拍 / 有用 MACs / 多花倍率 / 占比 / 类内前 3 贵）。"""
    tap_override = tap_override or {}
    cs = class_split(units, tap_override=tap_override)
    tot_iss = cs["_total"]["issued"]
    _p(out, )
    _p(out, "== ★ P0b 类账：issued 拍 × 有用 MACs × 多花倍率（类 = desc TYPE 1:1）==")
    if tap_override:
        _p(out, "注：--perturb-taps 已生效 %s ⇒ 相应类的 issued 按注入口径计（负对照）" % tap_override)
    _p(out, "%-8s %3s %14s %13s %13s %8s %9s %s"
       % ("class", "n", "useful MACs", "ideal(拍)", "issued(拍)", "浪费×", "issued占比", "类内前 3 贵（issued 拍）"))
    for c in CF_CLASSES:
        a = cs[c]
        tops = "  ".join("%s=%d" % (t["u"].name, t["issued"]) for t in a["top"])
        _p(out, "%-8s %3d %14d %13.0f %13d %7.2f× %8.1f%%  %s"
           % (c, a["n"], a["macs"], a["ideal"], a["issued"], a["waste"],
              100.0 * a["issued"] / tot_iss, tops))
    a = cs["_total"]
    _p(out, "%-8s %3d %14d %13.0f %13d %7.2f× %8.1f%%"
       % ("TOTAL", a["n"], a["macs"], a["ideal"], a["issued"], a["issued"] / a["ideal"], 100.0))
    _p(out, "机器可读（闸门按 UNIT 行独立复算后比对）：")
    emit_class_lines(cs, out=out)

    # 按绝对 issued 拍的全局前 12 贵（类内占比就是"谁交的钱多"）
    _p(out, )
    _p(out, "== 绝对 issued 拍 Top-12（谁是最大的一笔浪费；倍率与绝对值分开看）==")
    flat = [(class_of(u), u, tap_override.get(class_of(u), SLICE_TAP_BEATS) * u.passes * u.H * u.W)
            for u in units if u.is_conv]
    _p(out, "%-4s %-10s %-9s %4s %4s %4s %4s %9s %9s %13s %6s %6s"
       % ("idx", "name", "type", "C_in", "C_out", "H", "W", "passes", "taps_eff", "issued", "浪费×", "占比"))
    for c, u, iss in sorted(flat, key=lambda x: -x[2])[:12]:
        _p(out, "%-4d %-10s %-9s %4d %4d %4d %4d %9d %9d %13d %5.2f× %5.1f%%"
           % (u.desc.idx, u.name, u.wtype, u.C_in, u.C_out, u.H, u.W, u.passes,
              tap_override.get(c, SLICE_TAP_BEATS), iss, iss / (u.macs / float(MAC_PER_BEAT)),
              100.0 * iss / tot_iss))


def print_counterfactuals(units, tap_override=None, out=sys.stdout):
    """P0b §2-§5：反事实 A / B / A+B + 时钟敏感表。"""
    cf = counterfactuals(units, a_taps=CF_A_TAPS, tap_override=tap_override)
    _p(out, )
    _p(out, "== ★ P0b 反事实（拍数与 fps；同 issued 口径：不含 tile halo，@npu_clk 计）==")
    _p(out, "A = 1×1 类的抽头拍数 9 → %d（跳拍档：只留权重所在的那一拍，槽 0；数值逐字节不变）" % cf["a_taps"])
    _p(out, "B = dw 类 issued → ideal（MACs/64，\"用满阵列\"；★ modeled 上界，需数据通路改动，见文件头警示）")
    _p(out, "%-22s %14s %10s %10s %10s" % ("口径", "beats", "s/frame", "fps@50MHz", "vs issued"))
    rows = [("as-built 9拍/像素/趟", cf["issued"], "—"),
            ("A（1×1 只发 %d 拍）" % cf["a_taps"], cf["A"], "−%d" % cf["A_removed"]),
            ("B（dw 用满阵列）", cf["B"], "−%.0f" % cf["B_removed"]),
            ("A+B", cf["AB"], "−%.0f" % cf["AB_removed"]),
            ("理想（MACs/64）", cf["ideal"], "−%.0f" % (cf["issued"] - cf["ideal"]))]
    for lab, beats, vs in rows:
        fps = NPU_CLK_HZ / beats
        _p(out, "%-22s %14.1f %10.4f %10.4f %10s" % (lab, beats, 1.0 / fps, fps, vs))
    # ★ 切片 A 落 RTL 之后的**实测口径**（自下而上逐单元加总；与上行 "A" 是同一条账的两条独立路径）
    ia = impl_a_beats(units)
    _p(out, "%-22s %14d %10.4f %10.4f %10s"
       % ("A 已落 RTL（实计）", ia, 1.0 / (NPU_CLK_HZ / float(ia)), NPU_CLK_HZ / float(ia),
          "−%d" % (cf["issued"] - ia)))
    _p(out, "IMPL_A fps@50MHz=%.4f（自下而上 Σ taps_eff·passes·HW；与 CF A 逐位相等是 CHECK impl_a_eq_cf_a）"
       % (NPU_CLK_HZ / float(ia)))
    _p(out, "A+B 后残差 = %.4f× ideal（类内取整：Conv_0 的 8/3、C=1 尾块的 64×、C=10 尾块 …）"
       % (cf["AB"] / cf["ideal"]))
    emit_cf_lines(cf, out=out)

    _p(out, )
    _p(out, "== ★ P0b 时钟敏感表（**敏感度，不是测量**：fps = clk ÷ beats；PnR 实测可闭合 %.3f MHz）=="
       % CLK_PNR_ACHIEVED_MHZ)
    _p(out, "%-8s %10s %10s %10s %10s %10s" % ("clk", "as-built", "A", "B", "A+B", "理想"))
    for r in clock_sensitivity(cf):
        _p(out, "%-8s %10.2f %10.2f %10.2f %10.2f %10.2f"
           % ("%d MHz" % r["mhz"], r["issued"], r["A"], r["B"], r["AB"], r["ideal"]))
        _p(out, "FPS_CLK clk_mhz=%d issued=%.4f A=%.4f B=%.4f AB=%.4f ideal=%.4f"
           % (r["mhz"], r["issued"], r["A"], r["B"], r["AB"], r["ideal"]))
    hz = CLK_PNR_ACHIEVED_MHZ * 1e6
    _p(out, "注：PnR 实测 %.3f MHz 档 ⇒ as-built %.2f / A+B %.2f / 理想 %.2f fps（同样只是敏感度外推）。"
       % (CLK_PNR_ACHIEVED_MHZ, hz / cf["issued"], hz / cf["AB"], hz / cf["ideal"]))



def print_scenarios(units, out=sys.stdout):
    s = scenarios(units)
    b = burst_stats(units)
    _p(out, )
    _p(out, "== 逐帧流量场景（带宽侧；基 = 冻结 fuse_both 12.576 MB + 冻结 bypass 6.9456 MB）==")
    _p(out, "注：MB = 1e6 B（与 275.9 MB/s 同口径）；bursts = 32 B 粒度请求数（measured/modeled 见报告）。")
    labels = [("A", "(a) v1 as-is（宽路 tile 实测放大 + Add 4.4×）"),
              ("B", "(b) +窗口片上留住（杀 nCo 重读）"),
              ("C", "(c) +平面 32B 补齐（杀 band/对齐余量）"),
              ("D", "(d) +NC8HW 分块布局（字节同 c；请求 ÷4）"),
              ("E", "(e) +Add 单趟化（4.4×→2.0×）")]
    _p(out, "%-52s %14s %9s %8s %12s" % ("scenario", "bytes", "MB/frame", "ms", "fps@275.9"))
    for k, lab in labels:
        by = s[k]
        mb = by / 1e6
        ms = by / DDR_BYTES_PER_S * 1e3
        fps = DDR_BYTES_PER_S / float(by)
        _p(out, "%-52s %14d %9.4f %8.1f %12.2f" % (lab, by, mb, ms, fps))
    _p(out, "SCEN_BASE0=%d  CONV_DELTA_A=%d  CONV_DELTA_B=%d  CONV_DELTA_C=%d  ADD_DELTA=%d"
          % (s["BASE0"], s["CONV_DELTA_A"], s["CONV_DELTA_B"], s["CONV_DELTA_C"], s["ADD_DELTA"]))
    _p(out, "BURSTS32 A=%d B=%d C=%d D=%d E=%d  D_REQUESTS=C/4=%d"
          % (b["A"], b["B"], b["C"], b["D"], b["E"], b["D_requests"]))
    # 信息性（modeled，未计入上面任何一档）：宽路趟瓦片装载 = 每趟 576 B 经 DDR 段读
    wgt_pass = sum(576 * u.passes for u in units if u.is_conv)
    _p(out, "WGT_PASSLOAD_BYTES=%d（modeled：Σ nPasses×576 B；冻结模型不计权重装载）" % wgt_pass)


def emit_unit_lines(units):
    """机器可读的逐单元行（闸门用 bash 独立算预测增量）。"""
    for u in units:
        print("UNIT %d %s %s %s %d %d %d %d %d %d %d %d %d"
              % (u.desc.idx, u.name, u.wtype, u.flags_name, u.C_in, u.C_out, u.GROUP,
                 u.H, u.W, u.taps, u.macs, u.passes, u.issued_beats))


# ============================ main ============================
def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--scenarios", action="store_true")
    ap.add_argument("--perturb", default=None, help="IDX:FIELD:DELTA，如 20:C_OUT:8")
    ap.add_argument("--perturb-taps", default=None,
                    help="CLASS:TAPS（可逗号分隔），把某类的抽头拍数换掉（负对照），如 dw:3")
    ap.add_argument("--emit-table", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv[1:])

    for p in (DESC_BIN, WGT_INDEX, BLOB_BIN):
        if not os.path.exists(p):
            print("ENV_ERROR missing %s" % p)
            return 3
    try:
        perturb = parse_perturb(args.perturb)
        tap_override = parse_tap_override(args.perturb_taps)
        if args.selftest and tap_override:
            print("ENV_ERROR --selftest 与 --perturb-taps 互斥（自检是基准口径）")
            return 3
        units, payload, wus, raw = build_units(perturb)
    except SystemExit as e:
        print("ENV_ERROR %s" % e)
        return 3

    if args.selftest:
        ok, _, metrics = checks(units, payload, wus)
        emit_unit_lines(units)
        print("TOTAL_MACS=%d" % sum(u.macs for u in units))
        print("DECODED_UNFUSED_EXACT=%d" % metrics["unfused_exact"])
        print("DECODED_FUSED_EXACT=%d" % metrics["fused_exact"])
        print("DECODED_UNFUSED_TABLE=%d" % metrics["unfused_table"])
        c = ceilings(units)
        print("FPS_COMPUTE_IDEAL=%.4f FPS_COMPUTE_ISSUED=%.4f FPS_COMPUTE_ISSUED_TILED=%.4f"
              % (c["fps_ideal"], c["fps_issued"], c["fps_issued_tiled"]))
        # ★ 切片 A（NPU v2 §4.6-5）：**落 RTL 后**的 issued 账与 fps（自下而上；等价性由 CHECK 钉住）
        ia = impl_a_beats(units)
        print("IMPL_A_BEATS=%d FPS_COMPUTE_IMPL_A=%.4f IMPL_A_REMOVED=%d"
              % (ia, NPU_CLK_HZ / float(ia), c["issued_beats"] - ia))
        # ★ P0b：类账 + 反事实的机器可读行（闸门按 UNIT 行独立复算后比对）
        emit_class_lines(class_split(units))
        emit_cf_lines(counterfactuals(units))
        sc = scenarios(units)
        print("SCEN_A_BYTES=%d SCEN_B_BYTES=%d SCEN_C_BYTES=%d SCEN_D_BYTES=%d SCEN_E_BYTES=%d"
              % (sc["A"], sc["B"], sc["C"], sc["D"], sc["E"]))
        print("SELFTEST %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1

    if args.perturb or tap_override:
        emit_unit_lines(units)
        print("TOTAL_MACS=%d" % sum(u.macs for u in units))
        emit_class_lines(class_split(units, tap_override=tap_override))
        emit_cf_lines(counterfactuals(units, tap_override=tap_override))
        return 0

    if not args.quiet:
        print_table(units)
        print_ceilings(units)
        print_classes(units)
        print_counterfactuals(units)
    if args.scenarios or not args.quiet:
        print_scenarios(units)
    if args.emit_table:
        with io.open(args.emit_table, "w", encoding="utf-8", newline="\n") as f:
            print_table(units, out=f)
            print_ceilings(units, out=f)
            print_classes(units, out=f)
            print_counterfactuals(units, out=f)
            print_scenarios(units, out=f)
        print("EMIT_TABLE=%s" % args.emit_table)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
