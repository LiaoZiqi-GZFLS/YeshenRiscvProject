# 小 spec：**让真帧跑得完** —— 旁路算子 tiling + 宽路 gather 去 `HW%32==0` 前提

- 日期：2026-10-14
- 上游：`T-S2`/`T-S2R`/`T-S2b`（**conv 侧** tile 循环已逐字节证死）、`T-S2b-i`（宽路首像素 + `s=2` 挂起已修）；
  `y1/reports/c4b_frame.md` §9（真几何量化：conv 输入行宽 `{640,320,160,80,40,20}`、`max H·W=102400`、`bypass max outPix=25600`）
- 触发：用户裁决（2026-10-14）「**先补这两处，再 S3**」

---

## 1. 一句话

真表 67 个单元里，**conv 侧**已被 T-S2/S2b 的 tile 循环覆盖；**剩两类**穿过 RTL 的几何对账会**响亮 err**（宁可红、不做静默错值）：

1. **旁路算子**（`maxpool`/`resize`）—— `BypassExec` 仍按 `W_MAX=34` 分配，真帧的 `MaxPool_5`（160×160）`outPix=25600`、输入行宽 320 ⇒ 卡在 `desc[3]`；
2. **20×20 的宽 conv**（11 层）—— `tilingWideC` 要求 `inH·inW % 32 == 0`，`400 % 32 = 16` ⇒ 被挡；非 tiled 宽路又要 `IMG_W == WIDTH(34)` ⇒ 也被挡。

本 spec **只**补这两处（不动描述符格式、不动数值口径），目标是让 **S3（PnR → 比特流 → 板 → 12 路 + G7）一次跑完整帧**。

---

## 2. 现状（实测，带出处）

| 量 | 值 | 出处 |
|:--|:--|:--|
| 板级 `dev_map` @ tiled 几何（`WIDTH=34/H_TILE=32/TILING=true`） | **PASS**，`Adm-4088 = 0` | `y1/pds/devmap_c4a.log`（2026-10-14，本 spec 立项前刚跑） |
| LUT | 122,770 / 159,800 = **76.83%** | 同上 |
| **DRM** | **375.5 / 415 = 90.48%**（**只剩 ~39 块**） | 同上 |
| APM | 556 / 740 = 75.14% | 同上 |
| `LUTs as dram` | 6,784 / 39,500 = 17.17% | 同上 |

`BypassExec` 的 `go` 那一刻对账（`rtl/BypassExec.scala:269-304`）：
- `rowWOk`：`MaxPool`/`Resize` 要 `1 ≤ rowW ≤ WIDTH`（`=34`）且 `MaxPool` 行宽**偶数**；`Add`/`Sigmoid`（零几何状态）只要 `rowW ≥ 1`；
- `geomOk`：`outPix ≤ MAXPIX`（`= WIDTH·IMG_H_MAX = 34·32 = 1088`）；
- `planarOk`（布局模式）：`inCols % 32 == 0 ∧ outPix % 32 == 0`。

真表（`y1/gen/wgt_index.json`，67 单元）：

| 事实 | 值 |
|:--|:--|
| 旁路 `outPix` 最大 | **25600**（`MaxPool_5` 160×160，C=16） |
| 旁路输入行宽最大 | **320**（`= 2·IMG_W`，同层） |
| `Resize` 输入行宽 | `40`（`Resize_49` 80×80 输出 ⇒ 输入 40）> 34 ⇒ err |
| `Add`/`Sigmoid` | 逐点（无列状态）⇒ 只受 `outPix ≤ MAXPIX` 与 `planarOk` 约束 |
| 20×20 的**宽** conv | `Conv_33/34/36/37/39/40/58/64/70/76/77`（C=64 dense/dw、C=10 dw）|

---

## 3. 方案

### 3.1 T-S3a：**旁路算子 tile 循环**（`BypassExec`）

