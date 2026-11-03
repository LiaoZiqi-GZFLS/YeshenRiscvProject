"""Y1-A3-static: 由 RTL 拍数静态导出 DDR 访问路径的吞吐上限（可审计算术）。

用法:
  python ddr_path_ceiling.py bridge <s_cycles> <s_freq_hz> <d_cycles> <d_freq_hz>
  python ddr_path_ceiling.py oneclk <cycles>   <freq_hz>
  python ddr_path_ceiling.py raw    <bytes_per_beat> <freq_hz>

模型（依据 src/soc/DDR3Bridge.scala 头 + src/soc/CDCQueue.scala）:
  · 桥是"单 outstanding"，且一笔 DDR 事务只发 1 个 256bit beat(=32B)
    （ddrAwLen/ddrArLen 恒 0）⇒ 每 32B 必须走完**一整次** CDC 四相握手往返。
  · 该往返在源域(sClk=AXI 侧)花 s_cycles 拍、在目的域(dClk=DDR 侧)花 d_cycles 拍；
    两域异步且不可重叠 ⇒ 墙钟周期是**两段之和**:
        T = s_cycles/f_s + d_cycles/f_d      (不是"取某一个域"!)
        BW = 32B / T
  · oneclk 模式 = 只按单域拍数算的**错误上界**，仅用于展示"只数一个域"会高估。
输出只含 ASCII（Windows 控制台为 GBK）。
"""
import sys

sys.stdout.reconfigure(errors="replace")

BEAT_BYTES = 32.0
WORKLOAD_MB = 30.5              # 每帧 30.5 MB
NEED10 = WORKLOAD_MB * 10e6     # 305e6 B/s = 305 MB/s
NEED15 = WORKLOAD_MB * 15e6     # 457.5e6 B/s


def verdict(bw_mbs):
    if bw_mbs >= NEED15 / 1e6:
        return "OK >=458 (15fps)"
    if bw_mbs >= NEED10 / 1e6:
        return "ONLY 305-458 tier"
    return "FAIL <305 (10fps)"


def show(label, period_ns, detail):
    bw = BEAT_BYTES / (period_ns * 1e-9)
    print(f"{label:34s} T={period_ns:8.3f} ns/32B -> {bw/1e6:8.1f} MB/s  [{verdict(bw/1e6)}]")
    print(f"{'':34s} ({detail})")
    return bw / 1e6


def main():
    mode = sys.argv[1]
    print(f"need: @10fps {NEED10/1e6:.0f} MB/s ; @15fps {NEED15/1e6:.0f} MB/s   (workload {WORKLOAD_MB} MB/frame)")
    print(f"raw user port @125MHz = {BEAT_BYTES*125e6/1e6:.0f} MB/s"
          f" ; SoC mem 64bit @100MHz = {8*100e6/1e6:.0f} MB/s")
    print("-" * 78)
    if mode == "bridge":
        s_cyc, s_f, d_cyc, d_f = (float(x) for x in sys.argv[2:6])
        T = s_cyc / s_f + d_cyc / d_f
        show("bridge 4-phase round trip", T * 1e9,
             f"{s_cyc:g} cyc @ {s_f/1e6:g} MHz (src) + {d_cyc:g} cyc @ {d_f/1e6:g} MHz (dst)")
    elif mode == "oneclk":
        cyc, f = (float(x) for x in sys.argv[2:4])
        show("single-domain WRONG upper bound", cyc / f * 1e9, f"{cyc:g} cyc @ {f/1e6:g} MHz")
    elif mode == "raw":
        W, f = (float(x) for x in sys.argv[2:4])
        bw = W * f
        print(f"{'raw (no protocol overhead)':34s} {W:g} B/beat @ {f/1e6:g} MHz"
              f" -> {bw/1e6:8.1f} MB/s  [{verdict(bw/1e6)}]")
    else:
        print("unknown mode", file=sys.stderr)
        return 2
    print("-" * 78)
    print("required beat period (32B): @305 -> %.1f ns ; @458 -> %.1f ns"
          % (BEAT_BYTES / NEED10 * 1e9, BEAT_BYTES / NEED15 * 1e9))
    return 0


if __name__ == "__main__":
    sys.exit(main())
