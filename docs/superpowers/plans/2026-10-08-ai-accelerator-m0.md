# AI 加速模块可行性探针（M0）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 回答「YOLOv5 族的检测网 + 这个 SpinalHDL CNN 加速器 + 盘古676 200K」能否落地 —— 产出①算子覆盖表（无"不覆盖"项）与②本器件上的资源/时序数字。

**Architecture:** 两条互不依赖的主线。**Part A（算子核实）** 取 ultralytics YOLOv5 v3.0 → 导出 opset-11 ONNX → 用通用分析脚本逐层展开 → 对照加速器算子面出三态覆盖表。**Part B（RTL 探针）** 从只读克隆复制 Scala 源码到独立工程 → 用"覆盖文件"机制把 4 处 Xilinx IP 依赖换成纯 SpinalHDL/行为模型（守住延迟契约）→ sbt 生成 Verilog → PDS `dev_map` 出资源数字。

**Tech Stack:** Scala 2.12.18 / SpinalHDL 1.15.0（`sbt`，JDK 17）；Python 3.9 + onnx 1.19.1（`NaxYeshenLinux/sim/reglogs/lxvenv`）；Pango PDS 2025.2（`dev_map` / `pnr`）；YOLOv5 v3.0（ultralytics release 资产）。

**Spec:** `docs/superpowers/specs/2026-10-08-ai-accelerator-m0-design.md`

---

## 全局约定（每个 Task 都适用）

- **只读克隆零改动**：`third_party/SpinalHDL_CNN_Accelerator` 只读。所有改动落在 `ai_npu_exp/`。每个 Task 收尾都用
  `git -C third_party/SpinalHDL_CNN_Accelerator status --porcelain` 自证为空。
- **代理**：取件/拉依赖前 `export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897`。
- **判据带正负对照**：每个自写判据脚本都要喂一份已知-good 与一份已知-bad 输入，必须一绿一红。
- **产物指纹**：每步记 md5 / 字节数，写进报告。
- **提交**：本机无 git 身份，用一次性环境变量（**不 push**）：
  ```bash
  GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  git commit -m "<msg>"
  ```

## 文件结构（先定死，再动手）

```
VexiiYeshenLinux/ai_npu_exp/
├── tools/
│   ├── onnx_report.py            # 通用 ONNX 算子/分组/形状报告（Part A 的引擎）
│   ├── check_coverage.py         # 覆盖表判据：把报告映射到加速器算子面并判三态
│   └── check_sdpram_latency.py   # sdpram 延迟契约判据（含正负对照）
├── port/
│   ├── apply_pango_port.sh       # 复制只读克隆 → rtl_src/ 并覆盖 5 个文件
│   ├── build.sbt                 # M0 工程自己的 sbt 构建（指向 rtl_src）
│   └── override/                 # 我们的 Pango 化版本（整文件覆盖，便于逐文件审）
│       ├── config/Config.scala
│       ├── wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala
│       ├── wa/WaFifo.scala
│       ├── wa/xip/math/DSP.scala
│       ├── wa/xip/math/Mul.scala
│       └── misc/TotalTcl.scala
├── rtl_src/                      # [gitignored] apply_pango_port.sh 生成的副本
├── models/                       # [gitignored] yolov5s.pt / yolov5s.onnx
├── gen/                          # [gitignored] 生成的 Verilog
├── pds/                          # dev_map tcl（入库）+ 日志（gitignored）
└── reports/                      # 入库：算子报告、覆盖表、资源与结论
```

`ai_npu_exp/.gitignore`：
```
rtl_src/
models/
gen/
*.log
deps_export/
```
（`deps_export/` 是 A3 装 torch 的隔离目录，Windows 轮子实测 **3.5 GB** —— 必须忽略。）

---

# Part A —— 算子覆盖核实（主线 B′）

> Part A 与 Part B 互不依赖；Part A 的结论决定 Part B 的值不值得跑（spec §5.4/§5.5）。

### Task A1: M0 工程骨架 + 通用 ONNX 报告脚本（含正负对照）

**Files:**
- Create: `ai_npu_exp/.gitignore`
- Create: `ai_npu_exp/tools/onnx_report.py`
- Reuse（只读）: `third_party/yunet/analyze_yunet.py`（母本）、`third_party/yunet/deps`（onnx 1.19.1）、`third_party/yunet/yunet.onnx`（正对照输入）

- [ ] **Step 1: 建目录与 .gitignore**

```bash
mkdir -p ai_npu_exp/{tools,port/override,models,gen,pds,reports}
cat > ai_npu_exp/.gitignore <<'EOF'
rtl_src/
models/
gen/
*.log
EOF
```

- [ ] **Step 2: 先写判据（`onnx_report.py` 的输出契约）**

`onnx_report.py` 必须打印固定 5 段，供后续机器判定（顺序固定）：
1. `== io ==` 行：输入/输出的 name 与 shape；
2. `== ops ==` 段：`<op_type> <count>` 每行一个，按 count 降序；
3. `== conv ==` 段：每个 Conv 一行 `idx name group=.. k=.. s=.. p=.. d=..`；
4. `== conv_group_hist ==` 行：`{group: count}`；
5. `== activations ==` 段：出现的非线性算子与实际 gate（若可从 initializer 或属性判出）。

- [ ] **Step 3: 实现 `onnx_report.py`（由 `analyze_yunet.py` 通用化）**

要点：把母本里硬编码的文件名换成 `argv[1]`；把 activation 段改为"只列实际出现的非线性算子，不预设候选清单"；`sys.stdout.reconfigure(errors="replace")` 必须有（Windows GBK）。

```python
import sys, collections, json
import onnx

sys.stdout.reconfigure(errors="replace")
path = sys.argv[1]
m = onnx.load(path)
g = m.graph

def dims(t):
    return [d.dim_value if d.HasField("dim_value") else (d.dim_param or "?")
            for d in t.type.tensor_type.shape.dim]

print("== io ==")
for i in g.input:
    print(f"  in  {i.name} {dims(i)}")
for o in g.output:
    print(f"  out {o.name} {dims(o)}")

hist = collections.Counter(n.op_type for n in g.node)
print("== ops ==")
for k, v in hist.most_common():
    print(f"  {k} {v}")

print("== conv ==")
groups = collections.Counter()
idx = 0
for n in g.node:
    if n.op_type != "Conv":
        continue
    idx += 1
    a = {x.name: x for x in n.attribute}
    def gi(k, d=None):
        if k not in a:
            return d
        v = a[k]
        return list(v.ints) if v.ints else v.i
    grp = gi("group", 1)
    groups[grp] += 1
    print(f"  {idx} {n.name[:40]} group={grp} k={gi('kernel_shape')} "
          f"s={gi('strides')} p={gi('pads')} d={gi('dilations')}")
print(f"== conv_group_hist == {json.dumps(dict(sorted(groups.items())))}")

NONLINEAR = {"Relu", "LeakyRelu", "PRelu", "Sigmoid", "Softmax", "Tanh",
             "HardSigmoid", "HardSwish", "Silu", "Swish", "Clip", "Exp", "Elu", "Mish"}
print("== activations ==")
hit = {k: hist[k] for k in sorted(NONLINEAR) if hist.get(k)}
if not hit:
    print("  (none)")
for k, v in hit.items():
    print(f"  {k} {v}")
```