- **tile = 输出 32×32** ⇒ `outPix(每 tile) ≤ 1024 ≤ MAXPIX(1088)` ⇒ **不新增宽存储**、**复用既有 `outMem`**（DRM 只剩 39 块，这一条是承重约束）。
- **每个 tile 的输入窗口 = 无 halo**（旁路算子是"窗口→1 输出"，与 conv 的 3×3 链不同）：

  | 算子 | 输入窗口（相对输出 tile 原点 `(oy0,ox0)`） | 备注 |
  |:--|:--|:--|
  | `maxpool` 2×2 s2 | 行 `[2·oy0, 2·oy1)`、列 `[2·ox0, 2·ox1)` | 输出 tile 32 ⇒ 输入 64 |
  | `resize` ×2 | 行 `[⌊oy0/2⌋, ⌊oy1/2⌋)`、列 `[⌊ox0/2⌋, ⌊ox1/2⌋)` | 输出 32 ⇒ 输入 16；`oy0/ox0` 恒偶（现有 `isRz` 的偶数要求） |
  | `add`/`sigmoid` | 输入窗口 == 输出窗口 | 逐点 |

- **读**：按**输入行跨步**发 32 B 对齐的窗口读（与 conv gather 同一 idiom：band 基址 `& ~31`）；
- **写**：每输出行一笔 **32 B 对齐 + `wstrb` 掩码**（与宽路 tile WR 同一 idiom，见 `rtl/DdrMaster.scala` 的 `io.wstrb`）；
- **tile 网格**：`tNtx = ceil(IMG_W/32)`、`tNty = ceil(IMG_H/32)`，最后一个 tile 取余量；
- **兼容策略**：**运行期二选一** —— `outPix ≤ MAXPIX ∧ rowW ≤ WIDTH ∧ inCols%32==0 ∧ outPix%32==0` ⇒ 走**原整层路径**（逐字节同形，既有闸门零改动）；否则走 tile。**不引入第二张网表、不引入编译期开关**（与 conv 的 `TILING` 不同：旁路的旧路径天然覆盖所有小层，面积/存储都不变）。
- **对账口径搬移**：`rowW` 改判"**tile 内输入行宽**"（`≤ 32·(pool?2:1) + 余量`，`≤ 64`… **注意**：`maxpool` 的 tile 输入行宽可达 `2·32=64 > WIDTH=34` ⇒ 见下"§3.1.1 列分块"）；`outPix ≤ MAXPIX` 改判 **tile 输出像素**。

#### 3.1.1 `MaxPool` 的 tile 输入行宽 > `WIDTH` 怎么办（**承重细节**）

`MaxPool` 的单元是"按**展开期 `WIDTH` 数列/配对**"的（列回绕、`accRow` 下标按 `WIDTH/2`）。若一个 tile 的**输入**行宽是 64（>34），单元内部列计数器仍会回绕。

⇒ **列方向必须再切到 ≤ `WIDTH`**：`maxpool` 的**输出** tile 宽取 `≤ 16`（输入 32 ≤ 34）。即 **pool 的 tile = 输出 16×32**（`outPix = 512 ≤ 1088`）。`resize`/`add`/`sigmoid` 的输出 tile 宽仍可取 32（输入 16/32 ≤ 34）。

> 这一条由 `dev_map` 之后的 `WIDTH=34` 决定，**实现时以 `WIDTH` 为参数**（`tw_tile = (WIDTH/2)` for pool），不写死 16。

#### 3.1.2 旁路算子的**通道维**（T-S3a 的另一半；2026-10-14 实测发现，T-S3a.1 实现中暴露）

**实测**（`gen/desc.bin` 解码，`y1/tools/run_bypass_tile_ab.sh` 的 C=16 作业也复现）：

| 单元 | 类型 | 实发 `C_IN=C_OUT` |
|:--|:--|:--|
| `MaxPool_5` | maxpool | **16** |
| `MaxPool_18/25/32` | maxpool | **64** |
| `Resize_43/49` | resize | **64** |
| `Sigmoid_85/93/101/109/117/125` | sigmoid | **1** |

而 `BypassExec.geomOk` 要求 `dw.cIn === C ∧ dw.cOut === C`（`C = 8`，`rtl/BypassExec.scala:331`）——
⇒ **真帧的旁路层在"通道"这一维就过不了**（与 §3.1 的"空间"维**并列**的两半）。此前 `desc[0]` 就红，所以这一条从未被撞到。

