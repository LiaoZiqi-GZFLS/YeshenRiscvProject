#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""★★ 参考 #2（additional reference）：**异型宽链**（真表 run = `head middle* tail`，逐片
`C_IN/C_OUT/GROUP` 不同）的逐字节黄金 —— 逐片串联口径。

本文件是 T-S3f/B1 的收口件：**显式声明的第 2 条参考**，不是第三条独立实现。理由逐条如下。

为什么**复用**不了冻结的链参考（`conv_unit_ref.py` 的 `chain_l`/`pair_two_stage`/`sched_chain`）
------------------------------------------------------------------------------------------------
1. 那些函数的链口径是"**单一 `(C_IN, C_OUT)` 贯穿全链**"（每段 `mac_ref.conv_core(1, CIN, COUT, ...)`
   用同一对通道数）；真表的 run 是**异型**（如 `Conv_6 16→16 → Conv_9 16→32`，下一片的输入通道
   数 = 上一片的输出通道数）⇒ 冻结函数在链第 2 片起**无定义**。实测（`reports/ts3f_red_first.txt` 附A）：
   `chain_l(CIN=64 COUT=10 L=2)` ⇒ `IndexError`（REFUSE）。
2. 冻结链参考没有 depthwise/GROUP 档、没有**逐片** requant 参数（M/z_pad/z_y/bias_adj 逐 LAYER_ID）、
   没有 1×1 核的 blob 布局（9 抽头补位）—— 这些正是真表 run 的构成。
⇒ 按项目规则（黄金复用、不写第三条参考；departure 必须**点名并给出理由**），本工具被**命名**为
   **参考 #2**，定位 = 冻结参考的**严格扩展**（同型特例逐字节退化成冻结 #1，见 `--selftest` L1）。

本工具的口径（**逐片**，与硬件宽通路逐片一致）
--------------------------------------------------------------------------------
每个成员（一次 `go`）的字节精确输出 = 冻结整层原语 `tiling_ref.conv_tiled`（= `MultiPassUnit` 的
趟分解，与 `quant_ref.conv_vec`/`conv_acc_whole` 由冻结恒等式 (a) 交叉钉死），参数**逐片**取：
  · 权重 = `gen/wgt_blob.bin` 的**本片段**（`wgt_index.json` 的 `offset/nbytes`，冻结的密集
    `[co][ci/G][tap]` 布局，`tap = ky*3+kx`；1×1 核的其余 8 抽头为 0）；
  · `s_x/z_pad/z_w/s_y_eff/z_y/bias_adj` = `wgt_index.json` 的 `centering[layer_id]`（= 硬件经
    信箱区域 2/3/4/5 收到的**同一批记录**）；
  · `M` = `requant_mult[layer_id]["M"]`（= `wgt_mult.bin` 里硬件真正收到的字）；并**断言**
    冻结口径 `scale_ratio_multiplier(s_x·s_w/s_y_eff)` == 该记录值（两条独立推导必须相等）。
链 = 逐片串联：`x_{k+1} = member_k(x_k)`；链的最终字节 = 末片输出（中间张量在硬件上落片上，
数值上与逐个落 DDR 相同 —— 这一点由 L1 的对账顺带钉死）。

