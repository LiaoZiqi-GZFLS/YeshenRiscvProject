import re, sys
sys.stdout.reconfigure(errors="replace")
# usage: check_dsp_latency.py <verilog> <expected_stages>
#
# 契约：DSP 的 MAC 是 expected_stages 级流水（= 原 Xilinx dsp_macro 的 tier_1..tier_6 = 6 级）。
# 判据：module DSP 体内流水寄存器 dspPipe_<n> 的不同索引个数 == expected，且索引恰为 0..expected-1
#       （连续、从 0 起，说明是一段真正的顺序移位流水，而不是随手改的寄存器）。
path, exp = sys.argv[1], int(sys.argv[2])
txt = open(path, encoding="utf-8", errors="replace").read()
m = re.search(r"module\s+DSP\b(.*?)\bendmodule", txt, re.S)
if not m:
    print("FAIL: 找不到 DSP 模块体"); sys.exit(2)
body = m.group(1)
idx = sorted({int(i) for i in re.findall(r"dspPipe_(\d+)", body)})
detected = len(idx)
print(f"expected={exp} detected={detected} indices={idx}")
ok = (detected == exp) and (idx == list(range(exp)))
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
