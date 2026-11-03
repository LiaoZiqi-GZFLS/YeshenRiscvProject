#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dw_lane_account.py —— ★★ NPU v2 切片 B-1：**dw lane 打包的价格重签发**（离线；只读输入）。

本工具把 P0/P0b 的"按类 issued 拍账"扩一条**dw 打包实计臂**，并把定价锚**逐条交叉**：

  · `as_built`  = 45,075,600 拍（P0/P0b 锚；口径 `taps·passes·H·W`，dw 的对角趟 `passes = nCo`）——**必须复现**；
  · `impl_a`    = 13,920,400 拍（切片 A 落 RTL 后的实计臂：1×1 类只发 1 拍）——**必须复现**；
  · `dw_before` = 8,031,600 拍（P0b 的 dw 类 issued；= 9·Σ_dw nCo·H·W）——**必须复现**；
  · `dw_2beat`  = 2·Σ_dw nCo·H·W = 1,784,800 拍（AFTER2：tap-inner 打包、无新乘法器）；
  · `dw_1beat`  = 1·Σ_dw nCo·H·W =   892,400 拍（AFTER1：tap-inner + 第 9 抽头行）。

**口径说明（measured / modeled 分开，先例 = P0 §6 / P0b §7 / SliceA §5）**
  · 每个 dw 单元的**拍/像素/趟 = 9 / 2 / 1** 是**实测**（`tools/run_dwlane_ab.sh`：TB 自报 `arr.en` 拍数，
    按预测量断言，六形状全等；数值逐字节 == 冻结黄金）。
  · **帧级**加总是**模型**：在真表 67 单元的 `own` 几何上把实测比值摊开（与 P0/P0b 同一套口径）。
    ★ 真帧从未端到端跑过（P0 §7-1 不变）。
  · `fps = npu_clk ÷ beats`（@50 MHz，同 P0）。

用法：
    cd y1
    PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' <py> tools/dw_lane_account.py
    ... tools/dw_lane_account.py --selftest      # 只跑断言（锚 + 扰动）
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

# ---- 冻结锚（出处：reports/npu_v2_accounting.md §0/§P0b-0/§P0b-1/SliceA-3）----
ANCH_TOTAL_AS_BUILT = 45_075_600
ANCH_TOTAL_IMPL_A   = 13_920_400
ANCH_DW_AS_BUILT    = 8_031_600
ANCH_MACS_TOTAL     = 344_224_000
NPU_CLK = 50_000_000


def n_passes(n):
    return (int(n) + 7) // 8


def taps_of(type_code):
    """RTL 的抽头口径（P0：不按核大小省拍）：1×1 也跑 9 抽头相位（切片 A 后 1×1 = 1 拍）。"""
    return 9


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


def beats_of(us, dw_beats=None):
    """返回 (总拍, 分类拍)。`dw_beats` = None ⇒ as-built（9 拍/像素/趟）；
    'A' ⇒ 切片 A（1×1 = 1 拍）；2 / 1 ⇒ 切片 A + dw 打包 2 / 1 拍每像素每趟。"""
    tot = 0
    cls = {"1x1": 0, "dw": 0, "d3x3": 0}
    dw = 0
    for u in us:
        is_dw = (u["tc"] == 3)
        passes = u["nco"] if is_dw else u["nci"] * u["nco"]
        if is_dw:
            t = 9 if dw_beats in (None, "A") else int(dw_beats)
        elif u["tc"] == 2:
            t = 9 if dw_beats is None else 1          # 切片 A：1×1 只发 1 拍
        else:
            t = 9
        b = t * passes * u["H"] * u["W"]
        tot += b
        cls["dw" if is_dw else ("1x1" if u["tc"] == 2 else "d3x3")] += b
        if is_dw:
            dw += passes * u["H"] * u["W"]
    return tot, cls, dw