★★ 与冻结 #1（`reports/c4a_ref_layers.json` + `gen/c4a_ref/*.npy`，G2/G3/G4 黄金）的**校准关系**
（`--selftest` 的 L2 逐条**实测断言**，不是声明）：
  · **3×3 / depthwise 成员且 `folded_ops == []`**：本工具的整层输出与冻结逐层张量**逐字节相等**
    （identity 关系）。已测：`Conv_7`（dw 16ch 160×160）409600/409600。
  · **1×1 成员**（blob 抽头落 `(ky,kx)=(0,0)`，desc `PAD=0`；硬件 3×3/pad-1 的固定锚点 ⇒
    读 `x(i-1,j-1)`）：本工具输出 == 冻结张量的 **(+1,+1) 相位平移**（`A[i,j] == F[i-1,j-1]`）。
    已测：`Conv_6` 404496/404496（= 全内点）。这是**硬件的 pad-0 折进口径**（真帧由驱动/表侧
    的地址折进补偿，见 `y1_convert.py` 的 H1 折进 + B4 布局折进；本工具只**如实记录并断言**
    这一关系，不自行折进）。★ 开口项：真帧"补偿落点"在实现片需要对账（见报告 §开口项）。
  · **`folded_ops != []` 成员**（Relu 折进 ⇒ 硬件用**单趟** eff 刻度 `s_y_eff/z_y_eff`）：本工具输出
    与冻结**两步**张量**本就不等**（已测 `Conv_7` 折进口径 80477/409600）——这是转换器/硬件
    的**刻意口径**（§4.4/§4.5 单趟 requant），不是本工具的误差；`--selftest` 把这一档**计数并打印**，
    并断言"本工具 == 记录口径"（即 M/z_y 逐条来自记录）。
  · 因此本工具**不是**"自己比自己"：它在 `folded_ops==[]` 的全部成员上被冻结 #1 逐字节钉死；
    在折进成员上其口径 = 硬件收到的记录（信箱投递的同一批数）。

用法
----
    PYTHONPATH='./.pydeps;../third_party/yunet/deps' <py3.9> tools/chain_wide_ref.py \
        --selftest [--gen gen] [--ref reports/c4a_ref_layers.json]
    tools/chain_wide_ref.py --calib                 # 19 条 run 的几何/段长/偏移标定表
    tools/chain_wide_ref.py --run 4 11 [--seed S]   # 逐片串联黄金（自造输入）
    tools/chain_wide_ref.py --all-runs [--seed S]   # 全部 19 条 run 的链黄金（md5 表）
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import tiling_ref as T          # 冻结（只读复用）
import quant_ref as Q           # 冻结（只读复用：M 口径交叉验证）
import desc_table as DT         # 冻结（只读复用：unpack，8 字线格式单一真源）

TOOLS = _HERE
Y1 = os.path.dirname(_HERE)


def md5_bytes(b):
    return hashlib.md5(bytes(b)).hexdigest()


