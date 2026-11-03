# Y1-C4a · **R2 时序收敛轮** —— mzRam 参数读 / requant 三段 / chainLen→描述符 三处流水

**日期**：2026-10-11
**范围**：只改 RTL（`y1/rtl/Conv3x3Slice.scala`、`y1/rtl/UnitExec.scala`、`y1/rtl/LayerSched.scala`、
`y1/rtl/MultiPassUnit.scala`）+ 一处闸门锚点显式重锚（`y1/tools/run_unitexec_ab.sh`）。
**本步不做**：**不跑 PDS / pds_shell**（PnR 由控制器跑，见 §7）。功能语义要求**逐字节不变**。
**风格**：沿用 C3 R0→R4 那一轮的"每轮只改一处、每处带受控对照"的纪律（见 `c3_pnr_timing.md`）。

---

## 0) 一句话结论

C4a 的 `cpu_clk` 100 MHz 违例（**WNS −11.393 ns / 46.74 MHz**，176,688 个违例端点）里，
**最坏那条路径**（`chainLenR → BypassExec → LayerSched 描述符 → UnitExec/mzRam(LUTRAM 组合读)
→ sliceRest 的 4 级 APM 乘法 cascade → 加法器 → 钳位 mux → outMemT DI`）已被**三处流水**切断：
路径上的三段各自"退化成寄存器到寄存器"（见 §3 的深度/扇出对照），**数值逐字节不变**、
**像素节拍仍 11 拍（零吞吐代价）**。

> ⚠ **诚实边界**：本轮**只**处理了这条被归因的路径（以及它两侧的高扇出网）。
> `cpu_clk` 上还有 **176,688 个**违例端点、平均 slack ≈ −2.05 ns（`TNS/个数`）——那不是一条链，
> 而是**全局拥塞**（C4a 在板级把 LUT 从 39% 抬到 **68%**、APM 37% → **72%**，
> 见 `y1/pds/devmap_c4a.log` 的 `Device Utilization Summary`）。**能不能整体收敛，要控制器重跑 PnR 才作数。**

---

## 1) 实测失败与路径归因（权威读数）

日志：`sim/reglogs/pds_pnr_c4a_c4a_p10.000/prj_tasks/pnr_1/place_route/seed_0/report_timing/yeshen_mini_board_top.rtr`
（`cpu_clk` 请求 100 MHz → 估计 **46.7443 MHz**，WNS **−11.393**，TNS −362,539.665，
**176,688** 违例端点 / 478,881；`Design Summary : Some Constraints Violated.`）

最坏 `cpu_clk` 路径逐字：

```
Startpoint : u_soc/u_npu/layerSched_1/chainLenR[9]/opit_0_L6Q_perm/CLK
Endpoint   : u_soc/u_npu/layerSched_1/unitExec_1/outMemT_5_39_x1x4/ram64x1C/DI
Data arrival 24.396 ns ; Logic Levels 15 ; Logic 8.697 ns (40.9%) ; Route 12.573 ns (59.1%)
Slack (VIOLATED) −11.393
```

**分段记账**（把 `.rtr` 的逐行 td/net 归成四段，供"改哪一段最值"用；`ns` 均为 `.rtr` 原值）：

| 段 | 内容 | 逻辑 | 布线 | 合计 |
|---|---|---|---|---|
| **A** | `chainLenR[9]` → BypassExec 的 `≥2` 归约 → LayerSched 描述符 mux（`chainRun ? headW : descFetch_words`）→ **1.510 ns 长线**（跨到 `unitExec_1`）→ `mzRam` 读地址 | 0.883 | 3.597 | **4.480** |
| **B** | `mzRam`（LUTRAM `readAsync`）→ 读出 mux（**net fanout=47**，布线 **2.239**） | 0.351 | 3.212 | **3.563** |
| **C** | `sliceRest_1/N349_m1..m4`（**4 级 APM cascade**，逻辑 **6.340**，级间布线 2.764）+ `N569` 加法器 + `N574_mux64/65` 钳位 mux | 6.840 | 7.019 | **13.859** |
| **D** | `outTSel`（按 `chainLen` 选的 8 切片 mux）→ `outMemT` DI | 0.256 | 1.960 | **2.216** |

（另：launch clock delay 3.126 + tco 0.213 ≈ 3.34 在 A 之前。）

**改动→段**：A 与 B 由 §2 的 **C1**（参数读寄存）一次性切掉；C 由 **C2**（requant 三段）切掉；
D 由 C2 的**输出寄存器**（`io.y` 直接由 `yR` 驱动）切掉；A 的头段另由 **C3**（描述符寄存）切掉。

---

## 2) 改动清单（每处都带"为什么 / 为什么逐字节等价"）

### C1 · `UnitExec`：§4.4/§4.5 参数表读出**寄存化**（`mR` / `zpadR` / `zyR`）

`mzRam` 是 **LUTRAM**（`readAsync` ⇒ 组合读 + 一族读出 mux）。它的读出网正是段 B：
`ram64x1B/DO` → 读 mux（**fanout 47**）→ 直接落在 `sliceRest_*/N349_m1` 的 APM 输入锥上。

**一层的 `M/z_pad/z_y` 在整层内恒定**（由描述符 `LAYER_ID` 索引，`go` 之前就由信箱灌好）⇒
读出一拍寄存**不改变任何数值**，只是把乘法器的输入从"LUTRAM 读出 + 47 扇出的 mux"换成**寄存器**。
寄存器初值 = 表初值（单位元 `M = 2^24`、`z_pad = z_y = 0`）⇒ 不写信箱参数时与 C3 逐字节同形。

```scala
val mRRaw = Cat(mzRd(3), mzRd(2), mzRd(1), mzRd(0)); val zpadRRaw = mzRd(4); val zyRRaw = mzRd(5)
val mR    = RegNext(mRRaw)    init (B(16777216, 32 bits))   // 初值 = 单位乘子
val zpadR = RegNext(zpadRRaw) init (B(0, 8 bits))
val zyR   = RegNext(zyRRaw)   init (B(0, 8 bits))
```

### C2 · `Conv3x3Slice`：§4.4 requant **三级流水**（数值逐位等价）

旧写法（**一条组合链**）：
`prod = accTot * M`（64×32，4 APM）→ `(prod >> 24) >> 6` → `+ z_y` → 钳位。

新写法（三级寄存器，每级只留"半个乘法 + 一点后处理"）：

| 级 | 触发 | 内容 |
|---|---|---|
| 1 | 出数拍 | `pHiR ← (accTot[63:32])·M`（64 位积）；`aLoR ← accTot[31:0]`（按**无符号**读） |
| 2 | +1 拍 | `pLoR ← aLoR.resize(33).asSInt · M`（33 位**零扩** ⇒ 恒非负，65 位积） |
| 3 | +2 拍 | `shf = (pLoR >>> RQ) + (pHiR <<< (32−RQ))`，`RQ = REQUANT_Q + SHIFT = 30`；`valq = shf + z_y`；钳位 → `yR` |

**为什么逐位等价**（精确整数恒等式，不是近似）：令 `A = accTot`（64 位有符号）、`M = requant_m.asSInt`
（32 位有符号，**与旧写法同一读法**），把 `A` 按 32 位切成 `A = AH·2^32 + AL`
（`AL = A[31:0]` 按无符号读、`AH = A[63:32]` 按有符号读）：

```
prod = A·M = AH·M·2^32 + AL·M
AH·M·2^32 / 2^30 = AH·M·4 是**整数** ⇒ floor(prod/2^30) = floor(AL·M/2^30) + AH·M·4
```

旧写法 `((prod >> 24) >> 6)` = `floor(prod/2^24)` 再 `floor(/2^6)` = `floor(prod/2^30)`（嵌套 floor 恒等）
⇒ 两种写法给出**完全相同的整数**；`z_y` 的加法、±127/−128 的钳位、`resize(8)` **一字未改**。
位宽无溢出：`|AL·M| ≤ (2^32−1)·2^31 < 2^63`、`|AH·M| < 2^63`。
（另有一段独立的 Python 恒等式数值验证：20 万组随机 64 位 `A`，`(AL·M>>31)+(AH·M<<1) == A>>7` 全中——
这条是 §4 负对照 A 的推导依据。）

同时把**出料相位**与**写回相位**显式分成两条契约：
* `io.y` 直接由 `yR` 驱动、`io.y_valid = emitD3`（出数脉冲延迟 **3 拍**）；
* 新增输出口 **`ps_valid`** = **未延迟**的出数脉冲，`ps_out` 仍只在那一拍成立（`MultiPassUnit` 的
  部分和写回改用它，见 C2b）。**像素节拍仍是 11 拍**（收列 1 + 相位 10），全零吞吐代价。

### C2b · `MultiPassUnit` / `UnitExec`：把"随 `y_valid` 走"的像素号补上（**C2 的配套项**）

