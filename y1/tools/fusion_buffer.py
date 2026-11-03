#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Y1-C3.0 —— `fuse_both` 的融合缓冲需求分析（离线，不碰板子、不跑 PDS）。

问题（要关掉的那个开口项）：
  带宽分析推荐调度 `fuse_both`（33 对融合）要求 33 条边界上的中间张量**不出片**。
  这些中间张量在片上到底是"整块驻留"还是"行流式"？
  整块驻留 ≈ 1.6 MB，行流式可能小一两个数量级 —— 两个答案对应完全不同的调度器设计。
  本脚本把它算成一份可复算的逐单元表 + 机器可读的 `MAX_*` 末行。

用法：
    PYTHONPATH='../third_party/yunet/deps' <py3.9> \
        tools/fusion_buffer.py ../third_party/yunet/yunet.onnx

============================ 枚举来源（复用，不重推融合规则） ============================
  直接 import 上一阶段的冻结件 `tools/ddr_traffic.py`（本脚本**不改**它）：
      dt.find_fusion_pairs(gv)        -> 7 对   3x3(stride1) --逐元素--> 1x1
      dt.find_fusion_pairs_native(gv) -> 26 对  1x1(stride1) --逐元素--> 3x3
      fuse_both = 两方向并集 = 33 对（与 ddr_traffic_budget.md 的 C0.3 "33 对"逐字一致）
  每个单元的"中间张量"取该报告 --fusion-report 打印的那个（3x3->1x1 取 A.output[0]；
  1x1->3x3 取 mid == B.input[0] == A.output[0]），形状由 onnx.shape_inference 得到。

============================ 两种实现模型 ============================
  (a) 整块驻留：中间张量整张 materialise = C*H*W 字节（int8 即字节数）。
  (b) 行流式  ：生产者逐行产出、消费者逐行吃掉，只留一个"行窗口" = rows_live*C*W 字节。
                rows_live=3 见下面的口径；rows_live=5 为保守（嵌套）上界。

============================ 片上预算（推导量，非实测） ============================
  空闲 DRM = 415 - 24.5 = 390.5 块；1 块 DRM36K = 36 Kbit = 36864 bit = 4608 B
  => 空闲片上 RAM = 390.5 * 4608 = 1,799,424 B ≈ 1.80 MB
  空闲 FF  = 319600 - 87409(切片) - 17187(SoC+host/master glue) = 215,004
  （这两个数在本报告里一律标注为"推导量"，不是测量值。）