**口径（推荐）**：
- **通道分块**：`cIn/8` 个 block（`16 ⇒ 2`、`64 ⇒ 8`），src/dst 的平面偏移 `+ 8·HW`（planar 布局）——与 `UnitExec` 宽路的 ci-block 同一 idiom；
- **`C_in = 1`（`Sigmoid_*`，`H=1`、`W ∈ {400,1600,6400}`）**：这四个算子是**逐点**的 ⇒ 用**布局折**把"8 个连续像素"当一拍（`C_eff = 8`）⇒ `tPix = ⌈W/8⌉ ≤ 800 ≤ MAXPIX(1088)`；**算子的数值口径一字不动**。
- 四个算子**通道独立**（maxpool/resize 在空间、add/sigmoid 逐点）⇒ 通道分块**不引入跨通道状态**、**不需要新存储**。

**判据追加**：`run_bypass_tile_ab.sh` 的真表形状里**必须**含 `C=16` 与 `C=64` 的 maxpool/resize，以及 `C=1` 的 sigmoid（§4-A）。

### 3.3 宽链（★ 2026-10-15 由 T-S3c 整表预检发现；**用户裁决 = A：实现宽链**）

**实测**（`gen/desc.bin` + `LayerSched.scala` 的 FLAGS 编码 `head=0/plain=1/middle=2/tail=3`；链条 = 极大 `head middle* tail`，`plain` = 链外单点）：
**34 个 run / 67 个描述符；其中 19 个多算子 run，且 19 个**全部**是宽的**（`16→16` / `64→64` / `64→1` / `64→4` / `64→10`；链长 2/4/6/8）。

而 RTL 的**宽路**要求 `chain_len == 1`（`UnitExec.scala` 的 `wideGeomOk` / `tilingWideC`）
⇒ 这些 run 覆盖的 **~44 个真单元无路**（`LayerSched` 会把它塌缩成一次 `go` 并给 `chain_len=2..8`
⇒ `UnitExec` 在 `IDLE` 那拍**响亮 err**）。C4b 的"53/53 覆盖"是**逐单元**的，**从未跑过一条宽链**
（链闸门用 C=8，宽闸门用 `FLAGS=1` 单点）。

**裁决 A**：把**宽路**（`WIDERUN` + 多趟编排）从 `chain_len == 1` 扩到**整链**（head/middle/tail）：
逐片行锁步 + `FusionBuf` 中间张量零 DDR。**不动转换器、不动描述符格式、不动数值口径**。

**判据**：① 真表 run 形状（`16→16` 链长 2、`64→64` 链长 4/6、`64→10` 链长 2、`64→4`/`64→1` 链长 2）逐字节 == 整层黄金（黄金复用冻结参考）；② 负对照：链长截短 / 少跑一片 ⇒ 必红；③ `TILING=false` 三网表逐字节不变；④ 既有 19 闸门全绿。

### 3.4 旁路 tile 的 **per-plane band**（`Resize_43`）

**实测**：`BypassExec` 的 **tile** 路径要求 `inCols % 32 == 0`（`rtl/BypassExec.scala:289-290` **点名** `Resize_43`：输出 40×40 ⇒ 输入 20×20、`inCols = 400`、`400 % 32 = 16`）
⇒ `Resize_43` **无路**（`geomOk` 的 `outPix=1600 > MAXPIX=1088` 挡整层，`tileAliOk` 挡 tile）。
根因 = **T-S3b 已从 `UnitExec` 宽路去掉的同一前提**（8 个平面共用同一 band 相位 ⇒ 平面步长必须 32 B 对齐）。

**修法**：与 T-S3b **同一套** per-plane band —— 旁路 tile 的平面索引也**按平面各记** `(bandBase, idx)`。
**判据**：`run_bypass_tile_ab.sh` 加 `resize` **40×40** 正对照（真表 `Resize_43` 形状）+ per-plane 负对照（两侧：`HW%32≠0` 红、`HW%32==0` 绿）。

### 3.5 `权重 blob × tiled 宽` 的仿真挂住（**先查**）

