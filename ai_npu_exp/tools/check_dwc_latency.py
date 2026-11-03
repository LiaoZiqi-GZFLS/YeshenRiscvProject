#!/usr/bin/env python3
"""B9b 判据：流位宽转换器（原 Xilinx axis_dwidth_converter IP）的**结构**契约。

usage: check_dwc_latency.py <verilog> <expected_stages> [s_width] [m_width] [module_name]

检查项（三项互相独立，各自能咬）：
  1. **存储级数**：module 体内 `dwcPipe_<n>` 的不同索引个数 == expected_stages，
     且索引恰为 0..N-1。生产值 = 比例 R = M/S = 8（升宽 1:R 至少要收齐 R 个窄拍）。
  2. **方向（可选，给 s_width/m_width 时）**：端口声明必须是 `s_axis_tdata [S-1:0]`、
     `m_axis_tdata [M-1:0]`，且 **S < M** ⇒ 证明确实是「窄进宽出」（升宽）而不是反过来。
     依据：唯一调用点 `FeatureWidthConvert.scala:65,66` 的 `S_DATA_WIDTH=128` / `M_DATA_WIDTH=1024`，
     以及真网表里 `s_axis_tdata[127:0]` / `m_axis_tdata[1023:0]` 的实例端口。
  3. **打包顺序**：驱动 `dwcData` 的 concat 里，`dwcPipe_<i>` 必须按 **0,1,...,N-1 递增** 出现
     （每个恰好一次）⇒ 最先被接收的窄拍（存在 `dwcPipe_{N-1}`）落在**最低位**
     （`m_axis_tdata[S-1:0]`）。这是 AXI4-Stream 的 byte-lane 约定，也是调用点的假设
     （`mData.payload.subdivideIn(8 slices)(i)`，slice 0 = `[127:0]` = 最低位）。顺序反过来会被检查 3 抓住。

第 5 参是 module 名（可选）：不传时按实现实际发出的名字匹配（装置里 componentName = "dwc"）；
传了就点名检查 —— 用于在**真网表** gen/Npu.v 上检查 `conv11DataCvt`。

**不证**：与 Xilinx IP 的逐拍等价（原 tcl 里**没有任何延迟键**，无从推出 IP 固有拍数），
也不证数值/握手时序 —— 数值另用 iverilog 交叉验证（见 reports/build_notes.md 的 B9b 节）。
"""
import re
import sys

sys.stdout.reconfigure(errors="replace")

if len(sys.argv) < 3:
    print("usage: check_dwc_latency.py <verilog> <expected_stages> [s_width] [m_width] [module_name]")
    sys.exit(2)

path = sys.argv[1]
exp_stages = int(sys.argv[2])
s_width = int(sys.argv[3]) if len(sys.argv) > 3 else None
m_width = int(sys.argv[4]) if len(sys.argv) > 4 else None
mod_filter = sys.argv[5] if len(sys.argv) > 5 else None

txt = open(path, encoding="utf-8", errors="replace").read()
if mod_filter:
    m = re.search(r"module\s+" + re.escape(mod_filter) + r"\b(.*?)\bendmodule", txt, re.S)
else:
    m = re.search(r"module\s+(StreamDataWidthConvert|dwc\w*)\b(.*?)\bendmodule", txt, re.S)
if not m:
    print("FAIL: 找不到 StreamDataWidthConvert 模块体")
    sys.exit(2)
mod_name, body = (mod_filter, m.group(1)) if mod_filter else (m.group(1), m.group(2))

print(f"module={mod_name}")

# --- 检查 1：存储级数 ---
idx = sorted({int(i) for i in re.findall(r"dwcPipe_(\d+)", body)})
stages_ok = (len(idx) == exp_stages) and (idx == list(range(exp_stages)))
print(f"expected_stages={exp_stages} detected_stages={len(idx)} indices={idx}")

ok = stages_ok

# --- 检查 2（可选）：位宽方向 ---
if s_width is not None and m_width is not None:
    ms = re.search(r"input\s+(?:wire\s+)?\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*s_axis_tdata", body)
    mm = re.search(r"output\s+(?:wire\s+)?\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*m_axis_tdata", body)
    if not ms or not mm:
        print("FAIL: 找不到 s_axis_tdata / m_axis_tdata 的端口声明")
        sys.exit(2)
    s_decl = int(ms.group(1)) + 1
    m_decl = int(mm.group(1)) + 1
    dir_ok = (s_decl == s_width) and (m_decl == m_width) and (s_width < m_width)
    print(f"expected_s_axis_tdata={s_width} declared={s_decl} | expected_m_axis_tdata={m_width} declared={m_decl}"
          f" | narrow_to_wide={s_width < m_width}")
    ok = ok and dir_ok

# --- 检查 3：打包顺序 ---
# 槽位语义：`dwcPipe_<k>` = 本包第 k 个窄拍（k=0 是最先到的）。Verilog 的 concat 最左元素放最高位，
# 所以"最先到的拍落在最低位"= concat 里索引**严格递减**：{dwcPipe_{N-1}, ..., dwcPipe_1, dwcPipe_0}。
mc = re.search(r"assign\s+dwcData\s*=\s*\{([^}]*)\}", body)
if not mc:
    print("FAIL: 找不到驱动 dwcData 的 concat")
    sys.exit(2)
order = [int(i) for i in re.findall(r"dwcPipe_(\d+)", mc.group(1))]
want_order = list(range(exp_stages - 1, -1, -1))
order_ok = (order == want_order)
print(f"packing_order={order} (need {want_order}; descending <=> first beat (slot 0) at LSBs)")
ok = ok and order_ok

print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
