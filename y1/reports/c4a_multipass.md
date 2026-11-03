# Y1-C4a.8 报告 —— C4a 收口：多趟累加 / depthwise 数值结论 + 与 float ORT 逐层偏差 + 面积（集成实测）

> **本任务（C4a.8）只做三件非 PDS 的事**：① 多趟/depthwise 的数值结论收口（含 C4a.5b 的三处缺陷
> 与受控实验）；② 与 float ORT 的**逐层偏差记录**（**记录，不是判据**；判据在 C4b/G7）；③ 含
> `PartialSumBuf` 的**面积表**（C4a.8 只留**清楚标记的占位**；**现已由控制器 `dev_map` 回填，见 §5**）。外加：**全非 PDS
> 回归**（15 单元闸门 + C4a 闸门 + 台账 + dangling）。
>
> **明确不做（控制器做）**：跑 `dev_map` / PnR、填面积占位。
> **明确不做（C4b 做）**：G6（权重从 DDR 搬）、G7（整帧端到端 / fps / 上板）。

**Status: DONE**（非 PDS 全绿，见 §7；面积已按控制器 `dev_map` 回填，见 §5；PnR 在飞，见 §6）。日期 2026-10-11。

---

## 0) 本步交付物

| 文件 | 说明 | 状态 |
|:--|:--|:--|
| `y1/reports/c4a_multipass.md` | 本文件 | 新增 |
| `y1/pds/devmap_c4a.tcl` | 含 `PartialSumBuf` 的 C4a `dev_map`（`YESHENMINI_C4A_MODE` = integrated/nputop/layersched） | 新增（**不跑**） |
| `y1/pds/pnr_c4a.tcl` | C4a PnR -> report_timing -> 比特流（一键） | 新增（**不跑**） |

---

## 1) 多趟累加（C4a.4 离线 + C4a.5 RTL）—— **G3**

### 1.1 形状集合与逐字节结论

**形状集合**取自**真表**（`gen/c4a_tiling/c4a_tiling.json`，转换器 + `desc_table` 的真形状集，去重）。
真表 15 种 `(C_in,C_out,GROUP)`，其中 **13 种是"宽层"**（`C_in>8 || C_out>8` ⇒ 多趟）：

| 形状 `(C_in,C_out,GROUP)` | 代表层 | `n_ci` | `n_co` | 趟数 `passes` | 多趟正对照 |
|:--|:--|--:|--:|--:|:--|
| (3,16,1) | `Conv_0` | 1 | 2 | 2 | `POS_MISMATCH=0` |
| (16,16,1) | `Conv_2` | 2 | 2 | 4 | `POS_MISMATCH=0` |
| (16,16,16) | `Conv_3` | 2 | 2 | 4 | `POS_MISMATCH=0` |
| (10,10,10) | `Conv_73` | 2 | 2 | 4 | `POS_MISMATCH=0` |
| (16,32,1) | `Conv_9` | 2 | 4 | 8 | `POS_MISMATCH=0` |
| (32,32,1) | `Conv_12` | 4 | 4 | 16 | `POS_MISMATCH=0` |
| (32,32,32) | `Conv_10` | 4 | 4 | 16 | `POS_MISMATCH=0` |
| (32,64,1) | `Conv_15` | 4 | 8 | 32 | `POS_MISMATCH=0` |
| (64,1,1) | `Conv_54` | 8 | 1 | 8 | `POS_MISMATCH=0` |
| (64,4,1) | `Conv_60` | 8 | 1 | 8 | `POS_MISMATCH=0` |
| (64,10,1) | `Conv_72` | 8 | 2 | 16 | `POS_MISMATCH=0` |
| (64,64,1) | `Conv_19` | 8 | 8 | 64 | `POS_MISMATCH=0` |
| (64,64,64) | `Conv_16` | 8 | 8 | 64 | `POS_MISMATCH=0` |

（另 2 种 `(1,1,1)`/`(4,4,4)` 是**单趟**窄形状，不属"多趟"档，但仍在离线闸门里对账。）

- **离线半边（C4a.4）**：拆趟模拟 == 整层参考，`SHAPES_TOTAL=15 MISMATCH_TOTAL=0`（`run_tiling_ab.sh`，
  `exit 0`）。负对照"故意漏一趟" ⇒ `DROP_MISMATCH>0`（每层都发火）。