**实测**（T-S3c 用既有装置做的受控子实验）：`UnitExecWideTb` + `gen/UnitExec_tiled.v`，64→64 40×40 ——
**无 `+WBASE`** ⇒ `RESULT: PASS`；**加 `+WBASE`**（= 真帧的权重编程方式，走权重 blob DMA）⇒
**4M 拍不收工、无 `done` 无 `err`**（只发了一笔 128 B 权重突发）。此**组合**（`+WBASE × +TILED_W`）**无任何闸门覆盖**，而真帧正需要它。

**处置**：**先查**（① TB 的 blob 供料是否接对、② 还是 RTL 在 `WGTLD/WGTRUN → WIDERUN` 的衔接上真挂起），
定位后再定修法；判据 = 该组合有一条**正对照**（收工 + 逐字节）与一条**负对照**。

### 3.6 宽链 + **口径修订**（★ 2026-10-15 T-S3f 实测后**用户裁决 = A'：修口径 + 实现宽链**）

**T-S3f 的三条实测事实（它们是本节的硬约束，不是猜测）**：

| # | 事实 | 证据 |
|:--|:--|:--|
| **B1** | 真表的宽 run 是**异型链**（成员 `C_IN/C_OUT` 逐片不同，如 `Conv_6 16→16 → Conv_9 16→32`），而**冻结**的 `desc_table.py:147` 只把**链首**几何写进每个成员；冻结链路参考（`chain_l`/`pair_two_stage`/`sched_chain`）**拒绝** `C_IN≠C_OUT` 的链（`chain_l(CIN=64 COUT=10 L=2)` ⇒ `IndexError`） | `y1/reports/ts3f_red_first.txt` |
| **B2** | 真 blob 的**逐成员段长 ≠ `chainLen × N_i(链首)`**——**19/19 run 漂移**（run`[13..16]` 推进 147,456 B 而真 blob 只有 74,880 B，因为 depthwise 成员更短）⇒ `LayerSched` 的 `chainLen×N_i` 指针**从第 2 片起读错字节** | 同上 |
| **B3** | 忠实镜像窄链（逐片行锁步 + `FusionBuf` 环）需每片的 pass-tile 集常驻：`L×N_i` 最大 **221 KB** vs 剩余 **DRM 39.5 块 ≈ 178 KB** ⇒ **装不下** | 同上 |

⇒ **两条推论**：① **当前宽链编码与真表本来就不一致**（B1+B2）——即使 RTL 支持 `chain_len>1` 也读错权重；② 忠实镜像不可行（B3），必须有**新设计**。

**口径修订的范围（最小解冻）**
1. **逐片几何**：描述符本来就是**逐算子一条**（67 条）⇒ 几何已在表里。要改的是**链的传递口径**：`LayerSched` 在 `CHAINSCAN` 扫链时已逐条取回成员描述符 ⇒ 把它们（或每片的几何数组）**交给 `UnitExec`**，而不是只用链首。
2. **逐成员段长**：权重的**每片基址**必须逐片给（blob 的 `aligned_bytes` 逐单元已在 `wgt_index.json` 里）⇒ 新增"每片基址"的投递（走既有权重信箱/表内保留位的同一套 idiom），**不改 8 字描述符线格式**。
3. `desc_table.py` 的**解冻范围**：只解冻 ① 异型链的校验口径（成员几何可不同）② 逐成员段长的记账；**位打包与校验六规则的其余部分一字不动**。

**RTL 设计（B3 下的可行档，与窄链**不**同构——必须在文件头写清楚为什么）**
- **逐片串行 + 嵌套窗口**：每个 tile 内**逐片**跑完再换片（不做 L 片同时驻留），中间张量借 `FusionBuf`/`wOutMem` 乒乓；窗口按链的内缩重算（`T = 34 − 2L` 量级）。
- **每 (tile, 片) 的权重重载**：WidthStore 写口 8 bit ⇒ 1 B/beat 的现实代价要记账（L4/C64 每 tile ≈5.2 MB 量级）⇒ 设计里要写**为什么可接受**或给出更省的载法。
- 保留"不合几何 ⇒ 响亮 err、零搬运"的纪律。

