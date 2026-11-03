#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""frame_preflight.py —— **整表几何预检**（spec §4-C 判据 C 的"Python 快门"；T-S3c.1）。

它做什么
--------
读**真表** `gen/desc.bin`（67 条载荷 + 尾哨兵，每条 8 个 32-bit 小端字；位表见
`y1/tools/desc_table.py` 的模块 docstring / `y1/rtl/DescDefs.scala`），逐单元算出 RTL 在
`go` 那一刻要用的**派生几何**，再**照着 RTL 的判据逐条判**（每条判据都在下面的函数里注明
RTL 行号，供读者复算）：

  · conv 类（`TYPE ∈ {0x01,0x02,0x03}`）走 `UnitExec`：
      `inWOk` / `wideGeomOk` / `tilingWideC` / `tilingOkC` / `wgtLoadOk` / `chainOk` / `lidOk` /
      `qShiftOk`，以及 FSM 的**路由顺序**（`y1/rtl/UnitExec.scala:1957-2038`）
      和 `WGTRUN` 收工那一拍的二次对账（`y1/rtl/UnitExec.scala:2079`）。
  · 旁路类（`TYPE ∈ {0x10,0x11,0x13,0x14}`）走 `BypassExec`：
      `geomOk` / `rowWOk` / `planarOk` / `cBlkOk` / `blkPlanarOk` / `blkPhaseOk` /
      `tileOk`（`tileOpOk`/`tilePlOk`/`tileAliOk`/`tileRzOk`/`tileG0Ok`）/ `wholeOk` /
      `foldPt`，以及路由（`y1/rtl/BypassExec.scala:1051-1064`）。

两种口径（**都必须打印**）
-------------------------
  · `UNIT` 口径（= `PREFLIGHT_ERR`，闸门判决的那个数）—— spec §4-C 点名的口径：**每个单元自己一条**，
    看它的**几何/形状**在 RTL 里**有没有**合法通路。默认按**既有闸门用的那一档编程**判：
      `--xdma 1`（宽层激活走 DDR gather）+ `--blob 0`（权重按层预载进信箱区域 1 的趟瓦片 `wRam`）
      + `--unit-flags plain`（把它当**单个 plain 单元**跑，= 既有宽/旁路闸门每个作业的 `+FLAGS=1`）。
      ⇒ 这就是"**每个真表形状都能被 RTL 处理**"的完备性证书（T-S3a/T-S3b 修的三处盲区的**全表**版）。
  · `DISPATCH` 口径（= `DISPATCH_ERR`）—— **忠实派发**口径：
    ① `LayerSched` 会把一段 `head middle* tail` 的**融合链塌缩成一次 `go`**
       （`y1/rtl/LayerSched.scala` CHAINSCAN/CHAINSCANW），链长作独立入参交给 `UnitExec`
       （`LayerSched.scala:473`）⇒ 链上每个条目实际看到的 `chain_len` = **整段 run 的长度**；
    ② 运行时开关按**真帧驱动**（`tools/npu_frame_run.py`）：`XDMA_EN=1` + `WGT_BLOB_BASE≠0`（权重走 DDR blob）。
    ★★ A2（2026-10-16，spec §5.0）后：真表**宽 run 已拆成 plain**（`y1_convert.py` 的
    `defuse_wide_runs`；窄 run 才会保留链）⇒ 每个单元看到的 `chain_len` 恒 1 ⇒ 原先"宽层链
    无通路"的 54 条 err 全部消失。**镜像同步**（两处 RTL 已先行修复、各自有逐字节闸门）：
      · `:2079` 的 WGTRUN-end err 条件现为 `wlWideR && !wideGeomOk && !tilingW`（T-S3d 缺陷修-①：
        tiled 宽路**豁免** `inWOk`）⇒ 本镜像在 wide-tile 支**不再检查**、narrow-tile 支该条恒假；
      · 旁路 tile 的 `tileAliOk`（`inCols%32==0`）**已从 RTL 去掉**（T-S3e per-plane band，
        `Resize_43` 40×40 已逐字节证明可跑）⇒ 本镜像同步删除该项。


