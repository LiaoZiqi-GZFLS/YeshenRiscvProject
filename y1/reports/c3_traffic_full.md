# Y1-C3.1 报告 —— R6 携带项：旁路算子流量补进模型（离线）+ C3 before 基线

**Status: DONE**

**一句话**：C0 的 **12,576,000 B/帧（12.576 MB，21.94 fps）** 只计 Conv 的激活读写，是一条
**下界**；把**旁路算子自身的激活 IO**（`MaxPool`/`Resize`/`Add`/`Sigmoid`，spec §2 裁决"进硬件"
的四类）补进去后，**整帧真流量 = 19,521,600 B/帧（19.5216 MB）⇒ 14.13 fps**（DDR 下限 275.9 MB/s）。
`--no-bypass` 档**逐字**回到 12,576,000，正向证明"补进去的确实是旁路那部分"。

---

## 0) 它与上一步/spec 的关系（为什么是这一步）

spec R6 明确写着：

> **C0 的流量模型是下界**：只计 Conv 的输入/输出，**不含旁路算子自身的激活读写**、不含 12 个头张量的后处理。

C0.3 推荐的 `fuse_both`（33 对融合）在此口径下是 12.5760 MB/帧、21.94 fps。补进旁路后 21.94 fps
会打折 ⇒ 本任务把这个折扣**量出来**，并给 C3 立一条 **before 基线**（C3 要改 `DdrMaster.scala`，
C2 的字节级闸门必须能回归对比）。

**本任务只做离线分析**：新建 1 个只读脚本 + 3 个报告产物；不碰 RTL / SoC / 板 / 描述符。

---

## 1) C3 的 before 基线（Step 1）

在 `y1/` 下逐条跑 C2 的五道设备闸门并记指纹（`y1/reports/c3_baseline.txt`）：

```
run_ddrread_ab=0
run_ddrwrite_ab=0
run_ddrcopy_ab=0
run_hostregs_ab=0
run_nputop_ab=0
e1871260a5509c95bea0f0fd8be3bf61 *gen/DdrMaster.v
9bc9ba6f821b36d1fe72079a3ed192e9 *gen/NpuTop.v
```

**五道闸门全绿（exit 0）** ⇒ before 基线的判据本身是成立的（没有"把别人的红当我的 before"）。
`gen/DdrMaster.v` 与 `gen/NpuTop.v` 的 md5 已落盘：C3 的 `DdrMaster` 改动落地后，**这两个
指纹必须变**，且五道闸门**必须仍全绿**（否则就是回归）。

---

## 2) 失败判据先红（Step 2）

按项目纪律，先写一个**只打印 `TOTAL_BYTES=0`** 的桩，跑一遍确认"期望输出对不上"
（证明这个判据不是橡皮图章）。桩的真实 stdout（逐字）：

```
TOTAL_BYTES=0
```

对照期望契约——`UNITS_BASE / BASE_BYTES / BYPASS_OPS / BYPASS_BYTES / FPS_AT_275_9MBps /
SELFTEST_BYPASS_OFF` **一行都没有**，且 `TOTAL_BYTES=0` ≠ `19,521,600` ⇒ **判据红**。
随后用真实现替换该桩（下面的绿）。

---

## 3) 真实现与绿（Step 2b / Step 3）

脚本 `y1/tools/bypass_traffic.py`：**只读** `import ddr_traffic`（一个字节都不改），复用它的
`GraphView`（形状层）与 `STRATEGIES["fuse_both"]`（BASE）。口径（与 ddr_traffic **同源**）：

- **形状**：`dt.GraphView.shape_of`（`onnx.shape_inference` 推断，与 ddr_traffic 同一来源）；
- **字节**：int8，**元素数 == 字节数**（与 ddr_traffic 同一张量化口径）；
- **每个旁路算子**：`Σ(输入张量字节) + Σ(输出张量字节)`；一个消费者记一次真读
  （共享张量被两个旁路算子读 ⇒ 记两次，这正是"真流量"的来源）；