- [ ] **Step 4: 跑正对照 —— 必须复现 YuNet 的已知数字**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH=../third_party/yunet/deps \
  ../../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/onnx_report.py ../third_party/yunet/yunet.onnx
```
Expected（spec §3.2 的既知值，逐条核对）：
- `== conv_group_hist == {"1": 33, "10": 3, "16": 2, "32": 2, "4": 3, "64": 10}`
- `== ops ==` 含 `Conv 53`、`Relu 15`、`Transpose 12`、`Reshape 12`、`Sigmoid 6`、`MaxPool 4`、`Resize 2`、`Add 2`
- `== activations ==` 只有 `Relu 15`、`Sigmoid 6`

任一不符 ⇒ **停**，先修脚本（不是改期望值）。

- [ ] **Step 5: 跑负对照 —— 坏输入必须报错，不能"安静地 0 算子"**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH=../third_party/yunet/deps \
  ../../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/onnx_report.py ../third_party/yunet/face_detection_yunet_2023mar.onnx ; echo "exit=$?"
```
（该文件是 131 B 的 git-lfs 指针，不是 ONNX。）
Expected: 非 0 退出，且 stderr 有 protobuf/onnx 解析失败信息；**不得**打印出 `== ops ==` 且计数为 0。

- [ ] **Step 6: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/.gitignore ai_npu_exp/tools/onnx_report.py
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): 通用 ONNX 算子报告脚本（YuNet 正对照 + lfs 指针负对照）"
```

---

### Task A2: 取 YOLOv5 v3.0 权重（记指纹）

**Files:**
- Create: `ai_npu_exp/models/yolov5s.pt`（gitignored）

- [ ] **Step 1: 下载并核指纹**

Run:
```bash
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/models
curl -sSL --max-time 300 -o yolov5s.pt \
  https://github.com/ultralytics/yolov5/releases/download/v3.0/yolov5s.pt
ls -l yolov5s.pt && sha256sum yolov5s.pt
```
Expected: `Content-Length: 15184597`（HEAD 已实测）；落到 15,184,597 B。字节数不符 ⇒ 停（可能是 LFS 指针或重定向页面），先 `head -c 64 | xxd` 看是不是 `PK`（zip/pytorch 归档魔数）。

- [ ] **Step 2: 记指纹**

把 URL、字节数、sha256 写进 `ai_npu_exp/reports/model_provenance.md`（本 Task 只写这一个文件，后续 Task 追加）。

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/reports/model_provenance.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "docs(m0): 记 YOLOv5 v3.0 权重来源与指纹"
```

---

### Task A3: 导出 ONNX（opset 11，去 NMS）

**Files:**
- Create: `ai_npu_exp/tools/export_onnx.py`
- Create: `ai_npu_exp/models/yolov5s.onnx`（gitignored）

- [ ] **Step 1: 装导出依赖（隔离目录，不污染既有 venv）**

Run:
```bash
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
../../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe -m pip install --quiet --target ./deps_export torch --index-url https://pypi.org/simple
ls deps_export | head
```
Expected: 目录里出现 `torch`。失败（网络/体积）⇒ 记录到 `reports/model_provenance.md` 并跳到 **Step 4 的退路**。

- [ ] **Step 2: 写导出脚本**

```python
# tools/export_onnx.py  —— 只取 raw 卷积图：不做 NMS，不做 anchor 解码
import sys, torch
sys.stdout.reconfigure(errors="replace")
pt, out = sys.argv[1], sys.argv[2]
model = torch.load(pt, map_location="cpu", weights_only=False)["model"]
model = model.model if hasattr(model, "model") else model
model.eval()
dummy = torch.zeros(1, 3, 640, 640)
torch.onnx.export(
    model, dummy, out,
    opset_version=11,
    input_names=["input"],
    output_names=["output"],
    do_constant_folding=True,
    dynamic_axes=None,
)
print("wrote", out)
```

（若 `model.model` 属性名与该版本不符，用 `print(type(model))` 先看清结构再改这一行 —— **只改这一行**。）

- [ ] **Step 3: 导出并核产物**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH=./deps_export \
  ../../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/export_onnx.py \
  models/yolov5s.pt models/yolov5s.onnx
ls -l models/yolov5s.onnx && sha256sum models/yolov5s.onnx
```
Expected: 生成非空 `.onnx`（量级数 MB）。0 字节 ⇒ 失败。

- [ ] **Step 4: 退路（仅当 Step 1/3 失败）**

不导出 ONNX，改写 `reports/model_provenance.md`：证据等级标为 **"源码级，未做 ONNX 级核实"**，并以 v3.0 的 `models/common.py`（`nn.LeakyReLU(0.1)`）与 `models/yolov5s.yaml`（`Focus`/`SPP`/`Upsample`/`Concat`/anchors）作为对照依据；Task A4 整段跳过。**不得**把源码级结论写成 ONNX 级结论。

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/tools/export_onnx.py ai_npu_exp/reports/model_provenance.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): YOLOv5 v3.0 -> ONNX(opset11) 导出脚本与指纹"
```

---

### Task A3 修订（2026-10-08，实证推翻假设）

原 A3 假设 "release 资产 `yolov5s.pt` 就是 LeakyReLU 那版"。**实测推翻**：该资产里 51 个 `Conv.act` 是 `nn.Hardswish`（ONNX 里成 `HardSigmoid`+`Mul`），只有 8 个 `BottleneckCSP` 内部激活是 `LeakyReLU(0.1)`；而 tag v3.0 的源码是**全 LeakyReLU**。⇒ **资产 ≠ 源码**，直接拿资产核算子会误判"不覆盖"（假阴性）。

