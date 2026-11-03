# NPU 提频候选：`tInPixW` 寄存一拍（54 → 60 MHz 目标）

日期：2026-10-24　状态：**60 MHz PnR 已收敛（tag npu60）；PLL 已改 11.25；tag npu60b 出最终比特流中**

## 1. 依据（W3/led1 的布线后报告）

`pds_led1.../report_timing/*.rtr`，npu 域头号路径（+0.652 ns @18.4 ns）：

- 起点：`unitExec_1` 的 **APM（DSP）级联**（`P[6]→PO[0]→P[5]→P[24]→P[0]`）——即
  `tInPixW = tInHi * tInWi`（**两个寄存器相乘**）与随后的 `tInPixW * p`；
- 途经：`wxSgBB → wxPNE_4`；终点：**`wxFAdrR` 的 CE**；
- 逻辑 9.361 ns / 布线 7.803 ns / 16 级。

⇒ 两级乘法串在一条 18.4 ns 路径上：`tInHi*tInWi` → `×p` → `+wxGAbs` → `比 wxBndB` → CE。

## 2. 改动（`y1/rtl/UnitExec.scala:1646`，单行、TILING 门控）

```scala
val tInPixW = if (TILING) RegNext((tInHi.resize(34) * tInWi.resize(34)).resize(34), U(0, 34 bits))
              else        (tInHi.resize(34) * tInWi.resize(34)).resize(34)
```

- `tInHi/tInWi` 是**寄存器**且**整个 unit 内不变**（只在 unit 几何锁存时更新）⇒ 寄存一拍后
  取值仍正确；把第一级乘法移出组合链（第二级 `×p` 仍在，但输入已是寄存器）。
- 窄路（TILING=false）走 `else` 分支，**表达式逐字不变** ⇒ 非 tiled 三网表 md5 复验
  **`9d8fa906/52fa5b20/c41e0449` 全部未变**。
- tiled 网表 `5ff0664a → a6e1cf89`。

## 3. 判据

1. **功能**：`run_b1_tilebuf_ab.sh` 必须 PASS —— conv15 与 c64_40 都 `MISMATCH=0`、
   `GATHER_BYTES` 精确、负对照只在计数上发火（证明"寄存一拍"没改地址语义）。
2. **时序**：FDC `npu_clk` 周期 18.4 → **16.667 ns（60 MHz）** 跑 PnR，npu 域 **WNS ≥ 0** 且
   其它域不劣化（soc/cpu/core 仍 All Met）。
3. **频率实现**：若 2 通过，改 `board/pll_50m.v` 的 **`STATIC_RATIO0 12.5 → 11.25`**
   （VCO 675 / 11.25 = **精确 60.000 MHz**；`STATIC_DUTY0 12 → 11`），重跑 PnR 出比特流。
4. **收益**：60/54 = **+11.1%** NPU 时钟 ⇒ 帧时间 1.47 s → **~1.32 s**（若帧完全被 NPU 限住）。
   与 G2-c（预测 1.10~1.20 s）叠加时，注意"两者都受益于同一段 gather 路径"——**先分别验证，
   再一起量**。

## 4. 风险

- `wxPl0`（ci 块平面偏移）也用 `tInPixW`：若几何在 gather 起动前**不足一拍**，会错地址。
  b1 的 conv15/c64_40 都覆盖"多 ci 趟 + 多 tile"，`MISMATCH=0` 即是硬证据。
- 60 MHz 若 PnR 不收敛，退到 58.8 MHz（675/11.5）或保持 54 MHz（本改动回退）。

## 5. 功能闸门结果（2026-10-24，RESULT: PASS）

`run_b1_tilebuf_ab.sh`（网表 `a6e1cf89`）：

- [0] 冻结：非 tiled 三网表 `9d8fa906/52fa5b20/c41e0449` **未变**；`NEUTRAL base/new` 逐字节相同；
- [2] conv15：`MISMATCH=0 NEIGHBOR_BAD=0`、`GATHER_BYTES=924800 == GEXP`；
- [3] c64_40 3×3：`MISMATCH=0 NEIGHBOR_BAD=0`、`GATHER_BYTES=123904 == GEXP`；
- [4] 负对照：数值仍对、计数 123904→991232（8×）、`GB_OK=0` ⇒ 红点唯一。