C2 让 `y_valid` 晚 3 拍，而 `MultiPassUnit.pixCount`（随出数拍走）**不延迟** ⇒ 两者错 3 个像素。
* `MultiPassUnit`：部分和写回/读地址推进改用 **`ps_valid`**（= 原相位），与改动前**逐拍相同**。
* `UnitExec` 宽层收料：新增 `wEmitCnt`（按 `mpu.y_valid` 计数的**本趟像素号**，每趟 `wSt==2` 复位），
  用它做 ① `wOutMem` 写地址、② 趟收工判定（`y_valid && wEmitCnt == H*W−1`，取代
  `mpu.pixCount == H*W`）。**这一条是实测抓出来的**：不修时 `run_unitexec_wide_ab.sh` 报
  `MISMATCH=139`（每趟最后 3 个像素丢在 `wFeedSt` 关闭之后）。

### C3 · `LayerSched`：喂 `UnitExec` 的**描述符寄存化**

旧写法把 `Mux(chainRun, headW/tailDstR, descFetch.words)` **组合地**接到 `unitExec.io.desc` 上，
而 `chainRun = chainLenR ≥ 2` 是 `chainLenR` 的 OR 归约 ⇒ 正是段 A 的头段。
本 FSM 在**进 `RUNSTART` 之前**（`FETCHW` 的 plain 分支 / `CHAINSCANW` 的 tail 分支）就已把
链长与链首/链尾字全部定案 ⇒ 在那两个分支里把 8 个字落寄存器 `unitDescR`，`RUNSTART` 的 `go` 拍
它们已稳定 ⇒ **一拍延迟都没有**（`go` 相位、run 相位、`UnitExec` 的验收判据全不变）。
副作用：`chainRun` 与只服务这条通路的 `tailDstR` 变成死逻辑（`chainRun` 的 8 个负载归零；
`tailDstR` 已删）。`w5` 的口径不变（`unitDescR(5)` = 链尾 `DST_ADDR`）。

### 延迟变更（明写，无静默放宽）

| 信号 | 变化 | 影响面 |
|---|---|---|
| `Conv3x3Slice.io.y` / `io.y_valid` | **+3 拍** | 全部消费者都是标志驱动的流式握手（`UnitExec` 的 `outMem/outMemT` 写与行推进、`MultiPassUnit`→TB）⇒ 顺序/个数/数值不变 |
| `Conv3x3Slice.io.ps_valid`（新口） | = 旧 `y_valid` 相位 | `MultiPassUnit` 的部分和写回（**相位逐拍不变**） |
| `UnitExec.chain_len` / 描述符 | 不变（描述符改为寄存，`go` 不加拍） | 无 |
| 像素节拍 | **11 拍不变** | 吞吐零代价 |
| `mR/zpadR/zyR` | 寄存 1 拍（层内恒定） | 无 |

---

## 3) 受控前后对照证据（结构级；**不含 PnR**）

方法（可复跑）：把 HEAD 版 RTL 用 `git show` 还原后**生成一份"改动前"网表**（`tmpgen_old/`，其
md5 与基线逐字相同，见 §5），再与改动后网表做**同一套量测**。

> **★★ 本轮实测量（2026-10-11，完成轮复核）**：下表全部数字由**探针复测**得到（不是转抄）：
> 探针 = 在**单个 module 定义体内**建图（节点 = 信号、边 = `assign` RHS 里的标识符、
> `reg`/端口/常量 = 0 级；再对 `always @(posedge)` 的 `<=` 目标取其 RHS 的标识符深度），
> 对 `gen/` 与 `tmpgen_old/` 两份网表各跑一遍。**结果与之前填写的数字逐条相符**（下面已在每处标注
> `[实测]`）。关键定点读数：
> * `Conv3x3Slice` 模块：`assign y_0` 组合深度 **10 → 1**；`reg_bits` **869 → 2224**；
>   行为级 `*` **10 → 18**；`>>>`/`<<<` **16/0 → 8/8**。
> * 三级流水各级**寄存器输入的组合深度**（`<=` RHS）：第 1 级 `pHiR/aLoR` = **4**、第 2 级 `pLoR` = **2**、
>   第 3 级 `yR` = **6**（见 (a) 表右列）。
> * `UnitExec.v` **整表**行为级 `*` **155 → 163**（+8）。

**(a) 组合深度【实测】**（模块内"赋值级数"探针：节点 = 信号、边 = `assign` RHS 里的标识符，
`reg`/端口 = 0 级；再对 `always @(posedge)` 的 `<=` 目标取其 RHS 深度）：

| 观测点（`Conv3x3Slice` 模块内） | 改动前 | 改动后 |
|---|---|---|
| `io.y`（requant 出料） | **10 级** | **1 级**（`assign y_0 = yR_0`） |
| 第 1 级寄存器 `pHiR/aLoR`（RHS 深度） | —（无） | 4 级（`pHiR_0 <= (signed _zz_pHiR_0) * (signed _zz_pHiR_0_1)`） |
| 第 2 级寄存器 `pLoR`（RHS 深度） | —（无） | 2 级（`pLoR_0 <= (signed _zz_pLoR_0) * (signed _zz_pLoR_0_2)`） |
| 第 3 级寄存器 `yR`（RHS 深度） | —（无） | 6 级（`+z_y` 与两级钳位 mux 都在此级） |
| `io.y_valid` | 4 级 | 1 级（`assign y_valid = emitD3`） |
| `io.ps_valid`（新口） | —（无） | 5 级（`assign ps_valid = emitPulse`，**不在被归因路径上**） |

⇒ 那条 **10 级 24.396 ns** 的组合链被切成 **≤6 级** 的三段 + 一段 1 级的出料。

**(b) 扇出（网表里"被读"次数）【实测，逐行 grep】**：

| 信号 | 改动前 | 改动后 | 说明 |
|---|---|---|---|
| `mzRam` 读总线（§4.4/§4.5 参数） | `assign mR = {mzRam_spinal_port1,{…port2,{…port3,…port4}}};`（= LUTRAM 读出网的 **组合直连**），`mR` 有 **10 个负载**（`conv_requant_m` + `sliceRest_0..6_requant_m` + `mpu_requant_m` + `rtl_m`） | `wire [31:0] mRRaw` = 同一条 LUTRAM 读出网，有 **1 个负载**（`mR <= mRRaw;`）；`mR` 变成 `reg [31:0] mR;`（`mR <= 32'h01000000;` init / `mR <= mRRaw;`），仍是 10 个负载 | 段 B 的 fanout-47 网消失；`mzRam→乘法` 之间多了一级寄存器 |
| `chainLenR` → `UnitExec` 描述符 | `assign unitExec_1_desc_7 = (chainRun ? headW_7 : descFetch_1_words_7);`（`unitExec_1_desc_0..7` 共 8 条组合 mux；`chainRun` 8 个负载） | `reg [31:0] unitDescR_5;`（`…_0..7`），`UnitExec` 端口映射 `.desc_5(unitDescR_5[31:0])`（**不再有 `unitExec_1_desc_*` 组合网**）；`chainRun` 只剩 `wire chainRun;` + `assign chainRun = (16'h0002 <= chainLenR);`⇒ **0 个负载** | 段 A 的组合通路被寄存器切断 |

**(c) 面积结构【实测】（同一个 `Conv3x3Slice` 模块定义内）**：

| 量 | 改动前 | 改动后 |
|---|---|---|
| `reg` 位数之和 | 869 | **2224**（+1355：`8×(64+32+65+8)+3`） |
| 行为级 `*` 个数 | 10（8 个 requant + 2） | 18（**8 → 16**：每个 co 的 64×32 拆成 32×32 + 33×32 两个半积） |
| requant 的 APM 总数 | 8 co × 4 = 32 | 8 co × (2+2) = 32（**不变**，只是被切成两段并各加一级寄存器） |
| `>>>` / `<<<` | 16 / 0 | 8 / 8 |

`UnitExec.v` 整表行为级 `*`：155 → 163（+8 = 单份 `Conv3x3Slice` 模块定义里的那 8 个）。
板级 FF 占用 36%（114,642 / 319,600）⇒ 本轮新增 ≈ 1.2 万 FF（≈ +3.8%），余量充足。

---

## 4) 闸门（全部逐字节绿）

**本轮实跑台账（2026-10-11 完成轮；网表 = §5 的 6 份重生成网表，md5 见 §5）。全部 `RESULT: PASS`、退出码 0：**