- **硬件半边（C4a.5）**：13 种宽形状走 RTL 多趟（`gen/MultiPassUnit.v` = `Conv3x3Slice` + `PartialSumBuf`）
  ⇒ 每个形状 `POS_MISMATCH=0`，与 C4a.4 的整层黄金**逐字节**一致（`run_multipass_ab.sh`，`exit 0`）。
  跨 `ci` 趟在**片上** `PartialSumBuf` 里累加（int64），**只在末趟 requant 一次**：
  `((acc·M) >> 24) >> 6 + z_y`（§4.4 乘子，`REQUANT_Q=24`、`SHIFT=6`）。
- **乘子真有牙**：单位乘子 `M=2^24` ⇒ `hit=0`（不命中黄金）且 `!= 黄金`；真乘子 ⇒ 逐字节命中。

### 1.2 闸门判据（全部带可发火负对照）

`bash y1/tools/run_multipass_ab.sh`（`RESULT: PASS`，退出 `0`）：

| # | 判据 | 实测 |
|--:|:--|:--|
| 0 | 参考自检（拆趟==整层 + 四份预测都有牙 + 黄金非退化） | `SELFTEST_MULTIPASS cases=8 fails=0`；`47` 条断言全 PASS |
| 2 | **正对照**：RTL 多趟 == C4a.4 整层黄金 | 13/13 形状 `POS_MISMATCH=0` |
| 3 | **乘子生效**：`+M=2^24` ⇒ 精确命中 `((acc·2^24)>>24)>>6 == acc>>6` 且 `!= 黄金` | `UNITY hit=0 !=gold` |
| 4 | **负对照 A1（漏一趟）**：`+DROPCI=i` ⇒ 命中 `conv_tiled(drop)` 且 `!= 黄金` | `DROP !=gold`（单趟形状标 `N/A`） |
| 5 | **负对照 A2（部分和从不写回）**：网表突变关掉 `PartialSumBuf` 写口 ⇒ 命中"只 requant 末趟 partial" 且 `!= 黄金` | 每个 `n_ci≥2` 形状都发火 |
| 6 | **负对照 B（部分和初值非 0）**：网表突变把 `.init` 的 `co=0` 行改 K ⇒ 命中 `requant(acc+K)` 且 `!= 黄金` | 每个形状都发火 ⇒ **"第 1 趟靠上电初值 0 清零"是承重项** |
| 7 | 退化守卫：黄金与 RTL 输出都 `distinct>1` | OK |
| 8 | 结构：`MultiPassUnit.v` 里 `PartialSumBuf` 是**一条 `Mem`**（`reg [511:0] mem[0:255]` = 131072 bit，**不在 FF**）+ 同步读 `mem_spinal_port1 <= mem[rd_addr]`；无组合读 | `STRUCT: PASS`；`check_dangling.py` 零悬空 |

**红色路径实跑**（证明闸门不是橡皮章）：把 `NL` 指向"requant 移位被改"的 scratch 网表 ⇒ `exit 1`；
把 `TB` 指向"忽略 `+DROPCI`"的 scratch 装置 ⇒ 负对照发不了火 ⇒ `exit 2`。

---

## 2) C4a.5b：宽层多趟通路在 `UnitExec` 级的**三处缺陷** + 受控实验证明

> 现象：`run_unitexec_wide_ab.sh` 起初 **RED**（`MISMATCH=2687/4096`）。三处根因**全部由受控实验定位**
> （不是试错），修后 `MISMATCH=0`。commit `cd839ec`。