⇒ **寄存一拍不改变地址语义**（含多 ci 趟/多 tile 的几何变化）。

## 6. 60 MHz PnR 结果（2026-10-24，tag `npu60`，**All Constraints Met**）

FDC npu 周期 16.667 ns（过约束探针，此时板钟仍 54 MHz）：

| 域 | 请求 | 估计 | period (req/est) | slack |
|---|---|---|---|---|
| `npu_clk` | 59.9988 MHz | **60.6024 MHz** | 16.667 / 16.501 | **+0.166** |
| `soc_clk` | — | — | — | +0.760 |
| `cpu_clk` | — | — | — | +0.249 |

Design Summary: **All Constraints Met**。比特流 `sim/reglogs/pds_npu60_p10.000/prj_tasks/pnr_1/
generate_bitstream/yeshen_mini_board_top.sbit`，9,188,552 B，md5 **`175430b9ae99aa0e5592d09df4e645e3`**
（⚠️ 该比特流内部 PLL 仍是 54 MHz，**只作时序证据，不是交付件**）。

按 T-18c 的认证关系"板钟 ≤ est"（60.000 ≤ 60.6024，余量 1.0%）⇒ 可以取真 60 MHz。

## 7. 真 60 MHz 交付（tag `npu60b`）

改动已提交（`d5d3c0e`）：
- `board/pll_50m.v`：`STATIC_RATIO0` 12.5 → **11.25**、`STATIC_DUTY0` 12 → **11**
  ⇒ clkout0 = 675 / 11.25 = **60.000000 MHz（精确）**；PFD/VCO 未动。
- `constraints/yeshen_mini.fdc`：`npu_clk` 周期 **16.667 ns**（注释升格为"最终交付约束"）。

流程：`TAG=npu60b build_all.sh --only devmap` → `--only pnr`（`YESHENMINI_SYNTH_MODE=speed`）。
判据：① All Constraints Met；② npu est ≥ 60.0；③ 板上 `y1run --frames 3` 仍 12/12 CRC，
RUN ms 相对 54 MHz 的 1,771.2 ms 应降 ~10%（NPU 限住的那部分）。

### 7.1 结果（2026-10-24，tag `npu60b`，**交付比特流**）

- dev_map 16m55s 过闸门；PnR 从零建工程（TAG 目录不存在 ⇒ 入口 B），全程约 1h20m。
- 时序：`npu_clk` 请求 **59.9988 MHz / 16.667 ns**、估计 **60.6024 MHz / 16.501 ns**、slack **+0.166**；
  `soc_clk +0.760`、`cpu_clk +0.249`、`core_clk +0.649`；**Design Summary: All Constraints Met**；
  seed 0 `Setup(Slow) +0.022 / Hold(Slow) +0.055`（多 seed 表）。