| 闸门 | 结果 | 关键正对照 |
|---|---|---|
| `run_unitexec_ab.sh` | `RESULT: PASS` (0) | `MISMATCH=0`；负对照 A 命中 `>>5` 预测 0 差 / != 黄金差 2009；GO2 连跑 dst2==黄金 |
| `run_unitexec_wide_ab.sh` | `RESULT: PASS` (0) | `Conv_0 POS_MISMATCH=0`、`Synth_16_16 POS_MISMATCH=0`（C2b 修 `wEmitCnt` 前实测 `MISMATCH=139`） |
| `run_chain_ab.sh` | `RESULT: PASS` (0) | `CHAIN_FIN_MISMATCH=0`；零 DDR 中间；实例计数 `Conv3x3Slice=9 FusionBuf=9 requant>>>5'd30=8 <<<2'd2=8` |
| `run_fuse_ab.sh` | `RESULT: PASS` (0) | 融合对逐字节 == 黄金 |
| `run_fuse_head_ab.sh` | `RESULT: PASS` (0) | `midWrEn` 锚点不变；逐字节 == 黄金 |
| `run_sched_ab.sh` | `RESULT: PASS` (0) | 整帧逐字节 == 黄金 |
| `run_nputop_ab.sh` | `RESULT: PASS` (0) | 端到端编程拷贝逐字节 == 黄金 |
| `run_nputop_sched_ab.sh` | `RESULT: PASS` (0) | 全帧调度逐字节 == 黄金 |
| `run_multipass_ab.sh` | `RESULT: PASS` (0) | 真表多趟逐字节 == 黄金 |
| `run_dw_ab.sh` | `RESULT: PASS` (0) | depthwise 5 形状逐字节 == 黄金 |
| `run_bypass_ab.sh` | `RESULT: PASS` (0) | 旁路算子四档逐字节 == 黄金 |
| `run_fusionbuf_ab.sh` | `RESULT: PASS` (0) | 两形状逐字节 == 黄金 |
| `run_hostregs_ab.sh` | `RESULT: PASS` (0) | 穷举回读 == 黄金 |
| `scripts/check_addr_map.py` | `PASS` (0) | 16 处地址台账一致 |
| `y1/tools/check_dangling.py`（9 份网表） | `PASS` (0) | 每份 0 悬空 |

（`run_numeric_ab.sh` / `run_linebuffer_ab.sh` 不在本轮清单内；它们的网表 `Conv3x3Slice*.v` 已重生成且
逐字节语义未变，`run_unitexec_ab.sh` 的数值正对照已覆盖同一份 requant 算术。）

**本轮改动的闸门锚点（两处，均显式重锚、带日期，不是悄悄放宽）**：

**(1) `run_unitexec_ab.sh` 的负对照 A**（requant 折叠成常量 `RQ = 30` 后网表里不再有 `>>> 3'd6`，
而"只动移位"必须**两处常量配套改**，同一恒等式 `q → q−1`）：

* 旧：`(>>> )3'd6 -> (>>> )3'd5`（命中 8），预测黄金 `shift = SHIFT−1`；
* 新：`(pLoR >>> )5'd30 -> 5'd29` **且** `({2'd0,pHiR} <<< )2'd2 -> 2'd3`（命中各 8），
  预测黄金**仍是** `shift = SHIFT−1`（= `>>5`）⇒ **这一发负对照的原意与严格性一字未变**。

> 试错记录（诚实）：只改第一项（`30→31`）实测 `MISMATCH=1029`；改 `<<< 2'd2 → <<< 2'd1` 也一样 ——
> 因为 `{2'd0,x}` 这条零扩与符号扩的等价性依赖"左移 ≥ 2 时 `2^64` 项被推到 `2^66 ≡ 0`"，
> 而单独改左移位数会让 `2^65` 留在符号位上。两处配套改（`30→29` + `2→3`）才得到**纯右移**语义。

**(2) `run_chain_ab.sh` 第 `7)` 节的"requant 文本指纹"（2026-10-11 显式重锚）**：该节原先数网表里
`>>> 3'd6` 的**命中数 = 8**（"单份 `Conv3x3Slice` 定义里 8 个 requant 站点"）。requant 折叠成常量后
这个串**已不存在** ⇒ 锚点改成**配套的两处常量**：`>>> 5'd30` **命中 8**、`<<< 2'd2` **命中 8**
（同一恒等式的两半，各 8 处）。**判据语义一字未改**（仍是"8 个 requant 站点"）——本轮**只**改了这一处
计数锚点；其余计数（`Conv3x3Slice=9`、`FusionBuf=9`）不变。

**`run_fuse_head_ab.sh` 的 `assign midWrEn = (conv_y_valid && isHead);` 锚点逐字不变**（仍在网表里，
突变照样只在那一处发火）——`y_valid` 只是相位后移，`midWrEn` 这行文字一字未动。

---

## 5) 确定性 + 指纹（2× 生成，md5 逐字相同）

`cd y1 && printf 'Test/runMain SliceGen …\nTest/runMain UnitExecGen …\nTest/runMain LayerSchedGen …\n
Test/runMain MultiPassGen …\nTest/runMain DwGen …\nTest/runMain NpuTopGen …\nexit\n' | bash sbt.sh`

| 网表 | 改动前（= HEAD 版 RTL 生成，与 C4a.8 基线 md5 一致） | 改动后（2× 生成一致） |
|---|---|---|
| `gen/UnitExec.v` | `9e6453f20bfd017a0b52bb974c4175bb` | **`074d9c1468320bf191853a4730b76ea1`** |
| `gen/UnitExec_w32.v` | `e74dd596a5bcec303661e59f7736d2a2` | **`b0db57d17c88781d6f1ace8a5c5d07fe`** |
| `gen/LayerSched.v` | `6f6b9ce9c3ae728d53325d3260b7f92c` | **`5284c2afd3f50bf3c3c1a7c81c9b1f27`** |
| `gen/NpuTop.v` | `e9a4f721c7c4d40cd86443f0a282e8de` | **`0a78bee16cff9d9c3bf6c34a817db42f`** |
| `gen/MultiPassUnit.v` | `2578dc51d95fcaac77e560cda34e2121` | **`76d2ca006baf1cea3fefe076d81ff2f3`** |
| `gen/DwUnit.v` | `2578dc51d95fcaac77e560cda34e2121` | **`76d2ca006baf1cea3fefe076d81ff2f3`** |
| `gen/Conv3x3Slice.v` | `79f66a80dc300b0b021e3160f322c5c3` | **`bbde53a5e88e3e64a93d4e7457e263b9`** |
| `gen/Conv3x3Slice_g4.v` | — | `6455aa3e9bcc66fddb5c435f231ff90b` |
| `gen/Conv3x3Slice_g8.v` | — | `d2a05b81bd0469b26c4e478613c42ea2` |

> ★ 生成器注意（本轮踩到）：SpinalHDL 把**源码行号**编进中间信号名（`_zz_when_UnitExec_l859`）⇒
> **改一行 `UnitExec.scala` 就会改 `LayerSched.v` / `NpuTop.v` 的 md5**（它们内联了 `UnitExec`）。
> 因此在**最后一次** RTL 改动之后必须把 6 份网表**全部重生成**，否则 `gen/` 会静默留着旧行号的副本。
>
> **★★ 完成轮复核（2026-10-11）**：按上面命令**连跑两次**生成，9 份网表两次 md5 **逐字相同**，
> 且与右列"改动后"值**逐条一致**（`sbt` 两次 `EXIT=0`）⇒ 确定性成立、网表确由当前 RTL 产生。

---

## 6) 预期改善（对**被归因那条路径**）+ 诚实的残留

按 §1 的分段记账 + §3 的"每一级 ≤ 6 级赋值"重算这条路径的预算
（板级可用预算 = `required − launch_clock ≈ 13.003 − 3.126 = 9.877 ns`）：

| 改动后路径 | 端点 | 估算（含 tco 0.213 + 布线） | 预算内？ |
|---|---|---|---|
| `mR`(寄存器) → 半乘法 → `pHiR`/`aLoR` | `pHiR_*` | ≈ 5.6 ns | ✅ 余 ≈ +4.3 |
| `pHiR`/`aLoR` → 半乘法 → `pLoR` | `pLoR_*` | ≈ 5.3 ns | ✅ 余 ≈ +4.6 |
| `pLoR`/`pHiR` → 移位 + 加法 + 钳位 → `yR` | `yR_*` | ≈ 3.8 ns | ✅ 余 ≈ +6.1 |
| `yR` → `outTSel`(chainLen mux) → `outMemT` DI | `outMemT DI` | ≈ 2.4 ns | ✅ 余 ≈ +7.5 |
| `unitDescR` 寄存器 → `mzRam` 地址（读） | `mRRaw` | ≈ 2 ns | ✅ |

⇒ **这条路径从 24.396 ns（slack −11.393）压到 ≤ 6 ns 级**，本路径单独看 **≥ 100 MHz 有余量**。