- **不计**形状无法推断的张量（`Resize` 的 `roi`/`scales`/`sizes` 三个常量输入）；
- **秩**：ddr_traffic 的 `act_bytes` 只认 4 维（特征图）。旁路里 **Sigmoid 的头张量是 3 维
  `[1,6400,1]`**；本脚本按"元素数 == 字节数"对**任意秩**求和，从而如实计入 Sigmoid 的读/写
  （C3.7 的 `SigmoidUnit` 确实读 int8、写 int8 ⇒ 这是真流量，不是装饰）。
- **硬断言（冻结期望值，真能发火）**：`BASE_BYTES` 必须逐字 == `12576000`，否则脚本停下
  （`FATAL`，不"修"这个数）；此外 `BYPASS_BYTES`/逐类字节/`TOTAL_BYTES` 必须逐字等于脚本内的冻结常量
  `BYPASS_BYTES_FROZEN`/`BYPASS_CLASS_FROZEN`/`TOTAL_BYTES_FROZEN`，且与一遍**独立遍历**的重算一致
  （否则 `SELFTEST_FROZEN_OK=0` ⇒ `RESULT: FAIL`、exit 1）。
- **字节口径的继承边界**：本脚本的 `tensor_bytes` 把**所有维**相乘，而 `ddr_traffic.act_bytes`
  丢掉 N（只乘 C/H/W）；两者**只有 N==1 时才相同**（本网 N==1，故口径同源）。

### 3.1 默认档 stdout（逐字，同时 tee 到 `y1/reports/c3_traffic_full.txt`）

> **契约边界（口径）**：`UNITS_BASE`/`BYPASS_OPS`/`BYPASS_BYTES`/`TOTAL_BYTES`/`SELFTEST_BYPASS_OFF`
> 这 **5 行**是稳定契约；其后的 `OVERLAP_PROBE` 与 `SELFTEST_*` 行是**自检/诊断行**（不属于那 5 行
> 契约的格式约束，但**全部参与 exit code**）。本块与 `c3_traffic_full.txt` **逐字一致**，**包含**
> `OVERLAP_PROBE` 行（该行由 §6 的 tee 命令一并落盘，不再是与 `.txt` 脱节的口头诊断）。

```
UNITS_BASE=33 BASE_BYTES=12576000
BYPASS_OPS maxpool=4 resize=2 add=2 sigmoid=6
BYPASS_BYTES=6945600
TOTAL_BYTES=19521600 FPS_AT_275_9MBps=14.1331
SELFTEST_BYPASS_OFF=12576000
OVERLAP_PROBE bypass_inputs=20 produced_by_fused_drop=0

== 逐算子明细（int8，元素数 == 字节数；含本档 drop 后的实账） ==
  op_type      n_ops          bytes
  maxpool          4        4736000
  resize           2         640000
  add              2        1536000
  sigmoid          6          33600
  TOTAL            -        6945600

SELFTEST_SUM_OK=1
== SELFTEST_FROZEN：计算值必须逐字等于文件内冻结常量（破口径即红） ==
  maxpool   computed=4736000    frozen=4736000    indep=4736000    OK
  resize    computed=640000     frozen=640000     indep=640000     OK
  add       computed=1536000    frozen=1536000    indep=1536000    OK
  sigmoid   computed=33600      frozen=33600      indep=33600      OK
  BYPASS    computed=6945600    frozen=6945600    OK
  TOTAL     computed=19521600   frozen=19521600   OK
SELFTEST_FROZEN_OK=1
== SELFTEST_DROP：逐类去掉后 TOTAL 的变化量必须 == 该类冻结贡献 ==
  drop maxpool   dTOTAL=4736000    contribution=4736000    frozen=4736000   OK
  drop resize    dTOTAL=640000     contribution=640000     frozen=640000    OK
  drop add       dTOTAL=1536000    contribution=1536000    frozen=1536000   OK
  drop sigmoid   dTOTAL=33600      contribution=33600      frozen=33600     OK
  drop ALL (旁路全关) TOTAL=12576000 BASE=12576000 OK
SELFTEST_DROP_OK=1

== 口径 ==
  BASE_BYTES=12576000 是下界（只计 Conv 的输入/输出激活读写；见 ddr_traffic 文件头）
  BYPASS_BYTES=6945600 是旁路算子自身激活 IO（MaxPool/Resize/Add/Sigmoid 的读+写）
  TOTAL_BYTES=19521600（base + bypass）；隐含 fps @275.9 MB/s ≈ 14.1331
  仍不含：12 个头张量的后处理（decode/NMS）读写、突发对齐/填充浪费、权重装载

SELFTEST_OVERLAP_OK=1
RESULT: PASS
```