**因此 A3 拆成三片，实际走的是 A3a/A3b/A3c：**
- **A3a（已完成，commit `7096fc7`）**：克隆 tag v3.0 到 `third_party/yolov5_v3.0`（commit `1ddf692b…`）+ 装 torch CPU 到 `deps_export` + `tools/probe_pt.py` 自证 `torch.load` 成功。（`deps_export/` 已加进 `.gitignore`，Windows 轮子 3.5 GB。）
- **A3b（已完成，commit `93566ea`）**：`tools/export_onnx.py` 把**资产**导成 `models/yolov5s.onnx`（29,905,151 B，opset 11）。**此产物保留作对照件，但不作为 M0 结论依据**（它是 Hardswish 版）。
- **A3c（替代原 A3 的正式产物）**：由 **tag v3.0 源码 + `models/yolov5s.yaml` 构建（随机权重）** 再导一份 → `models/yolov5s_v3src.onnx`。**门禁：op 直方图必须含 `LeakyRelu`（计数 > 0），且不得含 `HardSigmoid`/`Sigmoid`。** 这份才是 A4/A5 与 M0 结论的输入。

---

### Task A4: 跑算子报告并落盘

**Files:**
- Create: `ai_npu_exp/reports/ops_yolov5s_v3.md`

- [ ] **Step 1: 跑报告**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH=../third_party/yunet/deps \
  ../../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/onnx_report.py models/yolov5s.onnx > reports/ops_yolov5s_v3.txt
head -40 reports/ops_yolov5s_v3.txt
```
Expected: `== io ==` 里输入 `[1,3,640,640]`；`== conv_group_hist == {"1": N}` —— **只应有 group=1 这一档**（YOLOv5 主干是稠密卷积）。若出现非 1 的 group ⇒ 照实记录，这是 §5.5 的"不覆盖"项。

- [ ] **Step 2: 把报告整理成 Markdown**

把 `ops_yolov5s_v3.txt` 的内容按 5 段抄进 `reports/ops_yolov5s_v3.md`（不筛不改），并在顶部记 `models/yolov5s.onnx` 的 sha256。

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/reports/ops_yolov5s_v3.txt ai_npu_exp/reports/ops_yolov5s_v3.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "docs(m0): YOLOv5 v3.0 原始算子报告落盘"
```

---

### Task A5: 三态覆盖表 + 判定

**Files:**
- Create: `ai_npu_exp/tools/check_coverage.py`
- Create: `ai_npu_exp/reports/coverage_m0.md`

- [ ] **Step 1: 先写判据（加速器的算子面，写死在脚本里，来源=spec §3.1）**

`check_coverage.py` 输入 `ops_yolov5s_v3.txt`，输出每算子一行的三态，并按 spec §5.3 的**位置规则**归类：

```python
import sys, re, json
sys.stdout.reconfigure(errors="replace")

# 加速器原生支持（来源：third_party/SpinalHDL_CNN_Accelerator，spec §3.1）
NATIVE = {
    "Conv":        "覆盖（conv33/conv11，仅 group=1）",
    "Relu":        "覆盖（=LeakyRelu ratio 0，需配置化）",
    "LeakyRelu":   "覆盖（ratio 硬编码 0.1）",
    "MaxPool":     "覆盖（shape/MaxPooling）",
    "Add":         "覆盖（shape/Add）",
    "Concat":      "覆盖（shape/Concat）",
    "Split":       "覆盖（shape/Split）",
    "Resize":      "覆盖（shape/UpSampling；若为最近邻）",
    "Upsample":    "覆盖（shape/UpSampling）",
}
# 块间/头外 → 至多主机旁路
HOST_SIDELOAD = {"Transpose", "Reshape", "Sigmoid", "Slice", "Shape", "Gather",
                 "Unsqueeze", "Squeeze", "Flatten", "Constant", "Cast", "Mul", "Div", "Sub"}

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ops = dict(re.findall(r"^  (\w+) (\d+)$", text, re.M))
groups = json.loads(re.search(r"== conv_group_hist == (\{.*\})", text).group(1))
acts  = set(re.findall(r"^  (\w+) \d+$", text.split("== activations ==")[1], re.M)) \
        if "== activations ==" in text else set()

bad = []
print("| op | count | decision |")
print("|---|---|---|")
for op, cnt in sorted(ops.items(), key=lambda kv: -int(kv[1])):
    d = NATIVE.get(op) or HOST_SIDELOAD.get(op)
    if d is None:
        d = "不覆盖（未知算子）"; bad.append(op)
    print(f"| {op} | {cnt} | {d} |")

if any(int(v) > 1 for v in groups.values()):
    print(f"\n不覆盖：存在分组卷积 {groups}")
    bad.append("grouped-conv")
for a in ("Silu", "Swish", "HardSwish", "PRelu", "Elu", "Mish"):
    if a in acts:
        print(f"不覆盖：块内激活 {a} 不在加速器能力内")
        bad.append(a)

print("\nRESULT:", "PASS" if not bad else "FAIL " + ",".join(sorted(set(bad))))
```

- [ ] **Step 2: 跑判据（正对照 + 负对照）**

正对照 —— YuNet 必须 FAIL 且点名 grouped-conv（复现 spec §3.2 的裁决）：
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
PYTHONPATH=../third_party/yunet/deps \
  ../NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/onnx_report.py \
  ../third_party/yunet/yunet.onnx > /tmp/yunet_ops.txt
python tools/check_coverage.py /tmp/yunet_ops.txt | tail -3
```
Expected: `RESULT: FAIL grouped-conv`

负对照 —— YOLOv5 v3.0 应当 PASS：
```bash
python tools/check_coverage.py reports/ops_yolov5s_v3.txt | tail -3
```
Expected: `RESULT: PASS`

**两条必须一红一绿。** 若 YuNet 也报 PASS ⇒ 判据自己坏了（没读进 group），先修脚本。

- [ ] **Step 3: 写覆盖表报告**

`reports/coverage_m0.md`：贴 Step 2 的两张表 + 两行 RESULT，并写一句结论（通过/回炉）。回炉则按 spec §5.5 的规则处理，**不在本 Task 内自行改硬件或换模型**。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/tools/check_coverage.py ai_npu_exp/reports/coverage_m0.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): 三态算子覆盖判据 + 覆盖表（YuNet 负对照 FAIL / v3.0 PASS）"
```

---

# Part B —— RTL 生成 + Pango 化 + 综合闸门（主线 A）

> Part B 的"测试"= 编译/生成/结构判据，都是可跑命令 + 确定期望值。

### Task B1: Pango 化工作区（复制 + 覆盖机制 + 自证零改动）

**Files:**
- Create: `ai_npu_exp/port/apply_pango_port.sh`
- Create: `ai_npu_exp/port/override/config/Config.scala`（本 Task 先只放原样副本，后续 Task 改）

- [ ] **Step 1: 写覆盖脚本**