**残留（必须如实说）**：`cpu_clk` 上另有 176,688 个违例端点、平均 ≈ −2.0 ns。按 C3 的经验
（R3 的"普遍慢 2 ns"是 `MacArray` 的加法进位单元把 CLMS 逼到 89%），这一层极可能仍是
**C4a 新增的 68% LUT / 72% APM 拥塞**（`Conv3x3Slice` 的 requant 乘子 + 宽层多趟通路）。
本轮**不声称**能整体收敛；**下一轮**应看 PnR 的种子间方差与 `report_timing` 的前 40 条分布，
若仍是"一片 −2 ns"则应走**综合档/布局策略/资源复用**那一类（C3 R2 的 `speed` 档已在用）。

---

## 7) 控制器下一步（**我没跑 PnR**）

```bash
# 必须换新 tag，别复用陈旧工程（工程目录按 tag 分开）：
YESHENMINI_PNR_TAG=c4a_r2 /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file y1/pds/pnr_c4a.tcl \
    > y1/pds/pnr_c4a_r2.log 2>&1
```
* `pnr_c4a.tcl` 的源清单指向 `y1/gen/NpuTop.v`（= 本轮 §5 的那份），**开跑前请确认其 md5 =
  `0a78bee16cff9d9c3bf6c34a817db42f`**（完成轮 2× 生成一致；`git` 里 `gen/` 被忽略 ⇒ 不能只靠 `git` 核对，
  要现场 `md5sum y1/gen/NpuTop.v` 对一次）。
* 综合档默认 `ads`；要复现 C3 R4 的口径请显式 `YESHENMINI_SYNTH_MODE=speed`（C3 R2 的结论：
  同一份 RTL，`ads` 档比 `speed` 档差约 12 MHz）。
* 判据照旧：`Performance Summary` / `Setup Summary` 的 `cpu_clk` / `Design Summary` / 比特流存在。

---

# Y1-C4a · **R3a 时序收敛轮** —— 宽层多趟通路的 `wCob` 控制馈线寄存化

**日期**：2026-10-11
**范围**：只改 RTL 的**一处**（`y1/rtl/UnitExec.scala` 的宽层多趟段）。`MultiPassUnit.scala` **未改**
（下面的结构性证据说明这正是"在正确的地方改"）。
**本步不做**：**不跑 PDS / pds_shell**；**不碰**另外两条 `cpu_clk` 违例路径（高扇出复位释放网、DDR 桥——
它们是拥塞驱动的，另案处理）。功能语义要求**逐字节不变**。

## 8.0 一句话结论

R2 之后的新最坏 `cpu_clk` 路径（**WNS −3.787 ns**）
`.../unitExec_1/wCob[2] → .../unitExec_1/mpu/sl/N1035_m4/gopapm/Z[9]` 的唯一成因是
**`wCob` 组合地喂进 `MultiPassUnit` 里切片的 requant APM 乘法 cascade**（经 `bias` 那条锥）。
本步把这条馈线**打一拍寄存**（`wCobP` + `wBiasR[0..7]`，共 **260 个 FF**），
并把配套的 FSM/相位**一字不动**（因为几何在整趟内恒定 ⇒ 寄存值在第一次真正使用前 ≥577 拍就已就位）。
数值逐字节不变，**8 道闸门 + 2 个检查器全绿**。

## 8.1 归因（先复述实测路径，再逐级回查网表）

实测（`.../pds_pnr_c4a_c4a_r2.000/...` 的 `report_timing`）：

```
Startpoint : u_soc/u_npu/layerSched_1/unitExec_1/wCob[2]/opit_0_L6Q_perm/CLK
Endpoint   : u_soc/u_npu/layerSched_1/unitExec_1/mpu/sl/N1035_m4/gopapm/Z[9]
Slack      : -3.787 ns
```

在**改动前**的 `gen/UnitExec.v` 上把 `wCob` 的组合前向锥（`assign` + `always @(*)`；`<=` 视为屏障）
与切片内部的乘法锥对起来，这条链**唯一**：

| 级 | 位置 | 改动前网表逐字 |
|---|---|---|
| 1 | `UnitExec`：co-block 下标 | `assign _zz_wBiasIdx_1 = {2'd0, wCob};` → `assign _zz_wBiasIdx = (_zz_wBiasIdx_1 * 6'h08);` → `assign wBiasIdx = _zz_wBiasIdx[5:0];` |
| 2 | `UnitExec`：**64 项寄存器阵列的组合读 mux** | `assign _zz_bias_0_2 = (wBiasIdx + 6'h0);` + `always @(*) case(_zz_bias_0_2) 6'b000000: _zz_bias_0_1 = biasReg_0; … default: _zz_bias_0_1 = biasReg_63;` |
| 3 | `UnitExec`：`ci==0` 门 + 端口 | `assign mpu_bias_0 = ((wCi == 8'h0) ? _zz_bias_0 : 32'h0);`（`mpu_cob` 同样是 `assign mpu_cob = wCob[2:0];`） |
| 4 | `MultiPassUnit` → `Conv3x3Slice`：**累加器** | `assign _zz__zz_ps_out_0_2 = {{32{bias_0[31]}}, bias_0};` → `assign _zz_ps_out_0 = ($signed(_zz__zz_ps_out_0) + $signed(_zz__zz_ps_out_0_2));`（= `accTot = acc + ps_in + bias`） |
| 5 | `Conv3x3Slice`：**requant 的 4 级 APM 乘法** | `assign _zz_pHiR_0 = _zz_ps_out_0[63 : 32];` → `pHiR_0 <= ($signed(_zz_pHiR_0) * $signed(_zz_pHiR_0_1));`（`N1035_m4/gopapm/Z` 就是这个乘法的 APM） |

> 旁证：这条锥**只**到 `bias`。同一段里另外两路都以寄存器收尾/由寄存器给：`mR/zyR/zpadR`（R2 已寄存），
> `mpu_wdin`（`wRam` 组合读）落在 `WeightStore` 的**写口**（只在载权相 `wSt==1` 有效，切片此刻不吃权重）；
> 乘法器权重侧吃的是 `WeightStore` **读口**（地址 = 切片自己的 `ky/kx/ci` 计数器，与 `wCob` 无关）。

## 8.2 改动（一处：`y1/rtl/UnitExec.scala`；`MultiPassUnit.scala` 一字未动）

```scala
val wCobP  = RegNext(wCob) init (U(0, 4 bits))                        // 喂 mpu.io.cob（部分和分段基址）
val wBiasR = Vec(Reg(Bits(32 bits)) init (B(0, 32 bits)), C)          // 喂 mpu.io.bias（切片 bias 输入）
for (co <- 0 until C) {
  wBiasR(co) := Mux(wCi === U(0, 8 bits),
                    biasReg((wBiasIdx + U(co, bIdxW bits)).resize(bIdxW bits)), B(0, 32 bits))
}
…
mpu.io.cob      := wCobP.resize(log2Up(NCOB_MAX) max 1 bits)
mpu.io.bias(co) := wBiasR(co).asSInt                                  // 原来是组合 `Mux(wCi==0, biasReg[…], 0)`
```

**为什么逐字节等价**（与 R2 的 `mR/zpadR/zyR` 同一套 idiom，但**不需要**动 FSM 相位）：

* 一趟的几何（`wCob`/`wCi`/该趟的 `bias_adj` 词）在**整趟内恒定**：它们**只**在 `wSt==4`（换趟）那一拍变，
  而下一个真正用到它们的时刻是"换趟后 576 拍载权 + 1 拍 `start` + `(H+1)*W` 拍喂列"之后 ⇒
  **寄存后的值在第一次使用前 ≥577 拍就已稳定**（比 R2 里那条"进数据通路早于第一次 requant"还宽裕）。
* `biasReg` 由装载器在 `!ldBusy` **之前**就全部取完（宽层子 FSM 的入口门就是 `when(!ldBusy)`）⇒ 寄存的是**终值**。
* `ci==0` 的门**留在寄存器的 D 端**（语义不变：`bias` 只在该层第 1 趟非 0，C4a.4 冻结）。
* 于是 **`wSt` 序列、`mpu.start` 相位、喂列节拍、收料判据（`wEmitCnt`）、WR 相位**全部**一字未改**
  ——本步**没有**任何"延迟变更表"，这与 R2（+3 拍）不同，是本步更强的地方。

**如实记录的边界**：`mpu.we/waddr/wdin`（权重瓦片）**没动**——理由见 §8.1 的旁证（它不在 APM 锥上）；
`wOutAddr`/`wPassIdx` 里的 `wCob` 也**没动**（它们到的是存储器地址口，不是乘法器）。

## 8.3 受控前后对照（结构级；**不含 PnR**）

方法（可复跑）：`gen/` 在改动前的那 9 份网表**逐字**等于 README 基线（先按 §5 的 6 个 `*Gen` 重跑一次生成，
9 份 md5 与 §5 右列**逐条相同** ⇒ 基线可信），改动后再生成。探针（`assign` + `always @(*)` 组合图、
`<=` 作屏障，**前向**锥）对两份网表逐条量测：