`BYPASS_OPS maxpool=4 resize=2 add=2 sigmoid=6` 与 spec §8 裁决的四个算子计数**逐字一致**。
`OVERLAP_PROBE` 行（`produced_by_fused_drop=0`）**已包含**在上面的 `.txt` 里，且**已入判**
（`SELFTEST_OVERLAP_OK=1`；非 0 即 `RESULT: FAIL`、exit 1）。

### 3.2 `--no-bypass` 档 stdout（逐字）

```
UNITS_BASE=33 BASE_BYTES=12576000
BYPASS_OPS maxpool=4 resize=2 add=2 sigmoid=6
BYPASS_BYTES=0
TOTAL_BYTES=12576000 FPS_AT_275_9MBps=21.9386
SELFTEST_BYPASS_OFF=12576000
...
RESULT: PASS
```

`TOTAL_BYTES=12576000` **逐字等于** `BASE_BYTES`，且等于默认档里 `SELFTEST_BYPASS_OFF=12576000`。
注意（`...` 省略的是自检段）：该档下 `SELFTEST_FROZEN_OK=1`（逐类/总额/整帧仍逐字等于冻结常量——
冻结账是**图的固有事实**，与 CLI 的 drop 档无关）、`SELFTEST_OVERLAP_OK=1`、`RESULT: PASS`、exit 0。

### 3.3 判据"真能发火"的证据（变异测试，scratch，未入库）

按项目纪律（**controls must be able to fail**），在 `/tmp` 的 scratch 副本上**扰动字节计算器**，
对新旧两版脚本各跑一遍：`old` = 本次修复前的 HEAD 版本，`new` = 本次修复后的版本。驱动脚本
`mut_runner.py`（scratch，未入库）按模块路径加载脚本并 monkey-patch，然后调 `main`。

| 变异 | 做法 | `old`（修复前） | `new`（修复后） |
|:--|:--|:--|:--|
| `const999` | `tensor_bytes` 恒返回 999（评审的攻击） | `SELFTEST_SUM_OK=1` `SELFTEST_DROP_OK=1` **`RESULT: PASS` exit 0** | `SELFTEST_SUM_OK=0` `SELFTEST_FROZEN_OK=0` `SELFTEST_DROP_OK=0` **`RESULT: FAIL` exit 1** |
| `maxpool_x2` | 只把 MaxPool 的张量字节 ×2（单类漂移） | **`RESULT: PASS` exit 0**（自检恒等，抓不到） | `BYPASS_BYTES=12193600`、逐类 `MISMATCH`、**`RESULT: FAIL` exit 1** |
| `overlap_forced` | `overlap_probe` 恒返回 `produced_by_fused_drop=7` | **`RESULT: PASS` exit 0**（仅口头诊断） | `SELFTEST_OVERLAP_OK=0`、**`RESULT: FAIL` exit 1** |
| `base_fuse_pairs` | 换 `BASE_STRATEGY` 让 base 移动 | `FATAL …` exit 2 | `FATAL …` exit 2（原守卫，仍有效） |

`maxpool_x2` 在 `new` 上的关键 stdout（逐字，`RESULT: FAIL`，exit 1）：

```
BYPASS_BYTES=12193600
TOTAL_BYTES=24769600 FPS_AT_275_9MBps=11.1387
SELFTEST_SUM_OK=0
== SELFTEST_FROZEN：计算值必须逐字等于文件内冻结常量（破口径即红） ==
  maxpool   computed=9472000    frozen=4736000    indep=4736000    MISMATCH
  ...
  BYPASS    computed=12193600   frozen=6945600    MISMATCH
  TOTAL     computed=24769600   frozen=19521600   MISMATCH
SELFTEST_FROZEN_OK=0
  drop maxpool   dTOTAL=9472000    contribution=9472000    frozen=4736000   MISMATCH
SELFTEST_DROP_OK=0

SELFTEST_OVERLAP_OK=1
RESULT: FAIL
```