**判据（每条都要正 + ≥1 条能发火的负）**
1. 真表 run 形状逐字节（**先修 B1 的 golden 缺口**：冻结参考只支持同型链 ⇒ 异型链的黄金要么扩参考、要么用"逐片串联的参考"并**明写它是第几条参考**）；
2. **负对照**：链长截短 / 某一片的权重基址偏一段 ⇒ 必红且**定位到该片**；
3. `TILING=false` 三网表逐字节不变；既有闸门全绿（含**先修 `run_chain_ab.sh` §7 的既有红**——文本锚点已腐坏）；
4. `dev_map`：`Adm-4088=0` 且 DRM ≤ 415（当前 375.5）。

### 3.7 **收窄 `PartialSumBuf` 行宽**（★ 2026-10-15 用户提议；独立于宽链，面积大头）

**实测尺寸**（`rtl/PartialSumBuf.scala`）：一个字 = 一个 co-block 的 `C_OUT` 行部分和，行宽 **64 bit** ⇒
`WORD_W = C_OUT×64 = 512 bit`；`DEPTH = NCOB×PIXMAX = 8×1088 = 8704` ⇒ **557,056 B ≈ 544 KB**（NPU 里**最大**的一条存储）。

**收窄到 32 bit/行** ⇒ `WORD_W = 256 bit` ⇒ **278,528 B ≈ 272 KB**（**−272 KB，−50%**）。

**为什么 32 bit 是可证的（不是估）**：`|acc| ≤ max|x|·max|w|·taps`，`x∈[-128,127]`、`w∈[-127,127]`（§4.5 对称量化 `z_w≡0`）
⇒ `|x·w| ≤ 128×127 = 16,256`；taps 最大 = `(C_in/GROUP)×9 ≤ 64×9 = 576`（dense `C_in=64/GROUP=1`）
⇒ `|acc| ≤ 16,256 × 576 = 9,363,456 < 2^24` ⇒ **25 bit 有符号够**；32 bit 留 ~2^7 余量。
每个**部分和**都被最终累加值界定（中间量更小）⇒ 收窄**不动数值口径**。

**为什么要它**：spec §3.6 的 **B3**（忠实镜像宽链需 `L×N_i` ≤ 221 KB vs 余量 ~178 KB）——收窄腾出的 272 KB
**足以让"忠实镜像"这一档重新可行**，从而不必上"逐片串行 + 嵌套窗口"那个更绕的设计。

**判据**：① 收窄后**全部数值闸门逐字节不变**（`run_multipass_ab.sh` / `run_dw_wide_ab.sh` / `run_tiling2d_*` / `run_unitexec_wide_ab.sh` …）；
② **负对照**：把行宽再收到 24 bit（**低于可证界**）⇒ 用"最大幅度"激励（`x=w=±127`、满 taps）**必红**（证明这条界真在起作用）；
③ `dev_map`：`Adm-4088=0`、`DRM` 相对当前 375.5 **明显下降**（以日志为准）；④ `TILING=false` 三网表逐字节不变。

### 3.2 T-S3b：**宽路 gather 的 per-plane band**（去掉 `HW%32==0` 前提）
- 现状：`wxBBR/wxIdx` **单个共享**（隐前提：`HW = inH·inW` 是 32 的倍数 ⇒ 8 个平面的 32 B band 边界重合）。
- 改为：**每平面各自**的 `(bandBase, idxW, idxB)`。`FETCH` 已逐平面推进地址（`wxFAdrR += tInPixW`）⇒ 每平面算出自己的 `gAbs`，band 基址 `& ~31`、band 内下标 `gAbs[4:0]`；`EMIT` 时 `wxCol(cl)` 用**第 `cl` 个平面**自己的 `(idxW(cl), idxB(cl))` 索引 `xwBuf`。
- **代价**：8×3 bit 索引寄存器 + 一个 8 路 mux；**0 新 DRAM**。
- **去掉** `tilingWideC` 里的 `tHW32(4 downto 0) === U(0,5 bits)` 一项（band 基址本身恒 32 B 对齐）。其余前提（`s∈{1,2}`、`IMG_W/H≠0`、`H·W%8==0`、`nCo≤NCOB_MAX`、`LAYER_ID<PN_LAYERS`、`XDMA_EN`）**一字不动**。

---

## 4. 判据（每条都要**正对照 + ≥1 条能发火的负对照**）