| 观测点（`gen/UnitExec.v` 的 `UnitExec` 模块内） | 改动前 | 改动后 |
|---|---|---|
| `wCob` 的**组合前向锥**大小 | **50 个网** | **33 个网** |
| `mpu_bias_0 … mpu_bias_7` 在锥内？ | **YES**（`assign mpu_bias_0 = ((wCi==8'h0) ? _zz_bias_0 : 32'h0);`） | **no**（`assign mpu_bias_0 = wBiasR_0;`） |
| `mpu_cob` 在锥内？ | **YES**（`assign mpu_cob = wCob[2:0];`） | **no**（`assign mpu_cob = wCobP[2:0];`） |
| 新增的管线级（网表逐行） | — | `always @(posedge)`：`wCobP <= wCob;` / `wBiasR_0 <= ((wCi == 8'h0) ? _zz_wBiasR_0 : 32'h0);`（初值 `4'b0000` / `32'h0`） |
| 新增 FF（`UnitExec.v`） | — | **260**（`wCobP` 4 + `wBiasR[0..7]` 8×32）；行数 68390 → **68401** |

**端点侧**（`gen/MultiPassUnit.v`，与改动前**逐字节相同**的 md5 `76d2ca…` ⇒ 端点所在模块本身没动）：
`bias_0 → _zz__zz_ps_out_0_2 → _zz_ps_out_0 → _zz_pHiR_0 → pHiR_0 <= _zz_pHiR_0 * requant_m`（同一锥，探针实测）。
⇒ 结论：**`wCob → 切片 APM` 这条链现在跨一个寄存器**，不再组合。

## 8.4 闸门（全部逐字节绿；网表 = §8.5 的 2× 生成）

| 闸门 | 结果 | 关键正对照 |
|---|---|---|
| `run_unitexec_wide_ab.sh` | `RESULT: PASS` (0) | `Conv_0 POS_MISMATCH=0`、`Synth_16_16 POS_MISMATCH=0`（两条负对照都发火） |
| `run_unitexec_ab.sh` | `RESULT: PASS` (0) | `MISMATCH=0`；`MUTGEN_HITS=8+8+8`（锚点未变）；GO2 连跑 `RUN1_DST_MISMATCH=0` |
| `run_multipass_ab.sh` | `RESULT: PASS` (0) | 8 个形状 `POS_MISMATCH=0`（含 32→64 的 32 趟） |
| `run_dw_ab.sh` | `RESULT: PASS` (0) | C=4/10/16/32/64 逐字节 `WHOLE_MISMATCH=0`；`DwUnit.v` 与 `MultiPassUnit.v` md5 **仍相同**（结构性断言成立） |
| `run_chain_ab.sh` | `RESULT: PASS` (0) | `CHAIN_FIN_MISMATCH=0`；实例计数 `Conv3x3Slice x9 / FusionBuf x9`、`>>>5'd30 x8 / <<<2'd2 x8`（锚点未变） |
| `run_fuse_ab.sh` | `RESULT: PASS` (0) | `FUSED_DST_MISMATCH=0`、`STEP1_TMP_MISMATCH=0`（`midWrEn` 锚点未变） |
| `run_sched_ab.sh` | `RESULT: PASS` (0) | `A1_MISMATCH=0 / A2_MISMATCH=0`（整帧 + 旁路段） |
| `run_nputop_sched_ab.sh` | `RESULT: PASS` (0) | 全部 `REGION … MISMATCH=0`（desc/src0..2/dst0..2 逐区） |
| `scripts/check_addr_map.py` | `PASS` (0) | `16 sites reconciled` |
| `y1/tools/check_dangling.py`（9 份网表） | `PASS` (0) | 每份 `total dangling instances: 0` |

**闸门锚点一字未改**（本步没有改任何 TB / 判据）：`run_unitexec_ab.sh` 的 requant 突变
（`>>> 5'd30` / `<<< 2'd2` 各 8 处、`MUTGEN_HITS=8+8+8`）、`run_chain_ab.sh` 的实例计数、
`run_fuse_head_ab.sh` 的逐字行 `assign midWrEn = (conv_y_valid && isHead);` 全部原样通过
⇒ **不存在"静默放宽"**。

## 8.5 确定性 + 指纹（2× 生成，md5 逐字相同）

`cd y1 && printf 'Test/runMain SliceGen <abs gen>\nTest/runMain UnitExecGen <abs gen>\n
Test/runMain LayerSchedGen <abs gen>\nTest/runMain MultiPassGen <abs gen>\nTest/runMain DwGen <abs gen>\n
Test/runMain NpuTopGen <abs gen>\nexit\n' | bash sbt.sh`（连跑两次，两次均 `EXIT=0`，31 份 `gen/*.v` 两次 md5 **全同**）

| 网表 | 改动前 | 改动后（2× 一致） |
|---|---|---|
| `gen/UnitExec.v` | `074d9c1468320bf191853a4730b76ea1` | **`5166db4d12367d1533b19dd8e262ce85`** |
| `gen/UnitExec_w32.v` | `b0db57d17c88781d6f1ace8a5c5d07fe` | **`28c28b17a12f7d2f69028399a65819c3`** |
| `gen/LayerSched.v` | `5284c2afd3f50bf3c3c1a7c81c9b1f27` | **`eecaa3292282eba14f4d7698491f28b5`** |
| `gen/NpuTop.v` | `0a78bee16cff9d9c3bf6c34a817db42f` | **`50a7a4d1710f45b1ec6b9e7e91f96544`** |
| `gen/MultiPassUnit.v` / `gen/DwUnit.v` | `76d2ca006baf1cea3fefe076d81ff2f3` | `76d2ca006baf1cea3fefe076d81ff2f3`（**未变**） |
| `gen/Conv3x3Slice(.g4/.g8).v` | `bbde53a5…` / `6455aa3e…` / `d2a05b81…` | **未变**（`Conv3x3Slice.scala` 一字未动） |

> 只有**内联了 `UnitExec`** 的 4 份网表变了（`UnitExec/UnitExec_w32/LayerSched/NpuTop`）——
> 与 R2 §5 的"源码行号进中间信号名"那条注意一致；`MultiPassUnit.v` 不变正是本步"改在正确的地方"的结构性旁证。
> `y1/rtl/UnitExec.scala` 改动后 md5 = `f9df9f189f0ed970ca9f9b8ac1e293a2`。

## 8.6 预期改善 + **诚实的残留**

按 §8.3：被归因那条路径上，`wCob` 到切片 APM 之间**原有一段"64 项 32 位寄存器阵列组合读 mux（≈3 级 LUT）
+ `ci==0` mux + 64 位三输入加法 + 4 级 APM 乘法 cascade"**，现在被 `wBiasR` 一个寄存器一刀切断：

| 改动后路径 | 端点 | 说明 |
|---|---|---|
| `wCob` → `wBiasIdx` → `biasReg` 64:1 mux → `wBiasR_*`（**新寄存器**） | `wBiasR_*` | 仍是寄存器到寄存器，但**不含** 64 位加法与乘法 cascade（与"pass 起点"同拍，且 ≥577 拍才被用） |
| `wBiasR_*` → `ci==0` mux → `accTot` → 半乘法 → `pHiR_*` | `pHiR_*` | 与 R2 §6 的 `mR → 半乘法` 同形（≈5.6 ns 级） |
| `wCobP` → `MultiPassUnit.base` → `psb.wr_addr` | 部分和写口 | 只到存储器地址口，**不在** APM 锥上 |

> ⚠ **诚实边界（与 R2 §0/§6 同一口径）**：本步**没有**跑 PnR（禁止项），所以**不声称** `cpu_clk` 收敛。
> R2 之后 `cpu_clk` 上仍有**两条**已归因的违例（高扇出复位释放网、DDR 桥路径）与**一片**拥塞驱动的
> 平均负 slack（C4a 集成后 LUT 68% / APM 72%）；那两条**本步不碰**（另案）。
> 本步能声称的只有：**这条被归因的路径**在结构上已"退化成寄存器到寄存器"，且**全部闸门逐字节绿**。
> 下一步（控制器）：换新 tag 重跑 `pnr_c4a.tcl`，核对 `gen/NpuTop.v` md5 =
> `50a7a4d1710f45b1ec6b9e7e91f96544`，再看新的前 40 条 `report_timing` 分布。

---

# Y1-C4a · **R3b 拥塞收敛轮** —— 宽层大存储落**块 RAM**（`wRam` 36 KB / `wOutMem` 16 KB）