```bash
#!/usr/bin/env bash
# 复制只读克隆的 Scala 源到 rtl_src/，再用 port/override/ 整文件覆盖。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$root/../third_party/SpinalHDL_CNN_Accelerator/src/main/scala"
dst="$root/rtl_src"

[ -d "$src" ] || { echo "FATAL: 克隆缺失 $src"; exit 1; }
rm -rf "$dst"; mkdir -p "$dst"
cp -r "$src/." "$dst/"

n=0
while IFS= read -r -d '' f; do
  rel="${f#$here/override/}"
  [ -f "$dst/$rel" ] || { echo "FATAL: 覆盖目标不存在 $rel"; exit 1; }
  cp "$f" "$dst/$rel"
  echo "override: $rel"
  n=$((n+1))
done < <(find "$here/override" -name '*.scala' -print0)
echo "applied $n override(s) into $dst"
```

- [ ] **Step 2: 造 `Config.scala` 的覆盖副本并先只做 `useUram` 一处改**

`cp third_party/SpinalHDL_CNN_Accelerator/src/main/scala/config/Config.scala ai_npu_exp/port/override/config/Config.scala`，然后把 `val useUram = true` 改成 `val useUram = false`（Pango 无 URAM）。

- [ ] **Step 3: 跑脚本 + 自证克隆零改动**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash port/apply_pango_port.sh
diff -r rtl_src ../third_party/SpinalHDL_CNN_Accelerator/src/main/scala | head -20
git -C ../third_party/SpinalHDL_CNN_Accelerator status --porcelain | head
```
Expected: 脚本打印 `applied 1 override(s)`；`diff -r` **只有 Config.scala 一行差异**（`useUram`）；`git status --porcelain` **为空**。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/apply_pango_port.sh ai_npu_exp/port/override/config/Config.scala
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): Pango 化工作区（复制+覆盖机制，克隆零改动自证通过）"
```

---

### Task B2: sbt 工具链（复用本机既装，含代理）

**Files:**
- Create: `ai_npu_exp/port/build.sbt`
- Create: `ai_npu_exp/port/project/build.properties`
- Create: `ai_npu_exp/port/sbt.sh`（带代理的启动包装）

- [ ] **Step 1: 核实本机既装的 sbt —— **不要再去下载 sbt****

`third_party/PINS.md` 的工具链表已记录：sbt runner **2.0.6**，路径 `C:\Users\Ziqi\AppData\Local\Coursier\data\bin\sbt.bat`（该目录不在 Git Bash 的 PATH 上，所以 `command -v sbt` 会误报"没有"）。

Run:
```bash
"/c/Users/Ziqi/AppData/Local/Coursier/data/bin/sbt.bat" --version
# 取一个本机已用过的 sbt 版本，避免联网拉新版本
cat /d/code/PDS/VexiiYeshenLinux/third_party/VexiiRiscv/project/build.properties 2>/dev/null || echo "(无 build.properties)"
```
Expected: 打印 `sbt runner version: 2.0.6`；第二行给出一个 `sbt.version=`（记为 `<V>`）。

- [ ] **Step 2: 写构建与包装脚本**

`ai_npu_exp/port/project/build.properties`（**必需**：加速器仓没有 `project/` 目录，sbt 必须由我们声明版本）：
```
sbt.version=<V>
```
（`<V>` 取 Step 1 第二行的值；取不到就用 `1.10.7`。）

`ai_npu_exp/port/build.sbt`:
```scala
name := "ai_npu_exp_m0"
version := "0.1"
scalaVersion := "2.12.18"
fork := true
Compile / scalaSource := baseDirectory.value / ".." / "rtl_src"
Test    / scalaSource := baseDirectory.value / ".." / "rtl_test"
libraryDependencies ++= Seq(
  "com.github.spinalhdl" % "spinalhdl-core_2.12" % "1.15.0",
  "com.github.spinalhdl" % "spinalhdl-lib_2.12"  % "1.15.0",
  compilerPlugin("com.github.spinalhdl" % "spinalhdl-idsl-plugin_2.12" % "1.15.0"),
  "com.google.code.gson" % "gson" % "2.7"
)
```

`ai_npu_exp/port/sbt.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
export JAVA_HOME="/c/Program Files/Eclipse Adoptium/jdk-17.0.20.8-hotspot"
export PATH="$JAVA_HOME/bin:/c/Users/Ziqi/AppData/Local/Coursier/data/bin:$PATH"
ADDR="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
exec sbt.bat $ADDR "$@"
```

（`coursier/data/bin` 下只有 `sbt.bat`，没有无扩展名的 `sbt`，所以必须写 `sbt.bat`。）

- [ ] **Step 3: 自证工具链可用**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/port
bash sbt.sh --version
```
Expected: 先打印 `sbt runner version: 2.0.6`，再打印 declared 版本（= `<V>`）；无 `command not found`。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/build.sbt ai_npu_exp/port/sbt.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): M0 工程 sbt 构建（JDK17 + 代理包装）"
```

---

### Task B3: `sbt compile` 过

**Files:**
- Modify: `ai_npu_exp/port/build.sbt`（按需加依赖）

- [ ] **Step 1: 编译**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/port
bash sbt.sh compile 2>&1 | tail -40
```
Expected: `[success]`。

- [ ] **Step 2: 按决策规则处理编译失败**

- 若报 `org.apache.commons.io` 找不到（`TDRam.scala` / `Mul.scala` / `TotalTcl.scala` 用到，而上游 `build.sbt` 未声明）：在 `build.sbt` 的 `libraryDependencies` 里**追加一行** `"commons-io" % "commons-io" % "2.11.0",`，重跑 Step 1。
- 若报 SpinalHDL API 不兼容：把该文件的 API 用法对到 1.15.0（`Mem.readSync(address, enable, outputStage)`、`StreamFifo`、`Vec`），**不改 RTL 语义**。
- 其它错误：把**原始报错全文**记入 `reports/build_notes.md` 后再改，不要凭猜改。

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/build.sbt ai_npu_exp/reports/build_notes.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "fix(m0): sbt compile 通过（依赖/API 修正记录）"
```

---

### Task B4: 生成 Npu Verilog（记指纹）

**Files:**
- Create: `ai_npu_exp/rtl_gen/GenNpu.scala`（M0 自己的生成入口，不动克隆的 `Npu.scala` 入口）
- Create: `ai_npu_exp/gen/`（gitignored）

- [ ] **Step 1: 写生成入口**

克隆的 `Npu.scala` 末尾已有一个 `Npu extends App`，但它把 Verilog 写到 `Config.filePath+"rtl"`。M0 用自己的入口，写到 `ai_npu_exp/gen`：

