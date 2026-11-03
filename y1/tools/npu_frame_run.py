#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""npu_frame_run.py -- **宿主侧整帧驱动**（C4b-B5 Step 1）+ 离线规划 + 同口径 int8 12 路张量。

============================ 三种模式 ============================
| 模式 | 命令 | 碰板？ | 用途 |
|:--|:--|:--|:--|
| **规划** | `--dry [--img X \| --no-face]` | **不碰** | 建 DDR 映像 + 程序序列 + 回读计划；CI/无硬件可跑 |
| **同口径** | `--int8-tensors --img X --npz out.npz` | 不碰 | 跑 `quant_ref`（冻结黄金）→ 12 路**规范**张量（反量化后）落 .npz |
| **上板** | `--run --port COM7 [--img X]` | **碰板** | 按规划真跑：灌 DDR → 编程 → start → 等 done/IRQ → 读 12 路 → 反折叠 → 后处理 |

============================ 板上口径（逐条来自已冻结的实测/契约）============================
* **寄存器窗** `0xF000_C000`；偏移见下（= `rtl/HostRegs.scala` 的地址表，一字不改）：
    `CTRL=0x00`(bit0 start / bit1 soft_reset) · `STATUS=0x04`(bit0 done_sticky w1c / bit1 err) ·
    `ID=0x30`(常数 `0x594E5031`) · `DESC_ADDR=0x34` · `DESC_COUNT=0x38` ·
    `WGT_SEL=0x3C` · `WGT_ADDR=0x40` · `WGT_DATA=0x44` · `WGT_WE=0x48`
* **地址口径**（C3 实测冻结；★ H2/H2b 后修订）：NPU 28bit 地址 `A` ↔ DDR 物理 `0x8000_0000 + A`；
  ★ H2 把 NPU arena `[0x8040_0000, 0x8200_0000)` 标成 reserved-memory/no-map 从内核 RAM 切走，
  H2b 把内核 Image/FDT/initrd 抬到 `0x8200_0000` 之上 ⇒ **内核实际可用 RAM = 物理
  `0x8200_0000-0x8FFF_FFFF`** ⇒ **NPU 侧 [0x0200_0000, 0x1000_0000) 才是内核区**；
  实测安全区 = 物理 `0x8000_0000-0x803F_FFFF`（NPU `0x0000_0000-0x003F_FFFF`，仅 4 MB，
  兼作主机写入区：input/desc/blob）。
* **描述符表**：`gen/desc.bin`（2176 B = 68×32 B，末项哨兵），**字面**用 `desc_table.unpack` 解；
  建议落点 `DESC_TABLE_ADDR = 0x0010_0000`（= `desc_table.DESC_TABLE_ADDR_SUGGEST`）。
* **起跑/收工**：先 `CTRL.soft_reset`(=0x2) 清陈旧 `errSticky`；写 `DESC_ADDR`/`DESC_COUNT`；
  `CTRL.start`(=0x1)；**轮询** `STATUS`（bit0 done / bit1 err）。done/err 是**电平保持**的粘滞位，
  由 `STATUS` 写 1（done）/ `CTRL.soft_reset`（err）清。
* **串口纪律**（C3 上板血泪）：① **逐字符慢发**（10 ms/字符）；② 板端长循环要**等它的完成标记**
  （`B=<tok>; echo "X${B}X"` —— 回显里是字面 `X${B}X`，只有真输出才是 `X<tok>X`，不会被回显骗）；
  ③ **绝不**把长命令行塞进 tty（R5：大 blob 走网络/分段）。

============================ 12 路输出住在哪（本文件的**核心推导**）============================
网表尾部 12 个 graph 输出 = 6 个 Sigmoid（cls/obj）+ 6 个 **折进寻址**的 Reshape（bbox/kps，无描述符）。
本文件**不改转换器**，只**读**冻结产物：
  · `gen/desc.bin`（`desc_table.unpack`）→ 每个单元的 `DST_ADDR` / 几何；
  · `gen/wgt_index.json` 的 `units`（`out_tensor` ↔ 表序）与 `layout_fold`（`src_stride`/`view_shape`）；
  · ONNX 图（12 个输出各自的产物链：Sigmoid 或 Reshape←Transpose←Conv）。
⇒ 每个输出的 **(desc 下标, DDR 地址, 字节数, 规范形状, 折叠读步长)** 全部**从冻结产物导出**，不手抄。

★ **两条 C4a 遗留（O3 同族）—— 本文件显式报出、留给 B6：**
  1) **Sigmoid 的 `SRC_ADDR` 折进（★ H1 已修，2026-10-12）**：旧 `desc.bin` 里 6 个 Sigmoid 的
     `SRC_ADDR` 指到"折叠视图"张量（291/303/315/327/339/351），而那些槽位**没有任何单元写过**
     （写它的是生产者 258/260/262/270/272/274 的 `DST_ADDR`）。B5 曾用 `--fold-src` 在**内存里**
     改写这 6 条；**H1 把折进做进了转换器**（`y1_convert.py` 的 `apply_src_addr_fold`：把**所有**
     被折进源——6 个 Sigmoid + 28 个 Relu 尾声消费者——的 `SRC_ADDR` 改到"生产者真正写过的 DST"）
     ⇒ 现在 `desc.bin` 已自洽，`--fold-src` 的工作量**恒为 0**。`fold_src_rewrite` 从"改写器"变成
     **复发哨兵**：若哪天表又被回退成旧口径，它**响亮失败**（不静默改写）。
  2) **冻结 arena 与内核 RAM 的重叠（★ 已由 H2/H2b 裁决）**：arena = NPU `0x0020_0000-0x01C5_05C0`
     （≈29.7 MB，来自 `desc_table.build_table` 的 bump 分配）⇒ 物理 `0x8020_0000-0x81C5_05C0`。
     H2 把 `[0x8040_0000, 0x8200_0000)` 标成 reserved-memory/no-map 从内核 RAM 切走、H2b 把内核
     Image/FDT/initrd 抬到 `0x8200_0000` 之上 ⇒ arena 现在**整个落在 NPU 专用的保留区里**，不再是
     内核 RAM。`--dry` 的 `ARENA_OVERLAP_KERNEL_RAM` 判据因此**不再发火**（kernel RAM 下界已
     随 DTS 上移到物理 `0x8200_0000`，见下面的 `KERNEL_RAM_NPU_LO`）。