class Artifacts(object):
    """真表产物（只读）：desc.bin / wgt_index.json / wgt_blob.bin / 冻结 #1 的层黄金。"""

    def __init__(self, gen_dir, ref_json):
        self.gen = gen_dir
        self.g = json.load(open(os.path.join(gen_dir, "wgt_index.json"), encoding="utf-8"))
        self.units = self.g["units"]
        raw = open(os.path.join(gen_dir, "desc.bin"), "rb").read()
        self.desc = [DT.unpack(raw[i * 32:(i + 1) * 32]) for i in range(len(raw) // 32)]
        self.blob = open(os.path.join(gen_dir, "wgt_blob.bin"), "rb").read()
        self.cent = {e["layer_id"]: e for e in self.g["centering"]}
        self.rq = {e["layer_id"]: e for e in self.g["requant_mult"]}
        self.ref = None
        self.lay = None
        self.npy = {}
        if ref_json and os.path.isfile(ref_json):
            self.ref = json.load(open(ref_json, encoding="utf-8"))
            self.lay = {e["tensor"]: e for e in self.ref["layers"]}
            d = os.path.join(gen_dir, "c4a_ref")
            if os.path.isdir(d):
                for fn in os.listdir(d):
                    if fn.endswith(".npy"):
                        self.npy[fn[:-4].split("_", 2)[2]] = os.path.join(d, fn)

    def frozen_tensor(self, tensor):
        return np.load(self.npy[tensor])

    def frozen_md5(self, tensor):
        return self.lay[tensor]["md5"] if tensor in self.lay else None


def runs_of(units):
    """真表 run = 极大 `head middle* tail`（按 FLAGS：0=head/2=middle/3=tail；1=plain 不在链上）。"""
    runs = []
    i = 0
    while i < len(units):
        if units[i]["flags"] == 0:
            j = i
            while j + 1 < len(units) and units[j + 1]["flags"] in (2, 3):
                j += 1
            runs.append((i, j))
            i = j + 1
        else:
            i += 1
    return runs


def n_i_of(own):
    """冻结段长公式 `N_i = C_out*(C_in/GROUP)*9`（真实字节数）。"""
    return int(own["C_OUT"]) * (int(own["C_IN"]) // int(own["GROUP"])) * 9


def ceil32(n):
    return (int(n) + 31) // 32 * 32


def member_params(A, idx):
    """逐片参数（硬件口径）：权重段 + centering 记录 + M 记录 + 段长/基址。"""
    u = A.units[idx]
    d = A.desc[idx]
    own = u["own"]
    w = u["weight"]
    c = A.cent[u["layer_id"]]
    rq = A.rq[u["layer_id"]]
    co, ci, g = int(own["C_OUT"]), int(own["C_IN"]), int(own["GROUP"])
    shape = w["shape"]
    is1x1 = (len(shape) == 4 and int(shape[2]) * int(shape[3]) == 1)
    wq = np.frombuffer(A.blob[w["offset"]:w["offset"] + w["nbytes"]], dtype=np.int8)
    wq = wq.reshape(co, ci // g, 3, 3).copy()
    biasp = np.asarray(c["bias_round"], dtype=np.float64) * (c["s_x"] * c["s_w"])
    return {
        "idx": idx, "name": u["name"], "own": own, "desc": d,
        "CO": co, "CI": ci, "G": g, "wq": wq, "is1x1": is1x1,
        "folded": bool(u.get("folded_ops")),
        "sx": float(c["s_x"]), "sw": float(c["s_w"]), "sy_eff": float(c["s_y_eff"]),
        "z_pad": int(c["z_pad"]), "zw": int(c["z_w"]), "zy": int(c["z_y_eff"]),
        "zy_own": int(c["z_y"]), "sy_own": float(c["s_y"]),
        "biasp": biasp, "bias_round": c["bias_round"], "syms": c.get("sum_w_q_all_taps"),
        "M_rec": int(rq["M"]), "M2": int(rq["M_two_step"]),
        "n_i": int(w["nbytes"]), "n_i_al": int(w["aligned_bytes"]), "off": int(w["offset"]),
        "in_tensor": u.get("in_tensor"), "out_tensor": u.get("out_tensor"),
        "out_eff": u.get("out_eff_tensor"),
    }


def member_hw_out(x, mp):
    """本片在**硬件口径**下的整层输出（含 eff 刻度折进的 M/z_y）。
    `x`: (1, CI, H, W) 码点（int64）。返回 (out[1,CO,H,W] int8, M, acc)。"""
    wd = {"q": mp["wq"], "scale": mp["sw"], "zp": mp["zw"]}
    out, acc, _parts, M = T.conv_tiled(
        x, wd, mp["sx"], mp["sy_eff"], mp["zw"], mp["z_pad"], mp["biasp"],
        [1, 1, 1, 1], [1, 1], mp["G"], mp["zy"])
    return out, M, acc


def member_unfold_out(x, mp):
    """本片在**未折进**口径下的输出（本片输出张量自己的 s_y/z_y）—— 与冻结 #1 的逐层单算子
    张量（`out_tensor`）对账用（`folded_ops == []` 时两口径相同）。"""
    wd = {"q": mp["wq"], "scale": mp["sw"], "zp": mp["zw"]}
    out, acc, _parts, M = T.conv_tiled(
        x, wd, mp["sx"], mp["sy_own"], mp["zw"], mp["z_pad"], mp["biasp"],
        [1, 1, 1, 1], [1, 1], mp["G"], mp["zy_own"])
    return out, M, acc


def run_golden(A, i, j, x0, calib="hw"):
    """逐片串联：返回 (mids, final, mps)。`x0`: (1,CI,H,W)。mid/final 均为 (1,CO,H,W) int8。"""
    x = x0
    mids = []
    mps = []
    for k in range(i, j + 1):
        mp = member_params(A, k)
        if mp["desc"]["STRIDE"] != 1:
            raise SystemExit("REFUSE: run 成员 %s STRIDE=%d != 1（本参考只覆盖 s=1 的 run）"
                             % (mp["name"], mp["desc"]["STRIDE"]))
        out, M, _acc = member_hw_out(x, mp) if calib == "hw" else member_unfold_out(x, mp)
        if M != mp["M_rec"]:
            raise SystemExit("FATAL: %s 的冻结口径 M=%d != 记录 M=%d" % (mp["name"], M, mp["M_rec"]))
        mps.append(mp)
        if k < j:
            mids.append(out)
        x = out
    return mids, x, mps


# ===========================================================================
# 标定自检（L1 同型特例 == 冻结 #1 链参考；L2 真表成员 == 冻结 #1 逐层黄金；L3 折进口径）
# ===========================================================================
def selftest(A, verbose=True):
    fails = []

    def chk(cond, msg):
        if not cond:
            fails.append(msg)
        if verbose:
            print(("  OK   " if cond else "  FAIL ") + msg)

    print("---- L0) 真表自身的结构/记账断言（19 run，逐片）----")
    runs = runs_of(A.units)
    chk(len(runs) == 19, "run 数 = 19（实得 %d）" % len(runs))
    cum_off = 0
    ok_mono = True
    ok_al = True
    ok_geom = True
    for u in A.units:
        w = u.get("weight")
        if w is None:
            continue
        if w["offset"] != cum_off:
            ok_mono = False
        cum_off += w["aligned_bytes"]
        if w["aligned_bytes"] != ceil32(w["nbytes"]):
            ok_al = False
    chk(ok_mono and cum_off == len(A.blob),
        "blob 偏移 = 逐单元 ceil32(N_i) 前缀和，且总和 == blob 字节数（%d）" % len(A.blob))
    chk(ok_al, "每片 aligned_bytes == ceil32(nbytes)（转换器冻结口径）")
    for (i, j) in runs:
        hs = set((A.units[t]["own"]["IMG_H"], A.units[t]["own"]["IMG_W"]) for t in range(i, j + 1))
        cd = [A.units[t]["own"]["C_OUT"] == A.units[t + 1]["own"]["C_IN"] for t in range(i, j)]
        if len(hs) != 1 or not all(cd):
            ok_geom = False
    chk(ok_geom, "19 run 逐片空间几何一致 且 C_OUT(k) == C_IN(k+1)（= 可链）")

    print("---- L1) 同型特例：本工具口径 == 冻结 conv_unit_ref.chain_l / chain_l_naive ----")
    import conv_unit_ref as R
    CIN = COUT = 8
    H, W = 4, 8
    SEED = 20265793
    wt, x_chw, _x_ddr, _y = R.build(CIN, COUT, H, W, seed=SEED, shift=6)
    segs = [wt, R.centre_tap(wt, CIN, COUT), wt, R.centre_tap(wt, CIN, COUT)]
    wts = [R.scale_wt(s, sc) for s, sc in zip(segs, [4, 4, 4, 1])]
    mids_ref, fin_ref = R.chain_l(x_chw, wts, CIN, COUT, H, W, 6)
    # x_chw 是 mac_ref 通道主序 => NCHW
    x = np.asarray(x_chw, dtype=np.int64).reshape(1, CIN, H, W)
    mids, fin, _ = [], None, None
    cur = x
    for k, w_ in enumerate(wts):
        wq = np.asarray(w_, dtype=np.int64).reshape(COUT, CIN, 3, 3).astype(np.int8)
        wd = {"q": wq, "scale": 1.0, "zp": 0}
        # 比率 sx*sw/sy = (1/64) => M = 2^24 => requant == >>6 + clamp（= chain_l 的口径）
        out, _acc, _p, M = T.conv_tiled(cur, wd, 1.0 / 64.0, 1.0, 0, 0, None,
                                        [1, 1, 1, 1], [1, 1], 1, 0)
        if M != (1 << 24):
            fails.append("L1: 本口径 M=%d != 2^24（同型对照失效）" % M)
        nhwc = R.permute_chw_nhwc([int(v) for v in out[0].reshape(-1)], COUT, H, W)
        if k < len(wts) - 1:
            mids.append(nhwc)
            cur = np.asarray(R.unpermute_nhwc_chw(nhwc, COUT, H, W), dtype=np.int64).reshape(1, CIN, H, W)
        else:
            fin = nhwc
    d_mid = [sum(1 for a, b in zip(m, r) if a != b) for m, r in zip(mids, mids_ref)]
    d_fin = sum(1 for a, b in zip(fin, fin_ref) if a != b)
    chk(all(d == 0 for d in d_mid) and d_fin == 0,
        "L=4 同型链：每段中间 + 最终与冻结 chain_l 逐字节相等（diff=%s/%d）" % (d_mid, d_fin))
    # 独立第二实现（朴素 NHWC）也必须一致
    x_ddr = R.permute_chw_nhwc(x_chw, CIN, H, W)
    mids_nai, fin_nai = R.chain_l_naive(x_ddr, wts, CIN, COUT, H, W, 6)
    d2 = sum(1 for a, b in zip(fin, fin_nai) if a != b)
    chk(d2 == 0, "L=4 同型链：最终与冻结 chain_l_naive（第二实现）逐字节相等（diff=%d）" % d2)

    print("---- L2) 真表成员：本工具（硬件口径）vs 冻结 #1 逐层张量（frozen 输入）----")
    n_unfold = 0
    n_fold = 0
    bad = []
    for (i, j) in runs:
        for k in range(i, j + 1):
            mp = member_params(A, k)
            if mp["in_tensor"] not in A.npy:
                bad.append("%s: 缺输入 npy %s" % (mp["name"], mp["in_tensor"]))
                continue
            x = A.frozen_tensor(mp["in_tensor"]).astype(np.int64)
            if mp["folded"]:
                n_fold += 1
                continue                      # L3：折进成员与两步张量本就不等（下面单独计数）
            out, M, _ = member_unfold_out(x, mp)
            if M != mp["M_rec"]:
                bad.append("%s: M 口径不等（%d != %d）" % (mp["name"], M, mp["M_rec"]))
                continue
            F = A.frozen_tensor(mp["out_tensor"])
            A_ = out
            if mp["is1x1"]:
                okc = int(np.count_nonzero(A_[0][:, 1:, 1:] == F[0][:, :-1, :-1]))
                tot = A_[0][:, 1:, 1:].size
                if okc != tot:
                    bad.append("%s: 1x1 相位 (+1,+1) 关系不成立（%d/%d）" % (mp["name"], okc, tot))
            else:
                n_eq = int(np.count_nonzero(A_[0] == F[0]))
                if n_eq != F[0].size:
                    bad.append("%s: 3x3/dw 逐字节不等（%d/%d）" % (mp["name"], n_eq, F[0].size))
            n_unfold += 1
    chk(not bad, "L2: 非折进成员全部与冻结 #1 建立逐字节关系（3x3/dw=identity、1x1=(+1,+1) 相位）"
                 " —— 通过 %d 片%s" % (n_unfold, ("；坏：%s" % bad[:4]) if bad else ""))
    if verbose:
        print("        （折进成员 %d 片按 L3 口径单独记账；非折进 %d 片全部现场比对）" % (n_fold, n_unfold))

    print("---- L3) 折进成员：口径 = 记录（M/z_y 逐条），与两步张量的差异**计数**（不是误差）----")
    n_diff = 0
    n_checked = 0
    for (i, j) in runs:
        for k in range(i, j + 1):
            mp = member_params(A, k)
            if not mp["folded"] or mp["in_tensor"] not in A.npy:
                continue
            x = A.frozen_tensor(mp["in_tensor"]).astype(np.int64)
            out, M, _ = member_hw_out(x, mp)
            if M != mp["M_rec"]:
                fails.append("L3: %s M=%d != 记录 %d" % (mp["name"], M, mp["M_rec"]))
            F2 = A.frozen_tensor(mp["out_eff"])          # 冻结的两步（conv+Relu）张量
            n_checked += 1
            d = int(np.count_nonzero(out[0] != F2[0]))
            if d != 0:
                n_diff += 1
            if verbose:
                print("        %s: 折进口径 vs 两步张量 mism=%d/%d（记录 M=%d / M_two_step=%d）"
                      % (mp["name"], d, F2[0].size, mp["M_rec"], mp["M2"]))
    chk(n_checked > 0 and n_diff > 0,
        "L3: 折进成员 %d 片，其中 %d 片与两步张量有差 —— 该差异已**实测记账**（硬件刻意口径，"
        "不是本参考的误差）" % (n_checked, n_diff))

    print("---- L4) 逐片 bias 恒等式 + z 一致性（全部 53 个消费权重的单元）----")
    ok_b = True
    ok_z = True
    for u in A.units:
        w = u.get("weight")
        if w is None:
            continue
        c = A.cent[u["layer_id"]]
        if int(c["z_pad"]) != int(c["z_x"]):
            ok_z = False
        if c.get("sum_w_q_all_taps") and c.get("bias_round"):
            bad_adj = [(int(br) - int(c["z_x"]) * int(sw))
                       for br, sw in zip(c["bias_round"], c["sum_w_q_all_taps"])]
            if bad_adj != [int(v) for v in c["bias_adj"]]:
                ok_b = False
    chk(ok_z, "z_pad == z_x（pad 码点口径）")
    chk(ok_b, "bias_adj == bias_round - z_x*sum_w_q_all_taps（§4.5 冻结口径恒等式）")

    print("---- 结论 ----")
    if fails:
        print("REF2_SELFTEST: FAIL（%d 条）" % len(fails))
        for f in fails:
            print("   - " + f)
        return 1
    print("REF2_SELFTEST: PASS")
    return 0


def calib_table(A):
    """19 条 run 的几何/段长/偏移标定表（实现片对账的 ground truth）。"""
    runs = runs_of(A.units)
    print("== 19 run 标定表（逐片；几何 = 本片 own；N_i 真实字节；al = ceil32(N_i)；"
          "off = blob 实际偏移；cum = run 内累计偏移）==")
    print("run      L  片  idx  name          TYPE           C_IN→C_OUT  G    H×W     N_i     al      off       cum")
    for (i, j) in runs:
        L = j - i + 1
        cum = 0
        head = A.units[i]
        N_head = n_i_of(head["own"])
        for t in range(i, j + 1):
            u = A.units[t]
            w = u["weight"]
            o = u["own"]
            role = {0: "head", 2: "mid", 3: "tail"}[u["flags"]]
            print("[%2d..%2d] %d %-4s %2d  %-13s 0x%02x %-8s %3d→%-3d %4d %3d×%-3d %6d %6d %8d %8d" % (
                i, j, L, role, t, u["name"], u["type_code"], u["type"],
                o["C_IN"], o["C_OUT"], o["GROUP"], o["IMG_H"], o["IMG_W"],
                w["nbytes"], w["aligned_bytes"], w["offset"], cum))
            cum += w["aligned_bytes"]
        adv = L * N_head
        print("          head N_i=%d  LayerSched-advance(L*N_head)=%d  real=Σaligned=%d  drift=%s"
              % (N_head, adv, cum, "YES" if adv != cum else "no"))
    # 帧级指针（跨 run 也漂移）
    print()
    print("== 帧级指针（LayerSched.wgtPtrR 口径）：逐单元 N_i（未对齐）vs ceil32(N_i) ==")
    drift_units = 0
    ptr = 0
    for u in A.units:
        w = u.get("weight")
        if w is None:
            continue
        if ptr != w["offset"]:
            drift_units += 1
        ptr += w["nbytes"]
    print("按未对齐 N_i 累加的指针与会落盘的偏移：%d/53 个单元错位（第 2 个起全部错位）"
          % drift_units)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="参考 #2：异型宽链逐片串联黄金（见文件头）")
    ap.add_argument("--gen", default=os.path.join(Y1, "gen"))
    ap.add_argument("--ref", default=os.path.join(Y1, "reports", "c4a_ref_layers.json"))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--calib", action="store_true")
    ap.add_argument("--run", nargs=2, type=int, metavar=("I", "J"))
    ap.add_argument("--all-runs", action="store_true")
    ap.add_argument("--seed", type=int, default=20261015)
    ap.add_argument("--dump", default=None, help="把 run 黄金按 %02x 落盘（可选目录）")
    args = ap.parse_args(argv)

    A = Artifacts(args.gen, args.ref)
    if args.selftest:
        return selftest(A)
    if args.calib:
        return calib_table(A)
    if args.run is not None:
        i, j = args.run
        rng = np.random.default_rng(args.seed)
        CI = A.units[i]["own"]["C_IN"]
        H, W = A.units[i]["own"]["IMG_H"], A.units[i]["own"]["IMG_W"]
        x = rng.integers(-128, 128, size=(1, CI, H, W), dtype=np.int64)
        mids, fin, mps = run_golden(A, i, j, x)
        print("run[%d..%d] L=%d seed=%d" % (i, j, j - i + 1, args.seed))
        for k, (mp, m) in enumerate(zip(mps, mids)):
            print("   [%2d] %-11s out md5=%s  (CO=%d %d×%d%s)"
                  % (mp["idx"], mp["name"], md5_bytes(m.astype(np.int8).tobytes()),
                     mp["CO"], H, W, ", 1x1" if mp["is1x1"] else (", dw" if mp["GROUP"] > 1 else "")))
        print("   final %-11s md5=%s" % (mps[-1]["name"], md5_bytes(fin.astype(np.int8).tobytes())))
        if args.dump:
            os.makedirs(args.dump, exist_ok=True)
            for name, arr in [("run_%d_%d_final" % (i, j), fin)] + \
                             [("run_%d_%d_mid%d" % (i, j, k), m) for k, m in enumerate(mids)]:
                with open(os.path.join(args.dump, name + ".hex"), "w", encoding="ascii") as f:
                    f.write("".join("%02x\n" % (int(v) & 0xFF) for v in arr.reshape(-1)))
        return 0
    if args.all_runs:
        runs = runs_of(A.units)
        rng = np.random.default_rng(args.seed)
        print("== 全部 19 run 的链黄金（自造输入 seed=%d；逐片 md5 + final md5）==" % args.seed)
        for (i, j) in runs:
            CI = A.units[i]["own"]["C_IN"]
            H, W = A.units[i]["own"]["IMG_H"], A.units[i]["own"]["IMG_W"]
            x = rng.integers(-128, 128, size=(1, CI, H, W), dtype=np.int64)
            mids, fin, mps = run_golden(A, i, j, x)
            print("run[%2d..%2d] L=%d %-11s..%-11s H=%d W=%d CI=%d: mids=%s final=%s" % (
                i, j, j - i + 1, mps[0]["name"], mps[-1]["name"], H, W, CI,
                ",".join(md5_bytes(m.astype(np.int8).tobytes())[:8] for m in mids),
                md5_bytes(fin.astype(np.int8).tobytes())))
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
