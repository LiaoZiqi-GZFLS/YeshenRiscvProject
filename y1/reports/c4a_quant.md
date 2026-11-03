# Y1-C4a.1 报告 —— 量化口径冻结 + 自研 affine PTQ 工具（`--selftest` 六条含可发火负对照）

**Status: DONE（2026-10-10 修订 r2：零值纳入 + percentile 序修 + 六条判据）**

**一句话**：C4a.1 把"**per-tensor affine int8 量化口径**"冻成一句可复核的话（写进 `y1/tools/quant_ptq.py`
的模块 docstring，逐字），并交出自研 PTQ 工具与它的自检 `--selftest`（**六条**，**每条都对独立期望**）+
闸门 `y1/tools/run_quant_ab.sh`（正对照 + **六发注入式负对照**，scratch 拷贝在 `/tmp`，**绝不改仓内文件**）。
`--selftest` 在**不带 ONNX** 时可独立跑（纯数值），ONNX 依赖只在 `--onnx` 分支里懒 import。

> **r2 修订摘要（相对初版）**：审阅发现两处 CRITICAL，本版修掉并补齐判据 ——
> ① **零值纳入**（`affine_params` 求参前把校准区间扩到含 0）：修「区间不含 0 ⇒ `zp` 被 clamp ⇒
> 整张量塌成几个码点」的**真退化**（实测命中真网 **3 个 conv 权重**，最高丢 89.7% 量程）；
> ② **percentile 分位序**（`sorted([p,100-p])`）：修 `p>50` 时 `lo>hi` 的反序 bug；
> ③ 新增 `zero_repr` / `percentile_ok` 两条判据与 `nozero` / `badpct` 两发负对照（各有专打）。
> **公式本身一字未改**（`q = clamp(round(x/scale)+zp, -128,127)`），只改"喂给公式的区间"与取分位序。

> 本报告只做 **C4a.1 的量化口径与工具**（离线数值）。C4a.2（同口径 int8 整网参考）会把"参考与 float
> ORT 的逐层最大偏差"续写进本文件；C4a.3（转换器）会消费本文件冻结的 `calibrate/affine_params/quant/dequant`。

---

## 1) Step 1：冻结的 affine 口径（逐字，唯一真源 = `y1/tools/quant_ptq.py` 模块 docstring）

```
per-tensor affine：
  q = clamp(round(x / scale) + zero_point, -128, 127)      # 权重与激活同式
  x ≈ (q - zero_point) * scale
校准：每层张量的 min/max（默认）；可选 percentile（记在报告里）
      ★ 校准区间**先零值纳入**再求参：lo=min(lo,0)、hi=max(hi,0)（承重项，见 §2）
权重：int8（q 直接落 blob）；激活：int8（scale/zp 由校准给）
累加：int32；requant = 算术右移 shift（= 6，与网表展开期 SHIFT 一致）
   （若某层 shift ≠ 6 ⇒ 该层必须走独立 shift 通路；C4a 先只支持 shift=6，遇到不同的层在报告里点名）
```

**硬约束（不得就地改，要改走 spec 修订）**：C4a.2 的 `quant_ref.py` 与 C4a.3 的 `y1_convert.py`
必须**逐字复用** `quant_ptq` 的 `calibrate / affine_params / quant / dequant`，不得各写一套 —— 否则
"同口径参考"就不再同口径，G2 的逐字节对账失去意义。

## 2) 实现 + 三处必须解释的口径选择（记在这里，供 C4a.2/C4a.3 与审阅复核）

| 点 | 冻结取值 | 理由 / 备注 |
|:--|:--|:--|
| 校准默认口径 | **min/max**（`percentile=None`）；给 `--percentile p`（`p∈(0,100)` 开区间）时取**升序**分位 `np.percentile(t, sorted([p,100-p]))` | plan 默认 min/max；percentile 是"可选项"，其**尾部分位之外**的样本由 `clamp` 饱和吸收（不丢、只是压到边界）。★ **升序取分位是关键**：写成 `[p,100-p]` 时 `p>50` 会给出 `lo>hi`（r1 的 bug） |
| **零值纳入**（承重项，r2） | 求 `scale/zp` 前先 `lo=min(lo,0)`、`hi=max(hi,0)` | per-tensor affine **必须能精确表示 0**（ReLU 边界 / 零填充 / 常量 0 都要 0 在可表示集合内）。否则区间不含 0 的张量 `zp=round(-lo/scale)-128` 越界被 `clamp` 吃成边界码点 ⇒ **整张量塌成极少数码点**（§6 实测）。零值纳入后对有限输入可证 `zp∈[-128,127]`（`-lo/(hi-lo)∈[0,1]` ⇒ `-lo/scale∈[0,255]`），`clamp` 退为安全网。**只改"喂给公式的区间"，公式一字不改** ⇒ 结构性修正，非旁路 |
| `zero_point` 取整 | `zp = int(round(-lo/scale)) - 128`，再夹到 `[-128,127]` | 取整用 **Python `round()`（银行家舍入）**；因 `-lo/scale` 通常非 .5，舍入方式影响 < 1 个码点 |
| `scale` 退化分支 | `hi == lo`（零值纳入后即 `lo==hi==0`）时 `scale = 1.0` | spec 给的 `(hi-lo)/255 if hi>lo else 1.0` |
| 空张量 | `calibrate` 对 `size==0` 返回 `(0.0, 0.0)` | 真网实测含一个 `shape=[0]` 的 initializer（见 §6），不抛 |

`shift` 冻结为常量 `SHIFT = 6`，并提供 `require_shift(layer_id, shift)`：任何 `shift != 6` 的层**响亮抛错并点名**
（C4a 不支持，需走 spec 修订加 per-layer shift 通路）——见 §7。

## 3) Step 2/3：`--selftest` 输出（逐字）+ 退出码