| # | 缺陷 | 机理 | 受控实验（预测 == 实测） | 修法 |
|--:|:--|:--|:--|:--|
| 1 | **信箱 `bias_adj` 提交用了同拍才赋值的高位字节** | `biasMem.write(..., Cat(bAcc(3),...), bLane===3)` 读到的是 `bAcc(3)` 的**旧值** ⇒ 每词最高字节迟一词并串进下一词；`bias_adj` 是有符号累加器单位量（真层 `Conv_0` 有负值）⇒ 污染词变 `0x00FFFFxx`（正巨值）+ 下一词变 `0xFFxxxxxx`（负巨值）⇒ 输出在这两个 co 上饱和到 `±127/128` | 由时序假设**预测**的"坏 co 集合"与实测**逐一相符**（`Conv_0`→5/6/10/11；synth 16→8→1/2/3/6；…） | 第 3 道取**当拍**数据 |
| 2 | **宽层 WR 相位把 `[co-block][pixel][cl]`（通道交错）当成 `[co][y][x]` 直推** | 冻结口径是**通道平面** `[co][y][x] = [co-block][cl][pixel]`，与"整字直推"差一个 8×像素数 的**转置** | 参考侧用 `x/w/b` 独立重算（多趟累加 + bias 折进 acc 再 requant）**与黄金 0 差** ⇒ 差异在 RTL 接线，不在参考 | 改**逐字节取**（地址 `pix*NCOB+cob`、取字内第 `cl` 字节）；加 `H*W % 8 == 0` 的响亮守卫 |
| 3 | **pad 行喂列不终止** | `wAdvance` 把 pad 行也挂在 `io.wide_x_valid` 上 ⇒ 主机列流在真行末尾用尽后 `wRow` 停在 `H`、切片被多喂列**越过 pad 行继续产多余像素**（`pixCount > H*W`）；多余像素按 `pixCount[7:0]` **回绕**写 `wOutMem[pix 0]` ⇒ **co-block ≥1 的像素 0 一个字节错** | 给 DUT 插层次探针实测到 `pixIdx=256` 的额外 `y_valid`（值恰等于被污染的像素 0 字） | pad 行只按 `x_ready` 推进（满 W 列即停）+ 收料口加"喂列窗口"闸（`wFeedSt && pixCount < H*W`） |

**修后判据**（`bash y1/tools/run_unitexec_wide_ab.sh`，`RESULT: PASS`，退出 `0`）：

```
WIDE_REF Conv_0    CIN=3  COUT=16 n_ci=1 n_co=2 M=57384  ZPAD=-128 ZY=41  NCOL=512
WIDE_REF Synth_16_16 CIN=16 COUT=16 n_ci=2 n_co=2 M=3000000 ZPAD=-128 ZY=-1  NCOL=1024
JOB Conv_0    n_ci=1 n_co=2 passes=2 M=57384  | POS_MISMATCH=0 distinct(gold=26,rtl=26) | PAD0 !=gold=397 | NOBIAS !=gold=4096
JOB Synth_16_16 n_ci=2 n_co=2 passes=4 M=3000000| POS_MISMATCH=0 distinct(gold=73,rtl=73) | PAD0 !=gold=2039| NOBIAS !=gold=45
自报/信箱= OK（WIDE_ON/PASSES/RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER == 经信箱按 LAYER_ID 灌进去的值）
负对照 A = OK（pad 用字节 0 ⇒ 精确命中 gold_pad0、且 != 黄金）
负对照 B = OK（bias_adj 全 0 ⇒ 精确命中 gold_nobias、且 != 黄金）
```

> 注：`run_chain_ab.sh` 的"实例计数"判据在宽层通路引入后**重锚**为 `L_MAX + 1`（`Conv3x3Slice x9`），
> 因为 `MultiPassUnit` 内部**自带 1 片** `Conv3x3Slice`（`run_multipass_ab.sh` 的 `requant>>>6` 仍是 8）。

---

## 3) depthwise（C4a.6）—— **G4**

**真表口径**：depthwise = `GROUP = C_in = C_out`；`C≤8` 一趟；`C>8` 拆趟（每趟 8 通道）。
**C 取值**（真表 20 个 depthwise 层，去重 5 种）：**`C ∈ {4, 10, 16, 32, 64}`**（两个独立源对账：
`gen/wgt_index.json` 的 `own` 几何 == `gen/c4a_tiling.json` 的 `GROUP`；`DW_TABLE units=20 distinct_own=5`）。

**pass 调度**：depthwise 只差在"**对角趟**"（co-block `b` 只吃 ci-block `b`，因 `GROUP==C_IN==C_OUT` 使
co 与 ci 同组当且仅当同块）；非对角趟权重瓦片全 0 ⇒ 对角趟与通用趟**必须逐字节相同**。

