# Y1 · C4a 实施计划：转换器 + 通道覆盖（**仿真可验收**：G1–G5）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让**硬件能吃真模型、并把真网的每一层都算对** —— 产出"量化口径 + PTQ 工具 + 转换器（表 + 权重 blob）+ 多趟通道覆盖（含跨趟累加）+ depthwise + 布局折进寻址"，判据 **G1–G5** 全部在**仿真**里逐层逐字节验收。

**Architecture:** 三段：① **宿主侧**（`y1/tools/`）：自研 affine PTQ → 同口径 int8 参考 → 转换器（ONNX → 描述符表 + 权重 blob，表序隐含指针）→ 拆趟规则；② **RTL**（`y1/rtl/`）：在多趟累加（片上部分和）与 depthwise 上扩 `Conv3x3Slice`/`UnitExec`，复用 C3 的调度器与描述符格式（**零格式改动**）；③ **判据**：与同口径参考**逐字节**对（真硬件判据）、与 float ORT **容差级**比较（记录最大偏差）。

**Tech Stack:** Python 3（`deps` venv：onnx / numpy / onnxruntime）+ Scala 2.12.18 / SpinalHDL 1.15.0 + sbt（Coursier 的 `sbt.bat`）+ iverilog；冻结件沿用 C3 的 `desc_table.py` / `ddr_traffic.py` / `mac_ref.py` / `bypass_ref.py`。

**设计依据：** `docs/superpowers/specs/2026-10-10-y1-c4-converter-and-coverage-design.md`（§3 冻结参数、**§4 三项已裁决**、§5 G1–G7、§6 风险）
**前置（已收口）：** C3 的 15 个单元闸门全绿、板级 PnR `All Constraints Met`、**上板六级功能验收**（含带权重 conv3x3 端到端 `MISMATCH=0`）—— 见 `y1/reports/c3_pnr_timing.md`、`y1/reports/c3_board_bringup.md`。

**本计划只做 C4a（G1–G5）。C4b（G6 权重从 DDR、G7 整帧端到端上板）另出一份计划。**

---

## 全局约定（每个 Task 都适用）

- **不上板**：C4a 全部离线（Python + 仿真 + 综合/映射）。上板属 C4b。
- **只读资产**：`third_party/**`、`y1/tools/ddr_traffic.py`、`fusion_buffer.py`、`bypass_traffic.py`、`mac_ref.py`、`bypass_ref.py`、`conv_unit_ref.py` 是**输入约束**。要"补进模型"就**新建**脚本 import 它，**不改它**。
- **描述符格式零改动**（§4.2 已裁决）：8×32-bit 字、`FLAGS` 四态、`CHAIN_L_MAX=L_MAX=8` 全不动；权重用**表序隐含**。
- **提交**（本机无 git 身份，**不 push**，**绝不改 git config**）：
  ```bash
  GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
  git commit -m "<msg>"
  ```
- **判据必须带正负对照**；**产物记指纹**（md5/字节数）；**不匹配要响亮失败**。
- **生成器 `headerWithDate=false` / `headerWithRepoHash=false`**（否则指纹跨 commit 必变）。
- **Python 环境**（全仓唯一可用组合）：
  ```bash
  cd /d/code/PDS/VexiiYeshenLinux/y1
  PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
    /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe <script> <args>
  ```
- **闸门退出码**（沿用 C3）：`0` 过 / `1` 不符 / `2` 负对照没发火 / `3` 前置/向量非法。
- **每轮 RTL 改动后**：15 个单元闸门 + `check_addr_map.py` + `check_dangling.py` 全绿；**改了 RTL 就要重跑 PnR**（C3 的 CLMA ~91% 满，余量薄）。

## 文件结构

```
y1/
├── tools/
│   ├── quant_ptq.py        # 【新】自研 affine PTQ：校准 → int8 权重 + 每层 (scale,zp,shift)
│   ├── quant_ref.py        # 【新】同口径 int8 整网参考（逐层落盘中间张量 → 指纹）
│   ├── y1_convert.py       # 【新】转换器：ONNX → 描述符表 + 权重 blob（表序）+ 拆趟规则
│   ├── tiling_ref.py       # 【新】"拆趟 == 整层" 的 Python 等价性验证（离线）
│   └── run_quant_ab.sh / run_convert_ab.sh / run_tiling_ab.sh / run_multipass_ab.sh / run_dw_ab.sh
├── rtl/
│   ├── Conv3x3Slice.scala  # 【改】加"多趟累加"输入（部分和载入/写回）与 depthwise 档
│   ├── UnitExec.scala      # 【改】编排多趟 + 部分和缓冲
│   └── PartialSumBuf.scala # 【新】片上部分和缓冲（C_out×8，RAM 结构 ⇒ DRM）
├── rtl_test/               # 【新】对应 Gen/Tb
└── reports/
    ├── c4a_quant.md        # 【新】量化口径 + 校准 + 与 float ORT 偏差
    ├── c4a_coverage.md     # 【新】G1 三态覆盖面表 + 指纹
    └── c4a_multipass.md    # 【新】多趟累加与 depthwise 的数值结论
```