运行时开关（主机编程面，**不在描述符里**）
------------------------------------------
  · `--xdma / --no-xdma`（`XDMA_EN`，信箱区域 7 道 0；`UnitExec.scala:1529-1531` 的 `xDmaOnR`）。
    真帧**必须 = 1**（宽层激活由本单元从 DDR gather；`tools/npu_frame_run.py:340-356` 同口径）。
    **默认 1**（= 既有宽/旁路闸门的编程：`UnitExecWideTb` 的 `+TILED_W` 会写区域 7 道 0 = 1）。
  · `--blob 0|1`（`WGT_BLOB_BASE != 0` ⇒ `dmaEn`；`UnitExec.scala:961`）。默认 **0**（= 既有闸门的编程：
    权重按层预载进信箱区域 1 的趟瓦片；真帧驱动走 DDR blob ⇒ 见 `DISPATCH` 口径的固定档）。
  · `--unit-flags plain|own`：`UNIT` 口径里把单元当 **plain 单单元**（`+FLAGS=1`，既有闸门口径，默认）
    还是用它**自己**的 `FLAGS`（链成员会带 `head/middle` ⇒ `!isHead` 那一条 tiling 前提不成立）。
  · `--layout derived|zero`（`io.src_planar/dst_planar`，信箱区域 7 道 2；**按 `LAYER_ID` 每层两位**）。
    ★ S3-2（2026-10-16）后**真帧驱动已投递**这两位（`tools/npu_frame_run.py` 的 `layout_bits()` 直接
    调本文件的 `derive_layout`，默认 `--layout derived`；投递表指纹见驱动的 `LAYOUT_BITS_MD5=`）。
    本文件默认 `derived` = 按**冻结契约**（`reports/c4b_input_layout.md` §1）从**表的 SRC/DST 图**推：
    源张量的生产者是 conv（或网络输入）⇒ `src_planar=1`；目标张量被 conv 消费（含经 `Add` 的
    `src2k` 第二路）⇒ `dst_planar=1`。`zero` 档 = 上电值两位全 0（= S3-1 板上实测的失败态）。


输出
----
逐单元一行：`unit, type, shape, -> path, verdict`；末尾 `PREFLIGHT_ERR=<n>`（UNIT 口径）、
`DISPATCH_ERR=<m>`、`RESULT: PASS|FAIL`（**PASS ⟺ `PREFLIGHT_ERR == 0`**）。

退出码：0 = PASS / 1 = FAIL（有 ERR）/ 3 = 前置缺失（表读不到 / 形状不对）。

**口径漂移风险（明写）**：本工具是 RTL 判据的**第二实现**（Python 侧），与 RTL 之间没有
自动对账 ⇒ 真源仍是**模拟里跑真 desc 序列**（spec §4-C 的终证，见报告"能证/不能证"）。

用法
----
    PYTHONIOENCODING=utf-8 <py3> y1/tools/frame_preflight.py [--desc PATH] [--inject UNIT,W|...]
                              [--xdma 0|1] [--blob 0|1] [--layout derived|zero] [--quiet]