**日期**：2026-10-11
**基线**：R3a 的 commit `1ef0dc1`（本步**在其之上**，`wCobP`/`wBiasR` 一字未动）。
**范围**：只改 `y1/rtl/UnitExec.scala`（宽层多趟段的两条 `Mem` 读口）。`MultiPassUnit.scala` /
`PartialSumBuf.scala` / `Conv3x3Slice.scala` / `FusionBuf.scala` **一字未改**。
**本步不做**：**不跑 PDS / pds_shell**（禁止项）⇒ 下面所有"落 DRM"的结论都是**结构级**（网表形态），
不是工具实测；`dev_map` 的复核由控制器跑。功能语义要求**逐字节不变**。

## 9.0 一句话结论

C4a 集成 `dev_map` 的**实测**头号异常是 **`Distributed RAM`（`LUTs as dram`）`1,767 → 10,855`**
（**+9,088 ≈ 72 KB 的 LUTRAM**），同时 LUT 46%→68%、APM 63%→72%，而 `cpu_clk` 最坏路径 **59% 是布线**
（= **拥塞驱动**）。归因到结构上：C4a.5b 新增的三条 **`readAsync`**（**组合读**）`Mem` ——
`wRam` 36 KB / `wOutMem` 16 KB / `mzRam` 512 B —— **Pango 忽略 `ram_style` 属性、映射随结构决定**，
组合读的 `Mem` 只能落 **LUTRAM**。本步把其中**两条大的**（合计 **53,248 B = 52 KB**）改成
**`readSync` 同步读**（= `PartialSumBuf`/`FusionBuf` 那套"单写口 + 单同步读口"的 idiom）
⇒ 它们的读出网从"LUTRAM 组合 mux"变成"寄存器"，既消灭了 LUTRAM 又给时序让出缓冲。
数值**逐字节不变**，**13 道闸门 + 2 个检查器全绿**。

## 9.1 归因（先复述实测，再回查网表）

**(a) 实测（`y1/pds/devmap_c4a.log`，`c4a_multipass.md` §5.1/§5.4）**：

| 项 | C3 基线 | **C4a 实测** | Δ |
|:--|--:|--:|--:|
| `Distributed RAM`（`LUTs as dram`） | 1,767（5%） | **10,855（28%）** | **+9,088** |
| LUT | 72,381（46%） | **107,401（68%）** | +35,019 |
| APM | 465（63%） | **532（72%）** | +67 |
| DRM（块 RAM） | 32.5 | **93.5** | +61（= `PartialSumBuf` 那部分，**同步读**那条通了） |

⇒ "**同步读** → DRM（+61）、**组合读** → LUTRAM（+9,088）"这一对照在**同一份 dev_map 里同时出现**，
是本节结构改动的实测依据（不是推断）。

**(b) 结构回查（改动前的 `gen/UnitExec.v`，逐行 grep；本步开头实测）**：

| 位置（改动前网表逐字） | 形态 | 体量 |
|---|---|---|
| `1389: (* ram_style = "distributed" *) reg [7:0] wRam [0:36863];` + `43112: assign wRam_spinal_port1 = wRam[_zz_wdin];` | **组合读** ⇒ LUTRAM | **36,864 B** |
| `1392: (* ram_style = "distributed" *) reg [63:0] wOutMem [0:2047];` + `45699: assign wOutMem_spinal_port1 = wOutMem[wideRdAddr];` | **组合读** ⇒ LUTRAM | **16,384 B** |
| `1387: (* ram_style = "distributed" *) reg [7:0] mzRam [0:511];` + `2124..2129` 六条 `assign mzRam_spinal_portN = mzRam[...]` | **组合读** ⇒ LUTRAM | 512 B |
| `1390/1391: (* ram_style = "distributed" *) reg [63:0] outMem/outMemT [0:255];` + `43395/43660` 两条 `assign` | **组合读** ⇒ LUTRAM | 2 × 2,048 B（**C3 就有**，不在 +9,088 里） |
| `1388: reg [31:0] biasMem [0:4095];` + `6236: biasMem_spinal_port1 <= biasMem[_zz_ldWord];` | **同步读** ⇒ 已是块 RAM 形态 | 16,384 B |

★★ 这一条纠正了 `c4a_multipass.md` §5.4 的一处**推断**：`biasMem` **不是** LUTRAM 来源
（它一开始就是 `readSync`，网表逐行可见）；而 §5.4 说的"bias/param 表 ~16 KB"实际对应的是
**`wOutMem` 16 KB**（宽层**输出**存储）+ `mzRam` 512 B。**+9,088 ≈ (36,864+16,384+512)×8/64 ≈ 6,720 个
`64x1` DRAM LUT**（量级吻合；余下差额来自别的 C4a 增量，本步不追）。

## 9.2 改动（两处；每处都带"为什么逐字节等价"）

### C1 · `wRam`（宽层**趟瓦片权重 RAM**，36,864 B）：写口整体打一拍

```scala
val wWtLoad = wSt === U(1, 3 bits)                     // 载权相（原来 mpu.io.we 的逐字同义式）
val wWtWeR  = RegNext(wWtLoad) init False              // 写使能打一拍
val wWtIdxR = RegNext(wK) init (U(0, log2Up(C*C*9) bits))  // 条目下标打一拍
val wWtDatR = wRam.readSync((wPassIdx*U(C*C*9,16) + wK.resize(16)).resize(log2Up(WGT_RAM_BYTES) bits))
mpu.io.we    := wWtWeR
mpu.io.waddr := wWtIdxR.resize(log2Up(C * C * 9) bits)
mpu.io.wdin  := wWtDatR.asSInt                         // 原来是 wRam.readAsync(...).asSInt
```

* **为什么逐字节等价**：`readSync` ⇒ 读出**晚一拍**。地址相（`wK`）照旧逐拍 `0..575` 推进
  （**FSM 的 `wSt` 序列一字未改**），写口用**上一拍**的 `(we, 下标)` 配**本拍**读出的字节
  ⇒ 每一道写的仍然是 `wRam[趟基 + wK] → WeightStore[wK]`，**一一对应**，只是整条写序列整体平移 1 拍。
* **边界**：第 1 道落在载权第 2 拍；**最后一道（`wK==575`）落在 `start` 那一拍**（`wSt==2`）。
  该拍 `WeightStore` 只被写、**不被读**：切片的权重读出地址是自己的 `ky/kx/ci` 计数器（此刻为 0），
  而 `prime`（由 `start` 触发）只清 per-image 相位、**不动 `WeightStore`** ⇒ **数值无影响**。
  再往后 `wWtWeR` 落 0（`wSt≠1`）⇒ 无重写、无漏写、无越界（`wWtIdxR` 合法域 `0..575`）。

### C2 · `wOutMem`（宽层**输出存储**，16,384 B）：WR 字节拼拍拆成"给地址相 / 落字节相"

```scala
val wideRdWord = wOutMem.readSync(wideRdAddr)       // 原来是 readAsync
val wRdLaneD = RegNext(wRdLane) init (U(0,3 bits))  // 与"上一拍地址"配套的寄存器
val wRdClD   = RegNext(wRdCl)   init (U(0,3 bits))
val wFetchR  = Reg(Bool()) init False               // 上一拍确实取了一道字节
val wBeatEndD = wFetchR && (wRdLaneD === U(C-1, 3 bits))
val wFetch = wideR && (state===WRRUN) && (!wBeatRdy) && (!wBeatEndD) && (ri < wrTotalEff)
when(wFetch) { /* 指针推进 + 换组/环回：与原 wFill 逐字同形 */ }
when(wFetchR) { /* 用寄存指针落字节进 wPack；wBeatEndD ⇒ wBeatRdy := True */ }
wFetchR := wFetch
```

* **为什么逐字节等价**：地址相**逐字保留**原来的指针表达式与推进/换组/环回次序；落字节相只是把
  "同拍取 + 同拍落"换成"本拍给地址、下一拍用**寄存的**指针落"⇒ 每一道字节**取一次、落一次、
  落进同一道槽**，`wPack` 的 8 B 与发出去的拍序（`[co-block][cl][pixel/8]` = `[co][y][x]`）**逐字节同序**。
* **★ 必须新增 `!wBeatEndD` 这一门**（本步唯一的新约束）：一拍的最后一道落进 `wPack` 的那拍，
  若同时给出下一个地址，下一拍就会把**下一条拍**的第 0 道写进**尚未发走**的 `wPack` ⇒ 总线背压下
  会污染在飞的拍。加门后：满拍那一拍只落不发，`wBeatRdy` 举起后才继续（每拍多 1 个气泡，**吞吐代价明写**）。
* `WRSTART` 里把 `wRdLaneD/wRdClD/wFetchR` 一并回零 ⇒ 多次 `go` 连跑与首次同形。

### 延迟变更（明写，无静默放宽）