==========================================================================
"""
import sys
import os
import math

# Windows 控制台可能是 GBK；本脚本只打 ASCII，仍做一次保险。
sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

# 复用上一阶段的冻结件（只读，不改）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ddr_traffic as dt  # noqa: E402

# ---- 板级/器件常量（推导量，来源见 ddr_traffic.py 顶部与任务背景） ----
DRM36K_BYTES = 36864 // 8          # 36 Kbit = 4608 B
FREE_DRM_BLOCKS = 415.0 - 24.5     # 器件 415 - (SoC+host/master glue) 24.5 = 390.5
FREE_DRM_BYTES = FREE_DRM_BLOCKS * DRM36K_BYTES
FREE_FF = 319600 - 87409 - 17187   # 器件 - 切片 - (SoC+glue) = 215004

# rows_live=3 的依据见模块内 selftest_streaming() 的注释；5 为保守嵌套上界。
ROWS_MIN = 3
ROWS_CONSERVATIVE = 5


class Unit(object):
    """一个融合单元：producer/consumer 两节点 + 其边界上的中间张量。"""

    def __init__(self, kind, producer, consumer, mid_name, shape, chain):
        self.kind = kind                 # "3x3->1x1" / "1x1->3x3"
        self.producer = producer
        self.consumer = consumer
        self.mid_name = mid_name
        self.C, self.H, self.W = shape
        self.chain = chain               # 被消掉的整条中间链（含 mid 本身）

    @property
    def full_bytes(self):
        """(a) 整块驻留：C*H*W。"""
        return self.C * self.H * self.W

    @property
    def row_bytes(self):
        """一行的字节数 C*W（行缓冲的"宽度"。"""
        return self.C * self.W

    def stream_bytes(self, rows_live):
        """(b) 行流式：rows_live 行的窗口。"""
        return rows_live * self.row_bytes


def enumerate_units(gv):
    """把 fuse_both 的 33 对摊成 Unit 列表；与 --fusion-report 逐对一致。"""
    units = []
    # 方向一：3x3(stride1) -> 1x1。报告里的 mid 是 A.output[0]（writer 侧张量）。
    fus33, _ = dt.find_fusion_pairs(gv)
    for (A, B) in fus33:
        T = A.output[0]
        s = gv.shape_of(T)
        assert s is not None and len(s) == 4, "mid %r shape %r 不是 4 维" % (T, s)
        # 报告用 2xsize 记账 ⇒ 链首尾同尺寸（逐元素穿透）；这里断言写/读两侧同尺寸。
        assert gv.act_bytes(T) == gv.act_bytes(B.input[0]), \
            "3x3->1x1 单元 %s->%s 两侧张量尺寸不等，2xsize 记账需复核" % (A.name, B.name)
        # 记录整条链（供报告说明"链上有几个同尺寸张量"）
        chain, cur = [], T
        while True:
            chain.append(cur)
            cons = gv.consumers_of(cur)
            n = gv.nodes[cons[0]]
            if n.op_type in dt.ELEMENTWISE_OPS:
                cur = n.output[0]
                continue
            break
        units.append(Unit("3x3->1x1", A.name, B.name, T, (s[1], s[2], s[3]), chain))
    # 方向二：1x1(stride1) -> 3x3。报告里的 mid == B.input[0] == A.output[0]（链为空）。
    fus11, _ = dt.find_fusion_pairs_native(gv)
    for (A, B, mid, chain) in fus11:
        s = gv.shape_of(mid)
        assert s is not None and len(s) == 4, "mid %r shape %r 不是 4 维" % (mid, s)
        assert gv.act_bytes(mid) == gv.act_bytes(A.output[0]) == gv.act_bytes(B.input[0]), \
            "1x1->3x3 单元 %s->%s 三处尺寸不等" % (A.name, B.name)
        units.append(Unit("1x1->3x3", A.name, B.name, mid, (s[1], s[2], s[3]), chain))
    return units


# ============================ 行流式非退化自检 ============================
def selftest_streaming(units):
    """行流式模型的自检 + 非退化断言。

    为什么要有：本项目曾因"测试向量周期 == 缓冲尺寸"让一次整块移位在眼里消失
    （见任务背景的 test-pattern collision）。这里用一个**每行各不相同**的探针
    （行内容 = 行号）走一遍 3 行窗口模型，断言：
      (1) H > rows_live  —— 图上确实不止一个窗口，流式是有意义的（不是退化成"整张=一个窗口"）；
      (2) 相邻窗口不同     —— 一次"整行移位"确实改变窗口内容 ⇒ 不会被周期混叠吞掉；
      (3) 窗口深度 rows_live 不等于任一维度 C/W —— 窗口深度不会被 C 或 W 的周期混叠掉。
    全部通过返回 True。
    """
    ok = True
    for u in units:
        C, H, W = u.C, u.H, u.W
        rows_live = ROWS_MIN
        # (1) 非退化：行数必须多于一个窗口
        c1 = H > rows_live
        # (3) 非退化：窗口深度不与 C/W 混叠
        c3 = rows_live not in (C, W)
        # (2) 逐行内容 = 行号（每行不同）；模拟 ring buffer 的 3 行窗口消费。
        #     生产者按 r=0..H-1 产行，消费者一旦攒够 3 行就吃一个窗口（含零填充）。
        ring = []          # 只保留最近 rows_live 行
        windows = []
        for r in range(-1, H + 1):            # r=-1 与 r=H 是上/下零填充行
            row = 0 if (r < 0 or r >= H) else (r + 1)   # 行内容 = 行号+1（>=1，区别于填充 0）
            ring.append(row)
            if len(ring) > rows_live:
                ring.pop(0)
            if len(ring) == rows_live:
                windows.append(tuple(ring))
        # 期望窗口数 = H（每个输出行 y 一个窗口）
        c2a = (len(windows) == H)
        # 相邻窗口必须不同（一次整行移位会改变窗口 ⇒ 可见）
        c2b = all(windows[i] != windows[i + 1] for i in range(len(windows) - 1))
        ok &= c1 and c2a and c2b and c3
        print("[selftest] %-9s->%-9s C=%2d H=%3d W=%3d | H>rows:%s windows==H:%s "
              "adjacent-differ:%s rows_live not in (C,W):%s"
              % (u.producer, u.consumer, C, H, W,
                 "Y" if c1 else "N", "Y" if c2a else "N",
                 "Y" if c2b else "N", "Y" if c3 else "N"))
    print("[selftest] 行流式非退化自检：%s" % ("PASS" if ok else "FAIL"))
    return ok


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) < 1:
        print(__doc__)
        return 2
    onnx_path = args[0]

    gv = dt.GraphView(onnx_path)
    units = enumerate_units(gv)

    n33 = sum(1 for u in units if u.kind == "3x3->1x1")
    n11 = sum(1 for u in units if u.kind == "1x1->3x3")
    print("== fuse_both 融合单元枚举（复用 tools/ddr_traffic.py 的查找器）==")
    print("  3x3->1x1 : %d 对 / 1x1->3x3 : %d 对 / 合计 %d 对" % (n33, n11, len(units)))
    assert len(units) == 33, "fuse_both 应为 33 对，实得 %d" % len(units)

    # ---------------- 逐单元表 ----------------
    hdr = "%-3s %-10s %-9s %-9s %-5s %3s %4s %4s %11s %11s %9s %9s %9s" % (
        "idx", "kind", "producer", "consumer", "mid", "C", "H", "W",
        "full_B", "full_DRM", "s3_B", "s5_B", "row_B")
    print()
    print(hdr)
    print("-" * len(hdr))
    for i, u in enumerate(units):
        print("%-3d %-10s %-9s %-9s %-5s %3d %4d %4d %11d %11d %9d %9d %9d"
              % (i, u.kind, u.producer, u.consumer, u.mid_name, u.C, u.H, u.W,
                 u.full_bytes, math.ceil(u.full_bytes / DRM36K_BYTES),
                 u.stream_bytes(ROWS_MIN), u.stream_bytes(ROWS_CONSERVATIVE),
                 u.row_bytes))
    print("-" * len(hdr))

    # ---------------- 最大值（跨 33 单元） ----------------
    max_full = max(units, key=lambda u: u.full_bytes)
    max_row = max(units, key=lambda u: u.row_bytes)
    max_c = max(u.C for u in units)
    max_w = max(u.W for u in units)
    max_h = max(u.H for u in units)

    MAX_FULL_BYTES = max_full.full_bytes
    MAX_FULL_DRM = math.ceil(MAX_FULL_BYTES / DRM36K_BYTES)
    MAX_ROW_ELEMS = max_row.row_bytes                 # = C*W 的最大值（行缓冲"宽度"）
    MAX_STREAM3_BYTES = ROWS_MIN * MAX_ROW_ELEMS
    MAX_STREAM5_BYTES = ROWS_CONSERVATIVE * MAX_ROW_ELEMS
    MAX_STREAM3_DRM = math.ceil(MAX_STREAM3_BYTES / DRM36K_BYTES)
    MAX_STREAM5_DRM = math.ceil(MAX_STREAM5_BYTES / DRM36K_BYTES)
    # 单一固定参数化（同时覆盖 max C 与 max W，实践上常这么做）：
    MAX_FIXED_ELEMS = max_c * max_w
    MAX_STREAM3_FIXED_BYTES = ROWS_MIN * MAX_FIXED_ELEMS
    MAX_STREAM3_FIXED_DRM = math.ceil(MAX_STREAM3_FIXED_BYTES / DRM36K_BYTES)

    print()
    print("== 跨 33 单元的最大值 ==")
    print("  最大整块中间张量      : %s %s -> %d B（%.4f MB / %.4f MiB）= %.3f MB"
          % (max_full.producer, max_full.mid_name, MAX_FULL_BYTES,
             MAX_FULL_BYTES / 1e6, MAX_FULL_BYTES / (1024.0 * 1024.0),
             max_full.full_bytes / 1e6))
    print("  出现最大整块的单元    : producer=%s consumer=%s kind=%s shape=(C=%d,H=%d,W=%d)"
          % (max_full.producer, max_full.consumer, max_full.kind,
             max_full.C, max_full.H, max_full.W))
    print("  最大行缓冲\"宽度\" C*W : %d 元素（单元 producer=%s consumer=%s, C=%d, W=%d）"
          % (MAX_ROW_ELEMS, max_row.producer, max_row.consumer, max_row.C, max_row.W))
    print("  单维最大              : C=%d  W=%d  H=%d" % (max_c, max_w, max_h))
    print("  行流式 rows_live=3    : %d B（= 3 x %d）= %d DRM 块"
          % (MAX_STREAM3_BYTES, MAX_ROW_ELEMS, MAX_STREAM3_DRM))
    print("  行流式 rows_live=5    : %d B（= 5 x %d）= %d DRM 块"
          % (MAX_STREAM5_BYTES, MAX_ROW_ELEMS, MAX_STREAM5_DRM))
    print("  单参数化 (C=%d,W=%d) 3 行: %d B = %d DRM 块（覆盖 max C 与 max W 两者）"
          % (max_c, max_w, MAX_STREAM3_FIXED_BYTES, MAX_STREAM3_FIXED_DRM))

    # ---------------- 片上预算对比 ----------------
    print()
    print("== 片上预算对比（预算为推导量）==")
    print("  空闲 DRM = %.1f 块 = %d B ≈ %.4f MB；1 块 DRM36K = %d B"
          % (FREE_DRM_BLOCKS, int(FREE_DRM_BYTES), FREE_DRM_BYTES / 1e6, DRM36K_BYTES))
    print("  空闲 FF  = %d" % FREE_FF)

    def verdict_line(label, bytes_, drm_blocks, ff_bits):
        fits_drm = drm_blocks <= FREE_DRM_BLOCKS
        fits_ff = ff_bits <= FREE_FF
        marg = 100.0 * (FREE_DRM_BLOCKS - drm_blocks) / FREE_DRM_BLOCKS
        print("  %-22s %9d B  %4d DRM  DRM余量 %+6.1f%%  %s | FF(8b/元) %8d  %s"
              % (label, bytes_, drm_blocks, marg,
                 "DRM-OK" if fits_drm else "DRM-NO",
                 ff_bits, "FF-OK" if fits_ff else "FF-NO"))
        return fits_drm, fits_ff

    full_drm_ff = MAX_FULL_BYTES * 8
    (a_drm, a_ff) = verdict_line("(a) 整块驻留 1 张", MAX_FULL_BYTES, MAX_FULL_DRM, full_drm_ff)
    (b3_drm, b3_ff) = verdict_line("(b) 行流式 3 行", MAX_STREAM3_BYTES, MAX_STREAM3_DRM,
                                   MAX_STREAM3_BYTES * 8)
    (b5_drm, b5_ff) = verdict_line("(b) 行流式 5 行", MAX_STREAM5_BYTES, MAX_STREAM5_DRM,
                                   MAX_STREAM5_BYTES * 8)
    verdict_line("(b) 行流式 3 行(单参数)", MAX_STREAM3_FIXED_BYTES, MAX_STREAM3_FIXED_DRM,
                 MAX_STREAM3_FIXED_BYTES * 8)

    print()
    print("  注：(a) 整块驻留的 DRM 需求 %d 块 < 空闲 %.1f 块，单张**勉强**装得下（余量仅 %.1f%%）；"
          % (MAX_FULL_DRM, FREE_DRM_BLOCKS, 100.0 * (FREE_DRM_BLOCKS - MAX_FULL_DRM) / FREE_DRM_BLOCKS))
    print("      但双缓冲（生产者写 / 消费者读各一张，C0.2 的 CHIP_BUFFERS=2 模型）即 2x%d=%d 块 > %.1f ⇒ 装不下。"
          % (MAX_FULL_DRM, 2 * MAX_FULL_DRM, FREE_DRM_BLOCKS))
    print("      且整块驻留若用 FF 实现需 %d 个 FF > 空闲 %d ⇒ 只能走 DRM。" % (full_drm_ff, FREE_FF))
    print("  注：行流式若用 FF(8 位/元素) 实现，最坏单元 3 行需 %d FF > 空闲 %d ⇒ **装不下**；"
          % (MAX_STREAM3_BYTES * 8, FREE_FF))
    print("      所以行流式缓冲**必须落成块 RAM（DRM）**，不能像现有 LineBuffer 那样落寄存器。")
    print("      （Pango 工具链忽略 ram_style，映射随尺寸/结构：%d B 的行窗口必须写成可寻址 RAM 结构才会被推断成 DRM36K。）"
          % MAX_STREAM3_BYTES)

    # ---------------- 自检 ----------------
    print()
    ok_stream = selftest_streaming(units)

    # ---------------- 机器可读末行 ----------------
    print()
    print("MAX_UNITS=%d MAX_FULL_BYTES=%d MAX_FULL_DRM=%d MAX_ROW_CxW=%d "
          "MAX_STREAM3_BYTES=%d MAX_STREAM3_DRM=%d MAX_STREAM5_BYTES=%d MAX_STREAM5_DRM=%d "
          "MAX_C=%d MAX_W=%d MAX_H=%d MAX_FIXED3_BYTES=%d MAX_FIXED3_DRM=%d "
          "FREE_DRM_BLOCKS=%.1f FREE_DRM_BYTES=%d FREE_FF=%d "
          "STREAM3_FF=%d STREAM5_FF=%d FULL_FF=%d "
          "STREAM_FITS_DRM=%s STREAM_FITS_FF=%s FULL_FITS_DRM=%s FULL_FITS_FF=%s"
          % (len(units), MAX_FULL_BYTES, MAX_FULL_DRM, MAX_ROW_ELEMS,
             MAX_STREAM3_BYTES, MAX_STREAM3_DRM, MAX_STREAM5_BYTES, MAX_STREAM5_DRM,
             max_c, max_w, max_h, MAX_STREAM3_FIXED_BYTES, MAX_STREAM3_FIXED_DRM,
             FREE_DRM_BLOCKS, int(FREE_DRM_BYTES), FREE_FF,
             MAX_STREAM3_BYTES * 8, MAX_STREAM5_BYTES * 8, full_drm_ff,
             "YES" if b3_drm else "NO", "YES" if b3_ff else "NO",
             "YES" if a_drm else "NO", "YES" if a_ff else "NO"))
    return 0 if ok_stream else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
