# 小 spec：**运行期行宽 + 2-D tile 调度**（让真帧装进 PG2L200H）

- 日期：2026-10-13
- 上游：`docs/superpowers/specs/2026-10-09-y1-c3-scheduler-design.md`、`2026-10-10-y1-c4-converter-and-coverage-design.md`
- 动因（实测，`y1/reports/c4b_frame.md` §9）：真帧 640×640 一次过**装不下器件**（行宽类存储 ≈**3.25 MB** > 器件 **1.87 MB / 415 DRM**，
  `Adm-4088 ×418`）；且 `inWOk` 对 `s=1` 层退化为 `IMG_W == WIDTH` ⇒ **一张网表只服务一个输入行宽**，
  而真表有 `{640,320,160,80,40,20}` 六个行宽 ⇒ **单张网表永远跑不完这条链**。
- 状态：**待审阅**（§4 待裁决项给了推荐值）

## 1. 目标与范围

**做什么**：① **运行期可变行宽 `rowW`**（寻址用运行值、分配按 `W_MAX`）——解"一张网表只一个行宽"；
② **2-D tile 调度（64×32）**——把行宽类存储压到装得下。两者**缺一不可**。

**不是什么**：不改描述符**格式**（内部 tiling 与 `IMG_W/H` 正交）；不做帧率（C5）；不做相机（Y5）。

## 2. 现状（实测事实，带出处）

| 结构 | RTL | 字节 | 随什么放大 |
|---|---|---|---|
| `PartialSumBuf.mem` | `PartialSumBuf.scala:68-70` | `512·P` | **W×H** |
| `wOutMem` | `UnitExec.scala:1248` | `64·P` | W×H |
| `outMem`+`outMemT` | `UnitExec.scala:511-512,1117,1133` | `16·P` | W×H |
| `BypassExec.outMem` | `BypassExec.scala:484` | `8·P` | W×H |
| `FusionBuf`×9 | `FusionBuf.scala:144` | `9·24·W` | **W only** |
| `wRam`/`mzRam`/`biasMem`/`layoutMem` | `UnitExec.scala:725,728,767`；`LayerSched.scala:511` | ≈54 KB | 都不随 |
| `LineBuffer` hist ×8（FF）/ `MaxPoolUnit.accRow` / `ResizeUnit.rb`（FF） | `LineBuffer.scala:74` 等 | 随 W（**FF，非 DRAM**） | W |

（`P = W×H`；`W_MAX` = 物理行宽；器件 415×DRM36K ≈ 1.87 MB。）
**记账更正**：`c4b_frame.md` 的 `outMem` 对是 **80 KB**（`2·8·5120`），不是 40 KB；真总占用 ≈**3.25 MB**。

## 3. 方案（含推荐）

| 方案 | 数字 | 判 |
|---|---|---|
| (A) 只做**列条带** | 层 0（H=320）要 `PartialSumBuf ≤ 1 MB` ⇒ `W_s ≤ 6` | **死** |
| (B) **行条带**（满宽 640、少行） | `H_t=3` ⇒ 总 **1.34 MB 装得下**，但竖向 halo 重读 ⇒ **12.58→18.09 MB/帧（+44%）** | **流量致命**（每个 `ci` 趟重流输入，halo 每边界重取） |
| **(C) 2-D tile 64×32（推荐）** | 总 **1.29 MB（留 0.43 MB）**；halo `2244/2048=1.0957` ⇒ **+0.79 MB ⇒ 13.37 MB/帧（+6.3%）**，20.6 ms@275.9 MB/s（预算 27.59 MB，**2× 余量**） | **取** |
| (D) 加宽 `rowW` 之外再"每层一张网表" | 6 张网表、6× PnR/验收，且**仍不能 tile** | 否 |

**推荐 (C) + 运行期 `rowW`**：tiling 落在 `UnitExec`/`BypassExec` **内部**（描述符冻结）。
**halo 只对"有 halo 的算子"付**：67 项里**只有 27 项**（`desc.bin` idx 0,2,5,7,9,11,14,16,19,21,24,26,28,32,36,38,40,42,44,46,48,50,52,54,56,58,60）有 halo。

### 3.1 `inWOk` 的修法（recommended，最小结构改动）

