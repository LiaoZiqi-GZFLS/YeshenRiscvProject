#!/usr/bin/env python3
"""B9b 判据：加/减法器（原 Xilinx c_addsub IP）的**结构**契约。

usage: check_addsub_latency.py <verilog> <expected_stages> [module_name] [add|sub]

检查项：
  1. **流水级数**：module 体内 `addPipe_<n>` 的不同索引个数 == expected_stages，
     且索引恰为 0..N-1（连续、从 0 起 ⇒ 是真正的顺序移位流水，而不是随手加的寄存器）。
     这个数字的来源是原 tcl 的 `CONFIG.Latency`（7 个调用点：1/1/1/1/2/2/5）。
  2. **可选 module 名**（第 3 参）：不传时按实现实际发出的名字匹配（装置里 componentName = "addsub"）；
     传了就点名检查 —— 用于在**真网表** gen/Npu.v 上逐个检查 AddZero / biasAdd / addAdd /
     addAdd64_64 / concatAdd / leakyAddZ3 / leakySubZ3（它们不以 "addsub" 开头，默认正则匹配不到）。
  3. **可选 add|sub**（第 4 参）：要求体内出现 `aExt + bExt` 或 `aExt - bExt`
     （= 原 tcl 的 `CONFIG.Add_Mode` = Add/Subtract 这个静态开关）。不传则不检查。

注意：本判据**只证结构**（级数 / 加或减），**不证数值等价**，也不证符号性
（符号性由发出的 `$signed(...)`/`$signed({1'b0,...})` 决定，数值上另用 iverilog 交叉验证，
见 reports/build_notes.md 的 B9b 节）。
"""
import re
import sys

sys.stdout.reconfigure(errors="replace")

if len(sys.argv) < 3:
    print("usage: check_addsub_latency.py <verilog> <expected_stages> [module_name] [add|sub]")
    sys.exit(2)

path = sys.argv[1]
exp_stages = int(sys.argv[2])
mod_filter = sys.argv[3] if len(sys.argv) > 3 else None
exp_op = sys.argv[4] if len(sys.argv) > 4 else None

txt = open(path, encoding="utf-8", errors="replace").read()
if mod_filter:
    m = re.search(r"module\s+" + re.escape(mod_filter) + r"\b(.*?)\bendmodule", txt, re.S)
else:
    m = re.search(r"module\s+(AddSub|addsub\w*)\b(.*?)\bendmodule", txt, re.S)
if not m:
    print("FAIL: 找不到 AddSub 模块体")
    sys.exit(2)
mod_name, body = (mod_filter, m.group(1)) if mod_filter else (m.group(1), m.group(2))

# --- 检查 1：流水级数 ---
idx = sorted({int(i) for i in re.findall(r"addPipe_(\d+)", body)})
stages_ok = (len(idx) == exp_stages) and (idx == list(range(exp_stages)))

print(f"module={mod_name}")
print(f"expected_stages={exp_stages} detected_stages={len(idx)} indices={idx}")

ok = stages_ok

# --- 检查 3（可选）：加还是减 ---
if exp_op is not None:
    if exp_op not in ("add", "sub"):
        print(f"FAIL: 第 4 参只能是 add|sub，实为 {exp_op}")
        sys.exit(2)
    want = r"aExt\s*\+\s*bExt" if exp_op == "add" else r"aExt\s*-\s*bExt"
    others = r"aExt\s*-\s*bExt" if exp_op == "add" else r"aExt\s*\+\s*bExt"
    found = re.search(want, body) is not None
    wrong = re.search(others, body) is not None
    print(f"expected_op={exp_op} found={found} opposite_op_present={wrong}")
    ok = ok and found and not wrong

print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
