#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""c_tail_account.py —— ★★ NPU v2 切片 C-1：**残差（块内取整 / ci-pad / 尾块）的逐层价签**（离线；只读输入）。

背景（P0b §P0b-4 / Slice B-1 / B1v-4；spec §5 表序 4）
----------------------------------------------------
A（1×1 跳拍，已落 RTL）+ B1（dw 逐 lane，已落 RTL）之后，算力侧剩一条**残差 1.502M 拍**：

    A+B1 = 6,781,200 拍        （实测口径：真表 67 单元 × 实测拍比 1/9(dw)... 见下"口径"）
    地板 = 5,278,762.5 拍      （dw_lane_account.py 的 `FLOOR（AFTER1）`；本片逐层复算必须逐位相等）
    残差 = 1,502,437.5 拍      （= 1.279× ideal 里除去"B 的那一份"之后真正剩下的那一块）

本工具把这条残差**逐单元摊开**，并给每一笔标上**机制**（哪一类取整/补位，能不能回收，回收要动什么）：

  · **co 尾块（1×1 类，`C_out∈{1,4,10}`，12 个单元）** —— `nCo = ceil(C_out/8)` 的向上取整：
    一个**只装了 1/4/2 个真 co 行的整趟**照付 `nCi·H·W` 拍（1×1 槽 1 拍/像素/趟）。⇒ **真多付的拍**，
    只能靠"跨单元 co 打包"或"跨像素行打包"回收（两者都不在现描述符/装载器口径里，见报告）。
  · **ci 补位（`Conv_0`，`C_in=3`）** —— `nCi=1` 恰好整块，**没有多出一趟**（相对 8 通道 dense 的拍数一字不差）；
    多付的是"每拍只有 3/8 条 ci 通道有用"（tap-major 拍序下 **ci 是 lane、tap 是拍**）。⇒ 拍数随
    `taps=9` 走，**不是块内取整**；要回收只能换**拍序**（ci 进拍、tap 进 lane；探针 C-1 实测的那条路）。
  · **dense `C=1` 六片**（`Conv_55/57/59/67/69/71`，`1→1 3×3`）—— 同上：拍数 = 9·H·W（taps 轴），
    每拍 64 槽只有 9 个有用乘。⇒ 与 `Conv_0` 同一类，探针 C-1 的同一张网表覆盖。
  · **dw 尾块（`C=4/10`，6 个单元）** —— AFTER1 后 `beats = nCo·H·W`，**空行不额外吃拍**（一趟服务
    整个 co-block）⇒ 相对"地板"（dw 按 `nCo·H·W` 计）**残差 = 0**：这是"空闲 lane 免费"的正例，
    报告里拿它当"哪一部分不是真浪费"的锚。跨像素打包有 10,500 拍的**理论**收益，但那是另一种机制。

口径（measured / modeled 分开，先例 = P0 §6 / P0b §7 / SliceA §5 / dw_lane_account.py）
  · 每类的**拍/像素/趟**是实测（1×1 = 1：Slice A 闸门 9.00×；dw = 1：B1 闸门 9.00×；dense = 9）+
    **模型**（真表 67 单元几何上摊开；整帧从未端到端跑过 —— P0 §7-1 不变）。
  · `fps = npu_clk ÷ beats`（@50 MHz，同 P0）；本片另给**实测 PnR 上限 52.6704 MHz** 档
    （出处：`sim/reglogs/pds_pnr_c4a_b1_p10.000/prj_tasks/pnr_1/place_route/report_timing/*.rtr`
    的 Performance Summary：npu_clk requested 50 MHz / estimated **52.6704 MHz** / slack +1.014 ns，
    Design Summary: All Constraints Met）。
  · **4 条冻结锚必须复现**（任何一条不符 ⇒ exit 1）：`MAC_TOTAL=344,224,000`、
    `as_built=45,075,600`、`impl_a=13,920,400`、`dw 类=8,031,600`；另加本片两条复算锚：
    `A+B1=6,781,200`（dw_lane_account.py 的 `A + dw AFTER1`）与 `FLOOR=5,278,762.5`。