---

### Task C4a.1: 量化口径冻结 + PTQ 工具（含同口径自检）

**Files:**
- Create: `y1/tools/quant_ptq.py`、`y1/tools/run_quant_ab.sh`
- Create: `y1/reports/c4a_quant.md`

- [ ] **Step 1: 冻结 affine 口径（写进 `quant_ptq.py` 的模块 docstring，逐字）**

```
per-tensor affine：
  q = clamp(round(x / scale) + zero_point, -128, 127)      # 权重与激活同式
  x ≈ (q - zero_point) * scale
校准：每层张量的 min/max（默认）；可选 percentile（记在报告里）
权重：int8（q 直接落 blob）；激活：int8（scale/zp 由校准给）
累加：int32；requant = 算术右移 shift（= 6，与网表展开期 SHIFT 一致）
   （若某层 shift ≠ 6 ⇒ 该层必须走独立 shift 通路；C4a 先只支持 shift=6，遇到不同的层在报告里点名）
```

- [ ] **Step 2: 写失败判据（先红）** —— `quant_ptq.py --selftest`

`--selftest` 必须打印并断言：
```
SELFTEST_PTQ roundtrip_maxerr=<e>            # 反量化误差 ≤ scale/2（边界内）
SELFTEST_PTQ monotone=1                      # x 增大 ⇒ q 不减（单调）
SELFTEST_PTQ clamp=1                         # 超范围必被夹到 ±(127/zp) 边界，不回绕
SELFTEST_PTQ scale_changed=1                 # 故意把 scale 改 1 bit ⇒ 反量化结果必须变（负对照）
RESULT: PASS
```
先写空实现跑，确认 4 条全红。

- [ ] **Step 3: 实现**（含校准）

```python
def calibrate(t, percentile=None):
    lo, hi = float(t.min()), float(t.max())
    if percentile: lo, hi = np.percentile(t, [percentile, 100-percentile])
    return lo, hi
def affine_params(lo, hi):                     # q = round(x/scale)+zp
    scale = (hi - lo) / 255.0 if hi > lo else 1.0
    zp    = int(round(-lo / scale)) - 128
    zp    = max(-128, min(127, zp))
    return scale, zp
def quant(t, scale, zp):  return np.clip(np.round(t/scale).astype(np.int32) + zp, -128, 127).astype(np.int8)
def dequant(q, scale, zp): return (q.astype(np.int32) - zp) * scale
```
**负对照必须真能发火**：把 `scale` 的 1 个 bit 翻掉，`dequant` 结果必须变（不是橡皮章）。

- [ ] **Step 4: 跑 + 提交**
```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/quant_ptq.py --selftest
echo "exit=$?"     # 期望 0
cd /d/code/PDS/VexiiYeshenLinux
git add y1/tools/quant_ptq.py y1/tools/run_quant_ab.sh y1/reports/c4a_quant.md
# （用全局约定里的 env 提交）
```

---

### Task C4a.2: 同口径 int8 整网参考（**G2/G3/G4 的黄金**）

**Files:**
- Create: `y1/tools/quant_ref.py`、`y1/tools/run_quant_ref.sh`
- Modify: `y1/reports/c4a_quant.md`（加"参考与 float ORT 的逐层最大偏差"）

- [ ] **Step 1: 冻结参考的行为（写进文件头）**

- 输入：`quant_ptq` 产出的每层参数；逐层按**算子顺序**执行 `Conv/Relu/MaxPool/Resize/Add/Sigmoid/Transpose/Reshape`；
- **每层中间张量落盘**（`.npy` 或逐字节 `.bin`）+ **每层 md5 进 JSON**（`reports/c4a_ref_layers.json`）；
- **Q/DQ 位置写死**：层内累加 int32 → `>>shift` → clamp int8 → 下一层的 int8 输入（**不插入额外 DQ**）。