**与 C4a.5 共用同一套算术（不允许另起一套）**：`md5(gen/DwUnit.v) == md5(gen/MultiPassUnit.v)`
（`2578dc51d95fcaac77e560cda34e2121`）—— 同一份网表，只换 pass 调度。

**判据**（`bash y1/tools/run_dw_ab.sh`，`RESULT: PASS`，退出 `0`）：

| 形状 | `n_ci` | `n_co` | 趟数 | 多趟正对照（对角） | 对角==通用 | 误映射负对照（`groupOfOut` 写成局部 `co`） |
|:--|--:|--:|--:|:--|:--|:--|
| C=4 | 1 | 1 | 1 | `POS_MISMATCH=0` | `diag_vs_generic=0` | `N/A`（`local==global`，映射重合；`tile_diff=0`） |
| C=10 | 2 | 2 | 4 | `POS_MISMATCH=0` | `diag_vs_generic=0` | `hit=61`（`tile_diff=36`） |
| C=16 | 2 | 2 | 4 | `POS_MISMATCH=0` | `diag_vs_generic=0` | `hit=247`（`tile_diff=142`） |
| C=32 | 4 | 4 | 16 | `POS_MISMATCH=0` | `diag_vs_generic=0` | `hit=749`（`tile_diff=418`） |
| C=64 | 8 | 8 | 64 | `POS_MISMATCH=0` | `diag_vs_generic=0` | `hit=1750`（`tile_diff=988`） |

分派对账：`gen/LayerSched.v` 的 `isDw = (tpe == 8'h03)` 折进 `isConv/typeKnown`（走数据通路，不是 err 路径）
⇒ `DISPATCH: PASS`。结构：`gen/DwUnit.v` `check_dangling.py` 零悬空。
（诚实标注：单块形状 `C≤8` 的误映射负对照**结构上 N/A**——`GROUP==C_OUT` 时 `groupOfOut(co)=co` 与
`(co*GROUP)/C_OUT` 恰好重合；它在每个 `C>8` 形状上发火。）

---

## 4) 与 float ORT 的**逐层**最大偏差 —— **记录，不是判据**（★ 非判据）

> **口径**：`max|dequant(我们的 int8) - ORT_float|`，逐层；`pct` = 该偏差 / 该层标定满量程 `(hi-lo)`。
> 数据源：`y1/reports/c4a_ref_layers.json` 的 `layers[*].ort_max_abs_dev`（**106 层全表**）；
> 数来源与派生口径同 `y1/reports/c4a_quant.md` §11.5（权重改对称 §4.5-A 后**重测**）。
> ★★ **这一节是 RECORD（记录），不是 JUDGMENT（判据）。** 量化精度是否够，是 **C4b 的 G7** 整帧端到端容差说了算。
> 输入是**确定性合成图**（`seed=20261010`，`U[0,1)`）；换真图会变数，但**不改判据**。

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