- 比特流：`sim/reglogs/pds_npu60b_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  9,188,552 B，md5 **`6906faf11786975061a233102cbea866`**。
- 该工程 compile 读的是 10-23 16:27 的 `y1/gen/NpuTop.v`（不含 G2-c 预取）⇒ **干净的 60 MHz 基线**。
- 板上待验：`y1run --frames 3` 12/12 CRC + RUN ms；预期 1,771.2 ms × 54/60 ≈ **1,594 ms**（若整帧被 NPU 限住）。

## 8. 提频②（2026-10-24）：把 `p·tInPixW` 也寄存（去掉每列的 `×p` APM 链）

**动因**：`npu60c`（60 MHz + G2-c）头号路径是
`tTw 减法 → ≥ 比较 → APM 乘法 → 减法 → APM 乘法 → 32 位相等 → APM.CE`（17 级、布线占 48%），
其中"APM 乘法"就是 `tInPixW × p`（p=0..7 的常量乘）——它每列都在。

**改法**（`y1/rtl/UnitExec.scala`，只 TILING）：
```scala
val tPixP = (0 until 8).map(p => RegNext((tInPixW.resize(35) * U(p, 35 bits)).resize(35), U(0, 35 bits)))
// wxPBB(p) = (wxGAbs + tPixP(p)) & ~31 ；wxPIDX(p) = (wxGAbs + tPixP(p))[4:0]
```
`tInPixW` 本身已是 RegNext（提频①），再叠一拍仍在"载权 576 拍"窗口内 ⇒ 几何早稳。

**证据**
- 功能：b1 `conv15` 与 `c64_40` 都 **MISMATCH=0**、`GATHER_BYTES == GEXP`（924,800 / 123,904），`RESULT: PASS`。
- 冻结：非 tiled 三网表按行号归一后 **diff = 0 行**（新锚 `ca1d5e86 / 0979b0d8 / 0a08c9ca`）。
- 面积（dev_map，tag `npu60e`）：**APM 263 → 257**（少一条常量乘链）、LUT 85,745（54%）、FF 117,919、DRM 305。
- 时序：tag `npu60e` PnR 见下（跑完回填）。

⚠️ 踩坑记录：闸门里我加的 `WORK_DIR` 旋钮会让供料（Windows python）把 `/tmp/x` 解析到别的盘号，
`job.txt` 落错地方 ⇒ `run_job` 读不到 ⇒ **伪装成"装置未 PASS"**（两次假红、害我回退过一版）。
已删除该旋钮，闸门固定 `mktemp -d`。

### 8.1 三轮 PnR 的实测（60 MHz，含 G2-c）

| tag | 改动 | npu_clk seed0 | soc / cpu / core | 备注 |
|---|---|---|---|---|
| `npu60c` | G2-c | **−1.960**（53.69 MHz） | −0.440 / −0.351 / −0.287 | 放置质量整体变差（Worst place −2661） |
| `npu60e` | + 提频② `tPixP` | **−0.905**（56.91 MHz） | +0.608 / +0.471 / +0.453 | **一级 APM 值 ≈ +1.06 ns** |
| `npu60g` | + 提频③ `wxPl0R/wxRowBasR` | **−0.860**（≈57.2 MHz） | — | 只再值 +0.045 ns |

⇒ 提频②有效（把头号路径从 `wxPBB` 链上搬走）；**提频③没兑现**，因为头号路径已经不在 gather 上，
而是**换 tile 时组合算出的几何链**：`tTx·tWT → (tWo−tOx0) → 比较 → tTw → ×tTwG → 减 → 32 位相等 → APM.CE`
（写侧地址，17 级、布线占近半）。这条链在 54 MHz 下本来就是接近临界（led1 npu +0.652@18.4）。

**下一步（未做）**：把 `tOx0/tOy0/tTw/tTh` 在 **TILING 分支**寄存一份（只给 tiled 用，避免动窄路的冻结），
让"换 tile"那条组合链断在寄存器上；预计值 >1 ns，足以把 60 MHz + G2-c 拉回正。

**当前交付仍是 `npu60b`**（60 MHz，无 G2-c，All Met +0.166，sbit `6906faf1…`）；
G2-c 与三处寄存的 RTL 已入库且功能闸门全绿，只是 **60 MHz 时序差 0.86 ns**。

### 8.2 提频④（tile 几何寄存）：**时序达标但功能闸门红 ⇒ 已撤回**

做法：把 `tOx0/tOy0/tTw/tTh` 在 TILING 分支寄存一份给 tiled 路径用。
- 时序：`npu60h`（`RegNext` 版）确实 **All Constraints Met**（npu 62.1002 MHz / +0.564），
  比 ③ 再值 **+1.42 ns**，比特流 `ca924d03…`。
- **但是**：`run_nputop_sched_ab.sh` 在 `RegNext` 版上 **挂死**（rd=2112/wr=0）；
  改成"在 `wSt==1` 载权相锁存"后不再挂死，但 **err=1**（保留像素判据不匹配）。
- 归因（对照实验）：同一 sched 闸门在 **③ 版网表上 PASS**，④ 版红 ⇒ **④ 是原因**。
  根因：tilingR 流（`RDSTART/WRSTART`）**不经过 `wSt==1`**，锁存点覆盖不到；
  而 `RegNext` 版在换 tile 的头一拍用旧几何（`tThT*tTwT` 可能是 0 ⇒ `pixDoneEff` 提前命中）。
- 处置：**已撤回**（RTL 回到 `cdf8d05` 的三个杠杆；网表 md5 复现 `cab08e89/7a388d13/956c5e5c`，
  tiled `49b88a51`）。`npu60h` 的比特流**作废**（不再对应源码）。

**⇒ 交付仍是 `npu60b`（60 MHz，无 G2-c）**；G2-c 在 60 MHz 下仍是 **−0.86 ns**（`npu60g`）。
④ 若要重做：锁存点必须同时覆盖 **tilingW（`wSt==1`）与 tilingR（tile 推进后的 `RDSTART` 首拍）**，
并在两种流上都跑 `run_b1_*` + `run_nputop_sched_ab.sh` 才算绿。

### 8.3 提频④ 的第二版（"推进那一拍锁下一 tile 几何"）与最终取舍

目的：去掉 `RegNext` 的"换 tile 后一拍旧值"窗口，同时保留时序收益。
做法：定义 `tTxN/tTyN`（下一 tile 索引）→ `tOx0N/tOy0N/tTwN/tThN` → 在 tile 推进那一拍锁存；
`go` 用 `tTw0/tTh0`（由 `dw.imgW/imgH` 直接算，避开同拍写入的 `tWo/tHo`）。

- **功能**：`c64_40` 逐字节、`conv15` 逐字节、`run_nputop_sched_ab.sh` 四项 **全 PASS**（EXIT=0）⇒ 语义正确。
- **时序（tag `npu60i`）seed0**：npu **−0.674**（57.67 MHz），soc +0.501 / cpu +0.596 / core +0.945。
  对比 `RegNext` 版的 **+0.564**：**差 1.24 ns**。
- 归因：`RegNext` 版是**纯寄存器**（无组合逻辑），确实把头号链切断；
  "算下一 tile"版把**同长度**的组合链搬到了锁存器的数据端 ⇒ 路径没消失，只是换了终点。

**最终取舍（2026-10-24）**：
- `RegNext` 版（+0.564）**功能红**（sched 挂死/err），不能用；
- 正确版（−0.674）**功能绿但时序不够**；
- ⇒ 交付保持 **`npu60b`（60 MHz，无 G2-c）**；RTL 保留**三个杠杆**（①`tInPixW` ②`p·tInPixW`
  ③`pl0/行基址`），网表 md5 复现 `cab08e89/7a388d13/956c5e5c`、tiled `49b88a51`；G2-c 仍 parked（−0.86 ns）。
- ④ 若要再试：必须是"纯寄存器 + 消费侧不读旧值"的第三种写法（例如给消费侧加一拍 valid 门，
  换 tile 后第一拍强制等），而不是把组合链搬到锁存器数据端。

### 8.4 提频④ 的第三版（地址 `RegNext`、完成判据保持组合）—— 仍被 sched 闸门否

假设：`RDSTART` 是 1 拍复位态 ⇒ RDRUN 在 T+2 才用地址，所以**地址**可以安全滞后一拍，
把 **完成判据**（`pixDoneEff` / `tPixKW` / `tWrQ`）留在组合原值上，就能既提频又不误判。

- 冻结：非 tiled 归一 **diff=0**（新锚 `a34e2d09/c4d54956/fcedd9aa`，tiled `2910e67a`）。
- 结果：`run_nputop_sched_ab.sh` **作业 1 正向就 timeout poll STATUS**（同 `RegNext` 版）。
  ⇒ 该假设**不成立**：sched 流（很可能是 tilingW 的 tile 推进分支）在**新 tile 的第一拍**就用
  `tFx/tNCol` 类地址，滞后一拍即错。
- 处置：**回退**（RTL 回到三杠杆；网表复现 `cab08e89/7a388d13/956c5e5c`、tiled `49b88a51`）。

**④ 的四次结论（到此为止）**：

| 写法 | 功能 | 60 MHz slack |
|---|---|---|
| `RegNext`（全部消费者） | sched 挂死 | +0.564 |
| 载权相锁存 | sched err=1 | — |
| 推进拍算下一 tile 锁存 | 全绿 | **−0.674** |
| 地址 `RegNext` + 判据组合 | **sched 作业1 超时** | — |

⇒ 只有"算下一 tile"版功能成立，但它把等长组合链搬到锁存器数据端，**不提频**。
**交付固定为 `npu60b`（60 MHz，无 G2-c）**；G2-c 预取在 60 MHz 下差 0.86 ns，parked。
若要再攻，方向应是**降低 gather/写回的每列工作量**（如 4 px/cycle 写回），而不是继续切 tile 几何。

### 8.5 `npu60g` 的头号路径不是 `wxPBB`，而是 **tile 窗口 → 写指针使能**（2026-10-24 复核）

`sim/reglogs/pds_npu60g_p10.000/.../seed_0/report_timing/yeshen_mini_board_top.rtr` 第一条
`npu_clk` 路径（−0.860 ns，25 级，逻辑 8.986 ns / 布线 7.886 ns）：

```
APM P[1] (1.690) → fsub 35bit 链 (N623, 6.03→6.79)
→ lt_9 比 tTw[2] (7.21→8.30)
→ APM P[5] (2.923) → adder 树 N10187 (12.31→13.25)
→ tFxEnd → slt_12 (13.69→14.12) → N10207 → slt_3 → tGInWin (14.91→16.37, 布线 1.146)
→ tProdDiscard → N11482 → ddrMaster_4_rd_ready (17.33→17.46)
→ wrNow (17.70, 布线 0.937) → N87811 → N21520 → pwant[15] 的 CE
```

读法/含义：

- 它**不是** 8.1 里那条 `wxPBB` 地址链，而是 **tile 几何（tTw/tFxEnd/tGInWin）→ 写请求
  使能（wrNow/pwant）** 的控制链，两个 DSP 级 + 两处 32 位比较 + 6 级尾部控制逻辑。
- `ddrMaster_4_rd_ready` 出现在链中间：G2-c 把"预取口在读"这一项并进了 `rd_ready`
  （`... || (pfSt===RD)`），于是**写指针使能**也挂上了预取状态 ⇒ G2-c 不只是"多一块逻辑"，
  它确实延长了这条控制链。
- 这也解释了为什么 8.2/8.3/8.4 的四次"提频④"都失败：要压这条链就得给 tile 几何拍一拍，
  而 sched 流在**新 tile 第一拍**就要用这些几何量。几何一拍都不能晚。

⇒ 60 MHz 下同时要 G2-c，代价不是"再修一条地址链"，而是**重构 tile 几何的产出时序**（高风险、四次前科）。
可选路径只剩三条：

| 选项 | 收益 | 代价/风险 |
|---|---|---|
| **A 交付 `npu60b`**（60 MHz，无 G2-c） | 已证 +11.1% 时钟 | 无；G2-c 的取数隐藏拿不到 |
| **B `npu54pf`**：G2-c + 54 MHz | G2-c 全额（sim 目标 ≤0.85×），但丢掉 11% 时钟 | 一次 PnR（54 MHz 预算比 60 多 1.73 ns，`npu60g` 的 −0.86 直接变正）+ 一次板级 A/B |
| **C 重构 tile 几何时序** | 两者兼得 | 四次失败的同一条路；需先写 spec 再动 |

**判据**：`npu60k`（三杠杆 + G2-c @60 MHz，4 个 seed 全跑）若有一个 seed 收敛，A 直接升级为
"60 MHz + G2-c"；若全红，则以 **B 的板级 A/B 决定 G2-c 值不值**（B 只是现成 RTL 换约束，风险低），
C 不在本轮范围。

### 8.6 `npu60k` 全 4 seed 判定：60 MHz + G2-c **无解**（2026-10-24 20:13）

| seed | `UserFilter` | Setup(Slow) |
|---|---|---|
| 0 | 0 | −0.860 |
| 1 | 0 | −1.399 |
| 2 | 0 | **−0.015**（最好） |
| 3 | 0 | −1.377 |

`Pass Rate 100%`（布线全通）、`Convergence Rate 0%`（时序全红）。⇒ **60 MHz 下 G2-c 不可交付**，
交付保持 `npu60b`（`6906faf1`）。seed 2 只差 0.015 ns 说明"差一点点"，但那一点在本轮已试过的
四种写法里都换不来。

处置：转 **路线 B'（56.25 MHz + G2-c）** —— `board/pll_50m.v` `RATIO0 11.25→12.0`、`DUTY0 11→12`，
`fdc` `npu_clk` 16.667→17.778 ns（commit `ae57b59`），PnR 标签 `npu56pf`。
预期：以 seed2 的 −0.015 为基线，56.25 MHz 多出 1.111 ns ⇒ **约 +1.10 ns**；
按 200 拍延迟档的实测预取收益（−34%），整帧 ~1,200 ms（较 `npu60b` 的 ~1,326 ms 再快 ~9%；
若预取收益落在板级标定的 −19% 档，则 ~1,240 ms）。

## 9. 反直觉实测：**放宽约束，PDS 把布局做慢了 1.56 ns**（2026-10-24）

同一份 G2-c 网表（`gen/NpuTop.v` = `761f1b28`）、同一工具、同一组 seed，只改 `npu_clk` 的约束周期：

| 约束 | 档 | 报告 slack | **物理最差路径**（Estimated Period） |
|---|---|---|---|
| **16.667 ns** | `npu60k` seed2 | −0.015 | **16.682 ns**（59.945 MHz） |
| **17.778 ns** | `npu56pf` seed0 | −0.467 | **18.245 ns**（54.810 MHz） |

⇒ 约束放松 **1.111 ns**，物理结果反而**慢了 1.563 ns**。PDS 的放置/布线把**约束当作优化目标**：
目标一松，它就停止施压。**"降频后自然就过"这个直觉得不到工具支持。**

**推论（路线 B' 的正确跑法）**：

- 设计目标（fdc）**保持 16.667 ns**，比特流里的 PLL 另出 **56.25 MHz**（`RATIO0=12.0`）。
- **真实时序 = 报告值 + 1.111 ns**。以 `npu56pf2` 为例，若复现 16.682 ns ⇒ 实跑 17.778 ns 下余量 **+1.096 ns**。
- 报告里 `npu_clk` 显示 −0.015 的"违例"**不是硬件违例**；判交付余量按上式算。
- 该口径已写进 `constraints/yeshen_mini.fdc` 第 193 行上方注释（commit `1dc3fc1`）。

**顺带的可选空间**：若 16.682 ns 的物理结果稳定，58.70 MHz（`RATIO0=11.5`，17.037 ns）的真实余量约
**+0.355 ns**，比 56.25 MHz 再多 4.3% 时钟——但需要再跑一次 PnR 才能确认（PLL 参数变化会改网表）。

### 9.1 `npu56pf2` 结果（2026-10-25 01:36）

按 9 的口径跑完（约束 16.667 ns + PLL 56.25 MHz），4 seed：

| seed | 报告 slack @16.667 | 物理最差路径 |
|---|---|---|
| **0（Best，出比特流）** | **−0.596** | **17.263 ns**（57.93 MHz） |
| 1 | −2.294 | 18.961 ns |
| 2 | −1.474 | 18.141 ns |
| 3 | −0.937 | 17.604 ns |

- **真实余量 @56.25 MHz（17.778 ns）= 17.778 − 17.263 = +0.515 ns**。
- 其余域（@10 ns）：soc **+0.473**、cpu **+0.380**；camera +1.606、lcd +8.713、core/rst 均正。
- 比特流 9,188,552 B，md5 **`3fb1afcd7e25b05ce0b6b59bdcaea382`**；
  综合网表里 `u_pll_npu`（`pll_50m`）的 **`STATIC_RATIO0=12`** 已核对（=56.25 MHz）。
- 交付档次序：**`npu56pf2`（56.25 MHz + 预取，真实 +0.515）为首选**，`npu60b`（60 MHz，+0.166）为基线。

## 10. 提频探边界：60 → 66.67 MHz（2026-10-25，tag `npu66`）

**动机（用 60 MHz 逐单元表算过的）**：把每类耗时按 `ms = a·N·nci·nco + b·N·nci` 分离
（`unit_trace.md §6.1`），`a` 是每趟·像素（算，随钟缩）、`b` 是每 ci-block 的 fill 附加（取数等待，
**不随钟缩**，它挂在 DDR 侧 LAT 上）：

| 类 | 总 ms | `a` 部分（随钟） | `b` 部分（不随钟） |
|---|---:|---:|---:|
| conv1x1 | 585.0 | **387.4（66%）** | 207.4（35%） |
| depthwise | 354.8 | 11.5（3%） | **325.1（92%）** |
| maxpool | 162.9 | 3.8（2%） | **151.1（93%）** |

⇒ 全帧"随钟"的部分约 **0.4–0.5 s（~35%）**，60→66.67 MHz（×0.90）的**理论收益只有 −3.5%~−4%**，
不是早期"提频 10% = 提速 10%"的直觉。**这一档的价值主要是"探 fmax 边界"**：
`npu60b` 在 16.667 ns 下 est 60.6024 MHz，15.0 ns 要再快 9.1%。

**做法**：RTL 一字不改，`board/pll_50m.v` `RATIO0 11.25 → 10.125`（VCO 675 / 10.125 = 66.6667，
1/8 格点；`DUTY0 11 → 10`）、`constraints/yeshen_mini.fdc` `npu_clk` `16.667 → 15.000 ns`，
`TAG=npu66 YESHENMINI_PNR_FRESH=1 YESHENMINI_SYNTH_MODE=speed build_all.sh --only devmap,pnr`。

devmap（2026-10-25 05:06）：**0 error**；LUT 83,710.5 (53%)、FF 115,042 (36%)、DRM 305/415 (74%)、
APM 263、IO 146 —— 与 60 MHz 档同量级（约束收紧不改资源）。

PnR 判决见下一节（跑完回填）。

### 10.1 PnR 判决：**66.67 MHz 不收敛**（2026-10-25 05:52–06:33，tag `npu66`）

`multiseed_result.csv`（seed 0，约束 15.000 ns）：

| seed | State | Setup(Slow) | 物理最差路径 | 折算 fmax |
|---|---|---:|---:|---:|
| 0 | OK（布线通） | **−2.490 ns** | ≈ **17.49 ns** | **≈ 57.2 MHz** |
| 1–3 | 判决后停止 | — | — | — |

对照：同一 RTL 在 **16.667 ns** 约束下是 16.501 ns（**60.6 MHz**）、slack +0.166。
⇒ **把约束从 16.667 收到 15.0，PDS 反而把实现做慢了约 1.0 ns** —— 与 `§9`（17.778→18.245）
和 L2a-OC（17.5 ns，2 seed −2.444/−1.179）是**同一条反直觉规律**的第三次实例：
**约束=优化目标；把它设到达不到的值，布局器不会"更卖力"，而是给出更差解。**

结论与处置：
- **提频路线关闭**：60.6 MHz（est）就是这套流/RTL 的实际上限；再要高频只能改 RTL 关键路径
  （§8.5 已证 `npu60b` 的头号路径是 tile 几何→写指针链，四次"给几何拍一拍"全被 sched 闸门否）。
- 现场处置：`board/pll_50m.v` 与 `fdc` **已回退到 11.25 / 16.667 ns**（= 交付 `npu60b` 的源码态）；
  `sim/reglogs/pds_npu66_p10.000` 保留为证据；被停掉的 seed 1–3 只在 `run_route.log` 留下中途日志
  （判决由 seed 0 的 −2.49 ns 已足够：要达到 15.0 ns 需要再快 16%）。
- 顺带把"提频能拿多少"算清（§10 表）：随钟的部分只占全帧 ~35% ⇒ 即便 fmax 提到 66.67 MHz，
  整帧也只 ~−3.5%；**1 FPS 不可能靠提频达成**。