- **A（旁路 tiling）**：新闸门对**真表旁路形状**（`maxpool` 16/64ch 的 160×160 / 80×80 / 40×40 / 20×20、`resize` 40×40 / 80×80、`add`、`sigmoid`）逐层跑 tile ⇒ **逐字节 == 整层黄金**（黄金复用既有冻结参考，**不写第三条**）。
  - 负对照①：漏最后一个 tile 行 ⇒ `MISMATCH>0` 且**定位**在被漏的 tile 带；
  - 负对照②：tile 输入窗口**错一个像素的对齐**（pool 的 `2·oy0` 写成 `2·oy0+1`）⇒ 必红（证明"输入窗口对齐"这一条真在起作用）。
- **B（per-plane band）**：把 **20×20 的宽 conv 形状**加进 `run_tiling2d_wide_ab.sh` 的正对照（当前被 `tilingWideC` 挡）⇒ 逐字节 == 整层。
  - 负对照：把 per-plane `idx` 退回**共享 idx**（= 原来的 `HW%32==0` 口径）⇒ 在 `HW%32≠0` 的形状上**必红**。
- **C（整表预检，离线）**：对真表 **67 个单元**逐条走 RTL 的几何对账（`inWOk` / `wideGeomOk` / `tilingWideC` / `tilingOkC` / `BypassExec.geomOk`）⇒ **零 err**。这是"S3 一次跑完"的**离线保证**。
  - ★★ **执行结果（T-S3c.1，2026-10-15）：不成立 —— 1 个单元 err + 忠实派发口径 54 条无通路。**
    见 `y1/reports/c4b_frame_preflight.md`：`Resize_43` 撞 `BypassExec.tileAliOk`（整层 `inCols%32==0` 的前提没搬到 tile），
    且宽层的融合链全无通路（RTL 宽路判据都带 `chain_len==1`）。**本 spec §3/§6 的"S3 一次跑完"前提被推翻**，
    修法见该报告 §7（先修 `Resize_43` 那一类，再裁决宽层链）。
- **D（面积）**：每段 `dev_map`；**断言 `Adm-4088 = 0` 且 DRM ≤ 415**（当前 375.5/415）。
- **回归**：既有闸门全绿（尤其 `TILING=false` 的三份 `UnitExec*` 网表**逐字节不变**、`BypassExec` 旧路径**逐字节同形**）。

---

## 5. 风险

| # | 风险 | 处置 |
|:--|:--|:--|
| R1 | **DRM 只剩 39.5 块（90.5%）** | 旁路 tile **复用 `outMem`**（tile 输出 ≤ 1024 ≤ MAXPIX=1088）⇒ **0 新宽存储**；每段 `dev_map` |
| R2 | 旁路 FSM 从"整层一笔 RD/WR"变"每 tile 多笔" ⇒ 回归面大 | 与 conv tile 循环**同一 idiom**；既有闸门先跑基线，逐段改、逐段回归 |
| R3 | per-plane band 碰主口负载（`rd_ready`） | band 缓冲仍**单份**（8 平面**串行**取），只是**每个平面各记自己的 idx** ⇒ 不并发 |
| R4 | 20×20 层的 tile 边界（`tTh/tTw` 余量、单 tile） | 用真表 20×20 形状做正对照（§4-B） |
| R5 | `MaxPool` 的 tile 输入行宽 `> WIDTH` | **列方向再切**（§3.1.1）：pool 输出 tile 宽 `WIDTH/2` |

---

## 6. 分段（staged）

- **T-S3a**：旁路算子 tile 循环（`maxpool`/`resize` 为主；`add`/`sigmoid` 若原路径已过则**不动**）。
- **T-S3b**：宽路 gather per-plane band（去 `HW%32==0`）。
- **T-S3c**：整表几何预检（判据 C）+ `dev_map`/回归记账。
- 之后 = **S3**：PnR → 比特流 → 板 → 12 路 + G7（IoU ≥ 0.5 / 关键点平均 L2 ≤ 2 px / |Δconf| ≤ 0.1 / 检出数差 ≤ 1）。

### 6.1 G7 的 **kp 容差**修订（2026-10-17，S4-C 收口时）