⇒ 三处原"恒等"判据（SUM / DROP / OVERLAP）**现在都能真的发火**；健康路径仍 exit 0（§3.1/§3.2）。

---

## 4) 逐算子明细与两道正/负对照

| 旁路算子 | n | 读 (B) | 写 (B) | 该类合计 (B) | 说明 |
|:--|--:|--:|--:|--:|:--|
| MaxPool | 4 | 3,788,800 | 947,200 | **4,736,000** | 下采样，最大一张 `[1,16,320,320]` |
| Resize  | 2 | 128,000 | 512,000 | **640,000** | 上采样 ×2（`scales/sizes` 常量不计） |
| Add     | 2 | 1,024,000 | 512,000 | **1,536,000** | 残差加，`223`/`214` 被 MaxPool 与 Add 各读一次 ⇒ 记两次真读 |
| Sigmoid | 6 | 16,800 | 16,800 | **33,600** | 头张量 3 维 `[1,6400,1]` 等，读+写各一次 |
| **合计** | 14 | 4,957,600 | 1,988,000 | **6,945,600** | = `BYPASS_BYTES` |

> 读/写分解仅为本报告的可读性推导；脚本按 `Σ(in+out)` 逐算子累加（不分解方向）。

**对照 1（正向 / 下界证明）**：`--no-bypass` 档 `TOTAL_BYTES` **逐字 == `BASE_BYTES` == 12,576,000**。
⇒ 补进去的确实是"旁路那部分"，没有污染 base。

**对照 2（逐类负对照 / 求和自证）**：`SELFTEST_SUM_OK=1`（主路径逐算子求和 == **第二遍独立遍历**
`independent_class_bytes` 的求和 == **冻结总额**）；`SELFTEST_FROZEN_OK=1`（逐类、`BYPASS_BYTES`、
`TOTAL_BYTES` 逐字等于脚本内冻结常量 `BYPASS_CLASS_FROZEN`/`BYPASS_BYTES_FROZEN`/`TOTAL_BYTES_FROZEN`）；
`SELFTEST_DROP_OK=1`（**任一类**去掉后 `TOTAL` 的变化量**恰好**等于该类**冻结贡献**，逐类 OK；全关后逐字
回到冻结 base）。例：`--drop-op sigmoid` ⇒ `BYPASS_BYTES=6912000`、`TOTAL_BYTES=19488000`
（= 19,521,600 − 33,600），差量恰好是 Sigmoid 的贡献。

> **为什么这不是橡皮图章**：此前的 `SELFTEST_SUM_OK`/`SELFTEST_DROP_OK` 是**恒等式**（同一个 `per`
> 字典自己比自己），改坏字节模型也恒为 1。现已改为**拿计算值比外部冻结常量**，并加一遍**独立遍历**
> 重算；§3.3 的变异测试给出"真能发火"的证据（`old` 模块 PASS/exit 0，`new` 模块 FAIL/exit 1）。

**重叠检查（自证不双重计数），由可运行的 `OVERLAP_PROBE` 背书、且已入判**：脚本在 5 行契约之后
打印**自检行** `OVERLAP_PROBE`。它**真的**扫 ONNX 节点表求出每个旁路输入张量的产出节点
（`tensor -> producer` 节点列表扫描），再与 `fuse_both` 留在片上、不落 DDR 的 Conv 输出（= 融合单元
边界）求重叠。该边界集合**不再调用私有 API**，而是由**公开注册的策略**推导
（`public_fused_drop_out`：某 Conv 的输出写从 `STRATEGIES["baseline"]` 的 `>0` 变成
`STRATEGIES["fuse_both"]` 的 `==0` ⇒ 被 drop 的输出）。实测该公开推导与旧的私有
`ddr_traffic._fusion_drop_sets` 的 `drop_out` **逐元素相等**（`public_n=33 private_n=33 equal=True`），
即等价但对私有函数改名免疫。本机实跑输出（逐字）：

```
OVERLAP_PROBE bypass_inputs=20 produced_by_fused_drop=0
```