| 信号 | 变化 | 影响面 |
|---|---|---|
| `wRam` 写口 `(we, waddr, wdin)` | **+1 拍**（整体平移） | 576 道写得一一对应；末道与 `start` 同拍（切片此处不读权重） |
| 宽层 WR 相位的字节节拍 | **每拍 +1 气泡** | 只影响吞吐（`wideWrWords` 条数与字节序不变；判据是数值不是性能） |
| 窄通路（S2/头/融合对/链/DW/旁路） | **零变化** | `wideR=0` ⇒ `wFetch` 恒 0 ⇒ 新通路全冻结（`wrValidEff`/`wrDataEff` 的 `Mux(wideR, …)` 逐字未动） |
| 新增 FF | **18**：`wRdLaneD(3)`+`wRdClD(3)`+`wFetchR(1)`+`wWtWeR(1)`+`wWtIdxR(10)` | 相对被消灭的组合 mux（36 KB / 16 KB 的 LUTRAM 读出网）可忽略 |

## 9.3 **未搬**的候选 + 逐条理由（明写，不越界）

| 候选 | 体量 | 处置 | 理由 |
|:--|--:|:--|:--|
| `biasMem`（§4.5 bias_adj 表） | 16,384 B | **不需要动** | 它**本来就是** `readSync`（网表 `biasMem_spinal_port1 <= biasMem[_zz_ldWord];`）⇒ 已是块 RAM 形态。§5.4 把它列为嫌疑是**推断**，本步实测纠正 |
| `mzRam`（§4.4/§4.5 参数表 `M/z_pad/z_y`） | **512 B**（= 1/9 个 `DRM36K`） | **保留 LUTRAM** | ① **太小**：512 B（4 Kbit）**不足 1 个块 RAM**，搬过去反而浪费 8/9 个 DRM 且对 72 KB 的量级无贡献；② **读口结构不合**：它是**6 个字节道同时读**（`M` 4 B + `z_pad` + `z_y`）⇒ 要落块 RAM 需 6 倍复制或改成 64 位单口 + 字节掩码写（Pango 掩码写路径本项目**未验证**）；③ **不在时序路径上**：R2（§2 C1）已把它的读出**寄存化**（`mR/zpadR/zyR`），那条 fanout-47 的 mux 已被寄存器切断 |
| `outMem` / `outMemT`（**窄通路**输出存储） | 2 × 2,048 B | **保留 LUTRAM** | ① **不在宽层多趟通路上**（本步范围是宽层），且 **C3 就存在**（**不在** +9,088 增量里）；② 各 2 KB **不足 1 个块 RAM**；③ 它们的读是 `WR` 相位"一拍一字"流，改同步读要再插一级预取并动 `wr_valid` 相位 ⇒ 会碰**已冻结**的 S2/融合对逐字锚点，**收益（4 KB）远小于风险**。文件头（S2 一节）已记为 C3.13/S5 开放项 |
| `biasReg` = `Vec(Reg(Bits(32)),64)` | 2,048 **FF** | **不是 LUTRAM** | 它是**寄存器阵列**（不是 `Mem`）⇒ 落 FF，不参与 `LUTs as dram`；R3a 已把它的组合读用 `wBiasR` 打了一拍 |
| `SigmoidUnit.lut`（256×8，旁路段） | 256 B | **保留** | 极小（约 1/140 个 DRM），且不在宽层通路 |

## 9.4 受控前后对照（**结构级实测**；方法可复跑）

方法：`git show 1ef0dc1:y1/rtl/UnitExec.scala` 还原成"改动前"RTL，`UnitExecGen` 生成到 `tmpgen_old/`
（生成后**逐字核回**其 md5 = `5166db4d12367d1533b19dd8e262ce85` = §8.5 的 R3a 值 ⇒ 基线可信），
再与改动后的 `gen/UnitExec.v` 用同一套 grep 量测（`tmpgen_old/` 用完已删）。

| 观测点（`UnitExec` 模块内，逐行 grep） | 改动前 | 改动后 |
|---|---|---|
| `(* ram_style = "distributed" *)` 的存储阵列数 | **5**（`mzRam`/`wRam`/`outMem`/`outMemT`/`wOutMem`） | **3**（`mzRam`/`outMem`/`outMemT`） |
| `assign <mem>_spinal_portN = <mem>[...]`（**组合读**）条数 | **10** | **8** |
| `<mem>_spinal_portN <= <mem>[...]`（**同步读**）条数 | **1**（只有 `biasMem`） | **3**（`biasMem` + **`wRam`** + **`wOutMem`**） |
| `wRam` 读出（逐字） | `assign wRam_spinal_port1 = wRam[_zz_wdin];` | `always @(posedge clk) if(_zz_wWtDatR_1) wRam_spinal_port1 <= wRam[_zz_wWtDatR];` |
| `wOutMem` 读出（逐字） | `assign wOutMem_spinal_port1 = wOutMem[wideRdAddr];` | `always @(posedge clk) if(_zz_wideRdWord) wOutMem_spinal_port1 <= wOutMem[wideRdAddr];` |
| 新增管线寄存器（网表声明） | — | `reg [2:0] wRdLaneD;` / `reg [2:0] wRdClD;` / `reg wFetchR;` / `reg wWtWeR;` / `reg [9:0] wWtIdxR;`（**18 FF**） |
| `wPack` 落字节所在块 | `when(wFill)`（同拍） | `when(wFetchR)`（下一拍；逐字形如 `if(_zz_wideRdWord) … wPack[7:0] <= wideRdByte;`） |
| 网表行数 | 68,401 | 68,443 |
| md5（`gen/UnitExec.v`） | `5166db4d12367d1533b19dd8e262ce85` | **`e610b121d00312ee1de7f2ca40f719f4`** |

⇒ **被搬的两条（52 KB）现在是"`Mem` + 地址译码 + 同步读"的块 RAM 形态**：`ram_style` 属性消失、
`spinal_port1` 从 `wire` 变成 `reg`、组合读的 `assign` 变成 posedge 下的 `<=`（**与 `PartialSumBuf`
在 C4a.5a 给出的结构证据同一形式**）。按 §9.1 的对照（同步读→DRM），**预期** `LUTs as dram` 从 10,855
回落 ≈ **6,720**（= 53,248×8/64）——**但这条数字必须由 dev_map 实测确认**（本步不跑 PDS ⇒ 记为预期）。

## 9.5 闸门（全部逐字节绿；网表 = §9.6 的 2× 生成）

| 闸门 | 结果 | 关键正/负对照（逐字取自日志） |
|---|---|---|
| `run_unitexec_wide_ab.sh` | `RESULT: PASS` (0) | `Conv_0` `POS_MISMATCH=0`；`Synth_16_16`（**n_ci=2 ⇒ 跨 ci 趟累加**）`POS_MISMATCH=0`；两条负对照（PAD0/NOBIAS）都精确命中且 != 黄金 |
| `run_unitexec_ab.sh` | `RESULT: PASS` (0) | `MISMATCH=0`；`MUTGEN_HITS=8+8+8`（requant 锚点未变）；`RUN1/RUN2_DST_MISMATCH=0`（连跑逐字节同） |
| `run_multipass_ab.sh` | `RESULT: PASS` (0) | **10 个形状**（含 `64→64` 的 **64 趟**）`POS_MISMATCH=0`（`wRam` 读口在 **8×8=64 个趟基址**上全对） |
| `run_dw_ab.sh` | `RESULT: PASS` (0) | C=4/10/16/32/64 逐字节 `WHOLE_MISMATCH=0`；`DwUnit.v` 与 `MultiPassUnit.v` md5 **仍相同** |
| `run_chain_ab.sh` | `RESULT: PASS` (0) | `CHAIN_FIN_MISMATCH=0`、`MID_RING_MISMATCH=0`；实例计数 `Conv3x3Slice x9 / FusionBuf x9`（锚点未变） |
| `run_fuse_ab.sh` | `RESULT: PASS` (0) | `FUSED_DST_MISMATCH=0`、`STEP1_TMP_MISMATCH=0` |
| `run_fuse_head_ab.sh` | `RESULT: PASS` (0) | `MID_MISMATCH=0`；`MUTGEN_HITS=1`（`midWrEn` 逐字锚点未变） |
| `run_sched_ab.sh` | `RESULT: PASS` (0) | A1/A2 逐字节；6 道 C3.11b 负作业照样响亮 err + 零搬运 |
| `run_nputop_ab.sh` | `RESULT: PASS` (0) | 端到端整片逐字节 == Python 黄金；两条负对照发火 |
| `run_nputop_sched_ab.sh` | `RESULT: PASS` (0) | `W1/W2` 全 `MISMATCH=0`（含 8 片链 `chainLen=8`）；`W2ALIAS` 负对照全发火 |
| `run_bypass_ab.sh` | `RESULT: PASS` (0) | 四算子逐点 `SEG_MISMATCH=0`；IRQ 纪律 OK；结构判据 OK |
| `run_fusionbuf_ab.sh` | `RESULT: PASS` (0) | 两种形状 `PARTIAL/WIN` 全对；负对照 A1/A2/B 发火 |
| `run_hostregs_ab.sh` | `RESULT: PASS` (0) | 穷举回读 `MISMATCH=0`；负对照恰好 1 |
| `scripts/check_addr_map.py` | `PASS` (0) | `16 sites reconciled` |
| `y1/tools/check_dangling.py`（9 份网表） | `PASS` (0) | 每份 `total dangling instances: 0` |