命令（全仓唯一可用 Python 组合）：

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/quant_ptq.py --selftest
```

输出（逐字）：

```
SELFTEST_PTQ roundtrip_maxerr=0.0156863
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=1
SELFTEST_PTQ percentile_ok=1
RESULT: PASS
```

退出码 `exit=0`。`roundtrip_maxerr=0.0156863 = scale/2`（校准区间 `[-3,5]` ⇒ `scale=8/255≈0.0313725`）
—— 误差**恰好顶到数学上界**，不是远低于界的橡皮章数字。

## 4) 六条 check 的**独立期望**与**红证据**（每条都有专打）

| check | 对什么"独立期望"断言 | 专打它的注入 |
|:--|:--|:--|
| `roundtrip_maxerr` | 与**数学上界** `scale/2`（由校准区间独立算出）比，`err <= scale/2 + tol` | `floor`：`quant` 用 `floor` 代替 `round` ⇒ 误差逼近 `1·scale` |
| `monotone` | 对**升序**输入断言 `diff(q) >= 0`（性质，非恒等） | `negscale`：`scale` 取负 ⇒ x 增 q 减 |
| `clamp` | 与**外部常量** `[127, -128]` 比，超范围必夹到边界、**不回绕** | `noclip`：`quant` 去掉 `clamp` ⇒ int8 截断回绕 |
| `scale_changed` | 把 `scale` **真翻 1 bit**，断言 `dequant(q,scale2)-dequant(q,scale)` **等于解析预测** `(q-zp)*(scale2-scale)` 且**非零** | `noscale`：`dequant` 忽略 scale ⇒ 改 scale 不再变值（橡皮章） |
| `zero_repr`（r2 新增） | 对**全正、不含 0** 的张量（复刻真网 `bbox_head…` 的 `[0.1465,0.3100]`）断言 `zp∈[-128,127]` 且 **码点数 ≥ 32** 且 `maxerr ≤ scale/2` | `nozero`：`affine_params` 去掉零值纳入 ⇒ `zp` 被 clamp、码点塌到 27 个、`maxerr` 超界 |
| `percentile_ok`（r2 新增） | `calibrate(t,99)` 与 `calibrate(t,1)`（含离群样本）都须 `lo<=hi` 且**真剪到尾部**（`lo>min`、`hi<max`） | `badpct`：`calibrate` 取分位序写反 ⇒ `p>50` 时 `lo>hi` |

"先红"（TDD 顺序）由注入式负对照**逐条落实**：注入在**运行期猴补丁**（`_apply_injection`），
**不改** §2 的口径实现；闸门把工具**拷到 `/tmp`** 再注入。代码内置的故障名：

`--inject floor | noclip | negscale | noscale | nozero | badpct`。

### 红证据（逐发粘贴，均 `RESULT: FAIL`、`exit=1`）

**① `--inject floor` ⇒ `roundtrip` 红**（`quant` 用 floor：误差 `0.0313718 = 1·scale > scale/2`）：

```
SELFTEST_PTQ inject=floor
SELFTEST_PTQ roundtrip_maxerr=0.0313718
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=0
SELFTEST_PTQ percentile_ok=1
SELFTEST_PTQ FAIL roundtrip: maxerr=0.0313717647 > bound=scale/2=0.0156862745
SELFTEST_PTQ FAIL zero_repr: zp=-128 codes=136 maxerr=0.00121519 bound=0.000607776（未做零值纳入 ⇒ zp 越界被 clamp、码点塌缩）
RESULT: FAIL
```

**② `--inject noclip` ⇒ `clamp` 红**（去掉 clamp：极端值 `[117, -118, -33, 32]` 回绕，`monotone` 亦被带红）：

```
SELFTEST_PTQ inject=noclip
SELFTEST_PTQ roundtrip_maxerr=0.0156863
SELFTEST_PTQ monotone=0
SELFTEST_PTQ clamp=0
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=1
SELFTEST_PTQ percentile_ok=1
SELFTEST_PTQ FAIL monotone: 8 处 x 增大却 q 减小（最坏 -255）
SELFTEST_PTQ FAIL clamp: 4/4 极端值未夹到边界（期望 127/-128，实得 [117, -118, -33, 32]）
RESULT: FAIL
```

**③ `--inject negscale` ⇒ `monotone` 红**（scale 取负：x 增 q 减 255 处）：

```
SELFTEST_PTQ inject=negscale
SELFTEST_PTQ roundtrip_maxerr=1.98824
SELFTEST_PTQ monotone=0
SELFTEST_PTQ clamp=0
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=0
SELFTEST_PTQ percentile_ok=1
SELFTEST_PTQ FAIL roundtrip: maxerr=1.98823529 > bound=scale/2=-0.0156862745
SELFTEST_PTQ FAIL monotone: 255 处 x 增大却 q 减小（最坏 -1）
SELFTEST_PTQ FAIL clamp: 4/4 极端值未夹到边界（期望 127/-128，实得 [-128, 127, -128, 127]）
SELFTEST_PTQ FAIL zero_repr: zp=-128 codes=1 maxerr=0.309966 bound=-0.000607776（未做零值纳入 ⇒ zp 越界被 clamp、码点塌缩）
RESULT: FAIL
```

**④ `--inject noscale` ⇒ `scale_changed` 红**（`dequant` 忽略 scale：`bit_moved=True changed=False` ⇒ 负对照没发火）：

```
SELFTEST_PTQ inject=noscale
SELFTEST_PTQ roundtrip_maxerr=154.027
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=0
SELFTEST_PTQ zero_repr=0
SELFTEST_PTQ percentile_ok=1
SELFTEST_PTQ FAIL roundtrip: maxerr=154.02744 > bound=scale/2=0.0156862745
SELFTEST_PTQ FAIL scale_changed: bit_moved=True changed=False pred_ok=True（负对照没发火 ⇒ 橡皮章）
SELFTEST_PTQ FAIL zero_repr: zp=-128 codes=135 maxerr=254.691 bound=0.000607776（未做零值纳入 ⇒ zp 越界被 clamp、码点塌缩）
RESULT: FAIL
```

**⑤ `--inject nozero` ⇒ `zero_repr` 红（专打；其余五条全绿，证明这颗牙是它独有的）**：

```
SELFTEST_PTQ inject=nozero
SELFTEST_PTQ roundtrip_maxerr=0.0156863
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=0
SELFTEST_PTQ percentile_ok=1
SELFTEST_PTQ FAIL zero_repr: zp=-128 codes=27 maxerr=0.14654 bound=0.000320443（未做零值纳入 ⇒ zp 越界被 clamp、码点塌缩）
RESULT: FAIL
```

**⑥ `--inject badpct` ⇒ `percentile_ok` 红（专打）**：

```
SELFTEST_PTQ inject=badpct
SELFTEST_PTQ roundtrip_maxerr=0.0156863
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=1
SELFTEST_PTQ percentile_ok=0
SELFTEST_PTQ FAIL percentile_ok: p99=[0.9802,-0.9802] p1=[-0.9802,0.9802] tmin=-50 tmax=50（分位序写反 ⇒ lo>hi）
RESULT: FAIL
```

⇒ 六条 check **各有至少一发**能把它打红；`nozero` / `badpct` 两发是**专打**（其余全绿）。
`floor`/`negscale`/`noscale` 顺带带红别的 check 是"故障本身覆盖面更广"，无害。

## 5) 闸门 `y1/tools/run_quant_ab.sh`（正对照 + 6 发注入负对照）

```bash
bash y1/tools/run_quant_ab.sh        # 可 PY=<python> 覆盖解释器
```

职责：① 跑 `--selftest` 正对照；② 把 `quant_ptq.py` **拷到 `/tmp` scratch**（**绝不改仓内文件**），
逐个 `--inject` 并断言**对应 check 被精确打红**（出现 `SELFTEST_PTQ FAIL <check>` 且整体非 PASS 且 `rc!=0`）；
③ 打印**唯一一条** `RESULT: PASS|FAIL`。

**退出码**：`0` 全过 / `1` 正对照红 / `2` **负对照没发火**（判据无牙）/ `3` 前置缺失。

实测输出（收口）：

```
== run_quant_ab: PY=/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe ==
---- [1] quant_ptq.py --selftest（正对照） ----
SELFTEST_PTQ roundtrip_maxerr=0.0156863
SELFTEST_PTQ monotone=1
SELFTEST_PTQ clamp=1
SELFTEST_PTQ scale_changed=1
SELFTEST_PTQ zero_repr=1
SELFTEST_PTQ percentile_ok=1
   正对照 OK（exit=0, RESULT: PASS）