`bypass_inputs=20`（MaxPool 4×1 + Resize 2×3 + Add 2×2 + Sigmoid 6×1；含 Resize 的常量输入），
其产出节点全是 `Relu`/`Reshape`（常量输入无产出节点）；`produced_by_fused_drop=0` 表示
**没有一条**旁路输入由融合单元边界内的 Conv 产出——且该值是**由计算得出、未硬编码**。
⇒ 基础模型只计 Conv 的读/写，旁路补的是"旁路算子自己发起的读/写"，两者**不同方向、不重叠**，
不双重计数。

该值**已接进判据**：`SELFTEST_OVERLAP_OK`（= `ov_hit == 0`）。强制令 `overlap_probe` 返回
`produced_by_fused_drop=7` 时，`new` 模块打印 `SELFTEST_OVERLAP_OK=0`、`RESULT: FAIL`、exit 1
（`old` 模块此时仍是 `RESULT: PASS`/exit 0 —— 这正是本次要修的漏洞）。如需"只看不判"的诊断档，
须显式加 `--overlap-advisory`（默认=入判）。

---

## 5) 口径声明（口径决定后面判据用哪个数）

- **`BASE_BYTES=12,576,000 B/帧（12.576 MB）= 下界**：只计 Conv 的 `input[0]`/`output[0]` 激活
  读写（`ddr_traffic.py` 文件头口径，逐字未改）。**它不含旁路算子自身的激活 IO**。
- **`BYPASS_BYTES=6,945,600 B/帧（6.9456 MB）**：旁路算子（`MaxPool`/`Resize`/`Add`/`Sigmoid`）
  自身在 DDR 上的激活读 + 写。
- **`TOTAL_BYTES=19,521,600 B/帧（19.5216 MB）** = base + bypass；对应 **14.13 fps**（@275.9 MB/s）。
- **仍是下界（口径声明，务必照抄）**：补进旁路后**仍只是下界**——**不含 12 个头张量的后处理
  （decode/NMS）读写**、不含突发对齐/填充浪费、不含权重装载（整网权重常驻片上、只装载一次）。
  真实流量只会**更高**，fps 只会**更低**。

### S4（及其后）的判据用哪个数

- **S4 的功能判据不直接用字节数**（它的判据是"跑 ≥3 个单元、含 ≥1 个旁路算子、**帧内中断计数
  == 0**、旁路输出与 Python 参考逐点一致"）。
- 但凡后面要引用"整帧 DDR 流量"这个口径（报告/预算/与 C5 实测对账）——**用
  `TOTAL_BYTES=19,521,600`，不要用 12,576,000**。12,576,000 是 **Conv-only 下界**，
  把它当"完整帧流量"会系统性乐观（这正是 R6 要修的折扣来源）。
- 参考：`TOTAL/275.9e6 ⇒ 14.13 fps`（vs 只用 base 的 21.94 fps）。

---

## 6) 产物与复现

| 文件 | 作用 |
|:--|:--|
| `y1/tools/bypass_traffic.py` | 【新】R6 脚本；只读 `import ddr_traffic`，不改它 |
| `y1/reports/c3_traffic_full.txt` | 【新】默认档 stdout（tee 落盘；含 `OVERLAP_PROBE` 行，见 §3.1） |
| `y1/reports/c3_traffic_full.md` | 【新】本报告 |
| `y1/reports/c3_baseline.txt` | 【新】C3 before 基线（五闸门 exit + 两网表 md5） |

复现（与本报告逐字一致）：

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/bypass_traffic.py ../third_party/yunet/yunet.onnx | tee ../y1/reports/c3_traffic_full.txt
# 下界证明（对照 1）：
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe \
  tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --no-bypass
# 逐类负对照（对照 2）：
... tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --drop-op sigmoid
# 可选：仅诊断档（`OVERLAP_PROBE` 只打印不判；默认=入判）
... tools/bypass_traffic.py ../third_party/yunet/yunet.onnx --overlap-advisory
```

固定契约与判据：前 5 行逐字不变（`--no-bypass` ⇒ `TOTAL_BYTES=12576000`、exit 0）；自检行
`SELFTEST_SUM_OK`/`SELFTEST_FROZEN_OK`/`SELFTEST_DROP_OK`/`SELFTEST_OVERLAP_OK` 任一为 0 ⇒
`RESULT: FAIL`、exit 1。变异测试证据见 §3.3。