**闸门锚点一字未改**（本步没有改任何 TB / 判据）：`run_unitexec_ab.sh` 的 `>>> 5'd30`/`<<< 2'd2` 突变
（`MUTGEN_HITS=8+8+8`）、`run_chain_ab.sh` 的实例计数、`run_fuse_head_ab.sh` 的逐字行
`assign midWrEn = (conv_y_valid && isHead);` 全部原样通过 ⇒ **不存在"静默放宽"**。

## 9.6 确定性 + 指纹（2× 生成，md5 逐字相同）

生成命令（与 §5/§8.5 逐字相同，连跑两次，两次均 `EXIT=0`，9 份网表两次 md5 **全同**）：
`cd y1 && printf` 出 6 条 `Test/runMain <X>Gen D:/code/PDS/VexiiYeshenLinux/y1/gen`（`SliceGen` /
`UnitExecGen` / `LayerSchedGen` / `MultiPassGen` / `DwGen` / `NpuTopGen`）`| bash sbt.sh`。

| 网表 | 改动前（= R3a §8.5 的"改动后"值） | 改动后（2× 一致） |
|---|---|---|
| `gen/UnitExec.v` | `5166db4d12367d1533b19dd8e262ce85` | **`e610b121d00312ee1de7f2ca40f719f4`** |
| `gen/UnitExec_w32.v` | `28c28b17a12f7d2f69028399a65819c3` | **`2d2518e1cb9ce250fa4c40ebac8ce609`** |
| `gen/LayerSched.v` | `eecaa3292282eba14f4d7698491f28b5` | **`0be30f30889eba336cb12b7fc1ef99cb`** |
| `gen/NpuTop.v` | `50a7a4d1710f45b1ec6b9e7e91f96544` | **`d95a71d9de1102a391ad7e9ec4fe6a9d`** |
| `gen/MultiPassUnit.v` / `gen/DwUnit.v` | `76d2ca006baf1cea3fefe076d81ff2f3` | `76d2ca006baf1cea3fefe076d81ff2f3`（**未变**） |
| `gen/Conv3x3Slice(.g4/.g8).v` | `bbde53a5…` / `6455aa3e…` / `d2a05b81…` | **未变**（本步没碰 `Conv3x3Slice.scala`） |

> 只有**内联了 `UnitExec`** 的 4 份网表变了（含 §5 那条"源码行号进中间信号名"的注意）；
> `MultiPassUnit.v` / `Conv3x3Slice*.v` 不变正是"改在 `UnitExec` 内部"的结构性旁证。
> `y1/rtl/UnitExec.scala` 改动后 md5 = **`95b77cdb8aa6f5f02ffb15c35d4dcea6`**。

## 9.7 预期改善 + **诚实的残留** + 控制器下一步

**预期（结构可推，非实测）**：被搬的 `wRam`/`wOutMem` 合计 **52 KB**，占 C4a `+9,088` LUTRAM 的
≈ **74%**（按"64 bit/LUT"折算 ≈ 6,720 个 DRAM LUT）。若 dev_map 复核确认它们落 DRM，则：
* `LUTs as dram` 应显著回落（预期 ≈ 10,855 − 6,720 ≈ **4,100** 量级，**以实测为准**）；
* 对应 LUT 的 `LUTs as logic` 随之回落（DRAM 占用的 LUT 释放）⇒ **缓解拥塞**（本轮靶子）；
* DRM 小幅增长（52 KB / 4.5 KB ≈ **+12 DRM** 量级，相对 `415 − 93.5 = 321.5` 的余量可控）；
* 时序侧：这两条读出网的"LUTRAM 组合 mux + 大扇出"被**寄存器**取代 ⇒ 对 `cpu_clk` 只增一级
  "存储 → 寄存器"的浅锥（D 端 = 存储读出 mux）。

> ⚠ **诚实边界（与 R2 §6 / R3a §8.6 同一口径）**：本步**没有**跑 PDS（禁止项）⇒ **不声称**
> `cpu_clk` 收敛、**不声称** `LUTs as dram` 已回落（那是 dev_map 的职责）。
> R2/R3a 之后 `cpu_clk` 上仍有**两条**已归因违例（高扇出复位释放网、DDR 桥路径）与一片**拥塞驱动**
> 的平均负 slack —— 本步只针对**拥塞/LUTRAM** 这一条，另两条**不碰**。
> 本步能声称的只有：**52 KB 的两条大存储**在结构上已是块 RAM 形态（§9.4 逐行证据），
> 且**全部闸门逐字节绿**、**网表 2× 确定**。

**下一步（控制器）**：
1. 换**新 tag** 重跑 `y1/pds/devmap_c4a.tcl`（例如 `c4a_r3b`）⇒ 核对 `DRM` 上升、
   **`LUTs as dram` 是否从 10,855 明显回落**（判据从 §5.4 的 `Adm-4088 = 0` 升级为
   "`Adm-4088 = 0` **且** `LUTs as dram` 增量 ≈ 0"）；
2. 再换新 tag 跑 `y1/pds/pnr_c4a.tcl`，核对 `gen/NpuTop.v` md5 = `d95a71d9de1102a391ad7e9ec4fe6a9d`，
   看 `cpu_clk` 平均负 slack / 拥塞是否缓解（新的前 40 条 `report_timing` 分布）；
3. 仍开放的另两条违例（复位释放高扇出、DDR 桥）**另案**。

---

## 10) ★ PnR 收口（R3b 实测，2026-10-11）—— **面积成功、时序持平；打住转"NPU 独立时钟"**

**实测**（`sim/reglogs/pds_pnr_c4a_c4a_r3b_p10.000/…/seed_0/report_timing/yeshen_mini_board_top.rtr`，
`pnr_c4a.tcl` + `YESHENMINI_PNR_TAG=c4a_r3b`，`YESHENMINI_SYNTH_MODE=speed`；seed 0，控制器中途停掉其余种子）：

| 项 | R1（未流水化） | R2（mzRam/requant/描述符） | **R3b（+宽层 wCob + 大缓冲进块 RAM）** |
|---|---|---|---|
| `cpu_clk` 估计频率 | 46.74 MHz | 72.53 MHz | **71.40 MHz** |
| `cpu_clk` WNS | -11.393 | -3.787 | **-4.006** |
| `core_clk` / `rgmii_clk` | 92.4 / -0.383 | 102.3 / +0.452 | **117.2 / +0.500（MET）** |
| LUT | 68% | — | **63.4%** |
| **`LUTs as dram`** | 10,855 (27.5%) | — | **1,767 (4.47%)**（= C3 基线） |
| DRM | 93.5 | — | **120.0**（≤415 ✓） |

**结论（诚实）**：
- **面积目标达成**：`LUTs as dram` **10,855 → 1,767**（C4a.5b 的 +9,088 LUTRAM 全部消掉；判据升级项满足），
  LUT 68% → 63.4%，DRM 裕量充足。**R2/R3a/R3b 三轮都是净收益**（R2 = +26 MHz，R3a/R3b = 面积）。
- **时序打了个平手**：`cpu_clk` WNS 从 −3.787 到 **−4.006**（≈持平）。**最坏路径又换人**：
  `unitExec_1/mpu/psb/mem_51/gopdrm_36k/CLKB`（**PartialSumBuf 块 RAM 读**）→ `unitExec_1/mpu/sl/N1167_m4/gopapm/Z`
  —— 即"部分和块 RAM 读出 → 切片 4 级 APM 级联"。
  **每一轮只把"喂进那坨深 APM 级联的某一个组合输入"寄存掉，下一条就顶上来**（whack-a-mole）。
- **⇒ 打住**：继续在 NPU 内部逐条流水化是**边际递减**；NPU 自己的可达 fmax ≈ 71 MHz，
  而**给 NPU 一个独立 `npu_clk`（目标 50 MHz）能一次把 `cpu_clk` 解耦**。
- **移交**：本条转入 `docs/superpowers/specs/2026-10-11-y1-npu-clock-domain-design.md`
  （小 spec + 计划已立项，用户 2026-10-11 裁决）。**C4a 的时序口径到此记档**：
  "NPU 在 `cpu_clk` 下可达 **71.4 MHz**；100 MHz 的闭合交由 NPU 独立时钟方案解决"。
