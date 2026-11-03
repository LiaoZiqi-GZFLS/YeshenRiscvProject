"""由用户口位宽与频率算 DDR 的静态上界。
用法: ddr_ceiling.py <port_bytes> <freq_hz> [efficiency ...]
输出：raw 上界与按若干效率系数的可达估计，并给出对需要的 305/458 MB/s 的判定。
"""
import sys
sys.stdout.reconfigure(errors="replace")
W = float(sys.argv[1])          # 用户口字节数/拍
f = float(sys.argv[2])          # Hz
raw = W * f
print(f"user port = {W:g} B/beat @ {f/1e6:g} MHz -> raw ceiling {raw/1e6:.1f} MB/s")
need_15 = 30.5 * 1e6 * 15       # 30.5 MB/帧 @15fps
need_10 = 30.5 * 1e6 * 10
effs = [float(x) for x in sys.argv[3:]] or [0.5, 0.6, 0.7, 0.8]
for eff in effs:
    ach = raw * eff
    v15 = "OK" if ach >= need_15 else "NO"
    v10 = "OK" if ach >= need_10 else "NO"
    print(f"  eff={eff:.1f} -> {ach/1e6:7.1f} MB/s | @15fps(458 MB/s): {v15} | @10fps(305 MB/s): {v10}")
print(f"需要: @15fps {need_15/1e6:.0f} MB/s ; @10fps {need_10/1e6:.0f} MB/s")