- [ ] **Step 2: 判据** `run_quant_ref.sh`
1. **正对照**：整网跑完，最后一层输出与"同口径"的逐点参考（朴素三重循环实现，第二实现）**逐点一致**（`MISMATCH=0`）；
2. **与 float ORT 的容差**：逐层记录 `max|我们 - ORT_float|`（**只是记录，不是判据**；判据在 G7）；
3. **负对照（必须有牙）**：把某一层的 `zp` 改 1 ⇒ **该层起往后**的中间张量必须变（`MD5_DIFF_LAYERS ≥ 1`）；
4. **退化守卫**：断言输入不是常数、且末层输出 `distinct > 1`（防"全 0 也通过"）。

- [ ] **Step 3: 跑 + 提交**（命令同 C4a.1 的样式）

---

### Task C4a.3: 转换器（ONNX → 表 + 权重 blob）—— **G1 + G2 的表侧**

> ⚙ **新增约束（2026-10-10，spec §4.4）**：requant 需**每层 Q24 乘子 `M=s_x·s_w/s_y`**（纯 `>>6` 表达不了，
> 见 `reports/c4a_quant.md` §11.3）。`M` 按**表序**排在权重 blob 之后，走**既有 `WGT_ADDR/WGT_DATA/WGT_WE` 信箱**、
> 用 `w7` 的 `LAYER_ID` 索引 ⇒ **描述符 8 字零改动**。转换器要在 `wgt_index.json` 里加 `requant_mult` 段
> （每单元的 `M` 与 `REQUANT_Q=24`）；判据里加"改 1 个 `M` ⇒ blob 指纹变"。

**Files:**
- Create: `y1/tools/y1_convert.py`、`y1/tools/run_convert_ab.sh`
- Create: `y1/reports/c4a_coverage.md`（G1 三态覆盖面表）

- [ ] **Step 1: 冻结接口与"表序隐含权重"契约（写进文件头）**

```
输入：yunet.onnx + quant_ptq 的每层参数
输出（落 gen/ 下，gitignore）：
  ① desc.bin    —— 描述符表（**复用 desc_table.pack_table**；末尾自动哨兵）
  ② wgt_blob.bin—— 权重 blob，**按表序**连续排布；第 i 个消费权重的单元占用
                   N_i = C_out*(C_in/GROUP)*9 字节，起点 = Σ_{j<i} N_j
  ③ wgt_index.json —— 每个单元的名字/偏移/字节数（**供 G6 的装载与 G2 的索引**）
契约：表序 == blob 序（R4 的对冲：wgt_index.json + G6 的 blob 指纹 + G2 的逐层对账）
```

- [ ] **Step 2: 实现**（复用冻结件，不重推规则）
- 算子序 / 融合枚举一律取自冻结的 `ddr_traffic.py`（`find_fusion_pairs*`）与 `desc_table.py`（`build_table` 的编码口径）；
- `Transpose/Reshape` **折进寻址**：给每个消费者算 (src_stride, src_order)，**不产生单元**；
- `Relu` 折进生产者尾声（冻结口径）；
- 每层的 `IMG_W/IMG_H`：**conv 填输出尺寸；旁路算子填输出尺寸 + `IN_BYTES` 填输入字节**（§3 的坑）。

- [ ] **Step 3: 判据** `run_convert_ab.sh`
1. 表过 `desc_table.validate`（**字面调用冻结的 validate**）+ `pack/unpack` 往返；
2. **三态覆盖面表**（覆盖/需主机旁路/不覆盖）与 C3 冻结表**逐项对账**；`desc.bin` + `wgt_blob.bin` 记 md5/字节数；
3. 负对照：app 里改 1 个权重字节 ⇒ `wgt_blob.bin` 的 md5 必须变；`desc_count` 与哨兵不符 ⇒ `validate` 必须抛。

- [ ] **Step 4: 提交**

---

### Task C4a.4: 拆趟规则 + "拆趟 == 整层" 的 Python 等价性 —— **G3 的离线半边**

**Files:**
- Create: `y1/tools/tiling_ref.py`、`y1/tools/run_tiling_ab.sh`

- [ ] **Step 1: 冻结拆趟规则（写进文件头，逐字）**