```scala
import config.Config
import spinal.core._
import conv.compute.ConvConfig
import shape.ShapeConfig

object GenNpu extends App {
    val clockCfg = ClockDomainConfig(resetKind = SYNC, resetActiveLevel = HIGH)
    SpinalConfig(
        headerWithDate = false,
        oneFilePerComponent = false,
        defaultConfigForClockDomains = clockCfg,
        targetDirectory = "./gen"
    ).generateVerilog(new Npu(
        ConvConfig(8, 16, 16, 12, 4096, 512, 10, 10, 2048),
        ShapeConfig(8, 16, 640, 12, 2048)
    ))
}
```

（参数取自克隆 `Npu.scala:185` 的默认例化；`headerWithDate = false` 是为了让生成结果可复现 —— 指印稳定。）

- [ ] **Step 2: 生成**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
mkdir -p rtl_gen gen
cp rtl_gen/GenNpu.scala /dev/null 2>/dev/null || true
cd port && bash sbt.sh "runMain GenNpu" 2>&1 | tail -30
```
Expected: `[success]`；`ai_npu_exp/gen/` 下出现 `.v` 文件。

- [ ] **Step 3: 记指纹（可复现性判据）**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp/gen
ls -l; md5sum *.v | sort
cd ../port && bash sbt.sh "runMain GenNpu" >/dev/null 2>&1
cd ../gen && md5sum *.v | sort
```
Expected: 两次 md5 **逐行相同**（`headerWithDate=false` + SpinalHDL 确定性）。不同 ⇒ 先排查是否混入了时间戳，再往下走。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/rtl_gen/GenNpu.scala
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): Npu 生成入口（确定性指纹两次一致）"
```

---

### Task B5: Pango 化 · 片上双口 RAM（守住 READ_LATENCY 契约）

**背景**：`class sdpram`（`wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala:136`）内部包的是 Xilinx `xpm_memory_sdpram` BlackBox。活用的只有 2 处，都在 `conv/compute/Weight.scala`：:326（权重 RAM，latency=2）、:344（量化 RAM，block/latency=2）。**契约**：`doutb(t) == mem[addrb(t-READ_LATENCY)]`。

**Files:**
- Create: `ai_npu_exp/port/override/wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`
- Create: `ai_npu_exp/rtl_test/SdpramGen.scala`
- Create: `ai_npu_exp/tools/check_sdpram_latency.py`

- [ ] **Step 1: 先写延迟判据（含正负对照）**

`tools/check_sdpram_latency.py` 读生成的 Verilog（或 SpinalHDL 打印的表达式），检查 `doutb` 路径上的寄存级数 == 期望值：

```python
import sys, re
sys.stdout.reconfigure(errors="replace")
# 用法: check_sdpram_latency.py <verilog> <expected_latency>
path, exp = sys.argv[1], int(sys.argv[2])
txt = open(path, encoding="utf-8", errors="replace").read()
# 取 sdpram 模块体
m = re.search(r"module\s+sdpram\b(.*?)endmodule", txt, re.S)
assert m, "找不到 sdpram 模块"
body = m.group(1)
# 数 doutb 赋值链上的 RegNext 展开级：SpinalHDL 会打印 _zz_N 命名
stages = len(re.findall(r"\bdoutb\b\s*<=\s*\w+", body)) + len(re.findall(r"_zz_\w+_regNext", body))
print(f"expected={exp} detected={stages}")
print("RESULT:", "PASS" if stages == exp else "FAIL")
sys.exit(0 if stages == exp else 1)
```

- [ ] **Step 2: 写覆盖副本（纯 SpinalHDL Mem，延迟显式可配）**

整文件覆盖 `wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala`。保留 `xpm_memory_sdpram` 的 `BlackBox` 定义（它不再被例化 ⇒ 不进网表），只把 `class sdpram` 换成：

```scala
class sdpram(
    WRITE_WIDTH: Int, WRITE_DEPTH: Int,
    READ_WIDTH: Int, READ_DEPTH: Int,
    MEMORY_TYPE: String = "block", READ_LATENCY: Int = 2,
    CLOCK_MODE: String = "common_clock",
    clka: ClockDomain, clkb: ClockDomain
) extends Component {
    assert(WRITE_DEPTH * WRITE_WIDTH == READ_DEPTH * READ_WIDTH, "读写空间大小不匹配")
    assert(READ_LATENCY >= 1, "READ_LATENCY 至少为 1")
    val io = new Bundle {
        val doutb = out Bits (READ_WIDTH bits)
        val addra = in Bits (log2Up(WRITE_DEPTH) bits)
        val addrb = in Bits (log2Up(READ_DEPTH) bits)
        val dina  = in Bits (WRITE_WIDTH bits)
        val ena   = in Bool()
        val enb   = in Bool()
        val wea   = in Bits (1 bits)
    }
    noIoPrefix()
    val mem = new Mem(Bits(WRITE_WIDTH bits), wordCount = WRITE_DEPTH)
    mem.write(address = io.addra.asUInt, data = io.dina, enable = io.ena && io.wea(0))
    val rd = mem.readSync(address = io.addrb.asUInt, enable = io.enb, outputStage = false)
    // 显式 READ_LATENCY 级流水：doutb(t) = mem[addrb(t-READ_LATENCY)]
    val dataPipe = Vec(Reg(Bits(READ_WIDTH bits)) init (0), READ_LATENCY)
    val enPipe   = Vec(Reg(Bool()) init (False), READ_LATENCY)
    dataPipe(0) := Mux(io.enb, rd, dataPipe(0))
    enPipe(0)   := io.enb
    for (i <- 1 until READ_LATENCY) {
        dataPipe(i) := Mux(enPipe(i - 1), dataPipe(i - 1), dataPipe(i))
        enPipe(i)   := enPipe(i - 1)
    }
    io.doutb := dataPipe(READ_LATENCY - 1)
}
```

> 说明：`READ_LATENCY` 是构造参数，两个调用点分别传 2，与克隆中 `val latency = if (Config.useUram) 12 else 2` 一致；`useUram` 已在 Task B1 置 false ⇒ 恒为 2。若将来启用 12，该实现同样成立。

- [ ] **Step 3: 加一个只生成 sdpram 的装置**

`ai_npu_exp/rtl_test/SdpramGen.scala`：
```scala
import spinal.core._
object SdpramGen extends App {
    val cfg = SpinalConfig(targetDirectory = "./gen", headerWithDate = false)
    cfg.generateVerilog(new wa.xip.memory.xpm.sdpram(
        64, 512, 64, 512, "block", 2, "common_clock",
        ClockDomain.external("clka"), ClockDomain.external("clkb")))
}
```

- [ ] **Step 4: 跑正负对照**

Run（正：期望 2；负：把参数改成 3，判据必须报 detected=3 且与 expected=2 不符）：
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash port/apply_pango_port.sh   # 应用覆盖
cd port
bash sbt.sh "runMain SdpramGen" 2>&1 | tail -20
cd ../gen && ls sdpram.v
cd ..
python tools/check_sdpram_latency.py gen/sdpram.v 2   # 正对照
```
Expected 正对照: `RESULT: PASS`。
随后把 `SdpramGen` 的 `2` 临时改成 `3`、重生成，跑 `check_sdpram_latency.py gen/sdpram.v 3` ⇒ `detected=3 ... PASS`；再跑 `check_sdpram_latency.py gen/sdpram.v 2` ⇒ `FAIL`。**一红一绿才算判据可信。** 验完把参数改回 2。

