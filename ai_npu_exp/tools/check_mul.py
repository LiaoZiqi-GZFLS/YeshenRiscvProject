import re, sys
sys.stdout.reconfigure(errors="replace")

# usage: check_mul.py <verilog> <expected_stages> <expected_msb> <expected_lsb>
#
# B8 判据（结构性，不是数值等价）：从单个 Mul 小装置的 Verilog 里查两条契约。
#   1. **流水深度**：module 体内 `mulPipe_<n>` 的不同索引个数 == expected_stages，
#      且索引恰为 0..N-1（连续、从 0 起 ⇒ 是真正的顺序移位流水，而不是随手加的寄存器）。
#   2. **输出位段**：驱动 `P` 的赋值语句里出现 `[expected_msb:expected_lsb]`
#      （= 原 Xilinx mult_gen 的 `OutputWidthHigh` / `OutputWidthLow`）。
#
# 重载 1（不给位段，LeakyRelu / Shape）的「完整乘积、无切片」怎么表达：
#   原 tcl 里重载 1 设 `OutputWidthHigh = P_WIDTH-1`、不设 `OutputWidthLow`（默认 0），
#   所以「无切片」== 位段 `[P_WIDTH-1:0]`。实现里也**显式**发出 `assign P = mulPipe_N[P_WIDTH-1:0];`，
#   于是判据不需要额外的 `--full` 模式：传 `<P_WIDTH-1> <0>` 就精确表达了「完整乘积」，
#   而且照样能做正负对照。（任务书模板里那个 `[--full]` 占位因此没实现——它要表达的东西
#   用 (msb, lsb) 就能表达。）
#
# 相对任务书模板的改动（**两处都是加强，不是削弱**）：
#   a. module 名正则按实现实际发出的名字匹配（componentName = "mul"，命中 `mul\w*`）；
#      另加一个**可选**第 5 参用于在真网表上点名检查 scaleMul/concatMul/... （默认不变）。
#   b. 除模板的「体内任意切片命中」外，**额外要求**命中出现在**驱动 P 的赋值语句**里。
#      原因：模板只看「体内任意 [a:b]」，而 P 的端口声明 `output wire [31:0] P` 本身就在体内，
#      会让 (31,0) 之类的期望**蒙混过关**（LeakyRelu 那一路就正好是 32→[31:0]）。
#      P 赋值语句里的切片才是真正的位段选择，所以两条都查、取与。
path = sys.argv[1]
exp_stages = int(sys.argv[2])
msb = int(sys.argv[3])
lsb = int(sys.argv[4])
# 可选第 5 参：显式指定要检查的 module 名。用于在**真网表** gen/Npu.v 上逐个检查真实调用点的
# 模块 scaleMul / concatMul / addMul / leakyReluMul / shapeCount1 —— 它们不以 "mul" 开头，
# 默认正则匹配不到。不传时退回任务书模板的正则，默认行为与检查强度都不变。
mod_filter = sys.argv[5] if len(sys.argv) > 5 else None

txt = open(path, encoding="utf-8", errors="replace").read()
if mod_filter:
    m = re.search(r"module\s+" + re.escape(mod_filter) + r"\b(.*?)\bendmodule", txt, re.S)
else:
    m = re.search(r"module\s+(Mul|mul\w*)\b(.*?)\bendmodule", txt, re.S)
if not m:
    print("FAIL: 找不到 Mul 模块体")
    sys.exit(2)
mod_name, body = (mod_filter, m.group(1)) if mod_filter else (m.group(1), m.group(2))

# --- 检查 1：流水级数 ---
idx = sorted({int(i) for i in re.findall(r"mulPipe_(\d+)", body)})
stages_ok = (len(idx) == exp_stages) and (idx == list(range(exp_stages)))

# --- 检查 2：位段 ---
slices = re.findall(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", body)
body_slice_ok = any(int(a) == msb and int(b) == lsb for a, b in slices)
# 驱动 P 的赋值里的切片（严格更强的一路）
passign = re.findall(r"\bP\s*(?:<=|=)\s*[^;]*?\[\s*(\d+)\s*:\s*(\d+)\s*\]", body)
passign_ok = any(int(a) == msb and int(b) == lsb for a, b in passign)

print(f"module={mod_name}")
print(f"expected_stages={exp_stages} detected_stages={len(idx)} indices={idx}")
print(f"expected_slice=[{msb}:{lsb}] slices_found={sorted({(int(a), int(b)) for a, b in slices})}")
print(f"P-assign slices={sorted({(int(a), int(b)) for a, b in passign})} (need [{msb}:{lsb}])")

ok = stages_ok and body_slice_ok and passign_ok
print("RESULT:", "PASS" if ok else "FAIL", "")
sys.exit(0 if ok else 1)