用法：
    cd y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' <py> tools/c_tail_account.py
    ... tools/c_tail_account.py --selftest      # 只跑断言（锚 + 逐层残差分解）
退出码：0 = 全过；1 = 锚不符；3 = 前置缺失。
"""
import os
import sys
import json

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

_HERE = os.path.dirname(os.path.abspath(__file__))
IDX = os.path.abspath(os.path.join(_HERE, "..", "gen", "wgt_index.json"))

# ---- 冻结锚（出处：reports/npu_v2_accounting.md §0/§P0b-0/SliceA-3/B1v-4）----
ANCH_MACS_TOTAL      = 344_224_000
ANCH_TOTAL_AS_BUILT  = 45_075_600
ANCH_TOTAL_IMPL_A    = 13_920_400
ANCH_DW_AS_BUILT     = 8_031_600
ANCH_AB1             = 6_781_200        # dw_lane_account.py：A + dw AFTER1（实测拍比 × 真表几何）
ANCH_FLOOR           = 5_278_762.5      # dw_lane_account.py：FLOOR（AFTER1）= ideal − dw_ideal + dw_packed
ANCH_RESIDUAL        = ANCH_AB1 - ANCH_FLOOR     # = 1,502,437.5

# ---- 时钟锚（measured）----
NPU_CLK          = 50_000_000
PNR_FMAX_MEAS    = 52.670_4e6   # 实测 PnR（B1 网表）：npu_clk estimated frequency（见文件头）
TARGET_FPS       = 10.0

# ---- 本片钉死的可回收项（探针 C-1 实测的那一条：dense ci-inner）----
# `beats_dci(单元) = c_in · nCo · H · W`（nCi==1 的 dense；ci 进拍、9 个 tap 进 lane + 第 9 抽头行）
DCI_BEATS_TOTAL  = 1_363_200    # Conv_0 1,228,800 + 六片 C=1 134,400（下面对逐单元复算）
COTAIL_TOTAL     = 201_600      # 1×1 co 尾块（12 单元）的"真多付拍"
DWTAIL_XPIX      = 10_500       # dw 尾块跨像素打包的**理论**收益（另一机制，未实现未测）


def n_passes(n):
    return (int(n) + 7) // 8


def units():
    d = json.load(open(IDX, encoding="utf-8"))
    out = []
    for u in d["units"]:
        tc = int(u.get("type_code", -1))
        if tc not in (1, 2, 3):          # 只收 conv/dw（1=dense 3×3, 2=1×1, 3=depthwise）
            continue
        own = u["own"]
        ci, co = int(own["C_IN"]), int(own["C_OUT"])
        H, W = int(own["IMG_H"]), int(own["IMG_W"])
        grp = int(own["GROUP"])
        out.append(dict(idx=int(u["idx"]), name=u["name"], tc=tc, ci=ci, co=co, H=H, W=W, grp=grp,
                        nci=n_passes(ci), nco=n_passes(co)))
    return out


def taps_ab1(u):
    """A+B1 的拍/像素/趟（实测拍比）：dw = 1（AFTER1）；1×1 = 1（Slice A）；dense = 9。"""
    if u["tc"] == 3:
        return 1
    if u["tc"] == 2:
        return 1
    return 9


def passes_ab1(u):
    """趟数（口径 = P0/P0b）：dw = nCo（对角趟）；dense/1×1 = nCi·nCo。"""
    if u["tc"] == 3:
        return u["nco"]
    return u["nci"] * u["nco"]


def beats_ab1(u):
    return taps_ab1(u) * passes_ab1(u) * u["H"] * u["W"]


def macs_of(u):
    """P0 §2 口径：MACs = H·W·C_out·(C_in/GROUP)·taps（1×1 的 taps=1；dw 与 3×3 = 9）。"""
    taps = 1 if u["tc"] == 2 else 9
    cig = (u["ci"] // u["grp"]) if u["grp"] else u["ci"]
    return u["H"] * u["W"] * u["co"] * cig * taps


def floor_unit(u):
    """地板口径（= dw_lane_account.py 的 FLOOR）：非 dw ⇒ MACs/64；dw ⇒ nCo·H·W（AFTER1 打包实计）。"""
    if u["tc"] == 3:
        return float(u["nco"] * u["H"] * u["W"])
    return macs_of(u) / 64.0


def dci_unit(u):
    """dense ci-inner 的实计拍（本片探针的形状）：nCi==1 的 dense ⇒ C_in·nCo·H·W；否则 None。"""
    if u["tc"] == 1 and u["nci"] == 1:
        return u["ci"] * u["nco"] * u["H"] * u["W"]
    return None


def mechanism(u):
    """残差的机制标签（报告 §C-1-2 的四类）。"""
    if u["tc"] == 3:
        return "dw-tail(免费)" if (u["co"] % 8) else "-"
    if u["tc"] == 2:
        if u["co"] % 8:
            return "co-tail(真多付)"
        return "-"
    # dense
    if u["ci"] % 8:
        return "ci-pad(拍序)"
    if u["co"] % 8:
        return "co-tail(真多付)"
    if u["ci"] < 8 or u["co"] < 8:
        return "拍序"
    return "-"


def main(argv):
    selftest = "--selftest" in argv
    us = units()
    macs_total = sum(macs_of(u) for u in us)
    ab1_total = sum(beats_ab1(u) for u in us)
    floor_total = sum(floor_unit(u) for u in us)
    as_built = sum(9 * passes_ab1(u) * u["H"] * u["W"] for u in us)
    impl_a = sum((1 if u["tc"] in (2,) else 9) * passes_ab1(u) * u["H"] * u["W"] for u in us)
    dw_as_built = sum(9 * passes_ab1(u) * u["H"] * u["W"] for u in us if u["tc"] == 3)

    residual = ab1_total - floor_total
    dci_save = sum((beats_ab1(u) - dci_unit(u)) for u in us if dci_unit(u) is not None)
    cotail = sum((beats_ab1(u) - floor_unit(u)) for u in us
                 if u["tc"] == 2 and (u["co"] % 8))
    dwtail_x = 0
    for u in us:
        if u["tc"] != 3 or u["co"] % 8 == 0:
            continue
        # 跨像素打包（**另一机制，未实现未测**）：8 行按"每像素要 C_out 行"折 ⇒ beats = H·W·C_out/8
        # （= 72 MAC/拍：8 行 × 9 抽头；C=4 ⇒ 2 像素/拍、C=10 的尾趟 ⇒ 4 像素/拍）
        dwtail_x += beats_ab1(u) - u["H"] * u["W"] * u["co"] / 8.0

    print("INPUT   idx=%s units=%d (conv/dw)" % (os.path.basename(IDX), len(us)))
    print("ANCHOR  MAC_TOTAL=%d / as_built=%d / impl_a=%d / dw_as_built=%d"
          % (macs_total, as_built, impl_a, dw_as_built))
    ok = True

    def chk(cond, msg, detail=""):
        nonlocal ok
        ok = ok and bool(cond)
        print("  %s  %s%s" % ("PASS" if cond else "FAIL", msg, ("  " + detail) if detail else ""))

    chk(macs_total == ANCH_MACS_TOTAL, "MAC_TOTAL == P0 锚 344,224,000")
    chk(as_built == ANCH_TOTAL_AS_BUILT, "as-built 总拍 == P0/P0b 锚 45,075,600")
    chk(impl_a == ANCH_TOTAL_IMPL_A, "impl_a 总拍 == SliceA 锚 13,920,400")
    chk(dw_as_built == ANCH_DW_AS_BUILT, "dw 类 as-built == P0b 锚 8,031,600")
    chk(ab1_total == ANCH_AB1, "A+B1 == dw_lane_account 锚 6,781,200")
    chk(abs(floor_total - ANCH_FLOOR) < 1e-6, "FLOOR == dw_lane_account 锚 5,278,762.5",
        "%.1f" % floor_total)
    chk(abs(residual - ANCH_RESIDUAL) < 1e-6, "残差 == 1,502,437.5 = A+B1 − FLOOR", "%.1f" % residual)

    # ---- 逐层残差表（只列非零残差 + 机制）----
    print()
    print("== 逐层残差价签（A+B1 实计 − 地板；只列 delta != 0 的行）==")
    hdr = ("idx  %-9s %-8s %-9s %4s %4s %5s %4s %4s %3s %3s %11s %11s %11s  %s"
           % ("name", "type", "Cin->Cout", "H", "W", "grp", "nCi", "nCo", "tap", "pas",
              "beats_AB1", "floor", "delta", "机制"))
    print(hdr)
    print("-" * len(hdr))
    conv_groups = {"co-tail(真多付)": 0.0, "ci-pad(拍序)": 0.0, "拍序": 0.0, "dw-tail(免费)": 0.0}
    for u in sorted(us, key=lambda x: -(beats_ab1(x) - floor_unit(x))):
        d = beats_ab1(u) - floor_unit(u)
        if abs(d) < 1e-9:
            continue
        mech = mechanism(u)
        conv_groups[mech] = conv_groups.get(mech, 0.0) + d
        print("%3d  %-9s %-8s %3d->%-3d %4d %4d %5d %4d %4d %3d %3d %11d %11.1f %11.1f  %s"
              % (u["idx"], u["name"], {1: "dense3x3", 2: "conv1x1", 3: "depthwise"}[u["tc"]],
                 u["ci"], u["co"], u["H"], u["W"], u["grp"], u["nci"], u["nco"],
                 taps_ab1(u), passes_ab1(u), beats_ab1(u), floor_unit(u), d, mech))
    print("-" * len(hdr))
    print("SUM     delta = %.1f（必须 == 残差 %.1f）" % (sum(beats_ab1(u) - floor_unit(u) for u in us), residual))

    # 机器可读行（闸门/报告引用）
    conv0 = [u for u in us if u["idx"] == 0][0]
    print("RESID   conv0=%d ci_pad=%d" % (beats_ab1(conv0) - floor_unit(conv0),
                                          beats_ab1(conv0) - dci_unit(conv0)))
    print("RESID   dense_c1_total=%d dci_save_dense_c1=%d"
          % (sum(beats_ab1(u) for u in us if u["tc"] == 1 and u["ci"] == 1 and u["co"] == 1),
             sum(beats_ab1(u) - dci_unit(u) for u in us if u["tc"] == 1 and u["ci"] == 1 and u["co"] == 1)))
    print("RESID   cotail_total=%.1f cotail_c1=%.1f cotail_c4=%.1f cotail_c10=%.1f"
          % (cotail,
             sum(beats_ab1(u) - floor_unit(u) for u in us if u["tc"] == 2 and u["co"] == 1),
             sum(beats_ab1(u) - floor_unit(u) for u in us if u["tc"] == 2 and u["co"] == 4),
             sum(beats_ab1(u) - floor_unit(u) for u in us if u["tc"] == 2 and u["co"] == 10)))
    print("RESID   dw_fullblocks=%.1f dw_tail_free=%.1f dwtail_xpix_theory=%.1f"
          % (sum(beats_ab1(u) - floor_unit(u) for u in us if u["tc"] == 3 and u["co"] % 8 == 0),
             sum(beats_ab1(u) - floor_unit(u) for u in us if u["tc"] == 3 and u["co"] % 8),
             dwtail_x))
    print("RESID   by_mech co=%.1f ci=%+.1f taporder=%.1f"
          % (conv_groups.get("co-tail(真多付)", 0.0), conv_groups.get("ci-pad(拍序)", 0.0),
             conv_groups.get("拍序", 0.0)))
    chk(abs(sum(beats_ab1(u) - floor_unit(u) for u in us) - residual) < 1e-6,
        "逐层 delta 求和 == 残差（0 遗漏）")
    chk(abs(dci_save - DCI_BEATS_TOTAL) < 1e-6,
        "dense ci-inner（本片探针）逐层复算 == 1,363,200", "%.0f" % dci_save)
    chk(abs(cotail - COTAIL_TOTAL) < 1e-6, "1×1 co 尾块 == 201,600", "%.1f" % cotail)
    chk(abs(dwtail_x - DWTAIL_XPIX) < 1e-6, "dw 尾块跨像素理论值 == 10,500（另一机制）", "%.1f" % dwtail_x)
    chk(abs(conv_groups.get("dw-tail(免费)", 0.0)) < 1e-9, "dw 尾块在地板口径下残差 = 0（空闲行免费）")

    # ---- 臂 + 时钟算术 ----
    arm_ab1 = float(ab1_total)
    arm_dci = arm_ab1 - dci_save
    arm_dci_cotail = arm_dci - cotail
    arm_all = arm_dci_cotail - dwtail_x
    budget = PNR_FMAX_MEAS / TARGET_FPS
    print()
    print("== 臂与时钟（fps = clk ÷ beats；budget = 实测 PnR %.4f MHz ÷ 10 ===" % (PNR_FMAX_MEAS / 1e6))
    print("%-38s %13s %10s %10s %10s" % ("臂", "beats", "clk@10fps", "fps@50MHz", "fps@PnR"))
    for nm, b in [("A+B1（已落 RTL）", arm_ab1),
                  ("A+B1+DCI（本片探针）", arm_dci),
                  ("A+B1+DCI+1×1 co 尾块（另一机制）", arm_dci_cotail),
                  ("A+B1+DCI+co 尾块+dw 尾块跨像素（理论）", arm_all),
                  ("地板（= DCI+全 tail；dw 按 nCo）", ANCH_FLOOR)]:
        print("%-38s %13.1f %9.3fMHz %10.4f %10.4f"
              % (nm, b, TARGET_FPS * b / 1e6, NPU_CLK / b, PNR_FMAX_MEAS / b))
    print("BUDGET  @PnR %.4f MHz 过 10 fps 需 beats ≤ %.0f" % (PNR_FMAX_MEAS / 1e6, budget))
    print("GAP     A+B1 缺口 = %.0f 拍；+DCI 后仍缺 = %.0f 拍；+co 尾块后余量 = %+.0f 拍"
          % (arm_ab1 - budget, arm_dci - budget, budget - arm_dci_cotail))
    print("CLOCK   过 10 fps 所需 npu_clk：A+B1 ≥ %.1f MHz；+DCI ≥ %.1f MHz；+co 尾块 ≥ %.1f MHz；地板 ≥ %.1f MHz"
          % (10 * arm_ab1 / 1e6, 10 * arm_dci / 1e6, 10 * arm_dci_cotail / 1e6, 10 * ANCH_FLOOR / 1e6))
    print("CLOCK   实测 PnR（B1 网表）= %.4f MHz ⇒ A+B1 = %.4f fps；+DCI = %.4f fps；+co 尾块 = %.4f fps"
          % (PNR_FMAX_MEAS / 1e6, PNR_FMAX_MEAS / arm_ab1, PNR_FMAX_MEAS / arm_dci,
             PNR_FMAX_MEAS / arm_dci_cotail))
    chk(abs(arm_dci - 5_418_000.0) < 1e-6, "A+B1+DCI == 5,418,000 拍", "%.0f" % arm_dci)
    chk(abs(arm_dci_cotail - 5_216_400.0) < 1e-6, "A+B1+DCI+co 尾块 == 5,216,400 拍", "%.0f" % arm_dci_cotail)
    chk(arm_dci > budget, "单做 DCI 在实测 PnR 上限下**到不了** 10 fps（缺口 %.0f 拍）" % (arm_dci - budget))
    chk(arm_dci_cotail <= budget, "+co 尾块后才过 10 fps 预算（余量 %.0f 拍）" % (budget - arm_dci_cotail))
    chk(ANCH_FLOOR > budget, "地板本身 = 52.79 MHz > 实测 52.6704 MHz（0.22% 之外）——诚实边界")

    print()
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    if not os.path.isfile(IDX):
        print("FATAL: 缺 %s" % IDX)
        sys.exit(3)
    sys.exit(main(sys.argv))