```
宽层（C_in > 8 或 C_out > 8）拆成 ceil(C_in/8) x ceil(C_out/8) 趟：
  每趟 = 一个 plain conv 单元（C_in_t = min(8, 剩余), C_out_t = min(8, 剩余)）
  趟内 SKIP 的输入通道（C_in_t < 8 时）用**权重置 0** 掩掉（不新增字段）
  跨 (co) 趟：DST 不同区域（各写自己那段 co）；
  跨 (ci) 趟：**累加**（见 C4a.5 的片上部分和）——本任务只验证**算术等价**
判据：趟集合的 Python 模拟 == 整层参考（逐字节）
```

- [ ] **Step 2: 判据** `run_tiling_ab.sh`
1. 对**真表里出现过的每一种 `(C_in,C_out,GROUP)`**（从 `desc_table` 的真表读出，去重）跑一趟：**拆趟模拟 == 整层参考**（`MISMATCH=0`）；
2. 负对照：**故意漏一趟**（少一个 `ci` 块）⇒ `MISMATCH>0`；
3. 退化守卫：断言该层输出不是常数。

- [ ] **Step 3: 提交**

---

### Task C4a.5: RTL —— **多趟累加（片上部分和）** —— **G3 的硬件半边**

> ⚙ **新增约束（2026-10-10，spec §4.4）**：requant 处要加 **乘 + 双移位**（`((acc·M)>>24)>>6`），
> `M` 经权重信箱按 `LAYER_ID` 装载（描述符 8 字零改动）。`Conv3x3Slice` 现只有 `>>6`。
> **面积小涨 ⇒ 本任务收口必须重跑 PnR**（C3 CLMA ~91% 已满）。

**Files:**
- Create: `y1/rtl/PartialSumBuf.scala`（`C_out×8` 的 RAM 结构 ⇒ DRM）
- Modify: `y1/rtl/Conv3x3Slice.scala`（加部分和载入/写回）、`y1/rtl/UnitExec.scala`（编排多趟）
- Create: `y1/rtl_test/*Gen*.scala`、`y1/rtl_test/MultiPassTb.v`、`y1/tools/run_multipass_ab.sh`

- [ ] **Step 1: 冻结数据流（写进 `UnitExec.scala` 文件头）**
```
一个"宽层" = 表里的**一组连续 plain 单元**（由转换器生成，本任务由 TB 手工给）
  第 1 趟：累加器清零（或直接写）；第 k>1 趟：**读回部分和 → 加到本轮 acc → 写回**
  片上部分和缓冲：C_out 行 × 8 B（= 64 B/co-block），RAM 结构（DRM），**不得落 FF**
  注意与 C3 的"输出存储 readAsync 是 LUTRAM"是两回事：这里必须是 block RAM，判据由 dev_map 给
```
- [ ] **Step 2: 判据** `run_multipass_ab.sh`
1. 对真表出现的每种宽 `(C_in,C_out)`：走多趟 → 输出与 C4a.4 的"整层参考"**逐字节**一致；
2. **负对照 A**：漏加一趟（网表突变/plusarg 让某趟不写回）⇒ `MISMATCH>0`；
3. **负对照 B**：部分和缓冲初值非 0 ⇒ 必须红（证明"清零"这一拍真在起作用）；
4. **DRM 判据**：`dev_map` 后 `DRM` 用量比 C3 增长 ≥ 部分和缓冲的理论值，且 `LUTs as dram`/`Adm-4088` 三样证据表明它**真在 DRM**（沿用 S5 的方法）。

- [ ] **Step 3: 回归 + 提交**：15 个单元闸门 + 台账 + dangling 全绿；**不重跑 PnR 就不算收口**（记在报告里）。

---

### Task C4a.6: RTL —— **depthwise 单元（`0x03`）** —— **G4**

**Files:**
- Modify: `y1/rtl/Conv3x3Slice.scala`（depthwise 档：`GROUP == C_IN == C_OUT == 8` 的既有掩码已支持；本任务补**真表口径**：`GROUP=C` 且 `C>8` ⇒ 走 C4a.5 的拆趟）、`y1/rtl/DescDefs.scala`（若需补 TYPE 语义常量）、`y1/rtl/LayerSched.scala`（把 `0x03` 纳入分派）
- Create: `y1/rtl_test/DwGen.scala`、`DwTb.v`、`y1/tools/run_dw_ab.sh`