原拟定的「关键点平均 L2 ≤ **2 px**」对**完美板**也不可达：同口径 int8 黄金对 float ORT 本身
`kp_l2 = 4.81 px`（§14.3 归档）。实测：
* 板端 vs float：**1 个检出、IoU 0.9237、|Δconf| 0.0056、计数 1:1、kp_l2 = 2.787 px**
  （板端优于 int8 黄金）；
* 板端 vs **折进黄金**：检出与框**逐位相同**（conf 0.9349、同框）。

⇒ **修订**：kp 判据改为「**板端 vs float ≤ 5 px**（覆盖 int8 量化口径）」，且另立一条**同口径**
判据「板端 vs 折进黄金：检出框 IoU ≥ 0.99、conf 差 ≤ 1 个码点」作为数值正确性的硬判据。
其余三条（IoU/|Δconf|/计数差）不变。

---

## 7. 待裁决（给了推荐值）

1. **旁路 tile 的兼容策略**：**运行期二选一**（`outPix ≤ MAXPIX ∧ rowW ≤ WIDTH ∧ 对齐前提都满足 ⇒ 走旧路`）**推荐**；不引入第二张网表。
   （替代：编译期 `TILING` 开关，与 conv 同 —— 但旁路旧路径本来就能覆盖小层，多一张网表不划算。）
2. **判据 C（整表预检）的口径来源**：**推荐两者都做** —— Python 同源口径做**快速门**（逐单元几何对账表），**模拟里跑真 `desc` 序列**做**最终证**。
3. **`add`/`sigmoid` 的 tile**：只在"若原路径过不了"时才动（真表的 `Add`/`Sigmoid` 走逐点路径，预计不受 `WIDTH` 限制）—— **不改**，除非判据 C 点名。

---

## 8. 自查记录

1. **设计覆盖**：§2 的两类 err → §3.1/§3.2；§3.1.1 的 `WIDTH` 承重细节 → §4-A 负对照②；DRM 余量 → §5-R1 + §4-D；判据 C 的"整表零 err" → §6 的 T-S3c。
2. **占位扫描**：无 TBD。数值都给到（`outPix` 25600、输入行宽 320、`400%32=16`、DRM 375.5/415）。
3. **不动的**：描述符格式（8 字）、数值口径（PTQ/requant/`z_pad`）、`third_party/**`、冻结工具（`tiling_ref.py`/`multipass_ref.py`/…）、`TILING=false` 的三份 `UnitExec*` 网表。
4. **诚实标注**：判据 C 若落在 Python 同源口径上，**必须写明它与 RTL 的口径来源**（漂移风险见 §5-R3 的同类）；最终以模拟跑真 `desc` 为准。

---

## 9. T-S3c.1 执行结果（2026-10-15，**回写**）

判据 C 的 Python 快门已落地（`y1/tools/frame_preflight.py` + 闸门 `y1/tools/run_preflight_ab.sh`，
报告 `y1/reports/c4b_frame_preflight.md`）。**结论与本 spec §4-C 的"零 err"相反**：

| 口径 | 数 | 说明 |
|:--|:--|:--|
| `UNIT`（每单元各一条，`chain_len=1`） | **PREFLIGHT_ERR = 1** | **`Resize_43`（idx 29，resize 40×40 C=64）无合法通路**：`geomOk` 的 `outPix(1600)>MAXPIX(1088)` + `tileOk` 的 `tileAliOk`（`BypassExec.scala:607`，`inCols=400 ⇒ 400%32=16`）两条路同时堵死 |
| `DISPATCH`（忠实派发 = 链塌缩 + 真帧编程） | **DISPATCH_ERR = 54** | **宽层的融合链无任何通路**：RTL 宽路的 `wideGeomOk`/`wgtLoadOk`/`tilingOkC`/`tilingWideC` **全带 `chain_len==1`**（`UnitExec.scala:1236/1426/1451/1650`），而真表 53 个 conv **全是宽层**、其中 52 个在链上 ⇒ `chain_len≥2 ∧ isWide` 落空 |

