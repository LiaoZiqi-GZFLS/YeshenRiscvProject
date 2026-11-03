#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""y1 · J2 —— 用"主口每 32 B 自己加的开销"**预测** DDR traffic 速率。

用法:  predict_traffic.py <cyc_per_group>
输出:  预测 traffic 速率 = 32 B / (116 ns + cyc_per_group x 10 ns)
       -> MB/s、占 275.9 MB/s 的百分比、等价的有效拷贝速率（= 一半）、是否 >= 220 MB/s（= 275.9 的 80%）
       以及一行必须存在的标注：本数为**预测**（依据桥的静态 116 ns/32 B），非实测

  <cyc_per_group> = tools/run_ddrcopy_ab.sh 打出来的那个数：主口**自己**在每个 32 B 上额外花的
  100 MHz 拍数（= (CYC - 搬运数据本身必走的拍数) / (LEN/32)）。它**不含**桥自己的代价 ——
  桥的代价是下面那个 116 ns，两笔相加才是"一次 32 B DDR 事务"的墙钟时间。

============================ 必须先说清的一条硬事实 ============================
桥的 116 ns / 32 B **不是一个时钟域里的时间**，它是两个域的拍数**相加**（单 outstanding，
两段不可重叠）：
      6 拍 @ 100 MHz = 60 ns     （sClk 侧：A + D + F）
    + 7 拍 @ 125 MHz = 56 ns     （dClk 侧：B + C + E）
    = 116 ns / 32 B
  出处：y1/partA/ddr_path_ceiling.md 第 2、3 节；复现：
  `python y1/partA/ddr_path_ceiling.py bridge 6 100e6 7 125e6` -> 275.9 MB/s [FAIL <305]

**所以单时钟仿真复现不了它**：rtl_test 里只有一个 clk（100 MHz 口径），桥的 125 MHz 域与 CDC
四相往返根本不存在 —— 一次 Verilog 仿真**测不出** 116 ns。因此本脚本给的是**预测**
（"静态算出来的桥代价" + "单时钟仿真实测出来的主口开销"两笔相加），**不是实测**。
任何引用本脚本数字的地方都必须保留"预测"这个定语；后续 C2.4 若真做两时钟 + 行为级桥模型的
实测，那里的数字才可以去掉这个词。
==============================================================================
"""
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

BRIDGE_NS = 116.0          # 桥：6 拍 @100 MHz + 7 拍 @125 MHz = 60 + 56 ns（**静态**，来自 RTL 握手指数）
CYCLES_NS = 10.0           # 100 MHz => 1 拍 = 10 ns（主口开销的换算：cyc_per_group 是 100 MHz 拍数）
BAND_MBPS = 275.9          # 桥路径静态上界（十进制 MB/s，1 MB = 1e6 B）
GROUP_B = 32               # 一次 DDR 事务 = 32 B
THRESH_MBPS = BAND_MBPS * 0.8     # 275.9 的 80% = 220.72 MB/s（判据行里写"220"是它的取整说法）

USAGE = "用法: predict_traffic.py <cyc_per_group>   (例如 predict_traffic.py 1.250031)"


def main(argv):
    if len(argv) != 2:
        print(USAGE)
        return 2
    try:
        cpg = float(argv[1])
    except ValueError:
        print("FATAL: <cyc_per_group> 必须是数：%r" % argv[1])
        print(USAGE)
        return 2
    if cpg < 0:
        print("FATAL: <cyc_per_group> 不能为负：%r" % argv[1])
        return 2

    t_ns = BRIDGE_NS + cpg * CYCLES_NS
    rate = GROUP_B / (t_ns * 1e-9)          # B/s
    rate_mbps = rate / 1e6                  # 十进制 MB/s
    pct = rate_mbps / BAND_MBPS * 100.0
    copy_mbps = rate_mbps / 2.0             # 拷贝：同一份带宽里"读一份 + 写一份" ⇒ 有效拷贝速率是一半
    ge80 = rate_mbps >= THRESH_MBPS
    j2_ok = cpg <= 2.0

    print("CYCPG=%.6f  (主口每 32 B 自己加的 100 MHz 拍数，来自 run_ddrcopy_ab.sh 的单时钟实测)" % cpg)
    print("T_group = %.1f ns (桥静态) + %.3f x %.1f ns = %.3f ns / 32 B" % (BRIDGE_NS, cpg, CYCLES_NS, t_ns))
    print("PREDICT_TRAFFIC_MBPS=%.2f" % rate_mbps)
    print("PREDICT_PCT_OF_275.9=%.2f%%" % pct)
    print("PREDICT_COPY_MBPS=%.2f  (= traffic 的一半：一份带宽被读、写各占一次)" % copy_mbps)
    print("THRESHOLD_MBPS=%.2f  (= 275.9 x 80%%，判据行里说的 220 MB/s)" % THRESH_MBPS)
    print("VERDICT_GE_80PCT=%s" % ("YES" if ge80 else "NO"))
    print("J2_CRITERION cyc_per_group <= 2 at 100 MHz: %s (%.6f)"
          % ("PASS" if j2_ok else "FAIL", cpg))
    print("PREDICTION_LABEL: 本数为**预测**（依据桥的静态 116 ns/32 B = 60 ns@100 MHz + 56 ns@125 MHz），"
          "非实测 —— 单时钟仿真复现不了双时钟的 116 ns。")
    if not ge80:
        print("VERDICT: BELOW_80PCT")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