"""

import argparse
import hashlib
import os
import struct
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
_Y1 = os.path.abspath(os.path.join(_HERE, ".."))
DESC_DEFAULT = os.path.join(_Y1, "gen", "desc.bin")

# ===========================================================================
# 展开期常量 —— **与板级 tiled 网表同参**（网表里的常量就是这些数）
#   · UnitExec  : C=8 WIDTH=34 IMG_H_MAX=32 L_MAX=8 TILING=true
#                 （`rtl_test/UnitExecGen.scala:85` 的 `UnitExec_tiled.v`）
#   · BypassExec: C=8 WIDTH=34 IMG_H_MAX=32（`rtl_test/BypassExecGen.scala:15` 的 `BypassExec_w34.v`）
#   · LayerSched: 同参（`rtl_test/LayerSchedGen.scala:6-8`）
# ===========================================================================
C = 8                 # UnitExec.scala:461 `val C`；`DdrMaster` 一拍 8 B
WIDTH = 34            # T-S2：`W_MAX = W_TILE(32) + 2`（halo 列）
IMG_H_MAX = 32        # T-S2：`H_TILE`
L_MAX = 8             # UnitExec.scala:461；与 desc_table.CHAIN_L_MAX 同口径
TILING = True         # UnitExec 的 `TILING=true`（tiled 网表）
PN_LAYERS = 64        # UnitExec.scala:509 `PN_LAYERS`
NCOB_MAX = 8          # UnitExec.scala:515 `NCOB_MAX`
GROUP = 1             # UnitExec.scala:472 `val GROUP = 1`
SHIFT = 6             # 网表展开期 QUANT_SHIFT（mac_ref.SHIFT）
MAXPIX_UE = WIDTH * IMG_H_MAX     # UnitExec.scala:520（= 1088）
MAXPIX_BE = WIDTH * IMG_H_MAX     # BypassExec.scala:372（= 1088）
DDR_BYTES = 1 << 28               # DdrMaster.ADDR_W = 28（desc_table.DDR_ADDR_W 同源）

# ---- BypassExec 的 tile 编译期几何（BypassExec.scala:385-395）----
TILE_W = min(32, WIDTH)                       # = 32
TILE_H = (min(32, IMG_H_MAX) // 4) * 4        # = 32
TWP = max(min(TILE_W, (WIDTH // 4) * 2), 2)   # pool 输出 tile 宽 = 16
TWR = max(min(TILE_W, WIDTH * 2), 2)          # resize 输出 tile 宽 = 32
_tileConstOk = (TILE_H >= 4 and TILE_H <= IMG_H_MAX and (TILE_H * 4) % 4 == 0 and
                TWR >= 2 and (TWR // 2) >= 1 and (TWR // 2) <= WIDTH and
                TWP >= 2 and (2 * TWP) <= WIDTH and (TILE_W * TILE_H) <= MAXPIX_BE)

TYPE_NAME = {0x01: "conv3x3", 0x02: "conv1x1", 0x03: "depthwise", 0x10: "maxpool",
             0x11: "resize", 0x12: "concat", 0x13: "add", 0x14: "sigmoid", 0xFF: "sentinel"}
CONV_TYPES = (0x01, 0x02, 0x03)
BYPASS_TYPES = (0x10, 0x11, 0x13, 0x14)


# ===========================================================================
# 1) 读表（8 个小端字；位表 = desc_table.py + DescDefs.scala 逐字）
# ===========================================================================
def read_desc(path):
    raw = open(path, "rb").read()
    if len(raw) % 32:
        raise SystemExit("FATAL: %s 的 %d B 不是 32 B 的整数倍" % (path, len(raw)))
    out = []
    for i in range(len(raw) // 32):
        w = struct.unpack_from("<8I", raw, i * 32)
        out.append(dict(
            idx=i, w=list(w),
            TYPE=w[0] & 0xFF, FLAGS=(w[0] >> 8) & 0xFF,
            IMG_W=w[1] & 0xFFFF, IMG_H=(w[1] >> 16) & 0xFFFF,
            C_IN=w[2] & 0xFFFF, C_OUT=(w[2] >> 16) & 0xFFFF,
            GROUP=w[3] & 0xFF, STRIDE=(w[3] >> 8) & 0xF, PAD=(w[3] >> 12) & 0xF,
            SRC2K=(w[3] >> 16) & 0xFFFF,
            SRC_ADDR=w[4], DST_ADDR=w[5], IN_BYTES=w[6],
            QUANT_SHIFT=w[7] & 0xFF, LAYER_ID=(w[7] >> 8) & 0xFF, HASH=hashlib.md5(raw).hexdigest()))
    return out


def chain_runs(items):
    """按 FLAGS[1:0] 扫 `(plain | head middle* tail)*` ⇒ {下标: (run 首下标, run 长)}。

    与 `LayerSched` 的 CHAINSCAN/CHAINSCANW（`rtl/LayerSched.scala:770-790`）同口径：
    `head`(0b00) 起链、`middle`(0b10) 继续、`tail`(0b11) 收链；`plain`(0b01) 自成一段（`chain_len=1`）。
    与冻结校验器 `desc_table.validate` 规则 (5) 同构 ⇒ 合法表里这个扫描不会出错。
    """
    role = {}
    n = len(items)
    i = 0
    while i < n:
        f = items[i]["FLAGS"] & 3
        if f == 1:                       # plain：chain_len = 1
            role[i] = (i, 1)
            i += 1
            continue
        if f == 3:                       # tail without predecessor（表非法；此处不吞错）
            role[i] = (i, 1)
            i += 1
            continue
        j = i
        while j < n and (items[j]["FLAGS"] & 3) in (0, 2):
            j += 1
        if j >= n or (items[j]["FLAGS"] & 3) != 3:
            raise SystemExit("FATAL: head without tail @%d（表非法；先跑 desc_table.validate）" % i)
        L = j - i + 1
        for t in range(i, j + 1):
            role[t] = (i, L)
        i = j + 1
    return role


# ===========================================================================
# 2) UnitExec（conv 类）—— 逐条判据（每条都注明 RTL 行）
# ===========================================================================
def unit_exec(d, chain_len, xdma, blob):
    """返回 (ok, path|None, reason, derived)。`d` = 描述符字典；`chain_len` = 本次 `go` 看到的链长。"""
    tpe, iw, ih = d["TYPE"], d["IMG_W"], d["IMG_H"]
    cin, cout, grp, s_raw = d["C_IN"], d["C_OUT"], d["GROUP"], d["STRIDE"]
    R = {}
    # --- C4b-D1：步长 / 输入几何（UnitExec.scala:717-724）---
    s = s_raw if s_raw != 0 else 1                       # :717 strideEff（0 视作 1）
    in_rows = ih * s                                     # :719 `inRows = IMG_H·s`
    in_w_max = iw * s                                    # :724 `inWMax = IMG_W·s`
    in_w_ok = 1 <= in_w_max <= WIDTH                     # :742 `inWOk`
    stride_chain_ok = (s == 1) or (chain_len == 1)       # :745 `strideChainOk`
    # --- 窄/宽分派（UnitExec.scala:1384-1395）---
    narrow = (cin == C) and (cout == C) and (grp == GROUP) and (tpe != 0x03)
    is_wide = not narrow                                 # :1395
    # --- 装载器（UnitExec.scala:937-966, 1451）---
    cg = cin if grp == 1 else 1                          # :937 `cgW`
    grp_ok_w = (grp == 1) or (grp == cin == cout)        # :939 `grpOkW`
    wgt_wide_len = cout * cg * 9                         # :943 `wgtWideLen = C_out·(C_in/GROUP)·9`
    wgt_wide_rd = ((wgt_wide_len + 31) >> 5) << 5         # :948 `wgtWideRdLen = ceil32(N_i)`
    n_ci = (cin + 7) >> 3                                # :952
    n_co = (cout + 7) >> 3                               # :956
    dma_geom_ok = (cin == C) and (cout == C) and (grp == GROUP) and (tpe != 0x03)   # :962
    # `dmaWinOkW`（:966）= "段尾不越 28 bit DDR 窗"：`wgt_dma_addr + ceil32(N_i) <= 2^28`。
    # 这里只判"段长本身"（`wgt_dma_addr` 由主机编程：真帧的 blob 基址远小于 2^28、
    # 段偏移是各层 `N_i` 的累加和，实测 blob 总量 ~404 KB）⇒ 越窗不可能发生；判据保留为
    # "段长 <= DDR 窗"，**不**假装知道 `wgt_dma_addr` 的具体值。
    wgt_load_ok = (grp_ok_w and cin != 0 and cout != 0 and wgt_wide_len != 0 and
                   chain_len == 1 and wgt_wide_rd <= DDR_BYTES)                     # :1451
    # --- 计算侧几何（UnitExec.scala:1417-1429）---
    pix_per = ih * iw                                    # :1417
    in_pix = in_rows * in_w_max                          # :1425（`rowWUse = inWMax`）
    wide_geom_ok = (cout != 0 and n_co <= NCOB_MAX and in_w_ok and d["LAYER_ID"] < PN_LAYERS and
                    chain_len == 1 and pix_per % 8 == 0)                        # :1426
    # --- tile 判据（UnitExec.scala:870/913-914/1235-1237/1650）---
    tiling_shape_ok = (cin == C) and (cout == C) and (grp == GROUP) and (tpe != 0x03)  # :870
    tiling_s = s in (1, 2)                               # :1235
    tiling_ok_c = (tiling_shape_ok and tiling_s and chain_len == 1 and iw % 4 == 0 and
                   iw != 0 and ih != 0)                                        # :1236
    is_head = (d["FLAGS"] & 1) == 0                      # :1122 `isHead = dw.head`（OUT_TO_DDR==0）
    tiling_wide_c = (is_wide and chain_len == 1 and not is_head and tiling_s and
                     cout != 0 and n_co <= NCOB_MAX and d["LAYER_ID"] < PN_LAYERS and
                     pix_per % 8 == 0 and iw != 0 and ih != 0 and xdma)          # :1650
    # --- 通用对账（UnitExec.scala:819/1140/1221）---
    chain_ok = (chain_len != 0 and chain_len <= L_MAX and (d["FLAGS"] >> 2) == 0 and stride_chain_ok)
    lid_ok = d["LAYER_ID"] < PN_LAYERS                   # :819
    q_shift_ok = d["QUANT_SHIFT"] == SHIFT               # :1221（本网表 SHIFT=6）
    R.update(s=s, in_rows=in_rows, inWMax=in_w_max, inWOk=in_w_ok, narrow=narrow, isWide=is_wide,
             nCi=n_ci, nCo=n_co, pixPer=pix_per, inPix=in_pix, wideGeomOk=wide_geom_ok,
             wgtLoadOk=wgt_load_ok, tilingOkC=tiling_ok_c, tilingWideC=tiling_wide_c,
             chainLen=chain_len, isHead=is_head, grpOkW=grp_ok_w, dmaGeomOk=dma_geom_ok,
             wgtWideLen=wgt_wide_len, qShiftOk=q_shift_ok, chainOk=chain_ok, lidOk=lid_ok)

    # --- 路由（UnitExec.scala:1957-2038 的 FSM；顺序逐条照抄）---
    if not (q_shift_ok and chain_ok and lid_ok):
        why = ("qShiftOk" if not q_shift_ok else ("chainOk" if not chain_ok else "lidOk"))
        return False, None, "dispatch: %s" % why, R
    if TILING and tiling_wide_c:                                    # :1982
        if blob:
            if not wgt_load_ok:
                return False, None, "wide-tile: wgtLoadOk（:1989）", R
            # ★ T-S3d 缺陷修-①（`UnitExec.scala:2079` 的 WGTRUN 收工那一拍）：err 条件是
            #   `wlWideR(=dmaWide) && !wideGeomOk && !tilingW` —— 本分支 `tilingW=1` ⇒ **豁免**
            #   （"整层行宽 ≤ W_MAX"正是 tile 绕开的前提）⇒ 本分支**不再有** WGTRUN-end 检查。
        return True, "wide-tile", "", R
    if TILING and tiling_ok_c:                                      # :1993
        if blob:
            if not (dma_geom_ok and wgt_wide_rd <= DDR_BYTES):
                return False, None, "narrow-tile: dmaGeomOk/dmaWinOk（:2004）", R
            # ★ :2079 的 err 条件是 `wlWideR && ...`；窄层 `isWide=false` ⇒ `wlWideR=0` ⇒
            #   该条对本分支**恒不成立**（旧稿在此处的 `!wideGeomOk` 是对 RTL 的过严镜像，按 T-S3d 校正）。
        return True, "narrow-tile", "", R
    if blob:                                                        # :2008 `elsewhen(dmaEn)`
        if is_wide:
            if wgt_load_ok:                                         # :2021
                if not wide_geom_ok:                                # WGTRUN-end（:2079）
                    return False, None, "wide-whole: WGTRUN-end wideGeomOk（:2079）", R
                return True, "wide-whole", "", R
            return False, None, "wide-whole: wgtLoadOk(chain_len==1, :1451)", R
        if dma_geom_ok and wgt_wide_rd <= DDR_BYTES and in_w_ok:     # :2023
            return True, "narrow-whole", "", R
        return False, None, "narrow-whole: dmaGeomOk∧dmaWinOk∧inWOk（:2023）", R
    if is_wide:                                                     # :2025 `elsewhen(isWide)`
        if wide_geom_ok and ((not xdma) or (in_pix % 32 == 0)):       # :2030
            return True, "wide-whole", "", R
        return False, None, "wide-whole: wideGeomOk∧(!xDMA∨inPix%32==0)（:2030）", R
    if in_w_ok:                                                     # :2036
        return True, "narrow-whole", "", R
    return False, None, "narrow-whole: inWOk（:2036）", R


# ===========================================================================
# 3) BypassExec（旁路类）—— 逐条判据（每条都注明 RTL 行）
# ===========================================================================
def bypass_exec(d, src_planar, dst_planar):
    tpe, iw, ih = d["TYPE"], d["IMG_W"], d["IMG_H"]
    cin, cout = d["C_IN"], d["C_OUT"]
    is_pool = tpe == 0x10
    is_rz = tpe == 0x11
    is_add = tpe == 0x13
    is_sg = tpe == 0x14
    add_two_src = is_add and d["SRC2K"] != 0                        # :455
    R = {}
    # --- 几何反推（BypassExec.scala:460-464）---
    in_w = (iw + iw) if is_pool else ((iw >> 1) if is_rz else iw)   # :463
    in_h = (ih + ih) if is_pool else ((ih >> 1) if is_rz else ih)   # :464
    # --- C_in=1 逐点折（:490-500）---
    fold_pt = ((is_sg or add_two_src) and cin == 1 and cout == 1 and iw % 8 == 0)   # :490
    iw_e = (iw >> 3) if fold_pt else iw                             # :493
    ih_e = ih                                                       # :494
    in_w_e = (iw_e + iw_e) if is_pool else ((iw_e >> 1) if is_rz else iw_e)   # :496
    in_h_e = (ih_e + ih_e) if is_pool else ((ih_e >> 1) if is_rz else ih_e)   # :497
    tot_eff = iw_e * ih_e                                           # :499
    fpix = (((tot_eff + 3) >> 2) << 2)                              # :500（上取整到 4 的倍数）
    # --- 运行期行宽 / 输出像素（:516-533）---
    row_w = in_w_e                                                  # :516
    row_w_par_ok = (not is_pool) or (row_w % 2 == 0)                # :519
    row_w_ok = (row_w != 0 and (row_w <= WIDTH if (is_pool or is_rz) else True)
                and row_w_par_ok)                                   # :521
    out_pix = fpix if fold_pt else tot_eff                          # :525
    in_cols = fpix if fold_pt else (in_w_e * in_h_e)                # :527
    in_beats = in_cols if add_two_src else ((in_cols + in_cols) if is_add else in_cols)  # :530
    rd_len = in_beats * C                                           # :532
    wr_len = out_pix * C                                            # :533
    # --- 通道维（:549-552）---
    c_blk_ok = (cin == cout) and cin != 0 and (fold_pt or cin % 8 == 0)   # :549
    n_blk = 1 if fold_pt else (cin >> 3)                            # :552
    # --- 响亮对账（:558-564）---
    geom_ok = (row_w_ok and in_h_e != 0 and out_pix != 0 and c_blk_ok and
               ((not is_rz) or (iw % 2 == 0 and ih % 2 == 0)) and
               out_pix <= MAXPIX_BE and
               rd_len % 32 == 0 and rd_len != 0 and wr_len % 32 == 0 and wr_len != 0)
    # --- 布局维（:566-588）---
    src_pl = bool(src_planar) and not fold_pt                       # :566
    dst_pl = bool(dst_planar) and not fold_pt                       # :567
    planar_ok = ((not src_pl or in_cols % 32 == 0) and
                 (not dst_pl or out_pix % 32 == 0) and
                 (not (src_pl or dst_pl) or not is_add))            # :573
    blk_planar_ok = (n_blk == 1) or (src_planar and dst_planar)     # :580
    blk_phase_ok = (n_blk == 1) or (in_h_e % 2 == 0)                # :588
    # --- tile 判据（:393-395, 605-612）---
    #   ★★ T-S3e（2026-10-16）：原 `tileAliOk`（`inCols % 32 == 0`，旧 :607）**已从 RTL 去掉**
    #      （per-plane band：band 相位改为**每平面各算自己的**）⇒ 本镜像同步删除该项
    #      （`Resize_43` 的 40×40 在 T-S3e 已被逐字节证明可跑）。
    tile_op_ok = is_pool or is_rz or (is_add and add_two_src)       # :605
    tile_pl_ok = bool(src_planar) and bool(dst_planar)              # :606
    tile_rz_ok = (not is_rz) or (iw % 2 == 0 and ih % 4 == 0)       # :608
    tile_g0_ok = in_h_e != 0 and out_pix != 0                       # :609
    tile_ok = (_tileConstOk and c_blk_ok and blk_planar_ok and tile_op_ok and tile_pl_ok and
               tile_rz_ok and tile_g0_ok and not fold_pt)                   # :610
    whole_ok = geom_ok and planar_ok and blk_planar_ok and blk_phase_ok          # :614
    R.update(inW=in_w, inH=in_h, inWEff=in_w_e, inHEff=in_h_e, rowW=row_w, rowWOk=row_w_ok,
             outPix=out_pix, inCols=in_cols, nBlk=n_blk, cBlkOk=c_blk_ok, geomOk=geom_ok,
             planarOk=planar_ok, blkPlanarOk=blk_planar_ok, blkPhaseOk=blk_phase_ok,
             tileOk=tile_ok, wholeOk=whole_ok, foldPt=fold_pt, srcPlanar=src_pl, dstPlanar=dst_pl,
             rdLen=rd_len, wrLen=wr_len)

    # --- 路由（BypassExec.scala:1051-1064）---
    if whole_ok:
        return True, ("fold" if fold_pt else "bypass-whole"), "", R
    if tile_ok:
        return True, "bypass-tile", "", R
    why = []
    if not geom_ok:
        sub = []
        if not row_w_ok: sub.append("rowWOk(%d>WIDTH)" % row_w if row_w > WIDTH else "rowWOk")
        if in_h_e == 0: sub.append("inH!=0")
        if out_pix == 0: sub.append("outPix!=0")
        if not c_blk_ok: sub.append("cBlkOk(cIn=%d,cOut=%d)" % (cin, cout))
        if is_rz and not (iw % 2 == 0 and ih % 2 == 0): sub.append("resize-even")
        if out_pix > MAXPIX_BE: sub.append("outPix(%d)>MAXPIX(%d)" % (out_pix, MAXPIX_BE))
        if rd_len % 32 or rd_len == 0: sub.append("rdLen%32")
        if wr_len % 32 or wr_len == 0: sub.append("wrLen%32")
        why.append("geomOk（:558）：" + "+".join(sub or ["?"]))
    if not planar_ok:
        sub = []
        if src_pl and in_cols % 32: sub.append("inCols(%d)%%32!=0" % in_cols)
        if dst_pl and out_pix % 32: sub.append("outPix(%d)%%32!=0" % out_pix)
        if (src_pl or dst_pl) and is_add: sub.append("planar+Add")
        why.append("planarOk（:573）：" + "+".join(sub or ["?"]))
    if not blk_planar_ok:
        why.append("blkPlanarOk（:580，nBlk=%d 需平面通路）" % n_blk)
    if not blk_phase_ok:
        why.append("blkPhaseOk（:588，inH=%d 需偶）" % in_h_e)
    if not tile_ok:
        sub = []
        if not _tileConstOk: sub.append("tileConstOk")
        if not c_blk_ok: sub.append("cBlkOk")
        if not blk_planar_ok: sub.append("blkPlanarOk")
        if not tile_op_ok: sub.append("tileOpOk")
        if not tile_pl_ok: sub.append("tilePlOk")
        if not tile_rz_ok: sub.append("tileRzOk（:644，IMG_W%%2=%d IMG_H%%4=%d）" % (iw % 2, ih % 4))
        if not tile_g0_ok: sub.append("tileG0Ok")
        if fold_pt: sub.append("foldPt")
        why.append("tileOk（:646）：" + "+".join(sub or ["?"]))
    return False, None, " + ".join(why), R


# ===========================================================================
# 4) 布局位推导（--layout derived）：按冻结契约从表的 SRC/DST 图推（见文件头）
# ===========================================================================
def derive_layout(items):
    payload = items[:-1] if items and items[-1]["TYPE"] == 0xFF else items

    def producer(d):
        for p in payload:
            if p is d:
                continue
            if p["DST_ADDR"] == d["SRC_ADDR"] and p["DST_ADDR"] != 0:
                return p
        return None

    def consumers(d):
        """读 `d` 的 DST 张量的条目（含 E1 的 `Add` 第二路源：`SRC2_ADDR = DST_ADDR[idx-k]`）。"""
        out = []
        for c in payload:
            if c is d:
                continue
            if c["SRC_ADDR"] == d["DST_ADDR"] and d["DST_ADDR"] != 0:
                out.append(c)
            elif c["SRC2K"] and c["idx"] - c["SRC2K"] >= 0:
                k = c["idx"] - c["SRC2K"]
                if k < len(payload) and payload[k]["DST_ADDR"] == d["DST_ADDR"] and d["DST_ADDR"] != 0:
                    out.append(c)
        return out

    bits = {}
    for d in payload:
        p = producer(d)
        # 源张量的生产者为 conv（通道平面）或源是网络输入（B3：主机按平面摆放）⇒ src_planar=1
        sp = 1 if (p is None or p["TYPE"] in CONV_TYPES) else 0
        # 目标张量被 conv 消费（直接，或经 `Add` 的第二路再喂给 conv）⇒ dst_planar=1
        cs = consumers(d)
        dp = 1 if any(c["TYPE"] in CONV_TYPES for c in cs) else 0
        if not dp:
            for c in cs:                       # 间接：本张量是 Add 的第二路，而 Add 的输出喂 conv
                if c["TYPE"] == 0x13 and any(x["TYPE"] in CONV_TYPES for x in consumers(c)):
                    dp = 1
                    break
        bits[d["idx"]] = (sp, dp)
    return bits


# ===========================================================================
# 5) 主流程
# ===========================================================================
def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--desc", default=DESC_DEFAULT)
    ap.add_argument("--xdma", type=int, default=1, help="XDMA_EN（默认 1；真帧必须 1）")
    ap.add_argument("--blob", type=int, default=0, help="WGT_BLOB_BASE!=0 ⇒ dmaEn（默认 0 = 既有闸门口径）")
    ap.add_argument("--unit-flags", choices=("plain", "own"), default="plain",
                    help="UNIT 口径：把单元当 plain 单单元（默认）还是用它自己的 FLAGS")
    ap.add_argument("--layout", choices=("derived", "zero"), default="derived")
    ap.add_argument("--inject", action="append", default=[],
                    help="负对照：`idx,IMG_W,+1` / `idx,IMG_H,-1` / `idx,C_IN,*2` …（可多次）")
    ap.add_argument("--quiet", action="store_true", help="只打 ERR 行（默认全打）")
    a = ap.parse_args(argv)

    if not os.path.isfile(a.desc):
        print("FATAL: 找不到描述符表 %s" % a.desc)
        print("RESULT: FAIL")
        return 3
    items = read_desc(a.desc)
    if len(items) < 2 or items[-1]["TYPE"] != 0xFF:
        print("FATAL: %s 的表尾不是哨兵（末项 TYPE=0x%02X）" % (a.desc, items[-1]["TYPE"]))
        print("RESULT: FAIL")
        return 3
    payload = items[:-1]

    # ---- 负对照注入（作用于副本；只改字段，不改表文件）----
    if a.inject:
        for spec in a.inject:
            f = spec.split(",")
            if len(f) != 3:
                raise SystemExit("FATAL: --inject 形式 = idx,FIELD,expr（收到 %r）" % spec)
            i, field, expr = int(f[0]), f[1], f[2]
            if field not in ("IMG_W", "IMG_H", "C_IN", "C_OUT", "GROUP", "STRIDE", "LAYER_ID"):
                raise SystemExit("FATAL: --inject 不认识的字段 %s" % field)
            v = payload[i][field]
            payload[i][field] = int(eval("%d %s" % (v, expr)))     # expr 形如 "+1" / "*2"
            print("INJECT unit=%d %s %d -> %d" % (i, field, v, payload[i][field]))

    runs = chain_runs(payload)
    layout = derive_layout(payload) if a.layout == "derived" else {d["idx"]: (0, 0) for d in payload}
    xdma, blob = bool(a.xdma), bool(a.blob)

    rows = []
    err_unit = []
    err_disp = []
    for d in payload:
        i = d["idx"]
        run_head, run_len = runs[i]
        # ---- UNIT 口径（`chain_len = 1`；FLAGS 按 `--unit-flags`；编程按 `--xdma/--blob`）----
        du = dict(d)
        if a.unit_flags == "plain":
            du["FLAGS"] = 0x01                     # = 既有宽/旁路闸门每个作业的 `+FLAGS=1`
        if du["TYPE"] in CONV_TYPES:
            ok, path, why, r = unit_exec(du, 1, xdma, blob)
        else:
            sp, dp = layout.get(i, (0, 0))
            ok, path, why, r = bypass_exec(du, sp, dp)
        # ---- DISPATCH 口径（忠实派发：链塌缩 ⇒ `chain_len` = run 长；编程 = 真帧驱动）----
        hd = payload[run_head]
        if d["TYPE"] in CONV_TYPES:
            ok2, path2, why2, _ = unit_exec(hd, run_len, True, True)     # XDMA_EN=1 + blob=1
        else:
            sp, dp = layout.get(i, (0, 0))
            ok2, path2, why2, _ = bypass_exec(d, sp, dp)                 # 旁路恒 plain（chain_len=1）
        rows.append((i, d, run_head, run_len, r, (ok, path, why), (ok2, path2, why2)))
        if not ok:
            err_unit.append((i, why))
        if not ok2:
            err_disp.append((i, run_head, run_len, why2))

    # ---- 打印 ----
    md5 = items[0]["HASH"] if items else "-"
    print("frame_preflight —— 整表几何预检（spec §4-C 判据 C 的 Python 快门）")
    print("  table = %s" % os.path.abspath(a.desc))
    print("  md5=%s  payload=%d  sentinel@%d（+1 = %d 条）" % (md5, len(payload), len(payload),
                                                              len(items)))
    print("  网表参数 C=%d WIDTH=%d IMG_H_MAX=%d L_MAX=%d TILING=%s MAXPIX=%d"
          % (C, WIDTH, IMG_H_MAX, L_MAX, TILING, MAXPIX_BE))
    print("  运行时开关（UNIT 口径）XDMA_EN=%d dmaEn(blob)=%d unit_flags=%s layout=%s"
          % (a.xdma, a.blob, a.unit_flags, a.layout))
    print("  运行时开关（DISPATCH 口径）XDMA_EN=1 dmaEn(blob)=1（= 真帧驱动 tools/npu_frame_run.py）")
    print()
    print("  %-3s %-12s %-9s %-13s %-7s  %-12s %s"
          % ("idx", "type", "chain", "shape(WxHxCin>Cout)", "flags", "UNIT path", "verdict"))
    for (i, d, rh, rl, r, pos, dis) in rows:
        ok, path, why = pos
        shape = "%dx%d:%d>%d" % (d["IMG_W"], d["IMG_H"], d["C_IN"], d["C_OUT"])
        ch = ("plain" if rl == 1 else "run@%d L=%d" % (rh, rl))
        line = "  %-3d %-9s %-13s %-16s %-7s %-12s %s" % (
            i, TYPE_NAME.get(d["TYPE"], "?"), ch, shape, "0b%02d" % int(bin(d["FLAGS"])[2:]),
            path or "-", "OK" if ok else "ERR(%s)" % why)
        if (not ok) or (not a.quiet):
            print(line)
    print()
    # ---- DISPATCH 口径的开口项（真派发：链塌缩 ⇒ chain_len = run 长）----
    print("== DISPATCH 口径（忠实派发：LayerSched 把 run 塌缩成一次 go，chain_len = run 长）==")
    if not err_disp:
        print("  DISPATCH_ERR=0（每个 run 的链首都走得出合法通路）")
    else:
        seen = set()
        for (i, rh, rl, why) in err_disp:
            k = (rh, rl, why)
            if k in seen:
                continue
            seen.add(k)
            print("  run@%-3d L=%-2d 单元 %d..%d -> ERR(%s)" % (rh, rl, rh, rh + rl - 1, why))
        print("  DISPATCH_ERR=%d / %d 条载荷（run 内的 middle/tail 与链首同判）"
              % (len(err_disp), len(payload)))
    print()
    print("PREFLIGHT_ERR=%d" % len(err_unit))
    print("PREFLIGHT_ERR_UNITS=%s" % ("none" if not err_unit else
                                      ",".join(str(i) for (i, _w) in err_unit)))
    for (i, why) in err_unit:
        print("  PREFLIGHT_ERR_DETAIL unit=%d (%s) -> %s" % (i, TYPE_NAME.get(payload[i]["TYPE"], "?"), why))
    print("DISPATCH_ERR=%d" % len(err_disp))
    print("DISPATCH_ERR_RUNS=%s" % ("none" if not err_disp else
                                    ",".join(str(rh) for rh in sorted(set(rh for (_i, rh, _l, _w) in err_disp)))))
    print("RESULT: %s" % ("PASS" if not err_unit else "FAIL"))
    return 0 if not err_unit else 1


if __name__ == "__main__":
    sys.exit(main())