退出码：0 = 规划/落盘成功且**无红旗**；1 = 清场失败（如 `--strict` 下发现红旗）；3 = 前置缺失。
"""
import argparse
import hashlib
import json
import os
import struct
import sys

import numpy as np

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import yunet_post as YP   # noqa: E402  （后处理口径只此一份）
import y1_caliber as YCAL  # noqa: E402  ★ S4-B：Sigmoid 冻结 LUT 口径（D4；与转换器同一份）

_H1 = os.path.abspath(os.path.join(_HERE, ".."))
_H0 = os.path.abspath(os.path.join(_H1, ".."))

ONNX = os.path.join(_H0, "third_party", "yunet", "yunet.onnx")
DESC_BIN = os.path.join(_H1, "gen", "desc.bin")
WGT_INDEX = os.path.join(_H1, "gen", "wgt_index.json")
WGT_BLOB = os.path.join(_H1, "gen", "wgt_blob.bin")
WGT_MULT = os.path.join(_H1, "gen", "wgt_mult.bin")

# ---- 寄存器（HostRegs.scala 的地址表）----
REG_BASE = 0xF000C000
R_CTRL, R_STATUS, R_ID = 0x00, 0x04, 0x30
R_DESC_ADDR, R_DESC_COUNT = 0x34, 0x38
R_WGT_SEL, R_WGT_ADDR, R_WGT_DATA, R_WGT_WE = 0x3C, 0x40, 0x44, 0x48
# ★ S4-B：反量化缓存的口径版本（改了 Sigmoid 固定点/标定域 ⇒ 必须换这个串，缓存自动失效）
DEQ_CALIBER = "S4B-sigQ3.4-calreal"
CTRL_START, CTRL_SOFT_RESET = 0x1, 0x2
ID_CONST = 0x594E5031

# ---- DDR 口径 ----
DDR_PHYS_BASE = 0x80000000
SAFE_LO, SAFE_HI = 0x80000000, 0x803FFFFF          # 实测安全区（4 MB）
KERNEL_RAM_NPU_LO, KERNEL_RAM_NPU_HI = 0x02000000, 0x10000000   # 物理 0x8200_0000-0x8FFF_FFFF
# ★ H2/H2b（2026-10-12）：内核 RAM 的下界由物理 0x8040_0000 上移到 0x8200_0000 —— DTS 把
#   [0x8040_0000, 0x8200_0000) 标成 reserved-memory/no-map（H2）并从内核 RAM 切走，内核的
#   Image/FDT/initrd 也一并抬到 0x8200_0000 之上（H2b）⇒ 内核实际可用 RAM 只从物理 0x8200_0000
#   起。本常量必须与 DTS/装载链同步，否则 `ARENA_OVERLAP_KERNEL_RAM` 会对着**过时的**下界误报。
TENSOR_BASE = 0x00200000                            # desc_table.TENSOR_BASE（arena 起点）
DESC_TABLE_ADDR = 0x00100000                        # desc_table.DESC_TABLE_ADDR_SUGGEST
INPUT_NPU = 0x00200000                              # = input 张量的槽位（arena 首块）
INPUT_BYTES = 640 * 640 * 3                         # = 1_228_800
INPUT_END = INPUT_NPU + INPUT_BYTES                 # 0x0032_C000
BLOB_NPU = 0x00140000                               # 权重信箱映像（blob‖mult）落点：安全区内

# ---- 信箱区域（UnitExec.scala / LayerSched.scala 的 RGN_*）----
RGN_WGT, RGN_WRAM, RGN_M, RGN_ZPAD, RGN_ZY, RGN_BIAS, RGN_WBASE = 0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6
RGN_XDMA, RGN_LAYOUT = 0x7, 0x7                 # ★ B3：道 0 = XDMA_EN；★ B4：道 2 = 每层布局两位
LANE_XDMA, LANE_LAYOUT = 0x0, 0x2
MAILBOX_AW = 24
WBASE_LANES = 4                                      # WGT_BLOB_BASE 4 字节小端
# ★★ S4-A 根因修复（2026-10-17）：`UnitExec.mzRam`/`biasMem` 的层深 = RTL 的 `PN_LAYERS` = **64**
#   （板上 t18c 网表实测：`reg [7:0] mzRam [0:511]` = 64 层 × 8 B； `reg [31:0] biasMem [0:4095]`
#    = 64 层 × 64 字）。而**写侧** `mzOff = rgnLid*8 + lane` 再 resize 到 9 bit ⇒ **layer_id ≥ 64
#   的记录会回绕**落到 layer 0/1/2 的槽位：真表 `requant_mult` 含 lid=64/65/66 的 Sigmoid 条目
#   （M=0）⇒ 它们的 M 字节把 **layer 0/1/2 的真 M 清成 0** ⇒ requant 有效乘子 = 0 ⇒
#   desc[0..2] 输出恒 = z_y（= 41 = 0x29；2026-10-17 板上实测的"常数化帧"根因，见
#   `y1/reports/npu_v2_board_frame.md` §14）。正确投递口径 = **跳过 lid ≥ PN_LAYERS 的记录**
#   （RTL 读侧 `lidOk = layerIdx < PN_LAYERS` 本就响亮拒绝这些层；它们全是旁路算子，M/z/bias
#   不进 UnitExec 参数表）。`LayerSched.layoutMem` 深 256（PN_LAYOUT_L）⇒ LAYOUT 不受此限。
PN_LAYERS = 64                                       # = RTL UnitExec 的参数表层深（M/z_pad/z_y/bias）


def _hex(a):
    return "0x%08X" % (a & 0xFFFFFFFF)


def phys(a):
    """NPU 地址 → 物理地址。"""
    return DDR_PHYS_BASE + (a & 0xFFFFFFFF)


def align32(n):
    return (n + 31) & ~31


def md5f(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 16), b""):
            h.update(blk)
    return h.hexdigest()


# ============================ 冻结产物的读取 ============================
def load_desc(path=DESC_BIN):
    """`gen/desc.bin` → (descs, md5, raw)。**字面**用冻结的 `desc_table.unpack` 解（不重推位表）。"""
    import desc_table as dtab
    raw = open(path, "rb").read()
    if len(raw) % dtab.DESC_BYTES:
        raise SystemExit("FATAL: desc.bin %d B 不是 %d 的整数倍" % (len(raw), dtab.DESC_BYTES))
    descs = [dtab.unpack(raw[i * dtab.DESC_BYTES:(i + 1) * dtab.DESC_BYTES])
             for i in range(len(raw) // dtab.DESC_BYTES)]
    sent_ok = (descs[-1] == dtab.SENTINEL)
    return descs, hashlib.md5(raw).hexdigest(), raw, sent_ok


def load_index(path=WGT_INDEX):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def onnx_out_map(path=ONNX):
    """每个 graph 输出 → {'sigmoid':bool, 'conv_out':名字, 'fold_tensor':名字|None}。

    `fold_tensor` = 折进链末端消费的那个布局张量（= 尾 Reshape 的 `input[0]`）；
    对 Sigmoid 输出则 `fold_tensor` = Sigmoid 的 `input[0]`（折叠视图张量）。
    """
    import onnx
    g = onnx.load(path).graph
    prod = {}
    for n in g.node:
        for o in n.output:
            prod[o] = n
    res = {}
    for o in g.output:
        node = prod[o.name]
        sig = (node.op_type == "Sigmoid")
        fold_t = node.input[0] if node.op_type in ("Reshape", "Sigmoid") else None
        cur = node
        seen = 0
        while cur.op_type in ("Reshape", "Transpose", "Sigmoid") and seen < 8:
            cur = prod[cur.input[0]]
            seen += 1
        if cur.op_type != "Conv":
            raise SystemExit("FATAL: 输出 %s 的产物链没落到 Conv（停在 %s）" % (o.name, cur.op_type))
        res[o.name] = {"sigmoid": sig, "conv_out": cur.output[0], "conv_name": cur.name,
                       "fold_tensor": fold_t}
    return res


def build_output_plan(descs, index, onnx_map):
    """12 路输出 → 回读计划：`(desc 下标, addr, nbytes, 规范形状, 折叠读(stride/view) | None)`。"""
    units = index["units"]
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    lf = {e["dst_tensor"]: e for e in index["layout_fold"]}
    plan = []
    for name in YP.OUT_NAMES:
        m = onnx_map[name]
        st = int(name.split("_")[1])
        hw = (YP.NCH // st) ** 2
        c = YP.LITTLE[name.split("_")[0]]
        if m["sigmoid"]:
            # cls/obj：Sigmoid 的 DST 直接是规范 (1, N, 1) 线性缓冲。
            if name not in out2idx:
                raise SystemExit("FATAL: %s 不在 wgt_index.units 的 out_tensor 里" % name)
            k = out2idx[name]
            plan.append({"name": name, "desc_idx": k, "addr": descs[k]["DST_ADDR"],
                         "nbytes": hw * c, "shape": [1, hw, c], "kind": "sigmoid",
                         "fold": None})
        else:
            # bbox/kps：折进寻址 —— 数据住在生产者(Conv)的 DST；用 layout_fold 的步长反折叠。
            e = lf.get(m["fold_tensor"])
            if e is None:
                raise SystemExit("FATAL: %s 的折叠张量 %s 不在 layout_fold 里" % (name, m["fold_tensor"]))
            src = e["src_tensor"]
            if src not in out2idx:
                raise SystemExit("FATAL: %s 的源张量 %s 不在 units 里" % (name, src))
            k = out2idx[src]
            plan.append({"name": name, "desc_idx": k, "addr": descs[k]["DST_ADDR"],
                         "nbytes": hw * c, "shape": [1, hw, c], "kind": "fold",
                         "fold": {"src_tensor": src, "src_shape": e["src_shape"],
                                  "src_stride": e["src_stride"], "src_order": e["src_order"],
                                  "view_shape": e["view_shape"]}})
    return plan


def fold_src_rewrite(descs, index):
    """★ H1 复发守卫：**必须无改写**（转换器已把每个 SRC_ADDR 折进生产者 DST）。

    H1（commit 见 `y1/reports/c4a_coverage.md` §O3/H1）之前，这里把 6 条 Sigmoid 的 `SRC_ADDR`
    从"从未被写过的折叠视图"槽位**在内存里**改写到生产者 `DST_ADDR`；转换器修好后，`desc.bin` 里这 6 条
    **已经** = 生产者 `DST_ADDR` ⇒ 本函数**恒返回 []**。

    若仍有 Sigmoid 的 `SRC_ADDR` 指到折叠视图（= 转换器的 SRC 折进没生效 / 表被回退到旧口径），
    本函数**响亮失败**（`SystemExit`）——这就是"会抓到复发"的那道哨兵，不是静默改写。
    只检查**连续展平**的折叠（`src_order is None`）；真转置（bbox/kps 侧）不消费描述符、无 SRC_ADDR。
    """
    units = index["units"]
    out2idx = {}
    for i, u in enumerate(units):
        out2idx.setdefault(u["out_tensor"], i)
    lf = {e["consumer"]: e for e in index["layout_fold"]}
    needed = []
    for i, u in enumerate(units):
        e = lf.get(u["name"])
        if e is None:
            continue
        if e["src_order"] is not None:
            continue                                  # 真转置（bbox/kps 侧）——不消费描述符，无 SRC_ADDR
        src = e["src_tensor"]
        if src not in out2idx:
            raise SystemExit("FATAL: %s 的源张量 %s 不在 units 里" % (u["name"], src))
        j = out2idx[src]
        if descs[i]["SRC_ADDR"] != descs[j]["DST_ADDR"]:
            needed.append({"desc_idx": i, "unit": u["name"], "out_tensor": u["out_tensor"],
                           "src_tensor": src, "desc_src": descs[i]["SRC_ADDR"],
                           "producer_dst": descs[j]["DST_ADDR"]})
    if needed:
        lines = "\n".join("   desc[%d] %-12s SRC=0x%08X != 生产者 DST=0x%08X (%s)"
                          % (r["desc_idx"], r["unit"], r["desc_src"], r["producer_dst"], r["src_tensor"])
                          for r in needed)
        raise SystemExit(
            "FATAL/H1-REGRESSION: %d 条 Sigmoid 的 SRC_ADDR 仍指到『从未被写过的折叠视图』槽位 ——\n"
            "转换器（y1_convert.py）的 SRC_ADDR 折进没生效 / desc.bin 被回退到旧口径。\n"
            "请重跑 `bash y1/tools/run_convert_ab.sh` 重生成 gen/desc.bin。明细：\n%s" % (len(needed), lines))
    return []


# ============================ DDR 映像 / 程序序列 ============================
def ddr_regions(index, plan, reloc=0):
    """要主机灌进 DDR 的三块 + 12 路回读区（含重定位后的地址）。"""
    in_end = INPUT_END
    def R(a):
        return a + reloc if a >= in_end else a
    blob_bytes = os.path.getsize(WGT_BLOB) + os.path.getsize(WGT_MULT)
    regs = [
        {"name": "input_int8", "role": "写", "npu": INPUT_NPU, "bytes": INPUT_BYTES,
         "src": "640x640x3 int8（同口径 quant）"},
        {"name": "desc_table", "role": "写", "npu": DESC_TABLE_ADDR, "bytes": os.path.getsize(DESC_BIN),
         "src": "gen/desc.bin"},
        {"name": "wgt_mailbox", "role": "写", "npu": BLOB_NPU, "bytes": blob_bytes,
         "src": "gen/wgt_blob.bin ‖ gen/wgt_mult.bin"},
    ]
    for p in plan:
        regs.append({"name": p["name"], "role": "读", "npu": R(p["addr"]), "bytes": p["nbytes"],
                     "src": "desc[%d] DST（%s）" % (p["desc_idx"], p["kind"])})
    return regs, R


def check_plan(regs, descs, reloc=0):
    """红旗清单（**不静默**）。

    分两类：
      · **HARD**（真 bug，默认就退 1）：对齐错 / 超 28bit / 主机写入区互相重叠 / 写入区出安全区；
      · **WARN**（板上约束，不是本文件能改的）：描述符 arena 压在内核 RAM 里（C4a 的地址向量冻结所致）。
    """
    hard, warn, notes = [], [], []
    lim = 1 << 28

    def R(a):
        return a + reloc if a >= INPUT_END else a

    for r in regs:
        if r["npu"] % 32:
            hard.append("MISALIGN: %s npu=%s 不是 32 B 对齐" % (r["name"], _hex(r["npu"])))
        if r["npu"] + r["bytes"] > lim:
            hard.append("OOB_28BIT: %s 末端 %s 超 28bit 地址空间" % (r["name"], _hex(r["npu"] + r["bytes"])))
    write_regs = [r for r in regs if r["role"] == "写"]
    for i in range(len(write_regs)):
        for j in range(i + 1, len(write_regs)):
            a, b = write_regs[i], write_regs[j]
            if a["npu"] < b["npu"] + b["bytes"] and b["npu"] < a["npu"] + a["bytes"]:
                hard.append("HOST_OVERLAP: %s 与 %s 的主机写入区重叠" % (a["name"], b["name"]))
    for r in write_regs:
        if not (SAFE_LO <= phys(r["npu"]) and phys(r["npu"]) + r["bytes"] - 1 <= SAFE_HI):
            hard.append("OUTSIDE_SAFE: 主机写入区 %s 物理 %s..%s 超出安全区 %s-%s"
                        % (r["name"], _hex(phys(r["npu"])),
                           _hex(phys(r["npu"]) + r["bytes"] - 1), _hex(SAFE_LO), _hex(SAFE_HI)))
    arena_lo = min(R(d["DST_ADDR"]) for d in descs if d["DST_ADDR"])
    arena_top = max(R(d["DST_ADDR"]) + 32 for d in descs if d["DST_ADDR"])
    notes.append("arena（描述符 DST 槽位范围）≈ [%s, %s)  = %.2f MB"
                 % (_hex(arena_lo), _hex(arena_top), (arena_top - arena_lo) / 1048576.0))
    ov_lo, ov_hi = max(arena_lo, KERNEL_RAM_NPU_LO), min(arena_top, KERNEL_RAM_NPU_HI)
    if ov_lo < ov_hi:
        warn.append("ARENA_OVERLAP_KERNEL_RAM: NPU [%s, %s)（%.2f MB）压在内核 RAM（物理 %s-%s）里；"
                    "NPU 可达且非内核的窗口只有 4 MB ⇒ **放不下**（C4a 的地址向量冻结所致；B6 需改 DTS/缩内核窗口或缩 arena）"
                    % (_hex(ov_lo), _hex(ov_hi), (ov_hi - ov_lo) / 1048576.0,
                       _hex(DDR_PHYS_BASE + KERNEL_RAM_NPU_LO), _hex(DDR_PHYS_BASE + KERNEL_RAM_NPU_HI)))
    if arena_top > lim:
        hard.append("ARENA_OOB_28BIT: arena 末端 %s 超 28bit" % _hex(arena_top))
    return hard, warn, notes


def layout_bits(mode="derived", desc_path=DESC_BIN):
    """★ S3-2：**每层 2-bit 布局表**（信箱区域 7 道 2）的真源 —— **复用镜像口径** `frame_preflight.derive_layout`。

    RTL 侧（`rtl/LayerSched.scala:589-602`）：`layoutMem` 深度 256、**按 `LAYER_ID`**（`WGT_ADDR[15:8]`）
    索引；每层两 bit：bit0 = `src_planar`（本层源张量在 DDR 上是通道平面 ⇒ 旁路消费者按步长 gather）、
    bit1 = `dst_planar`（本层目标是平面写 ⇒ 下游 conv 读到的仍是冻结布局）。上电值全 0。

    本函数**不另起一套推导**：镜像（`tools/frame_preflight.py`，T-S3c 的"整表几何预检"）里那套
    `derive_layout`（按冻结契约 `reports/c4b_input_layout.md` §1 从表的 SRC/DST 图推）就是唯一真源。
      · `mode="derived"`：投**推出来的**两位；并加一条**驱动侧判据**：每个旁路单元在 derived 两位下
        必须能走出合法通路（调用镜像的 `bypass_exec`，即 DISPATCH 口径逐条判）——不成立就**响亮停**，
        绝不带着一张"RTL 会拒"的表上板。
      · `mode="zero"`：**显式投零**（= 上电值，复现 `desc[3]` 那个已钉死的失败；显式写而不是"跳过"，
        这样即便上一轮跑过 derived 也能回到真正的零态 —— `layoutMem` 的初值只在断电时生效）。
    """
    import frame_preflight as FP                              # 同一目录（tool 面）；只读它的口径函数
    items = FP.read_desc(desc_path)
    if len(items) < 2 or items[-1]["TYPE"] != 0xFF:
        raise SystemExit("FATAL: 布局表真源 %s 的表尾不是哨兵" % desc_path)
    payload = items[:-1]
    derived = FP.derive_layout(items)
    out = {}
    for d in payload:
        if d["LAYER_ID"] != d["idx"]:
            raise SystemExit("FATAL: 布局表按 LAYER_ID 索引（LayerSched.layoutMem），而镜像按表序 idx 推导；"
                             "unit %d 的 LAYER_ID=%d != idx —— 两者不一致不能盲投" % (d["idx"], d["LAYER_ID"]))
        out[d["LAYER_ID"]] = derived[d["idx"]] if mode == "derived" else (0, 0)
    if mode == "derived":
        for d in payload:
            if d["TYPE"] in FP.BYPASS_TYPES:
                sp, dp = out[d["LAYER_ID"]]
                ok, _path, why, _r = FP.bypass_exec(d, sp, dp)
                if not ok:
                    raise SystemExit("FATAL: 布局表判据失败（镜像口径）：unit %d (%s) 在 derived 两位 "
                                     "src_planar=%d dst_planar=%d 下无合法通路 -> %s"
                                     % (d["idx"], FP.TYPE_NAME.get(d["TYPE"], "?"), sp, dp, why))
    return out


def layout_bits_md5(layout):
    """投递表的指纹：按 LAYER_ID 升序把每层一个字节（bit0=src、bit1=dst）串起来取 md5。"""
    seq = bytes((layout[lid][0] & 1) | ((layout[lid][1] & 1) << 1) for lid in sorted(layout))
    return hashlib.md5(seq).hexdigest(), len(seq)


def mailbox_writes(index, blob_base, with_params=True, xdma_en=True, layout=None):
    """权重信箱的程序序列：区域 6（blob 基址）+ 区域 7 道 0/道 2（XDMA_EN / 每层布局两位）
    + 区域 2/3/4/5（M / z_pad / z_y / bias_adj）。"""
    steps = []

    # ---- 区域 6：WGT_BLOB_BASE（4 字节道小端）----
    arr = [(RGN_WBASE << (MAILBOX_AW - 4)) | lane for lane in range(WBASE_LANES)]
    steps.append({"name": "WGT_BLOB_BASE=%s" % _hex(blob_base), "region": RGN_WBASE, "writes": [
        {"wgt_addr": a, "data": (blob_base >> (8 * lane)) & 0xFF} for lane, a in enumerate(arr)]})

    # ---- ★ C4b-B3：区域 7 道 0 = `XDMA_EN`（**全局开关**）----
    #   宽层激活的来源二选一（`reports/c4b_input_layout.md` §2）：
    #     0（上电值）= 由**外部 `wide_x` 端口**喂（C4a.5b 的挂具行为）；
    #     1 = **本单元从 `SRC_ADDR` 的通道平面张量 gather**（真帧必须走这条）。
    #   本板 `wide_x` 没有任何喂料口（它只在单元装置里由 TB 驱动）⇒ 真帧**必须 = 1**，
    #   否则宽层会**静默等一个永远不来的 `wide_x_valid`**，或落回 legacy 路由**响亮 err**
    #   （F1 实测两档见 c4b_frame.md §3/§4-B）。
    #   ★★ S3-2（2026-10-16）：**默认 = 1**（与 `frame_preflight` 的 DISPATCH 口径钉齐 ——
    #     预检的判据前提就是"真帧驱动 = XDMA_EN 1 + blob"；RTL 证据 `UnitExec.scala:1650-1658`
    #     `tilingWideC` 要求 `xDmaOnR`）⇒ 真帧**裸 `--run` 即正确**；`--no-xdma-en` 只是考古闸。
    if xdma_en:
        steps.append({"name": "XDMA_EN=1（区域 7 道 0）", "region": RGN_XDMA, "writes": [
            {"wgt_addr": (RGN_XDMA << (MAILBOX_AW - 4)) | LANE_XDMA, "data": 1}]})

    # ---- ★★ S3-2：区域 7 道 2 = **每层 2-bit 布局表**（B4 的投递口；F1 §4.4 的必办项）----
    #   表真源 = `layout_bits()`（**复用镜像口径** `frame_preflight.derive_layout`；调用方算好传进来）。
    #   RTL 消费侧：`LayerSched.scala:589-602`（`layoutMem` 按 LAYER_ID 索引，bit0=src_planar、
    #   bit1=dst_planar，`wgt_addr[1:0]==2` 写入）⇒ 每层一条单字节写。
    #   `layout=None` 才跳过（默认路径**一定**投 — 不投就是板上实测的 `desc[3]` 首错）。
    if layout is not None:
        wr = []
        for lid in sorted(layout):
            sp, dp = layout[lid]
            wr.append({"wgt_addr": (RGN_LAYOUT << (MAILBOX_AW - 4)) | (lid << 8) | LANE_LAYOUT,
                       "data": ((sp & 1) | ((dp & 1) << 1))})
        steps.append({"name": "LAYOUT[%d]（区域 7 道 2，每层 2 bit）" % len(wr),
                      "region": RGN_LAYOUT, "writes": wr})

    if not with_params:
        return steps
    # ---- 区域 2：M（每单元 Q24 乘子；[15:8]=LAYER_ID，[1:0]=字节道）----
    # ★★ S4-A（2026-10-17）：**跳过 lid ≥ PN_LAYERS 的记录** —— 它们的写地址会回绕到 layer 0.. 的
    #   槽位并把真 M 清 0（常数化帧的根因；口径与 RTL `lidOk` 一致，见 PN_LAYERS 常量注释）。
    wr, skipped = [], []
    for e in index["requant_mult"]:
        lid, M = int(e["layer_id"]), int(e["M"])
        if lid >= PN_LAYERS:
            skipped.append("%s(lid=%d)" % (e.get("name", "?"), lid))
            continue
        for lane in range(4):
            wr.append({"wgt_addr": (RGN_M << (MAILBOX_AW - 4)) | (lid << 8) | lane,
                       "data": (M >> (8 * lane)) & 0xFF})
    steps.append({"name": "M[%d]（每单元 4 字节小端；跳过 lid≥%d：%d 条%s）"
                          % (len(wr), PN_LAYERS, len(skipped),
                             (" -> " + ",".join(skipped)) if skipped else ""),
                  "region": RGN_M, "writes": wr})
    # ---- 区域 3/4：z_pad / z_y（单字节，[15:8]=LAYER_ID）----
    #   ★ 同样滤掉 lid ≥ PN_LAYERS（真表 centering 的 lid ≤ 60，本滤网是**不变量守卫**）。
    #   ★★ S4-B（D2）：折进 Relu 的单元必须投 **z_y_eff**（= 折进后消费者读的刻度；
    #     = -128 时 int8 clamp 就是 ReLU），不是 conv 自刻度的 z_y。非折进项两者相等。
    for rgn, key, nm in ((RGN_ZPAD, "z_pad", "z_pad"), (RGN_ZY, "z_y_eff", "z_y_eff")):
        wr = [{"wgt_addr": (rgn << (MAILBOX_AW - 4)) | (int(e["layer_id"]) << 8),
               "data": int(e.get(key) if e.get(key) is not None else e["z_y"]) & 0xFF}
              for e in index["centering"] if int(e["layer_id"]) < PN_LAYERS]
        steps.append({"name": "%s[%d]（单字节）" % (nm, len(wr)), "region": rgn, "writes": wr})
    # ---- 区域 5：bias_adj（每 co-block 8 个 int32 = 32 字节道）----
    wr = []
    for e in index["centering"]:
        lid, ba = int(e["layer_id"]), [int(v) for v in e["bias_adj"]]
        if lid >= PN_LAYERS:
            continue
        for cb in range((len(ba) + 7) // 8):
            blk = (ba + [0] * 8)[cb * 8:cb * 8 + 8]
            for lane in range(32):
                u = blk[lane // 4] & 0xFFFFFFFF
                wr.append({"wgt_addr": (RGN_BIAS << (MAILBOX_AW - 4)) | (lid << 8) | (cb << 5) | lane,
                           "data": (u >> (8 * (lane % 4))) & 0xFF})
    steps.append({"name": "bias_adj[%d co-block×32B]" % ((len(wr) + 31) // 32), "region": RGN_BIAS, "writes": wr})
    return steps


def program_sequence(descs, plan, index, blob_base, reloc=0, with_params=True, xfer="devmem",
                    xdma_en=True, layout=None):
    """整套**程序序列**（有序）。前 3 步是 DDR 灌写，之后是寄存器/信箱，最后是回读。"""
    seq = []
    n_payload = len(descs) - 1
    seq.append({"step": 0, "kind": "ddr_write", "what": "input_int8",
                "npu": INPUT_NPU, "phys": phys(INPUT_NPU), "bytes": INPUT_BYTES,
                "how": "net/dd（1.2 MB；**UART 硬灌会被 R5 否掉**）" if xfer == "net" else "devmem 逐字（慢，慎用）"})
    seq.append({"step": 1, "kind": "ddr_write", "what": "desc_table",
                "npu": DESC_TABLE_ADDR, "phys": phys(DESC_TABLE_ADDR), "bytes": os.path.getsize(DESC_BIN),
                "how": "net/dd（2.1 KB）" if xfer == "net" else "devmem 逐字（544 word，安全）"})
    blob_bytes = os.path.getsize(WGT_BLOB) + os.path.getsize(WGT_MULT)
    seq.append({"step": 2, "kind": "ddr_write", "what": "wgt_mailbox",
                "npu": BLOB_NPU, "phys": phys(BLOB_NPU), "bytes": blob_bytes,
                "how": "net/dd（404 KB）"})
    step = 3
    for m in mailbox_writes(index, blob_base, with_params=with_params, xdma_en=xdma_en,
                            layout=layout):
        seq.append({"step": step, "kind": "mailbox", "what": m["name"], "region": m["region"],
                    "writes": len(m["writes"])})
        step += 1
    seq.append({"step": step, "kind": "reg_write", "reg": "CTRL", "val": CTRL_SOFT_RESET,
                "why": "清 errSticky（只由 soft_reset 清；否则把陈旧 err 读成本轮失败）"})
    step += 1
    seq.append({"step": step, "kind": "reg_write", "reg": "DESC_ADDR", "val": DESC_TABLE_ADDR,
                "why": "表基址（32 B 对齐）"})
    step += 1
    seq.append({"step": step, "kind": "reg_write", "reg": "DESC_COUNT", "val": n_payload,
                "why": "载荷项数（不含尾哨兵）"})
    step += 1
    seq.append({"step": step, "kind": "reg_write", "reg": "CTRL", "val": CTRL_START, "why": "start（自清）"})
    step += 1
    seq.append({"step": step, "kind": "poll", "reg": "STATUS", "wait": ["done(bit0)", "err(bit1)"],
                "why": "done/err 电平保持；done 由 STATUS 写 1 清、err 由 CTRL.soft_reset 清"})
    step += 1
    for p in plan:
        seq.append({"step": step, "kind": "ddr_read", "what": p["name"],
                    "npu": p["addr"] + (reloc if p["addr"] >= INPUT_END else 0),
                    "phys": phys(p["addr"] + (reloc if p["addr"] >= INPUT_END else 0)),
                    "bytes": p["nbytes"], "shape": p["shape"], "kind2": p["kind"]})
        step += 1
    return seq


# ============================ --dry ============================
def do_dry(args):
    descs, dmd5, raw, sent_ok = load_desc()
    index = load_index()
    om = onnx_out_map()
    plan = build_output_plan(descs, index, om)
    rew = fold_src_rewrite(descs, index)
    eff = [dict(d) for d in descs]
    for r in rew:
        eff[r["desc_idx"]]["SRC_ADDR"] = r["new_src"]

    regs, R = ddr_regions(index, plan, reloc=args.reloc)
    hard, warn, notes = check_plan(regs, descs, reloc=args.reloc)
    lay = layout_bits(args.layout)
    lay_md5, lay_n = layout_bits_md5(lay)
    print("== npu_frame_run --dry（**不碰板**）==")
    print("desc.bin  = %s  %d B  md5=%s  sentinel=%s" % (DESC_BIN, len(raw), dmd5, sent_ok))
    print("wgt_index = %s  md5=%s" % (WGT_INDEX, md5f(WGT_INDEX)))
    print("wgt_blob  = %s  %d B" % (WGT_BLOB, os.path.getsize(WGT_BLOB)))
    print("wgt_mult  = %s  %d B" % (WGT_MULT, os.path.getsize(WGT_MULT)))
    print("XDMA_EN   = %d（默认 1：与 frame_preflight 的 DISPATCH 口径钉齐）" % int(bool(args.xdma_en)))
    print("LAYOUT    = %s（每层 2-bit；真源 = frame_preflight.derive_layout）；"
          "layers=%d bits_md5=%s" % (args.layout, lay_n, lay_md5))
    print("reloc     = %s（对 addr >= input_end(%s) 的槽位加偏移）" % (_hex(args.reloc), _hex(INPUT_END)))
    print("-- DDR 映像（主机要灌的 3 块 + 12 路回读）--")
    for r in regs:
        print("   %-10s %s  npu=%-10s phys=%-10s %8d B  <- %s"
              % (r["role"], r["name"], _hex(r["npu"]), _hex(phys(r["npu"])), r["bytes"], r["src"]))
    print("-- 12 路输出计划 --")
    for p in plan:
        print("   %-8s desc[%2d] addr=%-10s %7d B  shape=%-12s %s"
              % (p["name"], p["desc_idx"], _hex(p["addr"] + (args.reloc if p["addr"] >= INPUT_END else 0)),
                 p["nbytes"], p["shape"],
                 "sigmoid(线性)" if p["kind"] == "sigmoid"
                 else "fold stride=%s" % (p["fold"]["src_stride"],)))
    print("-- 折叠 SRC 改写（★ H1 后应恒为 0：转换器已把 SRC 折进生产者 DST）--")
    print("   改写条数 = %d（应为 0：desc.bin 自洽，驱动不再需要任何内存改写）" % len(rew))
    for n in notes:
        print("   note: %s" % n)
    if warn:
        print("-- WARN（板上约束；不是本文件能改的）--")
        for w in warn:
            print("   ~~ %s" % w)
    if hard:
        print("-- HARD（真 bug）--")
        for f in hard:
            print("   !! %s" % f)
    else:
        print("-- HARD：无 --")

    seq = program_sequence(descs, plan, index, BLOB_NPU, reloc=args.reloc, xfer=args.xfer,
                           xdma_en=args.xdma_en, layout=lay)
    print("-- 程序序列（%d 步）--" % len(seq))
    for s in seq:
        k = s["kind"]
        if k == "ddr_write":
            print("   %2d %-9s %-12s npu=%s bytes=%d  [%s]" % (s["step"], k, s["what"], _hex(s["npu"]), s["bytes"], s["how"]))
        elif k == "mailbox":
            print("   %2d %-9s %-28s region=%d writes=%d" % (s["step"], k, s["what"], s["region"], s["writes"]))
        elif k == "reg_write":
            print("   %2d %-9s %-12s = %s  (%s)" % (s["step"], k, s["reg"], _hex(s["val"]), s["why"]))
        elif k == "poll":
            print("   %2d %-9s %s wait=%s" % (s["step"], k, s["reg"], s["wait"]))
        else:
            print("   %2d %-9s %-8s npu=%s phys=%s bytes=%d" % (s["step"], k, s["what"], _hex(s["npu"]), _hex(s["phys"]), s["bytes"]))

    plan_md5 = hashlib.md5(
        (dmd5 + json.dumps([[r["name"], r["npu"], r["bytes"]] for r in regs], sort_keys=True)
         + json.dumps([[r["desc_idx"], r["new_src"]] for r in rew], sort_keys=True)
         + json.dumps([[s["step"], s["kind"], s.get("what"), s.get("reg")] for s in seq], sort_keys=True)
         ).encode("utf-8")).hexdigest()
    print("DRY_PLAN_MD5=%s" % plan_md5)
    print("DRY_OUTPUTS=%d DRY_FOLD_REWRITES=%d DRY_HARD=%d DRY_WARN=%d"
          % (len(plan), len(rew), len(hard), len(warn)))
    print("DRY_ARENA_LO=%s DRY_ARENA_TOP=%s"
          % (_hex(min(R(d["DST_ADDR"]) for d in descs if d["DST_ADDR"])),
             _hex(max(R(d["DST_ADDR"]) + 32 for d in descs if d["DST_ADDR"]))))
    print("DRY_RESULT: %s" % ("PASS" if not hard else "FAIL"))

    if args.emit_ddr:
        os.makedirs(args.emit_ddr, exist_ok=True)
        _emit_ddr(args, index, plan)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"desc_md5": dmd5, "plan_md5": plan_md5, "regions": regs, "outputs": plan,
                       "fold_rewrites": rew, "sequence": seq, "hard": hard, "warn": warn,
                       "notes": notes}, fh, indent=1)
        print("DRY_JSON=%s" % args.json)
    return 0 if not hard else 1


def _emit_ddr(args, index, plan):
    """把 3 块 DDR 映像 + 回读清单落盘（供 B6 走网络/分段搬）。"""
    d = args.emit_ddr
    if args.no_face:
        hwc = YP.synth_noface()
    else:
        hwc = YP.preprocess_image(args.img)
    q = to_int8_input(hwc)
    open(os.path.join(d, "input_int8.bin"), "wb").write(q.tobytes())
    open(os.path.join(d, "desc_table.bin"), "wb").write(open(DESC_BIN, "rb").read())
    with open(os.path.join(d, "wgt_mailbox.bin"), "wb") as fh:
        fh.write(open(WGT_BLOB, "rb").read())
        fh.write(open(WGT_MULT, "rb").read())
    with open(os.path.join(d, "readback.json"), "w", encoding="utf-8") as fh:
        json.dump({"input_int8.bin": {"npu": INPUT_NPU, "bytes": INPUT_BYTES},
                   "desc_table.bin": {"npu": DESC_TABLE_ADDR, "bytes": os.path.getsize(DESC_BIN)},
                   "wgt_mailbox.bin": {"npu": BLOB_NPU,
                                       "bytes": os.path.getsize(WGT_BLOB) + os.path.getsize(WGT_MULT)},
                   "outputs": [{"name": p["name"], "npu": p["addr"], "bytes": p["nbytes"],
                                "shape": p["shape"], "fold": p["fold"]} for p in plan]}, fh, indent=1)
    print("EMIT_DDR=%s（input_int8.bin / desc_table.bin / wgt_mailbox.bin / readback.json）" % d)


# ============================ 同口径 int8（quant_ref）============================
def to_int8_input(hwc_bgr):
    """BGR-raw HWC → int8，**同口径**（复用冻结 `quant_ptq.calibrate/affine_params/quant`）。

    对 0..255 的图：`lo=0, hi=255 ⇒ s=1.0, z=-128 ⇒ q = x - 128`（**不是**手搓，走冻结函数）。
    """
    import quant_ptq as ptq
    x = YP.to_nchw(hwc_bgr)                                # (1,3,640,640) float32
    lo, hi = ptq.calibrate(x)
    s, z = ptq.affine_params(lo, hi)
    return np.asarray(ptq.quant(x, s, z), dtype=np.int8)


def run_same_caliber_int8(hwc_bgr, onnx=ONNX):
    """→ (12 路**反量化**张量 dict, 元数据)。**同一份冻结参考**（`quant_ref`）算的。"""
    import quant_ref as QR
    x = YP.to_nchw(hwc_bgr)
    M = QR.Model(onnx, synth=x)
    M.build_params()
    P = QR._params_of(M)
    YCAL.apply_sigmoid_fix(P["act"], M.nodes)      # ★ S4-B（D4）：与转换器同一份 Sigmoid 口径
    T, recs = QR.run_net(M, P)
    out, meta = {}, {}
    for n in YP.OUT_NAMES:
        s, z = float(P["act"][n]["scale"]), int(P["act"][n]["zp"])
        d = np.asarray(QR.dequant(T[n], s, z))
        out[n] = d
        meta[n] = {"scale": s, "zp": z, "int8_shape": list(T[n].shape),
                   "int8_md5": hashlib.md5(np.ascontiguousarray(T[n]).tobytes()).hexdigest(),
                   "deq_min": float(d.min()), "deq_max": float(d.max()),
                   "int8_distinct": int(len(np.unique(T[n])))}
    meta["_input"] = {"scale": float(P["act"][M.input_name]["scale"]),
                      "zp": int(P["act"][M.input_name]["zp"]),
                      "int8_md5": hashlib.md5(np.ascontiguousarray(T[M.input_name]).tobytes()).hexdigest(),
                      "input_nchw_md5": hashlib.md5(x.tobytes()).hexdigest()}
    return out, meta


def do_int8(args):
    hwc = YP.synth_noface() if args.no_face else YP.preprocess_image(args.img)
    t1, m1 = run_same_caliber_int8(hwc)
    t2, m2 = run_same_caliber_int8(hwc) if args.det_two_runs else (t1, m1)
    det = YP.postprocess(t1, args.score_thr, args.nms_thr, args.top_k)
    det2 = YP.postprocess(t2, args.score_thr, args.nms_thr, args.top_k) if args.det_two_runs else det
    md = {n: m1[n]["int8_md5"] for n in YP.OUT_NAMES}
    md2 = {n: m2[n]["int8_md5"] for n in YP.OUT_NAMES}
    print("INT8 input_nchw_md5=%s  input_scale=%.6f zp=%d  input_int8_md5=%s"
          % (m1["_input"]["input_nchw_md5"], m1["_input"]["scale"], m1["_input"]["zp"], m1["_input"]["int8_md5"]))
    for n in YP.OUT_NAMES:
        print("   %-8s int8_md5=%s distinct=%3d deq=[%.4f,%.4f]"
              % (n, m1[n]["int8_md5"][:12], m1[n]["int8_distinct"], m1[n]["deq_min"], m1[n]["deq_max"]))
    same = (md == md2) and ([d["conf"] for d in det] == [d["conf"] for d in det2])
    print("INT8 DETERMINISM=%s（两跑 12 路 md5 逐路相等 + dets 置信度相等）" % ("OK" if same else "RED"))
    print("INT8 score_thr=%.2f nms_thr=%.2f => INT8_DETS=%d" % (args.score_thr, args.nms_thr, len(det)))
    for k, d in enumerate(det[:5]):
        print("   #%d conf=%.4f box=[%.1f,%.1f,%.1f,%.1f]" % (k, d["conf"], *d["box"]))
    if args.npz:
        np.savez(args.npz, **{n: t1[n] for n in YP.OUT_NAMES})
        print("INT8 tensors_npz=%s" % args.npz)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"meta": m1, "determinism_ok": bool(same),
                       "dets": [{"box": [round(v, 4) for v in d["box"]],
                                 "kps": [[round(a, 4), round(b, 4)] for a, b in d["kps"]],
                                 "conf": round(d["conf"], 6)} for d in det]}, fh, indent=1)
        print("INT8 json=%s" % args.json)
    ok = same and (len(det) >= 1 if not args.no_face else len(det) == 0)
    print("INT8_%s got=%d => %s" % ("NOFACE_expected_0" if args.no_face else "FACE_expected_ge1",
                                    len(det), "OK" if ok else "RED"))
    if args.npz or args.json:
        # 供 judges 取用：整份张量的指纹（不落盘也能核）
        print("INT8_ALL_MD5=%s" % hashlib.md5(json.dumps(md, sort_keys=True).encode()).hexdigest())
    print("INT8_RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


# ============================ 反折叠（板上回读 → 规范张量）============================
def folded_read(src_flat, view_shape, src_stride):
    """按 `src_stride` 从**线性缓冲**里读出 `view_shape` 张量（C4a.7 的口径，逐字同源）。"""
    src = np.asarray(src_flat)
    n = int(np.prod(view_shape))
    off = np.zeros(list(view_shape), dtype=np.int64)
    for k, sk in enumerate(src_stride):
        shp = [1] * len(view_shape)
        shp[k] = int(view_shape[k])
        off = off + (np.arange(int(view_shape[k])).reshape(shp) * int(sk))
    return src[off.reshape(-1)].reshape(view_shape)


def readback_to_tensors(raw_blocks, plan, descs, index, reloc=0):
    """`{输出名: 线性字节}` → 12 路**规范** (1,N,C) 张量（int8 码点）。

    cls/obj：Sigmoid DST 已是规范线性 ⇒ 直接 reshape；
    bbox/kps：生产者 `DST` 的线性缓冲 + `layout_fold` 步长 ⇒ `folded_read` 反折叠。
    值仍是 **int8 码点**（反量化由 `yunet_post` 的调用方按 quant_ref 的 scale/zp 做）。
    """
    out = {}
    for p in plan:
        b = raw_blocks.get(p["name"])
        if b is None:
            raise SystemExit("FATAL: 缺回读块 %s" % p["name"])
        q = np.frombuffer(b[:p["nbytes"]], dtype=np.int8)
        if p["kind"] == "sigmoid":
            out[p["name"]] = q.reshape(p["shape"]).astype(np.float64)
        else:
            f = p["fold"]
            v = folded_read(q, f["view_shape"], f["src_stride"])
            out[p["name"]] = v.reshape(p["shape"]).astype(np.float64)
    return out


# ============================ 上板（真跑）============================
class Board(object):
    """串口 + **等完成标记**的纪律（照抄 C3 上板口径）。"""

    def __init__(self, port, baud=115200, gap=0.010, quiet=False):
        import serial
        self.s, self.gap, self.quiet = serial.Serial(port, baud, timeout=0.2), gap, quiet
        self.s.dtr = False
        self.s.rts = False
        import time
        time.sleep(0.3)

    def send(self, cmd):
        import time
        for ch in cmd + "\r":
            self.s.write(ch.encode())
            time.sleep(self.gap)
        if not self.quiet:
            print("  $ %s" % cmd, flush=True)

    def drain(self, secs):
        import time
        b, t0 = b"", time.time()
        while time.time() - t0 < secs:
            d = self.s.read(4096)
            if d:
                b += d
        return b.decode("latin-1").replace("\r", "")

    def run_wait(self, cmd, tok, secs):
        """发一条命令 + `B=<tok>; echo "X${B}X"`，等 `X<tok>X`（**回显里是字面 `X${B}X`**）。"""
        self.send(cmd + '; B=%s; echo "X${B}X"' % tok)
        want = ("X%sX" % tok).encode()
        b, t0 = b"", __import__("time").time()
        while __import__("time").time() - t0 < secs:
            d = self.s.read(4096)
            if d:
                b += d
                if want in b:
                    break
        txt = b.decode("latin-1").replace("\r", "")
        if not self.quiet:
            print("    -> tok %s : %s" % (tok, want.decode() in txt))
        return txt

    def clear(self):
        import time
        self.s.write(b"\x03\x03\r\x11")
        time.sleep(0.4)
        self.drain(0.8)

    def close(self):
        self.s.close()


def _devmem_words(addr, words, tok, brd, secs):
    """把一串 word 灌到物理地址（板端加速比逐条 devmem 快；仍等完成标记）。"""
    parts = ["A=0x%08X" % addr]
    for k, w in enumerate(words):
        parts.append("devmem $A 32 0x%08X" % (w & 0xFFFFFFFF))
        parts.append("A=$((A+4))")
    brd.run_wait("; ".join(parts), tok, secs)


# ============================ 网络/DDR 通路（C4b-F1）============================
# 为什么必须有一条非 UART 的通路（2026-10-13 实测，tag=c4b_r4）：
#   ① 1.2 MB 的 input = 307200 word ⇒ 撞 R5（`--uart-word-limit`），B5 的 devmem 逐字**根本灌不动**；
#   ② 更要命的是**体量**：`Board.send` 是**逐字符 10 ms** 的串口纪律（C3 血泪），
#      544 word 的 desc 表就要 ~42 KB 命令行 ⇒ **7 分钟**；bias_adj 的 6912 条寄存器写
#      （每条 3 个 devmem）⇒ ~900 KB 命令行 ⇒ **2.6 小时**。UART 逐字路径对整帧是死的。
#   ③ 板内 `dd if=X of=/dev/mem bs=4096 seek=...` **会内核 oops**（见 scripts/board_ddr.py 头
#      的实测与根因：riscv32 /dev/mem 的 read/write 走 `__va` 线性映射，而 H2b 后内存节点
#      从 phys 0x8200_0000 起 ⇒ 低 2 MB 与 0xF000_C000 都不在映射里）。**只有 mmap 能碰**
#      （busybox `devmem` 就是 mmap）⇒ 板内用 `y1/tools/ddmem.c` 编出来的静态小工具。
# 判据：**写完就地回读 + 整块独立回读 md5 比对**（不是"信任 dd"）。
def _make_bdd(args, brd_log=None):
    """建网络/ddmem 通路（含把板内 ddmem 传上去，按 md5 幂等）。"""
    p = os.path.join(_H0, "scripts")
    if p not in sys.path:
        sys.path.insert(0, p)
    import board_ddr as BDD
    tool = args.ddmem or os.path.join(_H1, "build", "ddmem_rv32")
    if not os.path.isfile(tool):
        raise RuntimeError("缺板内工具 %s；先 `wsl -e bash -lc 'bash %s/y1/tools/build_ddmem.sh'`"
                           % (tool, _H0.replace("\\", "/")))
    bdd = BDD.BoardDdr(workdir=args.net_dir, chunk=args.net_chunk, tries=args.net_tries,
                       quiet=args.quiet, logpath=args.net_log, timeout=args.net_timeout)
    bdd.prepare(tool)
    return bdd


def _uses_net(net, nbytes, args):
    """块级路由：net 模式下 >= --net-min-bytes 的块走网络；小块仍走 UART devmem（R5 纪律保留）。"""
    return bool(net) and nbytes >= args.net_min_bytes


def deq_params(hwc, onnx=ONNX, cache=None):
    """12 路输出的**反量化** (scale, zp) —— **同口径**：直接取冻结 `quant_ref` 的 act 定标。

    `--int8-tensors` 那份黄金参考用的是同一套（`quant_ref.Model(...).build_params()`），
    所以板上 int8 用同一对 (s,z) 反量化后，与 ORT/参考才是**同一口径**的比较（G7 的前提）。
    """
    import quant_ref as QR
    x = YP.to_nchw(hwc)
    key = hashlib.md5(x.tobytes()).hexdigest()
    if cache and os.path.isfile(cache):
        try:
            d = json.load(open(cache, encoding="utf-8"))
            if (d.get("input_nchw_md5") == key and d.get("caliber") == DEQ_CALIBER
                    and all(n in d["act"] for n in YP.OUT_NAMES)):
                return ({n: (float(d["act"][n]["scale"]), int(d["act"][n]["zp"]))
                         for n in YP.OUT_NAMES}, d)
        except Exception:
            pass
    M = QR.Model(onnx, synth=x)
    M.build_params()
    P = QR._params_of(M)
    YCAL.apply_sigmoid_fix(P["act"], M.nodes)      # ★ S4-B（D4）
    act = {n: {"scale": float(P["act"][n]["scale"]), "zp": int(P["act"][n]["zp"])} for n in YP.OUT_NAMES}
    act["_input"] = {"scale": float(P["act"][M.input_name]["scale"]),
                     "zp": int(P["act"][M.input_name]["zp"])}
    meta = {"input_nchw_md5": key, "act": act, "caliber": DEQ_CALIBER}
    if cache:
        with open(cache, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=1)
    return ({n: (act[n]["scale"], act[n]["zp"]) for n in YP.OUT_NAMES}, meta)


def do_run(args):
    descs, dmd5, raw, sent_ok = load_desc()
    index = load_index()
    om = onnx_out_map()
    plan = build_output_plan(descs, index, om)
    rew = fold_src_rewrite(descs, index)
    eff = [dict(d) for d in descs]
    for r in rew:
        eff[r["desc_idx"]]["SRC_ADDR"] = r["new_src"]
    # 生效表：★ F1 修正 —— **逐字节**用冻结 `desc.bin`（不是重打包）。
    #   为什么：`desc_table.FIELD_ORDER` 只有 14 个字段，**不含** `SRC2_K`（= `w3[31:16]`，
    #   ★ E1 2026-10-13 的表内偏移）。`unpack`→`pack` 往返会把**它不认识的位当 0 写出** ——
    #   实测 `pack_table(unpack(desc.bin[:-1]))` 与本表 md5 不同（`fec587a1…` vs `5b525947…`），
    #   差异**恰在两处**：desc[30] / desc[34]（两个 `Add` 单元）的 `w3=0x00010101 → 0x00000101`
    #   ⇒ SRC2_K 从 1 被抹成 0 ⇒ Add 的第二路源会指到 `idx−0`（静默读错源）。H1 之后
    #   `fold_src_rewrite` 恒为 0 ⇒ 本驱动**不需要**任何改写 ⇒ 直接搬冻结表最安全。
    if not rew:
        eff_blob = raw
    else:
        import desc_table as dtab
        eff_blob = dtab.pack_table(eff[:-1])
        print("!! 生效表被**重打包**（%d 条折进改写）：`desc_table` 不认 `SRC2_K` ⇒ "
              "Add 的第二路表内偏移会被抹成 0（见 c4b_frame.md §5）" % len(rew))

    hwc = YP.synth_noface() if args.no_face else YP.preprocess_image(args.img)
    q = to_int8_input(hwc)
    qb = q.tobytes()
    mb_blob = open(WGT_BLOB, "rb").read() + open(WGT_MULT, "rb").read()

    print("== npu_frame_run --run（**碰板**：%s，xfer=%s）==" % (args.port, args.xfer))
    print("desc.bin md5=%s；生效表 md5=%s；H1 折进改写 %d 条（应为 0）"
          % (dmd5, hashlib.md5(eff_blob).hexdigest(), len(rew)))
    print("   生效表 = %s（%d B；%s）"
          % ("**冻结 desc.bin 逐字节**" if eff_blob == raw else "重打包副本（见下面的响亮警告）",
             len(eff_blob), "含 SRC2_K 等 unpack 不认识的位" if eff_blob == raw else "SRC2_K 已丢"))
    if len(rew) != 0:
        print("!! H1 折进改写条数 = %d（预期 0：转换器应已折进）—— 请先看 --dry 的红旗" % len(rew))

    print("-- 反量化定标（同口径 quant_ref；板上 int8 → float 的 (s,z)）--")
    deq, deq_meta = deq_params(hwc, cache=args.deq_cache)
    print("   input (s=%.8g z=%d)；12 路：" % (deq_meta["act"]["_input"]["scale"],
                                              deq_meta["act"]["_input"]["zp"]))
    for n in YP.OUT_NAMES:
        print("     %-8s s=%.8g z=%d" % (n, deq[n][0], deq[n][1]))

    net = (args.xfer == "net")
    bdd, net_ev = None, {}
    if net:
        print("-- 网络/DDR 通路（net/ddmem）--")
        try:
            bdd = _make_bdd(args)
        except Exception as e:
            print("JUDGE-RED: net/ddmem 通路准备失败：%s" % e)
            print("RESULT: FAIL")
            return 1
        print("   工作目录 %s（ssh 带外，**不占 COM7**）" % args.net_dir)

    brd = Board(args.port, args.baud, quiet=args.quiet)
    try:
        print("-- 清场 --")
        brd.clear()
        print(brd.drain(0.6).strip()[-80:])
        v = brd.drain(0.2)
        brd.send("devmem 0x%08X 32" % (REG_BASE + R_ID))
        v = (v + brd.drain(1.2))
        import re
        m = re.findall(r"0x([0-9A-Fa-f]{8})", v)
        print("-- 探活 ID=%s（期望 %s）--" % (m[-1] if m else "?", _hex(ID_CONST)))
        if not m or int(m[-1], 16) != ID_CONST:
            print("JUDGE-RED: 寄存器窗探活失败（ID 读不到常数）")
            print("RESULT: FAIL")
            return 1

        print("-- 清 errSticky（CTRL.soft_reset）--")
        brd.drain(0.3)
        brd.send("devmem 0x%08X 32 0x%08X" % (REG_BASE + R_CTRL, CTRL_SOFT_RESET))
        brd.drain(0.4)

        # ---------------- 灌 input_int8（1.2 MB）----------------
        print("-- 灌 input_int8（%d B = %d word）--" % (len(qb), qb.__len__() // 4))
        if _uses_net(net, len(qb), args):
            net_ev["input_int8"] = bdd.write(phys(INPUT_NPU), qb, label="input_int8")
            print("   net: 落 phys=%s 并**整块回读 md5 校验**（不是信任 dd）" % _hex(phys(INPUT_NPU)))
        else:
            if q.size // 4 > args.uart_word_limit:
                print("JUDGE-RED: input %d word 超 --uart-word-limit=%d；R5：大映像走网络/分段，"
                      "本驱动拒绝 UART 硬灌" % (q.size // 4, args.uart_word_limit))
                print("RESULT: FAIL")
                return 1
            words = list(struct.unpack("<%dI" % (q.size // 4), qb))
            _devmem_words(phys(INPUT_NPU), words, "FINOIS", brd, args.secs_in)

        # ---------------- 灌 desc_table（生效表）----------------
        print("-- 灌 desc_table（生效表 %d B = %d word）--" % (len(eff_blob), len(eff_blob) // 4))
        if _uses_net(net, len(eff_blob), args):
            net_ev["desc_table"] = bdd.write(phys(DESC_TABLE_ADDR), eff_blob, label="desc_table")
        else:
            dw = list(struct.unpack("<%dI" % (len(eff_blob) // 4), eff_blob))
            _devmem_words(phys(DESC_TABLE_ADDR), dw, "FINDESC", brd, args.secs_desc)

        # ---------------- 灌 wgt_mailbox（blob‖mult）----------------
        print("-- 灌 wgt_mailbox（%d B = %d word）--" % (len(mb_blob), len(mb_blob) // 4))
        if _uses_net(net, len(mb_blob), args):
            net_ev["wgt_mailbox"] = bdd.write(phys(BLOB_NPU), mb_blob, label="wgt_mailbox")
        else:
            if len(mb_blob) // 4 > args.uart_word_limit:
                print("JUDGE-RED: wgt_mailbox %d word 超 --uart-word-limit=%d；R5：大映像走网络/分段，"
                      "本驱动拒绝 UART 硬灌" % (len(mb_blob) // 4, args.uart_word_limit))
                print("RESULT: FAIL")
                return 1
            mw = list(struct.unpack("<%dI" % (len(mb_blob) // 4), mb_blob))
            _devmem_words(phys(BLOB_NPU), mw, "FINMBX", brd, args.secs_in)

        # ---------------- 编程权重信箱（WGT_BLOB_BASE + XDMA_EN + LAYOUT + M/z_pad/z_y/bias_adj）
        lay = layout_bits(args.layout)
        lay_md5, lay_n = layout_bits_md5(lay)
        mbs = mailbox_writes(index, BLOB_NPU, with_params=not args.no_params,
                             xdma_en=args.xdma_en, layout=lay)
        n_wr = sum(len(m["writes"]) for m in mbs)
        print("-- 编程权重信箱（%d 条寄存器写；区 6 基址 + 区 7 道 0 XDMA_EN=%d + 区 7 道 2 LAYOUT(%s,%d 层) "
              "+ 区 2/3/4/5 参数）--" % (n_wr, int(bool(args.xdma_en)), args.layout, lay_n))
        print("   LAYOUT_BITS_MD5=%s（区域 7 道 2 逐字节指纹；真源 = frame_preflight.derive_layout）" % lay_md5)
        if net:
            recs = [(w["wgt_addr"], w["data"]) for m in mbs for w in m["writes"]]
            # UART 逐条要 3 条 devmem：n_wr*3 次 ≈ n_wr*130 B 命令行，按 10 ms/字是**几十小时**级
            print("   net: 一次成批投递（UART 逐条 %d×3 条 devmem ≈ %d KB 命令行，不可行）"
                  % (n_wr, n_wr * 130 // 1024))
            net_ev["mailbox"] = bdd.mailbox(REG_BASE, R_WGT_ADDR, R_WGT_DATA, R_WGT_WE, recs)
        else:
            for m in mbs:
                parts = []
                for w in m["writes"]:
                    parts += ["devmem 0x%08X 32 0x%08X" % (REG_BASE + R_WGT_ADDR, w["wgt_addr"]),
                              "devmem 0x%08X 32 0x%08X" % (REG_BASE + R_WGT_DATA, w["data"]),
                              "devmem 0x%08X 32 0x1" % (REG_BASE + R_WGT_WE)]
                print("   %-28s writes=%d" % (m["name"], len(m["writes"])))
                brd.run_wait("; ".join(parts), "FINMB", args.secs_params)

        print("-- 起跑 --")
        brd.drain(0.3)
        # ★★ S4-A（2026-10-17）：起跑前**先写 STATUS=1 清 done 粘滞位**（w1c；err 由 soft_reset 清）。
        #   否则上一轮留下的 done=1 会让本轮 poll0 **立刻假 done** ⇒ 输出回读可能落在本帧还在跑的时候
        #   （实测踩过：驱动报 done 于 1.7s、而 npurun_t 同帧实为 6.49s）。协议与 npurun_t 逐字一致。
        brd.send("devmem 0x%08X 32 0x1; devmem 0x%08X 32 0x%08X; devmem 0x%08X 32 0x%08X; devmem 0x%08X 32 0x%08X"
                 % (REG_BASE + R_STATUS,
                    REG_BASE + R_DESC_ADDR, DESC_TABLE_ADDR,
                    REG_BASE + R_DESC_COUNT, len(descs) - 1,
                    REG_BASE + R_CTRL, CTRL_START))
        import re, time
        st, poll = None, 0
        t0 = time.time()
        while time.time() - t0 < args.timeout:
            brd.drain(0.05)
            brd.send("devmem 0x%08X 32" % (REG_BASE + R_STATUS))
            o = brd.drain(1.2)
            mm = re.findall(r"0x([0-9A-Fa-f]{8})", o)
            if mm:
                st = int(mm[-1], 16)
                if poll % 10 == 0:
                    print("   poll%d STATUS=%s done=%d err=%d" % (poll, _hex(st), st & 1, (st >> 1) & 1))
            poll += 1
            if st is not None and (st & 3):
                break
        print("   final STATUS=%s（轮询 %d 次，%.1fs）"
              % (_hex(st) if st is not None else "?", poll, time.time() - t0))
        if st is None or not (st & 1) or (st & 2):
            print("JUDGE-RED: 未 done 或 err=1（STATUS=%s）" % (_hex(st) if st is not None else "?"))
            print("RESULT: FAIL")
            return 1

        # ---------------- 回读 12 路 ----------------
        print("-- 回读 12 路 --")
        rawb = {}
        for p in plan:
            nb = align32(p["nbytes"])
            if _uses_net(net, p["nbytes"], args):
                rawb[p["name"]] = bdd.read(phys(p["addr"]), nb)
                print("   %-8s net 回读 %d/%d B（phys=%s）" % (p["name"], nb, nb, _hex(phys(p["addr"]))))
            else:
                txt = brd.run_wait("A=0x%08X; for j in $(seq 0 %d); do devmem $A 32; A=$((A+4)); done"
                                   % (phys(p["addr"]), nb // 4 - 1), "FINRB", args.secs_read)
                words = [int(x, 16) for x in re.findall(r"(?m)^0x([0-9A-Fa-f]{8})\s*$", txt)]
                rawb[p["name"]] = b"".join(struct.pack("<I", w) for w in words[:nb // 4])
                print("   %-8s devmem 读到 %d/%d word" % (p["name"], len(words[:nb // 4]), nb // 4))
        tens = readback_to_tensors(rawb, plan, descs, index)

        # ---------------- 反量化（同口径 (s,z)）----------------
        print("-- 12 路输出（int8 码点）--")
        dq = {}
        for p in plan:
            n = p["name"]
            v = np.asarray(tens[n]).reshape(-1)
            s, z = deq[n]
            dq[n] = (np.asarray(tens[n]).astype(np.float64) - z) * s
            qi = v.astype(np.int32)
            print("   %-8s desc[%2d] %7d B  int8_md5=%s  int8=[%d,%d] distinct=%d  deq=[%.4f,%.4f]"
                  % (n, p["desc_idx"], p["nbytes"],
                     hashlib.md5(np.ascontiguousarray(qi.astype(np.int8)).tobytes()).hexdigest()[:12],
                     qi.min(), qi.max(), len(np.unique(qi)),
                     float(dq[n].min()), float(dq[n].max())))

        dets = YP.postprocess(dq, args.score_thr, args.nms_thr, args.top_k)
        print("BOARD HW_DETS=%d（score_thr=%.2f nms_thr=%.2f top_k=%d）"
              % (len(dets), args.score_thr, args.nms_thr, args.top_k))
        for k, d in enumerate(dets[:5]):
            print("   #%d conf=%.4f box=[%.1f,%.1f,%.1f,%.1f] kps0=(%.1f,%.1f)"
                  % (k, d["conf"], *d["box"], d["kps"][0][0], d["kps"][0][1]))
        if args.json:
            with open(args.json, "w", encoding="utf-8") as fh:
                json.dump({"status": st, "desc_md5": dmd5,
                           "eff_desc_md5": hashlib.md5(eff_blob).hexdigest(),
                           "xfer": args.xfer, "net": net_ev,
                           "deq": {n: {"scale": deq[n][0], "zp": deq[n][1]} for n in YP.OUT_NAMES},
                           "out_int8_md5": {n: hashlib.md5(
                               np.ascontiguousarray(np.asarray(tens[n]).astype(np.int8)).tobytes()
                           ).hexdigest() for n in YP.OUT_NAMES},
                           "dets": [{"box": [round(v, 4) for v in d["box"]],
                                     "kps": [[round(a, 4), round(b, 4)] for a, b in d["kps"]],
                                     "conf": round(d["conf"], 6),
                                     "stride": d["stride"], "anchor": d["anchor"]} for d in dets]},
                          fh, indent=1)
            print("BOARD json=%s" % args.json)
        ok = (len(dets) >= 1) if not args.no_face else (len(dets) == 0)
        print("BOARD_RESULT: %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    finally:
        if bdd is not None:
            bdd.close()
        brd.close()


# ============================ CLI ============================
def main(argv):
    ap = argparse.ArgumentParser(description="宿主侧整帧驱动（规划 / 同口径 int8 / 上板）")
    ap.add_argument("--img", default=None, help="真脸图；与 --no-face 二选一")
    ap.add_argument("--no-face", action="store_true", help="用确定性'无人脸'合成图")
    ap.add_argument("--dry", action="store_true", help="只规划，**不碰板**")
    ap.add_argument("--int8-tensors", action="store_true", help="跑 quant_ref 出 12 路同口径张量")
    ap.add_argument("--run", action="store_true", help="**上板**真跑")
    ap.add_argument("--npz", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--emit-ddr", default=None, help="把 3 块 DDR 映像 + 回读清单落盘")
    ap.add_argument("--reloc", type=lambda s: int(s, 0), default=0,
                    help="对 addr>=input_end 的槽位加偏移（试算 arena 出内核区；**28bit/非内核都难**）")
    ap.add_argument("--fold-src", type=int, default=1,
                    help="[H1 起为**弃用 no-op**] 折进 SRC 改写已并入转换器；此开关无作用")
    ap.add_argument("--xfer", default="net", choices=("net", "devmem"),
                    help="大映像投递通路：net = ssh 带外 + 板内 mmap(ddmem)（默认）；"
                         "devmem = UART 逐字（R5 守卫，大块会被拒）")
    ap.add_argument("--ddmem", default=None, help="板内 mmap 工具路径（默认 y1/build/ddmem_rv32）")
    ap.add_argument("--net-dir", default="/tmp/npu_f1", help="板上工作目录（initramfs，/tmp 可写）")
    ap.add_argument("--net-chunk", type=int, default=131072, help="每块净荷字节数（4096 对齐倍数）")
    ap.add_argument("--net-min-bytes", type=int, default=1024,
                    help="net 模式下 >= 此字节数的块走网络；小块仍走 UART devmem")
    ap.add_argument("--net-tries", type=int, default=3, help="每块网络投递的重试次数")
    ap.add_argument("--net-timeout", type=float, default=180.0, help="单次 ssh/ddmem 会话超时（s）")
    ap.add_argument("--net-log", default=None, help="网络通路逐条会话日志落盘")
    ap.add_argument("--deq-cache", default=None,
                    help="反量化定标缓存（按输入 nchw md5 命中；省掉 quant_ref 的全网前向）")
    ap.add_argument("--strict", action="store_true", help="有红旗就退 1（默认只报不红）")
    ap.add_argument("--det-two-runs", type=int, default=1, help="--int8-tensors 跑两遍证确定性")
    ap.add_argument("--score-thr", type=float, default=YP.SCORE_THR)
    ap.add_argument("--nms-thr", type=float, default=YP.NMS_THR)
    ap.add_argument("--top-k", type=int, default=YP.TOP_K)
    ap.add_argument("--port", default="COM7")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-params", action="store_true", help="上板时跳过 M/z_pad/z_y/bias_adj 投递")
    ap.add_argument("--xdma-en", dest="xdma_en", action="store_true", default=True,
                    help="投递信箱区域 7 道 0 = XDMA_EN（宽层激活从 DDR gather，取代外部 wide_x 端口）。"
                         "★ 默认**开**：真帧必须 1（本板无外部 wide_x 喂料口；RTL 的 tilingWideC 要求 "
                         "xDmaOnR，见 UnitExec.scala:1650-1658），且 frame_preflight 的 DISPATCH 口径"
                         "本来就按 1 判 ⇒ 驱动默认与预检一致（S3-2 校准）")
    ap.add_argument("--no-xdma-en", dest="xdma_en", action="store_false",
                    help="关掉 XDMA_EN（**考古闸**：复现 legacy 路由的响亮 err；真帧不要用）")
    ap.add_argument("--layout", choices=("derived", "zero"), default="derived",
                    help="信箱区域 7 道 2 = 每层 2-bit 布局表（src_planar/dst_planar）：derived（默认）= "
                         "按 frame_preflight.derive_layout（冻结契约 c4b_input_layout.md §1）推导投递；"
                         "zero = 显式投零（复现 desc[3] 首错的考古档）")
    ap.add_argument("--uart-word-limit", type=int, default=4096, help="UART 硬灌的 word 上限（R5 守卫）")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--secs-in", type=float, default=900.0)
    ap.add_argument("--secs-desc", type=float, default=120.0)
    ap.add_argument("--secs-params", type=float, default=600.0)
    ap.add_argument("--secs-read", type=float, default=600.0)
    args = ap.parse_args(argv[1:])

    for p in (DESC_BIN, WGT_INDEX, WGT_BLOB, WGT_MULT, ONNX):
        if not os.path.isfile(p):
            print("FATAL: 前置缺失 %s" % p)
            return 3
    if not (args.dry or args.int8_tensors or args.run):
        args.dry = True
    if args.dry:
        return do_dry(args)
    if args.int8_tensors:
        if not args.no_face and not args.img:
            print("FATAL: --int8-tensors 需要 --img 或 --no-face")
            return 3
        return do_int8(args)
    return do_run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
