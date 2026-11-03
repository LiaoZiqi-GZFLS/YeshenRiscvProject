#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""unit_trace.py —— 把 `y1run --unit-trace` 的 `U <count> <ns>` 解析成逐单元时间表。

输入（只读）：
  · trace 文本（含 `U k t_ns` 行；可含多帧 ⇒ 只取**最后一帧**：遇到 `RUN ` 行就清空累积）
  · `y1/gen/wgt_index.json`（67 单元的 name/type/own 几何）

输出：
  · 逐单元：序号 / 名称 / 类型 / 耗时 ms / 占帧比 / 像素·趟 / ns per 像素·趟
  · 按类型汇总（conv1x1 / depthwise / conv3x3 / 旁路）
  · `SUM` 与 trace 末尾时间、以及和命令行给的 `--run-ns` 的差

口径：
  · 像素·趟：dense = nCi·nCo·H·W，dw = nCo·H·W，1×1 同 dense；旁路 = C_out·H·W（元素）
  · 拍 = ns × 54 MHz（板级 npu_clk = 54.000 MHz）
用法：python tools/unit_trace.py <trace.txt> [--run-ns N]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
Y1 = os.path.dirname(HERE)
IDX = json.load(open(os.path.join(Y1, "gen", "wgt_index.json"), encoding="utf-8"))["units"]
CLK_MHZ = 54.0


def npass(c):
    return (int(c) + 7) // 8


def work_of(u):
    o = u["own"]
    H, W = int(o["IMG_H"]), int(o["IMG_W"])
    ci, co, g = int(o["C_IN"]), int(o["C_OUT"]), int(o["GROUP"])
    t = u["type"]
    if t == "depthwise":
        return npass(co) * H * W
    if t in ("conv1x1", "conv3x3"):
        return npass(ci) * npass(co) * H * W
    return co * H * W  # 旁路：元素数（只作量级参考）


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    run_ns = None
    if "--run-ns" in sys.argv:
        run_ns = int(sys.argv[sys.argv.index("--run-ns") + 1])
    global CLK_MHZ
    if "--clk" in sys.argv:
        CLK_MHZ = float(sys.argv[sys.argv.index("--clk") + 1])
    marks, last = [], []
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        p = line.split()
        if len(p) == 3 and p[0] == "U":
            last.append((int(p[1]), int(p[2])))
        elif line.startswith("RUN "):
            if last:
                marks = last
            last = []
    if last:
        marks = last
    if not marks:
        print("no U lines")
        return 1
    prev = 0
    rows = []
    for cnt, t in marks:
        ui = cnt - 1
        if ui < 0 or ui >= len(IDX):
            continue
        u = IDX[ui]
        dt = t - prev
        prev = t
        wk = work_of(u)
        rows.append((ui, u["name"], u["type"], dt, wk))
    total = marks[-1][1]
    print("units=%d  trace_total=%.3f ms  (%.1f M cycles @%.0f MHz)"
          % (len(rows), total / 1e6, total * CLK_MHZ / 1e3, CLK_MHZ))
    if run_ns:
        print("run_ns=%d  diff=%.3f ms" % (run_ns, (run_ns - total) / 1e6))
    print("%3s %-12s %-10s %10s %7s %12s %10s" %
          ("idx", "name", "type", "ms", "share", "pixel-pass", "ns/pp"))
    for ui, name, typ, dt, wk in sorted(rows, key=lambda r: -r[3]):
        pp = wk if wk else 1
        print("%3d %-12s %-10s %10.3f %6.1f%% %12d %10.1f"
              % (ui, name, typ, dt / 1e6, 100.0 * dt / total, wk, dt / pp))
    agg = {}
    for ui, name, typ, dt, wk in rows:
        a = agg.setdefault(typ, [0, 0])
        a[0] += dt
        a[1] += wk
    print("---- by type ----")
    for typ, (dt, wk) in sorted(agg.items(), key=lambda kv: -kv[1][0]):
        print("%-10s %8.3f ms %6.1f%%  work=%d  ns/pp=%.1f"
              % (typ, dt / 1e6, 100.0 * dt / total, wk, dt / max(1, wk)))
    print("SUM=%.3f ms" % (sum(r[3] for r in rows) / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