**12 个 graph 输出**（`max_abs_dev` / 满量程 / `pct` / `distinct`）：

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
idx= 65 Conv      270    dev=5.638  range=21.98  pct=25.65%
idx= 85 Transpose 317    dev=5.638  range=21.98  pct=25.65%
idx= 86 Reshape   327    dev=5.638  range=21.98  pct=25.65%
idx= 75 Conv      280    dev=2.161  range=13.89  pct=15.56%
idx=104 Transpose 408    dev=2.161  range=13.89  pct=15.56%
idx=105 Reshape   kps_32 dev=2.161  range=13.89  pct=15.56%
idx= 69 Conv      274    dev=2.112  range=10.55  pct=20.02%
idx= 91 Transpose 341    dev=2.112  range=10.55  pct=20.02%
```

**读法**：首层偏差极小（`idx=0` 层 `dev=0.008585`、`pct=0.40%`），逐层累积到 9–29%。`obj_*` 的 `pct`
看着吓人，但那是**量程本身只有 1e-6~3e-3**（Sigmoid 后近似 0）⇒ 绝对偏差 1e-6~2e-3 级，**不构成判据**。
整体 9–29% 是 **8-bit per-tensor PTQ（无 QAT）** 的预期代价。
**逐层 106 行的完整表**见 `y1/reports/c4a_ref_layers.json`（`layers[*]`），本节不复制全表。

---

## 5) 面积（**C4a 集成实测 —— 已回填**）

> **数据源（唯一权威）**：日志 **`y1/pds/devmap_c4a.log`**，完成标记 **`Y1_C4A_INTEGRATED_DEVMAP_DONE`**
> （工程 `sim/reglogs/pds_devmap_c4a_p10.000`）。器件行与 C3 同源：
> `create_project -synthesize_tool 2 -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6`。
> 取数：`Device Utilization Summary`（APM/FF/LUT/Distributed RAM/DRM/IO）+ `Mapping Summary`
> （`Total LUTs` / `LUTs as dram` / `LUTs as logic` / `Total DRMs` / `Total APMs`）+ `grep -cE "Adm-4088"`。
> 本表为**板级 SoC + `NpuTop`（含 C4a 新增的 `PartialSumBuf` / `MultiPassUnit`）** 集成口径，与 C3 基线**同工具同口径**。

### 5.1 集成 C4a 顶层（板级 SoC + NpuTop(含 `PartialSumBuf`)）—— **C4a 实测**

| 资源 | **C4a 实测** | C3 权威基线（`c3_area.md` §11.3，板级+权重信箱，`L=8`） | **Δ vs C3** | 器件可用 |
|:--|:--|:--|:--|--:|
| LUT | **107,401（68%）**（`Total LUTs 107403 (67.21%)`；`LUTs as logic 96548`） | **72,381.5（46%）** | **+35,019.5**（46%→68%） | 159,800 |
| FF | **114,642（36%）**（参考项） | **105,282（33%）** | **+9,360**（33%→36%） | 319,600 |
| **DRM** | **93.5（23%）**（`Total DRMs 93.5 of 415 (22.53%)`） | **32.5（8%）** | **+61**（8%→23%） | **415** |
| **APM** | **532（72%）**（`Total APMs 532.00 of 740 (71.89%)`） | **465（63%）** | **+67**（63%→72%） | 740 |
| Distributed RAM（`LUTs as dram`） | **10,855（28%）**（`LUTs as dram 10855 of 39500 (27.48%)`） | **1,767（5%）** | **+9,088**（5%→28%） | 39,500 |
| IO | **99（25%）** | 99（25%） | **0** | 400 |
| **CLMA / CLMS** | **待 PnR**（`dev_map` 不印 CLMA；`pnr_c4a` **在飞**，见 §6） | **27,142 / 30,075 ≈ 90%**（`c3_pnr_timing.md` R3） | 待 PnR | 30,075 |

**G-gate 判据（按 C4a 实测判）**：

- **`SoC+C4a ≤ 预算`：`DRM 93.5 ≤ 415` ✓**（23%，余量 321.5 DRM ≈ 77%）。**★ S5 的 DRM 预算满足。**
- **`APM` = 72%（`532/740`）**、**`LUT` = 68%（`107,401/159,800`）** —— 均在器件内，但属**高占用档**，供 C4b 参考。
- **`CLMA` 余量**：`dev_map` 的 `Device Utilization Summary` **不含** CLMA/CLMS ⇒ 只能由 **PnR** 取（C3 口径 90% 余量薄）。
  C4a 改了 RTL ⇒ **必须重跑 PnR**；**`pnr_c4a` 由控制器在飞**，其 `report_timing` 结论**单独记 §6**（本步不判）。
- **`Adm-4088 = 0` ✓**（`grep -cE "Adm-4088" y1/pds/devmap_c4a.log` = `0`）—— 但**不等于**零 LUTRAM，见 §5.4。
- **完成标记**：`Y1_C4A_INTEGRATED_DEVMAP_DONE` ✓（log `y1/pds/devmap_c4a.log`，`=== dev_map DONE ===`）。

### 5.2 `PartialSumBuf` 真落 DRM 的三样证据 —— **C4a 实测**

| 证据 | 期望 | **实测** |
|:--|:--|:--|
| `DRM` 用量增长 ≥ 部分和缓冲理论值（`C_out×8 B`，RAM 结构） | 增长 | **`+61`**（`32.5 → 93.5`）—— 方向与 `PartialSumBuf` 落 **block RAM** 一致（结构侧见下） |
| `Mapping Summary` 的 `Total DRMs`（与 Summary 交叉印证） | 一致 | **一致**：Summary 的 `DRM 93.5` == `Mapping Summary` 的 `Total DRMs = 93.5 of 415 (22.53%)` |
| `Adm-4088`（LUT 当 DRAM 的推断告警） | `= 0` | **`= 0`**（`grep -cE "Adm-4088"` = `0`）；★ 该告警为 0 **不代表**无 LUTRAM —— `LUTs as dram = 10,855`（见 §5.4） |

> 结构侧证据（**本步已在仿真里给出**）：`gen/MultiPassUnit.v` 里 `PartialSumBuf` 是**一条 `Mem`**
> `reg [511:0] mem [0:255];`（= `C_out` 行 × 8 B 的字 × `NCOB*PIXMAX` 个字 = 131072 bit，**不在 FF 里**）+
> **同步读** `mem_spinal_port1 <= mem[rd_addr];` + 写侧地址译码 `mem[wr_addr] <= wr_word;`。
> 这是 block RAM 的标准形态（`run_multipass_ab.sh` 判据 8 断言"恰好一个存储阵列、无组合读"）。

### 5.3 两个可选补充探针（同 tcl、无板级约束）—— **本步未跑**

| 模式（`YESHENMINI_C4A_MODE`） | 用途 | 日志 | 结果 |
|:--|:--|:--|:--|
| `nputop` | 独立 `NpuTop`（把 NPU 增量从板级常量里分离） | `y1/pds/devmap_c4a_nputop.log` | **未跑**（无日志，非本步范围） |
| `layersched` | C4a 核心（`LayerSched`，避开权重口常量折叠；裸探针 IO 超限属预期） | `y1/pds/devmap_c4a_layersched.log` | **未跑**（无日志，非本步范围） |

> **注（CLMA 的来源）**：`dev_map` 的 `Device Utilization Summary` 只印 APM/FF/LUT/Distributed RAM/DRM/IO …
> **不含** CLMA/CLMS；CLMA/CLMS 的用量取**综合/布局的 `Mapping Summary`/PnR 报告**（C3 的 CLMA 口径
> 见 `y1/reports/c3_pnr_timing.md` R3：`27,142/30,075 ≈ 90%` —— 余量薄，**换了 RTL 必须重跑 PnR**）。

### 5.4 **面积观察（诚实标注）**：DRM `+61` vs Distributed RAM `+9,088` —— 宽层趟 RAM / bias 表疑落 **LUTRAM**

- **实测（measured）**：`DRM +61`（`32.5 → 93.5`，与 `PartialSumBuf` 落 **block RAM** 一致）；
  **`Distributed RAM`（`LUTs as dram`）`+9,088`**（`1,767 → 10,855`）。两者**同时**增长。
- **推断（inferred，非实测）**：C4a.5a 的**单元闸门只证** `PartialSumBuf` **自身**是 block-RAM 结构化
  （`gen/MultiPassUnit.v` 里 `PartialSumBuf` 是一条 `Mem`，见 §5.2 结构证据）；**未证** C4a.5b 新增的
  **宽层趟 RAM（~36 KB）** 与 **bias/param 查表（~16 KB）** 的存储结构 —— 这 ~52 KB 的增量**很可能落到了
  LUTRAM**（`LUTs as dram` 增 `9,088` ≈ 该量级），而非 block RAM。
- **待办（C4b / follow-up 的开放面积项）**：把上述两个候选缓冲（**宽层趟 RAM ~36 KB**、**bias/param 表 ~16 KB**）
  在 RTL 里显式钉成 block RAM（`Mem` 形态 + 同步读），并把判据从单看 `Adm-4088 = 0` 升级为
  **"`Adm-4088` = 0 **且** `LUTs as dram` 增量 ≈ 0"** 的双判据。
- **不越界**：本观察**不推测**具体哪一级推断失败、**不结论**是否影响时序；**且不违反**已述的 DRM 预算
  （`DRM 93.5 ≤ 415` ✓）。上表中"实测"列为 dev_map 实测，"推断"列如实标注为推断。

---

## 6) PnR（**不在本步范围**，控制器跑）

`y1/pds/pnr_c4a.tcl`（基于 `y1/pds/pnr_soc_npu.tcl`，源清单/器件行/策略/环境变量**逐行相同**，只换
工程 tag `c4a` 与结束标记 `YESHENMINI_PNR_C4A_DONE`）。判据：`report_timing` 的 `All Constraints Met` +
`Performance Summary`、比特流存在、结束标记。**本步不跑**（控制器做）。

**状态（2026-10-11）**：`pnr_c4a` 已由**控制器在飞**（`y1/pds/pnr_c4a.log` 进行中，尚未见 `YESHENMINI_PNR_C4A_DONE`）；
其 **timing / CLMA 结论**将**单独记入本节**（本节先只记状态，不改判）。

---

## 7) 全非 PDS 回归（本步实跑）

### 7.1 15 个单元闸门（核心集，同 C3 `c3_scheduler.md` §2.1 的台账）

```
run_ddrmaster32_ab=0   run_desc_ab=0       run_fusionbuf_ab=0   run_bypass_ab=0
run_unitexec_ab=0      run_fuse_head_ab=0  run_fuse_ab=0        run_chain_ab=0
run_sched_ab=0         run_nputop_ab=0     run_nputop_sched_ab=0 run_hostregs_ab=0
run_ddrcopy_ab=0       run_ddrread_ab=0    run_ddrwrite_ab=0
```
（15/15 `exit 0`，每道 `RESULT: PASS`。）

### 7.2 C4a 新增闸门（8 道，本步实跑）

```
run_quant_ab=0        run_quant_ref=0      run_convert_ab=0     run_tiling_ab=0
run_multipass_ab=0    run_dw_ab=0          run_layout_ab=0      run_unitexec_wide_ab=0
```
（8/8 `exit 0`，每道 `RESULT: PASS`；`run_quant_ref` 打印 `ORT 偏差 = 已逐层记录（记录，非判据）`。）

### 7.3 台账 + 结构 + 无 Xilinx 残留

```
python scripts/check_addr_map.py                -> PASS: address ledger consistent (16 sites reconciled)  exit 0
python y1/tools/check_dangling.py y1/gen/NpuTop.v        -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/LayerSched.v    -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/UnitExec.v      -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/MultiPassUnit.v -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/DwUnit.v        -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v    -> RESULT: PASS  exit 0
```

**台账站点数 = 16**（`16 sites reconciled`，与 C3 同口径，未变）。

> ★ 只读纪律：`third_party/**` 与冻结 Python 工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/
> `mac_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）本步**一字未动**。

---

## 8) C4a 到此**能证什么 / 不能证什么**

### 8.1 能证（本步 + C4a.1–C4a.7 的仿真证据）

- **真模型被吃进表**：`yunet.onnx` → 描述符表 + 权重 blob（G1 三态覆盖 82/24/0，与 C3 冻结表逐项对账）。
- **同口径整网**：`quant_ref` 与第二实现逐点一致、负对照有牙、退化守卫在线（黄金可信）。
- **多趟累加正确**：13 种宽 `(C_in,C_out)` 的 RTL 多趟 == 整层黄金，**逐字节 `MISMATCH=0`**（含跨 `ci` 趟
  片上累加、末趟唯一 requant）。
- **depthwise 正确**：真表 5 种 `C ∈ {4,10,16,32,64}` 的对角趟 == 通用趟，**逐字节 `MISMATCH=0`**。
- **宽层通路（`UnitExec` 级）正确**：真层 `Conv_0` + 合成 16→16，`MISMATCH=0`（三处缺陷已修 + 受控实验）。
- **布局折进**：18 个位置折进 `(src_stride, src_order)` == 显式参考（逐字节），且搬运 **不增**（折进 0 B vs
  不折进 537,600 B）。
- **偏差被如实记录**：与 float ORT 逐层 `max|ours − ORT|` **已落 JSON**（§4）——**记录**，供 C4b 裁决。

### 8.2 **不能**证（**本步不证**，指向 C4b / 控制器）

| 不证什么 | 为什么 | 谁证 |
|:--|:--|:--|
| **整帧端到端精度** | §4 只是**逐层记录**，无"整帧输出对 ORT 的容差"判据 | **C4b / G7** |
| **fps / 吞吐** | 本步无时序/带宽实测（PnR 与帧级计时都不在本步） | **C4b**（+ 控制器 PnR） |
| **上板** | 本步**不跑 PDS、不出比特流、不碰板**（`dev_map`/PnR 由控制器跑） | **C4b** |
| **权重从 DDR 搬** | 描述符无权重指针；转换器给了 `wgt_index.json` 的装载接口，硬件搬运未做 | **C4b / G6** |
| **面积/时序达标** | §5 面积已回填（**`DRM 93.5 ≤ 415` ✓**），但**时序 / CLMA 余量**待 PnR（`pnr_c4a` 在飞，§6） | 控制器 PnR |

---

## 9) 文件 + 指纹（本步新增）

| 文件 | 字节 | md5 |
|:--|--:|:--|
| `y1/pds/devmap_c4a.tcl` | 11624 | `0d7749078d7b384a1f50e9d62b8648aa` |
| `y1/pds/pnr_c4a.tcl` | 9039 | `e414e74ae31412d6ca06d765c30fadc5` |
| `y1/reports/c4a_multipass.md` | （见提交） | （见提交） |

**相关网表指纹（本轮 HEAD，供对照）**：

| 网表 | md5 |
|:--|:--|
| `y1/gen/NpuTop.v` | `e9a4f721c7c4d40cd86443f0a282e8de` |
| `y1/gen/LayerSched.v` | `6f6b9ce9c3ae728d53325d3260b7f92c` |
| `y1/gen/UnitExec.v` | `9e6453f20bfd017a0b52bb974c4175bb` |
| `y1/gen/MultiPassUnit.v` | `2578dc51d95fcaac77e560cda34e2121` |
| `y1/gen/DwUnit.v` | `2578dc51d95fcaac77e560cda34e2121`（== `MultiPassUnit.v`，只换 pass 调度） |

**两 tcl 的语法检查**：Tcl `info complete` = `1`（花括号/引号平衡，逐字已核）。

---

## 10) 自查记录（findings / concerns / 假设）

1. **两处诚实标注（面积）**：① §5 的数字**已按控制器 `dev_map` 回填**（**`DRM 93.5 ≤ 415` ✓**），但
   **CLMA/CLMS 不在 `dev_map` 的 `Device Utilization Summary` 里**（只有 APM/FF/LUT/Distributed RAM/DRM/IO），
   其读数来源（PnR/综合报告）已在 §5.1/§5.3 注明，`pnr_c4a` 在飞；② **`Distributed RAM +9,088`** 的 LUTRAM
   观察已**如实记入 §5.4**（宽层趟 RAM ~36 KB + bias/param 表 ~16 KB 疑落 LUTRAM），标为 **C4b / follow-up 的
   开放面积项**（**不越界结论、不违反 DRM 预算**）。
2. **一处诚实标注（偏差）**：§4 明确是 **RECORD 不是 JUDGMENT** —— 8-bit per-tensor PTQ 的 9–29% 是预期
   代价，够不够由 **C4b/G7** 整帧容差裁决。
3. **输入假设**：ORT 偏差用**合成图**（`seed=20261010`）；真图/校准代表性属 **C4b/G7**。
4. **触发重跑 PnR 的条件（提醒控制器）**：C4a 相对 C3 改了 RTL（`UnitExec` 宽层通路 + `MultiPassUnit` +
   `PartialSumBuf` + `Conv3x3Slice` 新口 + `LineBuffer.pad_val`）⇒ **C3 的 CLMA ~90% 余量薄，必须重跑 PnR**
   （`y1/pds/pnr_c4a.tcl`）并确认 `All Constraints Met`；这一步**不在本任务范围**。
5. **不做**：本步不跑 PDS、不碰 `third_party/**`、不改冻结 Python 工具、不 push。
   §5 数字**由控制器 `dev_map`（`y1/pds/devmap_c4a.log`）回填**，非本步自行测数；PnR 亦由控制器在飞。