---- [2] 负对照 inject=floor（须打红 check=roundtrip） rc=1 ----
--- [2] 负对照 inject=noclip（须打红 check=clamp） rc=1 ----
   负对照 OK: inject=noclip ⇒ check[clamp] 精确打红（rc=1）
---- [2] 负对照 inject=negscale（须打红 check=monotone） rc=1 ----
   负对照 OK: inject=negscale ⇒ check[monotone] 精确打红（rc=1）
---- [2] 负对照 inject=noscale（须打红 check=scale_changed） rc=1 ----
   负对照 OK: inject=noscale ⇒ check[scale_changed] 精确打红（rc=1）
---- [2] 负对照 inject=nozero（须打红 check=zero_repr） rc=1 ----
   负对照 OK: inject=nozero ⇒ check[zero_repr] 精确打红（rc=1）
---- [2] 负对照 inject=badpct（须打红 check=percentile_ok） rc=1 ----
   负对照 OK: inject=badpct ⇒ check[percentile_ok] 精确打红（rc=1）
==========================================================================
RESULT: PASS
```

（上面 `floor` 一行的 `负对照 OK: inject=floor ⇒ check[roundtrip] 精确打红（rc=1）` 因摘录排版略去；
完整逐行输出见运行记录。）**闸门退出码 = `0`**。

### 5.1 闸门自身两条退出路径的"发火"证据（证明它不是死代码）

- **`exit=2`（负对照没发火）**：把工具的注入器中性化（`_apply_injection` 首行改成 `if True:`）后放 `/tmp`
  的另一份 scratch，闸门六发全部"注入后仍 PASS" ⇒ 精确落进 `NEGCTL-FAIL ... 无牙` 并 **`exit 2`**。
- **`exit=1`（正对照红）**：把口径实现本身打破（`quant` 多偏 5 个码点）后放 `/tmp` scratch ⇒ 正对照 selftest 红：
  ```
  JUDGE-RED: 正对照未过（rc=1）
  RESULT: FAIL
  （退出码 1）
  ```

## 6) `--onnx`：对真模型做**权重侧** PTQ（C4a.2/C4a.3 的接口）+ 退化的 A/B 证据

```bash
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  .../python.exe tools/quant_ptq.py --onnx ../third_party/yunet/yunet.onnx [--percentile 99.9]
```

实测（`yunet.onnx`）：`IR version=6  opset ai.onnx=11  nodes=106  initializers=112`
（其中 **float32 = 109**，逐张量走冻结口径）。**汇总行（r2）**：

```
W_PTQ float32_initializers=109 percentile=None shift=6 range_excl_zero=22 degenerate_pre_zero=10 degenerate_after_zero=0
```

- `range_excl_zero=22`：109 个 float32 张量里 **22 个区间不含 0**（零值纳入前正是它们会退化）。
- `degenerate_pre_zero=10`：**旧口径**（无零值纳入）下 `err > scale/2` 的张量数 —— **含 3 个真 conv 权重**。
- `degenerate_after_zero=0`：零值纳入后**无一退化** —— 这就是本次修订要证的事，A/B 同源、可复核。

**关键退化张量（零值纳入后已修好；下表 scale/zp 为修后值）**：

```
W bbox_head.multi_level_cls.0.conv2.weight  shape=[1,1,3,3]  min=0.14654   max=0.309966  scale=0.00121555 zp=-128 maxerr=0.000541834
W bbox_head.multi_level_cls.2.conv2.weight  shape=[1,1,3,3]  min=-0.415628 max=-0.0972763 scale=0.00162992 zp= 127 maxerr=0.000715305
W bbox_head.multi_level_obj.1.conv2.weight  shape=[1,1,3,3]  min=0.0249823 max=2.3588    scale=0.00925019 zp=-128 maxerr=0.00340141
```

**修复前的真值（用 `_raw_params` 复算，写进汇总行的 `degenerate_pre_zero`）**：以
`bbox_head.multi_level_cls.0.conv2.weight [0.14654,0.309966]` 为例 —— 旧口径 `scale=(hi-lo)/255=6.409e-4`、
`zp_unc=round(-0.14654/6.409e-4)-128=-357` 被 `clamp` 到 `-128`，`quant` 只剩 **4 个码点**、
`maxerr=0.14654 = 区间 89.7%`（`dequant` 把 `[0.1465,0.31]` 全压到 `[0.1468,0.1634]`）。
零值纳入后 `scale=0.309966/255=1.2156e-3`、`zp=-128`（合法），`maxerr=5.4e-4 = scale/2`。

- **激活侧校准**（需要一个代表性输入跑 ORT 采 min/max）**不在本任务**，留 C4a.2/C4a.3；本分支只做权重侧，
  且**懒 import onnx** ⇒ `--selftest` 不依赖 onnx。
- 与 `--selftest` 分开：**闸门快、自足**，不被 ONNX 拖累。

## 7) `shift ≠ 6` 的点名政策

`SHIFT = 6` 已冻结（C3.8：描述符 `QUANT_SHIFT` 必须 == 网表展开期 `SHIFT`）。`require_shift(layer_id, shift)`
对任何 `!= 6` 的层**抛错并点名**。C4a.1 阶段尚无"每层 shift"的来源（那来自 C4a.3 转换器对每个单元下达的
`QUANT_SHIFT`）⇒ **本任务未遇到 `≠6` 的层**；C4a.3 在给每个单元定 `QUANT_SHIFT` 时必须调用它，
一旦出现 `≠6` 的层**必须在报告里点名**并走 spec 修订（加 per-layer shift 通路），**不得静默**。

## 8) 给 C4a.2 / C4a.3 的接口（待续）

- **唯一真源**：`y1/tools/quant_ptq.py` 的 `calibrate / affine_params / quant / dequant`（import 复用）。
- `ptq_weight_tensor(t, percentile=None) -> (scale, zp, q_int8, maxerr)`：单张量的权重侧 PTQ。
- `require_shift(layer_id, shift)` / `SHIFT`：requant 移位口径守卫。
- **C4a.2 续写**：本文件补"§参考与 float ORT 的逐层最大偏差"。
- **C4a.3 续写**：激活校准口径（代表性输入）、每单元 `(scale, zp, shift)`、权重 blob 的 `(scale, zp)` 落盘；
  且**零值纳入已保证任意张量不退化** ⇒ 转换器无需"跳过退化张量"的特殊分支（这条不再需要，r1 曾拟加）。

## 9) 文件 + 指纹 + 提交

| 文件 | 字节 | md5 |
|:--|--:|:--|
| `y1/tools/quant_ptq.py` | 22185 | `95f6dd3425d5360fcb305efc7edc8a3c` |
| `y1/tools/run_quant_ab.sh` | 6293 | `0b8f5f2e161fdf0971dbae0f48650e0c` |
| `y1/reports/c4a_quant.md` | 本文件 | — |

提交：本任务三件套同属一个提交（`git log -1 --format='%h %s' -- y1/tools/quant_ptq.py`），
message 见任务约定；**未改任何冻结工具**（`ddr_traffic.py` / `fusion_buffer.py` / `bypass_traffic.py` /
`mac_ref.py` / `bypass_ref.py` / `conv_unit_ref.py` / `desc_table.py` 一字未动）。

## 10) 自查记录（findings / concerns）

1. **六条判据均非恒等比较**：`roundtrip` 对数学上界 `scale/2`、`monotone` 对升序差分性质、`clamp` 对外部常量
   `127/-128`、`scale_changed` 对**解析预测** `(q-zp)*(scale2-scale)` 且要求非零、`zero_repr` 对**码点数 + 误差界**
   （全正张量）、`percentile_ok` 对**剪尾性质 + lo<=hi** —— 逐条均有独立期望（§4）。
   `roundtrip_maxerr` 实测**恰好顶到** `scale/2`（0.0156863），说明数据把上界逼紧了，不是宽松的假绿。
2. **红证据齐**：六条 check 各有 1 发注入精确打红（§4），其中 `nozero`/`badpct` 为**专打**；闸门的
   `exit 1`/`exit 2` 两条失败路径也各自实跑发火（§5.1）。
3. **⚠️ r2 修正的口径缺陷（原 §10.3 的判断有误，此处更正）**：初版称"真网卷积权重均跨 0 ⇒ 不退化，
   命中的只是非 NPU 张量"——**实测不成立**。用 `--onnx` 扫全 109 个 float32 张量，**22 个区间不含 0**，
   其中 **10 个在旧口径下真退化（`err>scale/2`）**，**含 3 个真 conv 权重**：
   `bbox_head.multi_level_cls.0.conv2.weight [1,1,3,3]`、`bbox_head.multi_level_cls.2.conv2.weight`、
   `bbox_head.multi_level_obj.1.conv2.weight`（另有 `bbox_head.multi_level_kps.1.conv2.bias [10]` 与
   两个 `bbox_head.multi_level_bbox.0.conv{1,2}.bias [4]`）。最坏者丢区间 **89.7%**。
   ⇒ **若不做零值纳入，C4a.3 会把这类"权重 blob"静默烤成塌缩常量**。**处置**：`affine_params` 加**零值纳入**
   （结构性修正，公式一字未改；`zp` 事后可证恒在界内），并加 `zero_repr` 判据 + `nozero` 负对照把这条**钉住**。
   汇总行的 `degenerate_pre_zero=10 / degenerate_after_zero=0` 是这版的 A/B 自证。
4. **percentile 分位序**：初版 `np.percentile(a,[p,100-p])` 在 `p>50` 时给出 `lo>hi`（实测 `p=99 ⇒ [0.98,-0.98]`）
   ⇒ 求参退化。**处置**：改 `sorted([p,100-p])`，并加 `percentile_ok` 判据 + `badpct` 负对照（§4⑥）。
5. **空张量**：真网含一个 `shape=[0]` initializer；`calibrate` 对 `size==0` 退化为 `(0,0)`（不抛），
   已在 `--onnx` 全量跑通（§6）。
6. **`--selftest` 自足**：只在 `--onnx` 分支懒 import onnx ⇒ 闸门不依赖 ONNX、跑得快（实测 < 1 s）。
7. **未过度解读**：本任务只证"**量化口径本身**自洽且自检有牙"，**不证**整网精度、不证与 ORT 的偏差、
   不证上板 —— 那些分别属 C4a.2/C4a.3/C4b。
8. **遗留（非本任务，记录）**：`require_shift` 在 C4a.1 无调用点（真来源在 C4a.3），保持"响亮抛错"待用；
   `scale_changed` 的 `pred_ok` 在实现下近乎定义式（因 `dequant` 与 `pred` 同源于 `(q-zp)*scale`）——
   它拦的是"`dequant` 里 scale 不生效"这类实现漂移（由 `noscale` 注入实证有牙），非独立物理量。

---

# §11 同口径 int8 整网参考（C4a.2）—— **G2/G3/G4 的黄金**

**Status: DONE_WITH_CONCERNS（2026-10-10）**：参考与闸门都已落地、判据全绿、负对照能发火；
**一处必须点名**：冻结的 `>>SHIFT`（纯移位 requant）**表达不了**标定出的 per-tensor scale 比，见 §11.3。

**Revision（2026-10-11）—— 权重改对称量化（spec §4.5-A）**：权重由 per-tensor **affine** 改为**对称**
（`z_w ≡ 0`、`s_w = max|w|/127`，`w_q ∈ [−127,127]` 恰落 int8 ⇒ 硬件 MAC 保持 int8×int8）；
**激活仍 affine**（`calibrate`/`affine_params` 零值纳入 + `quant`/`dequant`）。黄金**已重跑**：
权重标定 scale 变化 ⇒ 整网数值整体平移，逐层 md5、`c4a_ref_layers.json` 指纹与 §11.5 ORT 偏差全表刷新；
新增权重 blob 逐层 md5（§11.9）。**负对照靶层不变**（`419` 本就是**激活**张量；权重 zp 恒 0 不可翻）。

## 11.1 交付物

| 文件 | 说明 |
|:--|:--|
| `y1/tools/quant_ref.py` | 同口径 int8 整网参考（复用 `quant_ptq` 与 `ddr_traffic.GraphView` 的算子序） |
| `y1/tools/run_quant_ref.sh` | 闸门：口径自检 + 整网正对照 + 退化守卫 + zp 负对照（正/对照两发） |
| `y1/reports/c4a_ref_layers.json` | **逐层 md5 + 形状 + distinct + max\|ours-ORT_float\|**（106 层，仓内） |
| `y1/gen/c4a_ref/layers/*.npy` | 106 个中间张量落盘（`gen/` gitignore，26 MB） |

## 11.2 冻结的参考行为（逐字写在 `quant_ref.py` 文件头）

- **输入**：仓内**无代表性人脸图**（2026-10-10 决策）⇒ 用**确定性合成图**
  `np.random.default_rng(20261010).random((1,3,640,640), float32)`（U[0,1)）；
  **我们的 int8 参考与 ORT float 共用同一张**，且**不写任何东西进 `third_party/`**。
- **校准**：同一张图跑一次 ORT float，抓每个张量 min/max（把中间张量临时加进 `graph.output`，**只在内存**），
  再走 `quant_ptq.calibrate → affine_params`（min/max + 零值纳入）得**激活** `(s_x,z_x)`；
  **权重走对称口径** `quant_ptq.weight_params`（`z_w ≡ 0`、`s_w = max|w|/127`）→ `quant_weight` 求 `w_q`（§4.5-A）。
- **算子序**：`ddr_traffic.GraphView(onnx).nodes`（冻结件），并断言它与 `onnx.graph.node` 一致。
- **算子**：`Conv`（一般分组，`GROUP=C` 即 depthwise 特例；含 bias；零填充填"实数 0 的码点 `z_x`"）、
  `Relu`（`max(实数,0)`）、`MaxPool`（2×2/s2 int8 取最大）、`Resize`（nearest/asymmetric/floor = x2 逐位复制）、
  `Add`（两路 affine 相加）、`Sigmoid`（256 项 int8→int8 表，表由本层 affine 现算）、
  `Transpose`/`Reshape`（numpy；折进寻址是 C4a.7）。
- **Q/DQ 位置**：`acc(int32) → 乘子 M → >>SHIFT → clamp int8 → 下一层的 int8 输入`；**层间不插浮点 DQ**。
  权重对称 ⇒ `z_w ≡ 0`，累加退化为 `acc = Σ (x_q − z_x)·w_q + round(bias/(s_x·s_w))`（`w_q` 本身即中心化权重）。

**initializer 分类（109 个 float32，逐类点名；`--gate` 里逐条打印）**：
53 个 `Conv.input[1]` = **NPU 权重**（int8 PTQ）；53 个 `Conv.input[2]` = **NPU bias**（落累加器单位）；
`W464/W465`（shape `[4]`，`Resize.input[2]`）= **上采样 scales，不量化**（浮点常量）；
`W240`（shape `[0]`，`Resize.input[1]` roi）= 空张量、本口径不用；`W290/W362/W395` = int64 的 Reshape shape（非 float32）。
53+53+2+1 = **109** ✓。其中 `bbox_head.multi_level_obj.0.conv1.bias [1]` 喂真 conv ⇒ **算 NPU bias**。

## 11.3 ★ 点名：纯 `>>SHIFT` 表达不了标定的 scale 比（本任务最重要的发现）

`acc = Σ (x_q - z_x)(w_q - z_w) + round(bias/(s_x·s_w))` 的量纲是"实数 /(s_x·s_w)"，
要落回输出码点需乘 `ratio = s_x·s_w/s_y`。实测该 `ratio ≈ 2^-9`（层 0：`sx=1/255`、`sw≈3.9e-3`、
`sy=2.167/255` ⇒ `ratio≈1.8e-3 = 1/555`），而冻结 `SHIFT=6` 的乘子粒度是 `2^-6=1.6e-2 ≫ ratio`
⇒ 纯移位时 `M` 饱和到 1，整层偏 ≈8.6×。探针实测（`gen/c4a/frozen_requant_probe.py`，同一张图）：

| 变体 | `f(acc)` | 与 ORT 的最大偏差（满量程%） | 中间层退化？ |
|:--|:--|:--|:--|
| A | `acc >> 6`（纯冻结移位，无乘子） | **≈100%** | **是**（`419` distinct=2、`258` distinct=1） |
| B | `acc >> 6`（不扣 zero-point） | ≈100% | 是 |
| D6 | `(acc · round(ratio·2^6)) >> 6` | ≈100% | 是（`M` 饱和到 1） |
| **D31** | `(acc · round(ratio·2^31)) >> 31` | 7…32% | 否（各层健康） |
| E | `round(acc · ratio)`（精确浮点乘子） | 4…32% | 否 |

⇒ **纯 `>>SHIFT` 会做出一个"退化黄金"**（中间层塌成常数 ⇒ G3/G4 的逐字节对账变成橡皮章）。
**处置（本任务采用的冻结形式）**：requant = **每层 Q 格式乘子 × 冻结移位**：
```
M = round( (s_x·s_w/s_y) · 2^(SHIFT+REQUANT_Q) )            REQUANT_Q = 24
y_q = clamp( ((acc · M) >> REQUANT_Q) >> SHIFT + z_y, -128, 127 )
```
`>>SHIFT` 就是冻结的 requant 步（`require_shift` 对每层断言 `SHIFT==6`）；`>>REQUANT_Q` 是**乘子自身的 Q 格式**归一。
**这仍是纯整数**（无层间浮点 DQ），也是真实 NPU 的标准 requant 形式。
★ 但 **C4a.3/C4a.5 必须把"每层乘子 M"落进描述符/网表**（C3 的 `Conv3x3Slice` 目前只有 `>>6`，无乘子），
否则硬件与这条黄金对不上 —— **这是要回给 C4a.3 的接口约束**。

## 11.4 闸门输出（`bash y1/tools/run_quant_ref.sh`，逐字收口；2026-10-11 权重对称后重跑）

```
== run_quant_ref: PY=…/lxvenv/Scripts/python.exe ==
---- [0] quant_ref.py --selftest（口径自检 + 三重循环） ----
  PASS  算术右移：-1 不变号（不是逻辑右移）
  PASS  requant 大数照样 clamp 到 int8
  PASS  M(ratio=2^-SHIFT) == 2^REQUANT_Q（乘子 Q 格式自洽）
  PASS  ci=3 co=4 5x7 g=1 pads=[1, 1, 1, 1]：im2col==抽头循环==三重循环（差 0 / 0）
  PASS  ci=2 co=2 4x4 g=2 pads=[1, 1, 1, 1]：im2col==抽头循环==三重循环（差 0 / 0）
  PASS  ci=4 co=4 3x6 g=4 pads=[1, 1, 1, 1]：im2col==抽头循环==三重循环（差 0 / 0）
  PASS  ci=2 co=3 5x5 g=1 pads=[0, 0, 0, 0]：im2col==抽头循环==三重循环（差 0 / 0）
  PASS  权重对称（§4.5-A）：z_w=0、s_w=max|w|/127、w_q∈[-127,127]、roundtrip≤s_w/2   ← 2026-10-11 新增
  PASS  朴素三重循环输出非常数（判据有分辨率）
  PASS  Sigmoid 表 256 项、值在 int8 内 / 单调不减 / == quant(sigmoid(dequant(x))) / 非常数
---- [1] 整网正对照（向量化 vs 第二实现）+ 落盘 + JSON ----
REF model=yunet.onnx md5=4ae92eeb150c82ce15ac80738b3b8167
REF input=input shape=[1, 3, 640, 640] (synthetic seed=20261010, U[0,1)) md5=7511f30d15b7e32b5be5025f82e40651
REF nodes=106 float32_init_weights=53 biases=53 resize_scales=2
REF mismatch cls_8/16/32 obj_8/16/32 bbox_8/16/32 kps_8/16/32 = 0（12 个输出全部逐点一致）
GUARD input_distinct=256 lastlayer=kps_32 lastlayer_distinct=228
ORT_DEV layers_recorded=106 worst_pct_layer=obj_32(93) pct_of_range=80.50%
ORT_DEV worst_abs_layer=270(65) max_abs_dev=5.6379 pct_of_range=25.65%
FAULT_MISMATCH=100300 (inject +1 code at conv idx=0 => judge can go red)
WEIGHT_MD5 count=53 all_symmetric=1 aggregate=8d185e21bff2256635e85cc200293eb9
JSON …/y1/reports/c4a_ref_layers.json bytes=69433 md5=3d92c97d3698ac77d2554a95808ce473
DUMP dir=…/y1/gen/c4a_ref files=106
MISMATCH=0
REF_RESULT: PASS
   正对照 OK（MISMATCH=0 / 守卫在线 / 有分辨度 / ORT 偏差已记录）
---- [3] 负对照 zp(419)+1（须 MD5_DIFF_LAYERS >= 1） ----
    ZP_MUTATE tensor=419 delta=+1   MD5_DIFF_LAYERS=106   MD5_FIRST_DIFF_IDX=0
---- [3] 对照 zp(419)+0（须 MD5_DIFF_LAYERS == 0） ----
    ZP_MUTATE tensor=419 delta=+0   MD5_DIFF_LAYERS=0
   负对照 OK: zp+1 ⇒ 变 106/106 层（含该层起往后）；zp+0 ⇒ 变 0 层
==========================================================================
RESULT: PASS
```
退出码 = `0`。（`zp` 负对照：靶层 `419` 是**首层 Conv 的激活输出**，把生产者**写入时**的 `z_y` 改 1、消费侧仍用真
`z` ⇒ 实数整体偏 `delta·s` ⇒ **该层起往后 106/106 层 md5 全变**；`delta=0` ⇒ **0 层变**。权重对称后 `z_w ≡ 0`、
权重 zp 不可翻 ⇒ 负对照**本就在激活侧**，无需换靶层 —— 已在闸门注释与 `quant_ref.py` 文件头点名。）

## 11.5 与 float ORT 的**逐层**最大偏差（**记录，不是判据**；判据在 C4b/G7）

口径：`max|dequant(我们的 int8) - ORT_float|`（逐层；106 层全表见 `c4a_ref_layers.json` 的
`layers[*].ort_max_abs_dev`）。`pct` = 该偏差 / 该层标定满量程 `(hi-lo)`。
★ **2026-10-11 权重对称后重测**：权重 scale 由 `(hi-lo)/255` 改为 `max|w|/127` ⇒ 每层 `s_x·s_w/s_y` 比变
⇒ 整网数值整体平移，下表数字与 §11.3 老表**不可逐项复用**。

**按算子类型的最坏值**：

| 算子 | 层数 | 最坏 `max_abs_dev` | 最坏 `pct_of_range` |
|:--|--:|--:|--:|
| Sigmoid | 6 | 0.1365 | 80.50%（`obj_32`，量程仅 2.87e-3 ⇒ 百分比别当真） |
| Relu | 15 | 0.6808 | 33.22% |
| Resize | 2 | 0.6808 | 33.22% |
| Add | 2 | 0.7127 | 31.13% |
| Conv | 53 | 5.638 | 25.73% |
| Transpose / Reshape | 12 / 12 | 5.638 | 25.65% |
| MaxPool | 4 | 0.2300 | 22.60% |

**12 个 graph 输出**：

| 输出 | idx | `max_abs_dev` | 满量程 | `pct` | distinct |
|:--|--:|--:|--:|--:|--:|
| `cls_8` | 78 | 0.1365 | 0.4770 | 28.62% | 120 |
| `cls_16` | 81 | 0.03155 | 0.2222 | 14.20% | 86 |
| `cls_32` | 84 | 0.04697 | 0.2964 | 15.84% | 77 |
| `obj_8` | 87 | 4.316e-06 | 7.212e-06 | 59.84% | 32 |
| `obj_16` | 90 | 6.754e-06 | 4.554e-05 | 14.83% | 37 |
| `obj_32` | 93 | 2.311e-03 | 2.871e-03 | 80.50% | 32 |
| `bbox_8` | 95 | 0.6008 | 3.279 | 18.32% | 208 |
| `bbox_16` | 97 | 0.1582 | 1.114 | 14.20% | 238 |
| `bbox_32` | 99 | 0.4438 | 4.819 | 9.21% | 214 |
| `kps_8` | 101 | 0.5933 | 5.476 | 10.83% | 245 |
| `kps_16` | 103 | 0.09589 | 0.9900 | 9.69% | 218 |
| `kps_32` | 105 | 2.161 | 13.89 | 15.56% | 228 |

**绝对偏差最大的 8 层**（多为 20×20/40×40 的早期 head 分支，量程大 ⇒ 绝对偏差大但 `pct` 仅 16–26%）：

```
idx= 65 Conv       270    dev=5.638  range=21.98  pct=25.65%
idx= 85 Transpose  317    dev=5.638  range=21.98  pct=25.65%
idx= 86 Reshape    327    dev=5.638  range=21.98  pct=25.65%
idx= 75 Conv       280    dev=2.161  range=13.89  pct=15.56%
idx=104 Transpose  408    dev=2.161  range=13.89  pct=15.56%
idx=105 Reshape    kps_32 dev=2.161  range=13.89  pct=15.56%
idx= 69 Conv       274    dev=2.112  range=10.55  pct=20.02%
idx= 91 Transpose  341    dev=2.112  range=10.55  pct=20.02%
```

**读法**：首层偏差仍极小（`419` dev=0.008585，`pct=0.40%`），逐层累积到 9–29%（早期 head 分支量程大所以绝对数大）。
`obj_*` 的 `pct` 看起来吓人，但那是**量程本身只有 1e-6~3e-3**（Sigmoid 后近似 0）⇒ 绝对偏差 1e-6~2e-3 级，
**不构成判据**。整体 9–29% 的偏差是 **8-bit per-tensor PTQ（无 QAT）**的预期代价，由 C4b 的 G7 端到端容差收口。

## 11.6 负对照/失败路径实跑（证明闸门不是橡皮章）

| 路径 | 做法（**scratch 拷贝**，不改仓内文件） | 实测 |
|:--|:--|:--|
| `exit=1`（正对照红） | 只打破**第二实现**的 Sigmoid 取址（`lut[(k+1)%256]`）⇒ 整网 `MISMATCH>0` | `JUDGE-RED: 整网正对照未过`，`RESULT: FAIL`，`exit=1` ✓ |
| `exit=2`（负对照没发火） | 把 `ZY()` 中性化（不再改 `z_y`）⇒ `zp+1` 后 `MD5_DIFF_LAYERS=0` | `NEGCTL-FAIL: zp+1 后中间张量 md5 没变 ⇒ 无牙`，`exit=2` ✓ |
| 判据分辨度 | `--gate` 自带 `FAULT_MISMATCH`：向量化路径注入 1 码点 | `FAULT_MISMATCH=100300 > 0` ⇒ 判据能被打红 ✓ |

## 11.7 文件 + 指纹 + 提交

| 文件 | 字节 | md5 |
|:--|--:|:--|
| `y1/tools/quant_ref.py` | 40386 | `d1c75dc262cfd46bb6f7c66bf93ac159` |
| `y1/tools/run_quant_ref.sh` | 8153 | `491264533b5683424973a70177e47d9e` |
| `y1/reports/c4a_ref_layers.json` | 69433 | `3d92c97d3698ac77d2554a95808ce473` |

**未改任何冻结件**：`quant_ptq.py`（只 import）、`ddr_traffic.py`（只 import `GraphView`）、
`fusion_buffer.py` / `bypass_traffic.py` / `mac_ref.py` / `bypass_ref.py` / `conv_unit_ref.py` / `desc_table.py` 一字未动。

## 11.8 自查（findings / concerns / 假设）

1. **⚠ CONCERN（已点名，见 §11.3）**：冻结 `>>SHIFT=6` 的纯移位 requant **表达不了**标定出的 scale 比
   （`ratio≈2^-9`）。本任务把 requant 落成"**每层 Q 格式乘子 × 冻结移位**"（`REQUANT_Q=24`），
   `require_shift` 仍对每层断言 `SHIFT==6`。**C4a.3 必须把每层乘子落进描述符/网表**（C3 的 `Conv3x3Slice`
   现只有 `>>6`）—— 否则 G2 的逐字节对账对不上。这条是**接口约束**，不是本任务能单方修掉的。
2. **假设（合成输入）**：仓内无代表性人脸图 ⇒ 用定 seed(20261010) 的 U[0,1) 合成图。
   真图/校准代表性属 **C4b/G7**；本任务的 ORT 偏差**只记录不判定**，换图会变数但**不改判据**。
3. **假设（零填充 = 实数 0 的码点 `z_x`）**：affine 语义下"补 0"应填代表实数 0 的码点（不是字节 0）。
   C3 的 `npu_board_conv.py` 目前朴素填字节 0（且无 zero-point）⇒ **C4a.3/C4a.5 的 RTL 要按此对齐**。
4. **旁路算子的"输出刻度"**：每个算子（含 Relu/MaxPool/Resize）的**输出张量**有自己的标定 `(s_y,z_y)`，
   参考用**同一条 requant** 折算过去。硬件若把 Relu 折进生产者尾声（同刻度），需在 C4a.3 对齐。
5. **`Sigmoid` 口径**：C3 冻结的是 **Q3.4→Q0.7 占位表**（`bypass_ref.sigmoid_lut`）；本参考按**本层 affine**
   现算 256 项表（同一形式、真刻度）。**C4a.3 必须用真刻度重做表**（C3 的占位值属已知开口项）。
6. **不证**：本任务**不证**整网精度达标（那是 C4b/G7）、不证硬件能实现（C4a.3–C4a.6）、不证上板。
   它证的只有：**口径复用、第二实现逐点一致（含朴素三重循环）、负对照有牙、退化守卫在线**。
7. **确定性**：同代码两次 `--gate` 产出的 JSON md5 完全一致（2026-10-11 实测 `3d92c97d…` → `3d92c97d…`）。

## 11.9 2026-10-11 修订：权重对称量化（§4.5-A）后的黄金指纹

**口径变化**：`quant_ref.py` 里 Conv 权重由 `affine_params(calibrate(w))` + `quant(w,s,z)` 改为
`weight_params(w)` + `quant_weight(w,s)`（均**逐字复用** `quant_ptq`）；`w = {"q","scale","zp"}` 字典
**形状不变**、只是 `zp ≡ 0`，故 C4a.3 转换器的消费接口不受影响。**激活侧一字未改**（仍 `calibrate`/
`affine_params` 零值纳入 + `quant`/`dequant`）。`SHIFT=6` 与 requant 乘子形式均不变。
- 自检新增第 8 条 `PASS 权重对称（§4.5-A）：z_w=0、s_w=max|w|/127、w_q∈[-127,127]、roundtrip≤s_w/2`——把口径**改回 affine 即红**。
- `--gate` 新增 `WEIGHT_MD5` 行（权重 blob 指纹），JSON 新增 `weights` 段与 `frozen.weight_quant`。

**权重 blob 指纹**（53 个 Conv 权重，对 **int8 原始字节** 取 md5）：

- `count=53`、`all_symmetric=1`（每个 `w["zp"]==0`）、`s_w=max|w|/127`；
- **聚合 md5**（把 `"<name>:<md5>"` 逐行拼接后再 md5）= `8d185e21bff2256635e85cc200293eb9`；
- 全表在 `c4a_ref_layers.json` → `weights.list[*].{name,shape,nbytes,md5,scale,zp}`，逐层如下：

```
name                                     shape          bytes  md5(int8 q)
420                                      [16, 3, 3, 3]    432   9f7599a6aae6562160d5f60542082342
423                                      [16, 1, 3, 3]    144   cdcb2091b801055be469ead8e6cdd646
426                                      [16, 1, 3, 3]    144   cd903921120fa106d7fa26a0abe8de7c
429                                      [32, 1, 3, 3]    288   d658cabd775cce0c65476a0bbc0ebf7f
432                                      [32, 1, 3, 3]    288   2ff1ad817a11ebf7cd365ecce12072e2
435                                      [64, 1, 3, 3]    576   4c50196b3f1334885657443905c9bb67
438                                      [64, 1, 3, 3]    576   c7f7c791288962fe2789fe68738173c0
441                                      [64, 1, 3, 3]    576   54ad062ffff6dbcbb5d099e46ab76bea
444                                      [64, 1, 3, 3]    576   042fb1d3b4a3adfdb496f5b8f073b886
447                                      [64, 1, 3, 3]    576   38601ae2b650ae4f11927e5ea927a56e
450                                      [64, 1, 3, 3]    576   7f27e7268be22446d86c5102c8160fa7
453                                      [64, 1, 3, 3]    576   b5c658bfb509b0745baa6f629ae1737f
456                                      [64, 1, 3, 3]    576   28fdc827ce5bf3730f2aaf81c6c44dcc
459                                      [64, 1, 3, 3]    576   b4373f6551a5b0e9f070f1d222c8910f
462                                      [64, 1, 3, 3]    576   443a77d8d987e2ab0aee82558b376330
backbone.model0.conv2.conv1.weight       [16, 16, 1, 1]  256   bbf6d1f0b0c14fa2e7c59bb0c87fd26e
backbone.model1.conv1.conv1.weight       [16, 16, 1, 1]  256   734cca03ea49614996394c25e3be819a
backbone.model1.conv2.conv1.weight       [32, 16, 1, 1]  512   8d799e5da0785c567f3aab86ddc8df97
backbone.model2.conv1.conv1.weight       [32, 32, 1, 1]  1024  86953695e53b4b4caa0df63fa6bf557d
backbone.model2.conv2.conv1.weight       [64, 32, 1, 1]  2048  705110e327933115afbbb6818edcd53a
backbone.model3.conv1.conv1.weight       [64, 64, 1, 1]  4096  9af37276f8b96699ed6220cfa493ea1a
backbone.model3.conv2.conv1.weight       [64, 64, 1, 1]  4096  d25575429cb62b99230718142a5e02d7
backbone.model4.conv1.conv1.weight       [64, 64, 1, 1]  4096  eb9dd64d73c90998a6cbbb255bef6dcf
backbone.model4.conv2.conv1.weight       [64, 64, 1, 1]  4096  f8ea74008b20336cca14a861be4b9703
backbone.model5.conv1.conv1.weight       [64, 64, 1, 1]  4096  4dbf13ea2582a4d538b829f046ed2bab
backbone.model5.conv2.conv1.weight       [64, 64, 1, 1]  4096  b7e13ecbc3c2b7b3f4e29d8f714eb44d
bbox_head.multi_level_bbox.0.conv1.weight [4, 64, 1, 1]  256   43266443a26fb4052934f800dba4faeb
bbox_head.multi_level_bbox.0.conv2.weight [4, 1, 3, 3]    36   7365b4f3d1afb00d36fd92d0522c3d1e
bbox_head.multi_level_bbox.1.conv1.weight [4, 64, 1, 1]  256   d878af9b1b2e9cf3d16216f4ec59cfc1
bbox_head.multi_level_bbox.1.conv2.weight [4, 1, 3, 3]    36   5fd68c75d71b03bc1cfe0aec98576499
bbox_head.multi_level_bbox.2.conv1.weight [4, 64, 1, 1]  256   1f4c52ffbf5c11cb8ddd928fb1de8fe1
bbox_head.multi_level_bbox.2.conv2.weight [4, 1, 3, 3]    36   4859956f193c0087aa383c8f998dc213
bbox_head.multi_level_cls.0.conv1.weight  [1, 64, 1, 1]   64   5ffe2a530bdb9836fcfb4da98a596b3f
bbox_head.multi_level_cls.0.conv2.weight  [1, 1, 3, 3]     9    f82a243ebd1a26bcde379ca8909106e2
bbox_head.multi_level_cls.1.conv1.weight  [1, 64, 1, 1]   64   6670103f2dc0d7242ccbb9ae59f6e8c2
bbox_head.multi_level_cls.1.conv2.weight  [1, 1, 3, 3]     9    8255c8244711dcadc980d1de76bb9e19
bbox_head.multi_level_cls.2.conv1.weight  [1, 64, 1, 1]   64   e01065ba93e40ce2f2d18827d22596f7
bbox_head.multi_level_cls.2.conv2.weight  [1, 1, 3, 3]     9    30a7906101bde0341e839d06f0f08048
bbox_head.multi_level_kps.0.conv1.weight  [10, 64, 1, 1]  640   2bf9a74b49f16fc1384576781824407f
bbox_head.multi_level_kps.0.conv2.weight  [10, 1, 3, 3]    90   acd2b43ea8df5efe2bb21877b3989584
bbox_head.multi_level_kps.1.conv1.weight  [10, 64, 1, 1]  640   6ceb2839f03061855b9c2ba6903eba6a
bbox_head.multi_level_kps.1.conv2.weight  [10, 1, 3, 3]    90   805e57aef0618e62675753cb1a0457a7
bbox_head.multi_level_kps.2.conv1.weight  [10, 64, 1, 1]  640   dbb44c18b7a1a558b77c0ca4e6bb9b2e
bbox_head.multi_level_kps.2.conv2.weight  [10, 1, 3, 3]    90   92ec4cb406ea4ae4038cd38a186fff7d
bbox_head.multi_level_obj.0.conv1.weight  [1, 64, 1, 1]   64   8bb3492ec820eb73c7f67c541559ddd4
bbox_head.multi_level_obj.0.conv2.weight  [1, 1, 3, 3]     9    4c82c2c2b2e333f9e09f228c272223dc
bbox_head.multi_level_obj.1.conv1.weight  [1, 64, 1, 1]   64   f7317739da71f140f31f2f3c5beefcfe
bbox_head.multi_level_obj.1.conv2.weight  [1, 1, 3, 3]     9    1da388d0678da319bbbe89790a1dac32
bbox_head.multi_level_obj.2.conv1.weight  [1, 64, 1, 1]   64   ca2713beea90af8acf296ddabe703c43
bbox_head.multi_level_obj.2.conv2.weight  [1, 1, 3, 3]     9    4d8ae3565b247fb04d644b2b868191b6
neck.lateral_convs.0.conv1.weight        [64, 64, 1, 1]  4096  e8843869467f0880bf1d62d22a137456
neck.lateral_convs.1.conv1.weight        [64, 64, 1, 1]  4096  16270cd7cc0c62d4c4be70c38ff817ef
neck.lateral_convs.2.conv1.weight        [64, 64, 1, 1]  4096  d5a9c9fe1be14ea7752230047b236566
```

**`c4a_ref_layers.json`（Regenerated）**：bytes=**69433**、md5=**`3d92c97d3698ac77d2554a95808ce473`**
（两次 `--gate` 一致 ⇒ 确定性；较 2026-10-10 的 55150 B / `dc073b9d…` 变化源于权重口径 + 新增 `weights` 段）。

**负对照靶层无需换**：`419` 是**首层 Conv 的输出激活**张量（`run_net` 里 `ZY()` 只作用于算子**输出**；
权重从不经 `ZY()`）。权重对称后 `z_w ≡ 0` 本就不可翻，负对照**天然落在激活侧** —— 已在
`quant_ref.py` 文件头与 `run_quant_ref.sh` 注释点名，**无需 retarget**。