**⇒ S3（PnR → 比特流 → 板 → 12 路 + G7）在本 spec 的三处盲区修完之后仍然做不了**；
§3.1.1/§3.1.2/§3.2 修好的部分**逐条成立**（66/67 单元有合法通路），但"整帧跑完"还缺两块：
① 旁路 tile 的 per-plane band（`tileAliOk` 那一类）；② 宽层链的裁决（表侧拆链 **或** RTL 侧支持）。
sim 终证（判据 C 的第二半）**defer**：现有装置不支持 67 条真序列（见报告 §5.3），
**Python 预检与 RTL 的口径漂移风险**按 §8-4 如实记录为开口项。


### 10. §3.7 执行结果（2026-10-16，**回写**）

**Status: DONE**（实现 + 判据 + `dev_map` 全部落地；未 push）。三处提交：
`861d2c4`（RTL 收窄）→ `61781e1`（界判据闸门 + 装置）→ 本回写。

| 项 | 结果 |
|:--|:--|
| 收窄实现 | `PartialSumBuf`/`MultiPassUnit` 新增行宽参数 `PSW`（缺省 **32 bit = 4 B/行**；`WORD_W` 512→256 bit）；`Conv3x3Slice` 的 `ps_in/ps_out` 与累加器同参数化（`PSW==64` 时**逐字**是旧实现）；自报口 `rowBytes/wordBytes` 随 `PSW` 走 |
| 档位 | 板级（`LayerSched`→`NpuTop`，`TILING=true`）⇒ **32**；`TILING=false` 的三份冻结网表由 `UnitExec` 显式钉 **64** |
| `TILING=false` 三网表 | **逐字节不变**：`UnitExec.v 97912901…` / `_w32 618af338…` / `_w640 ddb9bb8a…`（`run_wgtblob_tiled_ab.sh` 的前置 md5 判据亦通过） |
| 判据 ②（可证界） | `tools/run_psbound_ab.sh`（新）：**实测峰值 `\|acc\| = 9,363,456`**（= 理论界 `128·127·576`，neg 档 `x=-128,w=127`；pos 档 `9,290,304` = `127·127·576`）⇒ 32 bit 满幅度激励**逐字节 == 冻结参考**；**24 bit**（低于可证界）**精确命中**二补数回绕预测且 `!=` 黄金（**96 字节** = 12 个顶到界的内部像素 × 8 co）⇒ 负对照会发火 |
| 判据 ①（回归） | 9 条闸门全绿：`multipass / dw / dw_wide / unitexec_wide / unitexec / tiling2d_wide / tiling2d_rtl / wgtblob_tiled / chain`（`unitexec / tiling2d_rtl / chain` 在本机需 `PY=<venv python>`，其缺省是裸 `python`）；另跑 `sched / fuse / stride_exec / nputop / nputop_sched / wgtdma / tiling2d` 亦全绿 |
| 判据 ③（面积） | `dev_map`（integrated，`y1/pds/devmap_c4a_s37.log`）：**DRM 375.5 → 247.5 / 415（90.48% → 60%）**，即**腾出 128 块**；`Adm-4088 = 0`；LUT 127,337→124,108、APM 558→542、FF 149,006→149,298 |
| 尺寸（板级几何） | `PartialSumBuf` 574,464 B → **287,232 B**（TILING 档 `DEPTH=8×(1088+34)=8976`；spec §3.7 的 272 KB 是"缺省 8704 字"那一档的数） |
| 新增网表 md5 | `MultiPassUnit.v = DwUnit.v 9ce1323d…`、`UnitExec_tiled.v b64e2c4a…`、`LayerSched.v 5e92fbbc…`、`NpuTop.v f338b37b…`、24-bit 负对照档 `gen/c4a_psbound/nl24/MultiPassUnit.v fad0a9d1…`（重跑确定性已复核） |
| 诚实标注 | ① `TILING=false` 三网表按"历史冻结锚"钉 64 —— 这是**闸门锚**而非板级档；② 闸门 `run_multipass_ab.sh` 的文本锚 `512'b0`→`256'b0`（生成风格随收窄变），**数值判据与黄金一字未动**；③ 界判据的两个极端用例的 32 bit 黄金是**饱和常数**（满幅度必然削顶）⇒ 退化守卫改打在 **24 bit 预测**上（`distinct24 = 2`，混合 `0x7F/0x80`），并由"24 bit 必须 `!=` 32 bit"补牙。 |