- [ ] **Step 5: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/override/wa/xip/memory/xpm/XPM_MEMORY_SDPRAM.scala \
        ai_npu_exp/rtl_test/SdpramGen.scala ai_npu_exp/tools/check_sdpram_latency.py
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): sdpram Pango 化（纯 SpinalHDL Mem，READ_LATENCY 契约带正负对照）"
```

---

### Task B6: Pango 化 · 同步 FIFO

**背景**：`WaXpmSyncFifo`（`wa/WaFifo.scala:48`）内部是 Xilinx `xpm_fifo_sync` BlackBox。活用的只有 1 处：`conv/compute/ConvCompute.scala:120`（feature RAM，`MEM_TYPE.block`、0、`FIFO_READ_MODE.fwft`、深度 `FEATURE_RAM_DEPTH`、宽 `FEATURE_S_DATA_WIDTH`）。

**Files:**
- Create: `ai_npu_exp/port/override/wa/WaFifo.scala`

- [ ] **Step 1: 覆盖 `WaXpmSyncFifo`，**保持对外 IO 逐字不变**（这样 `ConvCompute.scala` 一行都不用改）**

克隆里的对外 IO 是：`sCount/mCount`（in）、`sReady/mReady`（out Reg）、`dataIn`（slave Flow）、`rd_en`（in）、`dout`（out）。替换体用 SpinalHDL `StreamFifo`：

```scala
case class WaXpmSyncFifo(config: XPM_FIFO_SYNC_CONFIG) extends Component {
    val sCount = in UInt (config.WR_DATA_COUNT_WIDTH bits)
    val mCount = in UInt (config.RD_DATA_COUNT_WIDTH bits)
    val sReady = out(Reg(Bool()))
    val mReady = out(Reg(Bool()))
    val dataIn = slave Flow(UInt(config.WRITE_DATA_WIDTH bits))
    val rd_en  = in Bool()
    val dout   = out UInt (config.READ_DATA_WIDTH bits)

    val fifo = StreamFifo(UInt(config.WRITE_DATA_WIDTH bits), config.FIFO_WRITE_DEPTH)
    // 与克隆一致的 1 拍写延迟（原来是 RegNext(dataIn.fire) / RegNext(payload)）
    fifo.io.push.valid   := RegNext(dataIn.fire)
    fifo.io.push.payload := RegNext(dataIn.payload)
    fifo.io.pop.ready    := rd_en
    dout := fifo.io.pop.payload

    when(fifo.io.occupancy + sCount < config.FIFO_WRITE_DEPTH - 10) { sReady.set() } otherwise { sReady.clear() }
    when(fifo.io.occupancy >= mCount) { mReady.set() } otherwise { mReady.clear() }
}
```

> 保留文件顶部的 `WaStreamFifo` 定义与 `import`（`WaStreamFifo` 本身就是 SpinalHDL `StreamFifo`，无需改）。`XPM_FIFO_SYNC.scala` 里的 `FifoSync` BlackBox 保留但不再被例化 ⇒ 不进网表。

- [ ] **Step 2: 判据 —— 替换后 FIFO 不再指向 Xilinx 原语，且整体仍能生成**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash port/apply_pango_port.sh
cd port && bash sbt.sh "runMain GenNpu" 2>&1 | tail -20
cd ../gen
grep -c "xpm_fifo_sync" Vexii*Npu*.v 2>/dev/null || true
grep -c "xpm_" *.v | head
```
Expected: `[success]`；对 `xpm_fifo_sync` 的计数为 **0**（`xpm_memory_sdpram` 也应为 0，Task B5 已处理）。

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/override/wa/WaFifo.scala
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): sync FIFO Pango 化（StreamFifo，对外 IO 不变）"
```

---

### Task B7: Pango 化 · DSP（MAC）

**背景**：`wa/xip/math/DSP.scala` 的 `setInlineVerilog` 里例化的是 Xilinx `dsp_macro`（`(A+D)*B`，`tier_1..6` 全开 ⇒ **6 级流水**）。`Config.dsp2x = false` ⇒ 只走 else 分支。使用点：`conv/compute/ConvCompute.scala:177,187`。

**Files:**
- Create: `ai_npu_exp/port/override/wa/xip/math/DSP.scala`

- [ ] **Step 1: 把内联 Verilog 的 IP 例化换成行为模型（**延迟仍为 6 拍**）**

在覆盖副本里，只改 `else` 那段 `setInlineVerilog` 的尾部：把
`componentName componentName_inst ( .CLK(CLK), .A(ain), .B({1'b0,b}), .D(din), .P(pout) );`
换成等价的 6 级流水行为实现（保持 `pout` 是 `[33:0]` 这一内部信号名，其余取整逻辑不动）：

```verilog
  // 等价于 Xilinx dsp_macro (A+D)*B、tier_1..6 全开：6 级流水
  wire signed [33:0] mult = (ain + din) * $signed({1'b0, b});
  reg  signed [33:0] t1, t2, t3, t4, t5, t6;
  always @(posedge CLK) begin
      t1 <= mult; t2 <= t1; t3 <= t2; t4 <= t3; t5 <= t4; t6 <= t5;
  end
  assign pout = t6;
```

- [ ] **Step 2: 判据 —— 网表里没有 `dsp_macro`，且 DSP 实例数与预期同阶**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash port/apply_pango_port.sh
cd port && bash sbt.sh "runMain GenNpu" 2>&1 | tail -20
cd ../gen
grep -c "dsp_macro" *.v | head
grep -c "DSP DSP" *.v 2>/dev/null | head
```
Expected: `dsp_macro` 计数 **0**；`DSP` 实例数 = `COMPUTE_CHANNEL_IN_NUM × COMPUTE_CHANNEL_OUT_NUM` 及其它使用点之和 —— **把这个数记进报告**（它决定 Pango 综合要吃掉多少 APM，规格上限 740）。

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/override/wa/xip/math/DSP.scala
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): MAC DSP Pango 化（行为模型，6 级流水契约）"
```

---

### Task B8: Pango 化 · 乘法器

**背景**：`wa/xip/math/Mul.scala` 的 `Mul` 是 BlackBox，指向 Xilinx `mult_gen`（`mult_gen` 由 `genTcl` 生成 IP）。使用点 5 处：`LeakyRelu.scala:36`、`Quan.scala:99`、`shape/Add.scala:213`、`shape/Concat.scala:214`、`shape/Shape.scala:99`。注意其中 3 处用 `outMsb/outLsb` **取乘积的高位段**（如 `79:48`）。

**Files:**
- Create: `ai_npu_exp/port/override/wa/xip/math/Mul.scala`

- [ ] **Step 1: 用内联行为乘法替换 IP，并让延迟可控**

覆盖副本的 `Mul` 类加两个可选参数承载位段，`apply` 把它们传下去（**调用点签名不变**），`genTcl` 改成空操作：

```scala
class Mul(A_WIDTH: Int, B_WIDTH: Int, P_WIDTH: Int, A_TYPE: String, B_TYPE: String,
          clockDomain: ClockDomain, componentName: String,
          outMsb: Int = -1, outLsb: Int = 0, pipelineStage: Int = 3) extends BlackBox {
    val io = new Bundle {
        val A = if (A_TYPE == MulConfig.signed) in SInt (A_WIDTH bits) else in UInt (A_WIDTH bits)
        val B = if (B_TYPE == MulConfig.signed) in SInt (B_WIDTH bits) else in UInt (B_WIDTH bits)
        val P = if (A_TYPE == MulConfig.signed || B_TYPE == MulConfig.signed) out SInt (P_WIDTH bits)
                else out UInt (P_WIDTH bits)
        val CLK = in Bool()
    }
    noIoPrefix()
    this.setDefinitionName(componentName)
    mapClockDomain(clockDomain, io.CLK)

    // 等价于 Xilinx mult_gen（PipeStages = pipelineStage）
    val msb = if (outMsb >= 0) outMsb else A_WIDTH + B_WIDTH - 1
    val lsb = if (outMsb >= 0) outLsb else 0
    val full = CombInit(io.A.asBits.resize(A_WIDTH + B_WIDTH))
    // 乘法 + pipelineStage 级流水，取 [msb:lsb]
    val wide = io.P.getWidth
    val prod = (io.A.asUInt.intoSInt * io.B.asUInt.intoSInt).resize(A_WIDTH + B_WIDTH)
    val shifted = prod(A_WIDTH + B_WIDTH - 1 downto 0)
    val slice = shifted.resize(wide)
    val stages = if (pipelineStage <= 1) Vec(slice)
                 else (0 until pipelineStage).map(_ => RegNext(slice))
    io.P := stages.last
}
```

> 上面这段是**意图完整的实现骨架**；`A_TYPE/B_TYPE` 的符号性组合（signed×unsigned 等 5 个调用点各不相同）必须在 Step 2 用编译 + 生成结果确认，必要时把 `prod` 那一行按符号性分支写。

`object Mul.apply` 保持两个重载，第二个把 `outMsb/outLsb` 传进类，并让 `genTcl` 不再写 Xilinx tcl。

- [ ] **Step 2: 判据 —— 生成通过 + `mult_gen` 不复现**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash port/apply_pango_port.sh
cd port && bash sbt.sh "runMain GenNpu" 2>&1 | tail -30
cd ../gen && grep -c "mult_gen" *.v | head
ls -d ../port/tcl 2>/dev/null && echo "WARN: 仍在生成 Xilinx IP tcl" || echo "OK: 无 Xilinx IP tcl"
```
Expected: `[success]`；`mult_gen` 计数 **0**；无 `tcl/` 目录（或为空）。

- [ ] **Step 3: 数值对照（防止乘法语义被改坏）**

用一段最小仿真或"生成两份参数不同、对比表达式"的方式，确认 `P` 与 `outMsb/outLsb` 的取值一致。至少覆盖 `Quan.scala:99` 的 `(48,32,32,...,79,48)` 这一档（`P = prod[79:48]`）。把对照结果写进 `reports/build_notes.md`。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/override/wa/xip/math/Mul.scala ai_npu_exp/reports/build_notes.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): 乘法器 Pango 化（内联行为乘法，保留位段语义）"
```

---

### Task B9: Pango 化 · 收尾 + "无 Xilinx 残留"自证

**Files:**
- Create: `ai_npu_exp/port/override/misc/TotalTcl.scala`
- Create: `ai_npu_exp/tools/check_no_xilinx.sh`

- [ ] **Step 1: 停用 `TotalTcl` 的 Xilinx IP tcl 生成**

覆盖 `misc/TotalTcl.scala`：把 `genTotalTcl` 改成**只打印一行说明并直接返回**（不扫 `./tcl`、不拼 Xilinx 命令），保留类名与调用签名，使 `Npu.scala` / `top.scala` 的既有调用不需要改。

- [ ] **Step 2: 写"无 Xilinx 残留"判据**

`tools/check_no_xilinx.sh`：
```bash
#!/usr/bin/env bash
# 判据：生成网表里不得出现任何 Xilinx 原语/IP 例化名
set -uo pipefail
d="${1:?usage: check_no_xilinx.sh <gen_dir>}"
pat='xpm_memory_sdpram|xpm_memory_sprom|xpm_fifo_sync|xpm_cdc|dsp_macro|mult_gen|blk_mem_gen'
hits=$(grep -REn "$pat" "$d" | wc -l)
echo "xilinx-residual hits: $hits"
if [ "$hits" -eq 0 ]; then echo "RESULT: PASS"; exit 0; else grep -REn "$pat" "$d" | head; echo "RESULT: FAIL"; exit 1; fi
```

- [ ] **Step 3: 正负对照**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash tools/check_no_xilinx.sh gen                          # 正对照：应 PASS
mkdir -p /tmp/xil_neg && printf 'xpm_fifo_sync u_x (...);\n' > /tmp/xil_neg/bad.v
bash tools/check_no_xilinx.sh /tmp/xil_neg                 # 负对照：应 FAIL hits=1
```
Expected: 正 `RESULT: PASS`；负 `RESULT: FAIL`。**一绿一红。**

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/port/override/misc/TotalTcl.scala ai_npu_exp/tools/check_no_xilinx.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): 停用 Xilinx IP tcl 生成 + 无残留自证判据（正负对照通过）"
```

---

### Task B10: PDS `dev_map` 取资源 + 余量结论

**Files:**
- Create: `ai_npu_exp/pds/devmap_npu.tcl`
- Create: `ai_npu_exp/reports/resource_m0.md`

- [ ] **Step 1: 写 dev_map tcl（只综合 M0 的 Npu，不带 SoC）**

`pds/devmap_npu.tcl` 与仓库既有 `pds/flash_yeshen.tcl` 同风格：`create_project` → 指定器件 **PG2L200H-6IFBB676** → `add_design` 收 `ai_npu_exp/gen/*.v` → `set_top` 到 `Npu` → `dev_map`。**器件型号与封装必须从本仓既有 pds 脚本里抄**（不要手写记忆值），命令串用本仓已验证的 `pds_shell.exe -file <绝对路径>`。

- [ ] **Step 2: 跑 dev_map**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux
"<PDS 安装目录>/pds_shell.exe" -file "D:\code\PDS\VexiiYeshenLinux\ai_npu_exp\pds\devmap_npu.tcl" \
  > ai_npu_exp/pds/devmap_npu.log 2>&1
grep -n "Device Utilization Summary" -A 30 ai_npu_exp/pds/devmap_npu.log
grep -n "YESHENMINI_DEVMAP_DONE\|Error\|error" ai_npu_exp/pds/devmap_npu.log | tail
```
Expected: 出现 Device Utilization Summary 表；无 `Error`；日志末尾有完成标记。
（PDS 安装目录从本仓既有 tcl/脚本里读，spec §11 的既有文档 `docs/board_bringup.md` 有记录。）

- [ ] **Step 3: 写资源结论（与 spec §3.3 基线对照）**

`reports/resource_m0.md` 必须包含：
- NPU 单独的 **LUT / FF / APM(DSP) / DRM** 四行（Used / Available / %）；
- 与 SoC 基线（`sim/reglogs/m_yeshen_devmap.log`：LUT 14,130.5/159,800）的**相加后**是否 ≤ 可供量，给出**余量数字**；
- 一句显式结论：`SoC + NPU ≤ 159,800 LUT` 成立 / 不成立。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/pds/devmap_npu.tcl ai_npu_exp/reports/resource_m0.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): NPU 独立 dev_map 资源报告与余量结论"
```

---

### Task B11: （条件）PnR 时序

**前置**：Task B10 的余量结论为**成立**才做；不成立则跳过本 Task，并在 §8 的结论里写"资源超限"。

**Files:**
- Create: `ai_npu_exp/pds/pnr_npu.tcl`

- [ ] **Step 1: 写 pnr tcl** —— 与 `pds/flash_yeshen.tcl` 同风格，但**只跑 rtl→pnr**，不烧写；时钟约束按 M0 阶段的实际目标（NPU 单独跑，先给 100 MHz 试；过不了就降并记录实际 fmax）。

- [ ] **Step 2: 跑并取时序**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux
"<PDS 安装目录>/pds_shell.exe" -file "D:\code\PDS\VexiiYeshenLinux\ai_npu_exp\pds\pnr_npu.tcl" \
  > ai_npu_exp/pds/pnr_npu.log 2>&1
grep -n "All Constraints Met\|Performance Summary" -A 20 ai_npu_exp/pds/pnr_npu.log | head -40
```
Expected: 落出 Performance Summary（或明确写出违例）。

- [ ] **Step 3: 记结论** —— 把 WNS/TNS 与 fmax 写进 `reports/resource_m0.md` 的"时序"小节；M0 不设 All-Met 硬门槛（spec R5）。

- [ ] **Step 4: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/pds/pnr_npu.tcl ai_npu_exp/reports/resource_m0.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(m0): NPU PnR 时序数字"
```

---

### Task B12: M0 结论报告 + 收口

**Files:**
- Create: `ai_npu_exp/reports/M0_CONCLUSION.md`

- [ ] **Step 1: 写结论，逐条对上 spec §8 的四个判据**

必须含：
1. 算子覆盖：`reports/coverage_m0.md` 的 `RESULT`（PASS/FAIL）+ 证据等级（ONNX 级 / 源码级）；
2. 综合：`0 error`（贴 `sbt compile` + dev_map 的判定行）；
3. 资源：四行数字 + 余量结论；
4. 可复现性：每条结论对应命令 + 指纹清单（模型 sha256、ONNX sha256、生成的 `.v` md5、两份 devmap 日志路径）。
5. 只读克隆零改动自证：`git -C third_party/SpinalHDL_CNN_Accelerator status --porcelain` 为空。

- [ ] **Step 2: 终局自证（一次跑完所有判据）**

Run:
```bash
cd /d/code/PDS/VexiiYeshenLinux/ai_npu_exp
bash tools/check_no_xilinx.sh gen
python tools/check_sdpram_latency.py gen/sdpram.v 2
python tools/check_coverage.py reports/ops_yolov5s_v3.txt | tail -2
git -C ../third_party/SpinalHDL_CNN_Accelerator status --porcelain | wc -l
```
Expected: `RESULT: PASS` / `RESULT: PASS` / `RESULT: PASS` / `0`

- [ ] **Step 3: 提交**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add ai_npu_exp/reports/M0_CONCLUSION.md
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "docs(m0): M0 结论报告（覆盖/综合/资源/可复现性四项判据）"
```

---

## 自查记录（写完计划后对照 spec）

1. **Spec 覆盖**：spec §5（算子核实）→ Task A1–A5；§6（RTL/Pango/综合）→ Task B1–B11；§7 风险 → R1=Task A5 的激活判定、R2=Task B5 的延迟契约、R3/R4=Task B2/B3、R5=Task B11 的"条件"、R6=沿用既有 PDS 纪律；§8 验收 → Task B12；§9 产物 → 文件结构一节。
2. **占位扫描**：无 TBD/TODO。`Task B8` 明确写了"符号性组合必须在 Step 2 用编译确认，必要时按符号性分支"——这是**带判据的决策规则**，不是占位。
3. **类型一致性**：`check_sdpram_latency.py`(Task B5) 与 Task B12 的调用参数一致（`gen/sdpram.v 2`）；`check_no_xilinx.sh`(Task B9) 与 Task B12 一致（`gen`）；`check_coverage.py`(Task A5) 与 Task B12 的输入文件名 `reports/ops_yolov5s_v3.txt`(Task A4) 一致。
4. **Spec 偏差（已在 spec 内改过）**：候选模型由 YOLOv5-face 改为 **ultralytics YOLOv5 v3.0**（因为 face 权重只在网盘）；人脸落地目标保留在 M2。见 spec §2/§5.1/§11。