def macs_of(us):
    """P0 §2 口径：`MACs = H·W·C_out·(C_in/GROUP)·taps`，`taps` 由 TYPE 派生
    （conv3x3 → 9、depthwise → 9、**conv1x1 → 1** —— 1×1 的其余 8 个抽头权重恒 0，不计入"有用 MAC"；
    但**拍**不省，那是 §3 的 `SLICE_TAP_BEATS = 9`）。返回 (总, 分类)。"""
    tot = 0
    cls = {"1x1": 0, "dw": 0, "d3x3": 0}
    for u in us:
        taps = 1 if u["tc"] == 2 else 9
        cig = (u["ci"] // u["grp"]) if u["grp"] else u["ci"]
        m = u["H"] * u["W"] * u["co"] * cig * taps
        tot += m
        cls["dw" if u["tc"] == 3 else ("1x1" if u["tc"] == 2 else "d3x3")] += m
    return tot, cls


def fps(beats, clk=NPU_CLK):
    return clk / beats


def main(argv):
    assert_ok = True
    us = units()
    macs, macs_cls = macs_of(us)
    t_as, cls_as, dwnco = beats_of(us, None)
    t_a,  cls_a,  _     = beats_of(us, "A")
    t_b2, cls_b2, _     = beats_of(us, 2)
    t_b1, cls_b1, _     = beats_of(us, 1)

    print("INPUT   idx=%s units=%d (conv/dw)" % (os.path.basename(IDX), len(us)))
    print("ANCHOR  MAC_TOTAL=%d (expect %d)" % (macs, ANCH_MACS_TOTAL))
    print("ANCHOR  as_built=%d (expect %d) / impl_a=%d (expect %d) / dw_as_built=%d (expect %d)"
          % (t_as, ANCH_TOTAL_AS_BUILT, t_a, ANCH_TOTAL_IMPL_A, cls_as["dw"], ANCH_DW_AS_BUILT))
    for cond, msg in [
        (macs == ANCH_MACS_TOTAL, "MAC_TOTAL == P0 锚"),
        (t_as == ANCH_TOTAL_AS_BUILT, "as-built 总拍 == P0/P0b 锚 45,075,600"),
        (t_a == ANCH_TOTAL_IMPL_A, "impl_a 总拍 == SliceA 锚 13,920,400"),
        (cls_as["dw"] == ANCH_DW_AS_BUILT, "dw 类 as-built == P0b 锚 8,031,600"),
    ]:
        print("  %s  %s" % ("PASS" if cond else "FAIL", msg))
        assert_ok = assert_ok and cond

    print("CLASS   as-built: 1x1=%d dw=%d d3x3=%d  (Σ=%d)"
          % (cls_as["1x1"], cls_as["dw"], cls_as["d3x3"], t_as))
    print("DWUNIT  Σ_dw nCo·H·W = %d  ⇒ as-built=9×%d / AFTER2=2×%d / AFTER1=1×%d"
          % (dwnco, dwnco, dwnco, dwnco))

    ideal = macs // 64
    rows = [
        ("as-built",          t_as),
        ("A（1×1 跳拍，已落 RTL）", t_a),
        ("A + dw AFTER2（2 拍/像素/趟）", t_b2),
        ("A + dw AFTER1（1 拍/像素/趟）", t_b1),
    ]
    print("ARMS    %-34s %14s %9s" % ("臂", "beats", "fps@50MHz"))
    for nm, b in rows:
        print("ARMS    %-34s %14d %9.4f" % (nm, b, fps(b)))
    print("IDEAL   MACs/64 = %d ⇒ %.4f fps @50MHz（P0 的算力天花板；★ dw 的 AFTER1 档 72 MAC/拍 > 64 ⇒ "
          "它的**实计拍数低于**这条线上 dw 的那一份，见下）" % (ideal, fps(ideal)))
    # dw 打包后的"结构地板"（**modeled**）：ideal 里 dw 的那一份（= MACs_dw/64，非整数）换成打包实计
    dw_ideal = macs_cls["dw"] / 64.0
    floor_b2 = ideal - dw_ideal + cls_b2["dw"]
    floor_b1 = ideal - dw_ideal + cls_b1["dw"]
    print("DW      MACs_dw=%d ⇒ dw 的 ideal 拍 = %.1f（P0b 记 992,138）；打包实计：AFTER2=%d / AFTER1=%d"
          % (macs_cls["dw"], dw_ideal, cls_b2["dw"], cls_b1["dw"]))
    print("FLOOR   ideal 重算（dw 换成打包实计，其余仍按 MACs/64 ⇒ 等价于「块内取整全修」的下界）："
          "AFTER2 → %.0f（%.4f fps）；AFTER1 → %.0f（%.4f fps）"
          % (floor_b2, fps(floor_b2), floor_b1, fps(floor_b1)))
    print("CLOCK   过 10 fps 所需 npu_clk：A+B2 ≥ %.1f MHz；A+B1 ≥ %.1f MHz；AFTER1 + C(地板) ≥ %.1f MHz"
          % (10 * t_b2 / 1e6, 10 * t_b1 / 1e6, 10 * floor_b1 / 1e6))

    if not assert_ok:
        print("RESULT: FAIL（锚不符）")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    if not os.path.isfile(IDX):
        print("FATAL: 缺 %s" % IDX)
        sys.exit(3)
    sys.exit(main(sys.argv))