`UnitExec.scala:704-706` 从**编译期等式**改成**运行期界限**：`inWMax`（= `IMG_W·s`，`:703` 已算出）
**闩存为 `rowW`**（在 `go` 拍），断言 `1 ≤ rowW ≤ W_MAX`；此后**所有用于计数/寻址的编译期 `WIDTH` 换成 `rowW`**，
**分配仍按 `W_MAX`**：`LineBuffer` 列回绕与 hist 深度（`:74,79-81`）、`Conv3x3Slice` 的 `cw`/`colLast`/幻影列
（`:261,522,536-545`）、`FusionBuf` 行槽步长（`row_ptr*rowW + col`）、`UnitExec` 的 `cw`/`inPix`/喂流/gather
（`:1197,1252-1256,1308-1362`）、`MaxPoolUnit:67,98`、`ResizeUnit:103`、以及 `BypassExec.scala:263` 的第二处钉子
（`inW32 === WIDTH`——Sigmoid 头 `IMG_W=6400` 也要它）。

## 4. 待裁决项（给了推荐值）

1. **tile 尺寸**：推荐 **64×32**（`P=2048`）；余量紧时可换 32 位部分和（`PartialSumBuf` 减半，代价=重证 C4a 部分和闸门）。
2. **halo 的取法**：推荐**行跨步窗口读**（`w+2` 列、pitch `IMG_W·C`）——**这是新 RTL**（今天的 gather 走线性平面，`UnitExec.scala:1300-1362`）。
   备选"tile-major/复制 halo 布局"要多一次整读写（≈16.5 MB）⇒ **否**。
3. **描述符**：推荐**冻结**（内部 tiling）；若走"每 tile 一条描述符"则 `IMG_W/H` 语义变 ⇒ spec 修订 + 破 `c4a_coverage.md:252` 的几何断言 ⇒ **否**。
4. **tile 尺寸来源**：推荐编译期 `W_MAX/H_TILE`（先不做运行期 tile CSR）。

## 5. 判据（T0–T4，每条都要**正负对照**）

- **T0（离线，零 RTL）**：`tiling_ref.py` 扩展为 **"tile+halo == 整层"** 逐字节（把 halo 规则钉死）。**负对照**：不给 halo ⇒ 必红（接缝）。
- **T1（`rowW`）**：一张网表**重放 `desc.bin` 的 6 个行宽**全部逐字节对黄金；**负对照**：把 `rowW` 钉死成 640 ⇒ 非 640 的层必红。
- **T2（tile 循环 + `W_MAX=66`）**：整层 tile 拼接 == 整层；`dev_map` **零 `Adm-4088`**；**负对照**：tile 循环漏一趟 ⇒ 必红。
- **T3（回归）**：15 单元闸门中**必须重证的 9 个**（`bypass/unitexec/fuse_head/fuse/chain/sched/nputop/nputop_sched/fusionbuf`）+ `unitexec_wide/stride_exec/wgtdma_geom/wide` + 台账 + dangling + dup；**PnR `All Constraints Met`**。
- **T4（板级）**：重烧 + `npu_frame_run.py --run` → 12 路输出 + **G7 容差**（IoU ≥0.5 / 关键点 L2 ≤2px / |Δconf| ≤0.1 / 检出数差 ≤1）。

## 6. 风险

| # | 风险 | 处置 |
|---|---|---|
| R1 | `UnitExec` 的 gather/FSM 大改 ⇒ 回归面大 | T3 的 9 闸门**先跑给基线**，逐段改、逐段回归 |
| R2 | halo 跨 tile 边界错一拍 ⇒ 接缝 | **T0 离线先钉死 halo 规则**（零 RTL）+ T2 的"漏一趟"负对照 |
| R3 | `Add`（`SRC2`）的第二源在 tile 下是否可寻址 **未证** | **S1 之前先查/先证**；证不了就为该算子保留整层路径并记账 |
| R4 | 1.29 MB 仍超 | 32 位部分和（减半）或更小 tile（32×32）；**以 `dev_map` 为准** |
| R5 | 面积/时序（C3 CLMA 曾 ~90%） | 每段 `dev_map` + PnR 记账 |

## 7. 分段（staged，最小步先出真帧）

- **S0（离线）**：`tiling_ref.py` 证 "tile+halo == 整层"（**零 RTL**，钉 halo 规则）。
- **S1（只加 `rowW`，`W_MAX=640`）**：一张网表重放 `desc.bin` ⇒ **第一次"仿真真帧"**（无面积收益，但把链走通）。
- **S2（`W_MAX=66` + `H_TILE=32` + tile 循环）**：`dev_map` 归零 `Adm-4088`。
- **S3（PnR → 板 → 12 路 + G7）**。