- [ ] **Step 1: 真表口径（写进文件头）**：depthwise = `GROUP = C_in = C_out`；`C≤8` 一趟；`C>8` 拆趟（每趟 8 通道）。
- [ ] **Step 2: 判据** `run_dw_ab.sh`
1. 真表 20 个 depthwise 层的**形状**（去重后）各跑一层 → 逐字节对参考；
2. 负对照：`GROUP` 映射错（把 `groupOfOut` 写成 `co` 而不是 `(co*G)/C_out`）⇒ 必须红；
3. 与 C4a.5 共用同一套算术（**不允许另起一套**：判据里断言两者对同一输入给同一输出）。

---

### Task C4a.7: 布局算子折进寻址（转换器侧）—— **G5**

**Files:**
- Modify: `y1/tools/y1_convert.py`（把 `Transpose/Reshape` 折成 (src_stride, src_order)）
- Create: `y1/tools/run_layout_ab.sh`

- [ ] **Step 1: 判据** `run_layout_ab.sh`
1. 对每个含 `Transpose/Reshape` 的位置：折进寻址后的张量 == **显式转置参考**（逐字节）；
2. **搬运不增**：该段路径的 **DDR 读+写字节数不因折进而增加**（与"不折进"的对照）；打印两个数；
3. 负对照：把 `src_order` 写反 ⇒ 必须红。

---

### Task C4a.8: C4a 收口 —— 与 float ORT 的逐层偏差 + 面积/时序回归

**Files:**
- Create: `y1/reports/c4a_multipass.md`（多趟/depthwise 数值结论 + 与 ORT 的逐层偏差表）
- Modify: `y1/pds/devmap_c3.tcl` 或新建 `devmap_c4a.tcl`（含 `PartialSumBuf`）

- [ ] **Step 1: 逐层偏差报告**：逐层 `max|我们(int8) - ORT_float|` 与"相对该层满量程的百分比"；**声明这是记录、不是判据**（判据在 C4b 的 G7）。
- [ ] **Step 2: 面积闸门**：含 `PartialSumBuf` 的 `dev_map`；**DRM/CLMA/LUT/APM 全表 + 与 C3 的 Δ**；断言 SoC+C4a ≤ 预算（DRM ≤ 415、CLMA 报告余量）。
- [ ] **Step 3: 全回归**：15 个单元闸门 + `check_addr_map.py` + `check_dangling.py` + **重跑 PnR**（`All Constraints Met`）。
- [ ] **Step 4: 报告 + 提交**：`c4a_multipass.md` 必须写清 **C4a 到此能证什么/不能证什么**（不能证整帧、不能证 fps、不能证上板）→ 指向 **C4b**。

---

## 自查记录

1. **设计覆盖**：spec §4.1（多趟+片上部分和）→ C4a.4/C4a.5；§4.2（表序隐含）→ C4a.3 的契约 + C4a.3 Step 3 的负对照；§4.3（自研 PTQ + 同口径参考）→ C4a.1/C4a.2；§3 的"旁路几何口径是个坑"→ C4a.3 Step 2；G1 → C4a.3；**G2 → C4a.1+C4a.2+C4a.3**；G3 → C4a.4+C4a.5；G4 → C4a.6；G5 → C4a.7；§6 R1（多趟流量）→ C4a.5 Step 2 的第 4 条 + C4a.8 Step 2；R2（量化偏差）→ C4a.1/C4a.2/C4a.8 Step 1；R3（面积）→ C4a.5/C4a.8 Step 2；R4（表序契约）→ C4a.3 的契约 + G6（C4b）；G6/G7 → **C4b**（本计划明确不做）。
2. **占位扫描**：无 TBD。Python 任务给了**可运行骨架 + 断言清单**；RTL 任务给了**接口/契约 + 判据**（与 C3 的写法一致）；每个闸门都写死了**正对照 + ≥1 条能发火的负对照 + 退出码**。
3. **类型一致性**：`quant_ptq` 的 `(scale, zp, shift)` 在 `quant_ref`（消费）与 `y1_convert`（打包进描述符/权重）里同名同义；`y1_convert` 的 `wgt_index.json`（`offset/bytes`）是 C4b 的 G6 装载接口；`PartialSumBuf` 的 `C_out×8` 与 `Conv3x3Slice` 的 `C_OUT` 同源；拆趟的"单元 = plain conv"与 C3 的 `FLAGS=0b01` 一致。
4. **一处诚实标注**：`shift ≠ 6` 的层（若真网有）在 C4a.1 Step 1 里被**显式排除**并要求点名 —— 不静默处理；真遇到则走 spec 修订（加 per-layer shift 通路）。
