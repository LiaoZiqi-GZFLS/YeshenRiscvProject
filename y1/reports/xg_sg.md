# XG-SG：非 tile 宽 gather（head 层 / `Conv_0`）改 SG 批式

状态：**已实施、闸门绿、PnR/上板待判（2026-10-25，tag `xgsg`）**。

## 1. 病根（逐单元表 + RTL 对照，不是猜）

60 MHz 逐单元表（`unit_trace_60b.txt`）里 **`Conv_0` 独占 150.8 ms = 帧的 11.1%**，而且它的
**每像素·趟成本是同类 conv3x3 的 4.4 倍**（736 vs 165 ns/pp）。

RTL 对照给出唯一解释：`Conv_0` 是 head 层 ⇒ `tilingWideC` 里的 `!isHead` 把它挡在 tile 之外
⇒ 走 `xg` 组 gather（`UnitExec.scala` 的 `xgSt/xgK`）。那条路是：

```
when(xgK === False) { when(!ddrMaster.io.busy) { xgK := True } }   // 本拍举 start
... 收 4 拍 ... done ⇒ 换下一个平面（xgAddrR += inPix）
```

**严格 1 笔在飞**，而组内各笔是**同一 32 px 组的 8/3 个不同平面**（跨平面 = DDR 冷页散读）。
算式对得上：`Conv_0` 每组 `Npl=3` 笔，组 = 32 px ⇒ 3/32 笔/px；实测 44 拍/px ÷ 0.094 = **470 拍/笔**
—— 正是"1 笔在飞 + 冷页 LAT"的量级（`ddr_bridge_read_perf.md` 的 5.1 µs ≈ 306 拍）。

## 2. 改动

`xg` 的 FETCH 相位换成 SG 批式（与 `BypassExec` 的 B1'b 同构）：扫 `Npl` 个平面入队
（`sg_addr = 组基址 + k·inPix`，`sg_beatsM1=3`）→ 一拍 `start(mode=3)` → 按项序收 4 拍/项落
`xbuf(pl*4+b)` → `done` 回 DRAIN。`Npl ≤ 8`、`RQ=4` ⇒ 一组 = 2 波以内（原来是 `Npl` 个往返）。

- 编译期开关 `USE_XG_SG`（=true）；置 false 逐字回到旧路，便于 A/B。
- `rd_ready` / `start` / `mode` / `src` 全部按该开关二选一；SG 端口只在 `WIDERUN ∧ XDMA_EN ∧ !tilingW` 时占用。
- **顺带修的继承债**：`UnitExecWideTb.v` 里三行 `cyc_fetch/cyc_emit/...` 打印引用的是已移除的探针
  ⇒ 整个 wide/stride 闸门编不过。改成 `ifdef UE_PHASE` 包裹（默认不打）。

## 3. 闸门（先红后绿）

| 闸门 | 判据 | 结果 |
|---|---|---|
| `run_unitexec_wide_ab` | 逐字节 + pad/nobias 两个负对照 + 退化守卫 | **PASS** |
| `run_stride_exec_ab` | **真 `Conv_0` s=2** 逐字节；s=1 外科式必绿；忽略 STRIDE 的突变体必红并定位首个坏元素 | **PASS** |
| `run_nputop_sched_ab`（重生成 NpuTop 后） | 7 作业 + 非法表负对照 + 权重信箱 | **PASS** |
| `run_b1_tilebuf_ab` | tile 路回归（本改动不碰 tile）+ TILING=false 冻结 | 见 §3.1（重锚） |

## 4. 预期

`Conv_0` 的 fill 从 44 拍/px 降到 ~15（3 笔同批 ≈ 1 个 LAT）⇒ 该单元 150.8 → ~55–80 ms
⇒ 整帧 **−6~7.5%**（1,262 → ~1,170–1,185 ms）。板上判据：`y1run --frames 3` 12/12 ×3，整帧 ≥3% 才保留。

## 3.1 TILING=false 冻结锚的重锚（有等价性证据，不是"改锚点掩盖差异"）

`USE_XG_SG = TILING` ⇒ TILING=false 的构建里 `if (USE_XG_SG)` 走 **else 分支（旧路逐字保留）**。
但 SpinalHDL 的信号名里嵌**源码行号**（`_l<line>`），本次在文件中部插了 ~30 行 ⇒ 三份 TILING=false
网表 md5 必变。按本仓口径做**归一化 diff**（`s/_l[0-9]+//g; s/_zz[0-9]+/_zz/g`）：

```
$ diff <(norm pre/UnitExec.v) <(norm post/UnitExec.v)
2268a2269,2274
>   wire       [3:0]    xgSgScan;      … 6 根未用 wire
55171a55178,55183
>   assign xgSgScan = 4'b0000;         … 6 条常量赋值
```

**全部差异只有这 12 行新增常量**，既有网络**一行未改** ⇒ 判定"TILING=false 逻辑不变"，重锚到
`2a53bcd0 / fa688c59 / 90ffe8e5`（旧 `451102f3 / 0f549d2e / dbfc18db` 见 `run_b1` 注释）。
pre/post 两份网表留在 `y1/build/xgsg_pre|post/` 作证据。

## 5. 闸门覆盖的**已知缺口**（2026-10-25，烧板前记录）

XG-SG 改的是 `xg` 小 FSM（**宽路、非 tiled**）。本仓现有闸门**都没有**在 true 路径上跑它：

| 闸门 | 用的网表 | 走的 FSM | 覆盖 XG-SG？ |
|---|---|---|---|
| `run_b1_tilebuf_ab.sh`（conv15 / c64_40） | `UnitExec_tiled.v` | `+TILED_W` ⇒ `wx`（tiled） | ✗ |
| `run_tiling2d_*` / `run_wgtblob_tiled_ab.sh` | `UnitExec_tiled.v` | `wx` | ✗ |
| `run_inlayout_ab.sh`（XDMA + XLayout） | `gen/UnitExec.v`（TILING=false） | `xg`，但 `USE_XG_SG=false` 被编译掉 | ✗ |

原因：`xg` 只在 **wide ∧ head**（真表 = `Conv_0`，s=2、C_in=3）时生效，而现有 XDMA 闸门
（`XLayoutTb`）跑的是非 head 的宽层；head 档没有 DDR 影像/黄金。

**处置**：本片以**上板 12/12 CRC**作为该路径的真输入判据（`Conv_0` 的输出 CRC 就是逐字节对账，
且用的是真帧 640×640×3），并在报告里显式标注"单元级无覆盖"。
若本轮板上 CRC 红 ⇒ 先怀疑 XG-SG，回退即恢复（`USE_XG_SG := false` 一行）。
补闸门（head + XDMA 的单元作业）列入下一片，不作为本片的保留前提。

## 6. 判决（2026-10-25）：XG-SG 在产品网表里**不可达**，PnR 已停

用三条独立证据定位：

1. **真表没有 head 层**：`gen/wgt_index.json` 里 68 个单元 **没有一个** `flags.bit0 == 0`
   （`DescDefs.head = flags(OUT_TO_DDR)==False`）⇒ `isHead` 全 0，`Conv_0` 也是 `plain`。
2. **`tilingWideC` 对 `Conv_0` 成立**（isWide ∧ chainLen==1 ∧ !isHead ∧ s=2 ∧ …）⇒ `tilingW=1`
   ⇒ 它走 `wx`（tiled gather），而 `xg` 整块被 `!tilingW` 门掉（`UnitExec.scala:2364`）。
3. **产品网表根本跑不了 head/非 tiled 宽层**：用 `XLayoutTb` 的 head 档（`+FLAGS=0`）跑
   `gen/UnitExec_tiled.v`，`go` 那拍就 `err=1`、`ar=0`（`W_MAX` 只有 tile 宽度，整层行宽放不下）。
   这是"产品档没有 head 层"的**装置级反证**。

⇒ `USE_XG_SG` 置 **false**（一行），把这段硬件从网表里拿掉；`xg` 的旧路逐字保留。
`xgsg` 的 PnR 在 seed_0 布局阶段**主动终止**（避免白白占一个窗口）：它不可能改变板级行为。

### 6.1 那 `Conv_0` 的 150.8 ms 是什么？

它是 tiled 的，问题在**批的项数**：`C_in=3 ⇒ Npl=3`，一个 SG 批只有 3 项（96 B），
而 s=2 的窗口 34 列 ⇒ **每行 2 个 band = 2 个批** ⇒ 每行 2 个 LAT。

账：320×320 输出、tile 宽 16 ⇒ 20×10=200 tile；每 tile 4·(th+2)=66 行 ⇒ 13,200 行；
13,200 × 2 × 5.12 µs（LAT=640 @125 MHz）= **135 ms**（实测 150.8，含 drain/边界）。
对照：dw 层 Npl=8 ⇒ 8 项/批 ⇒ 实测贴 24.2 MB/s 的 1.07×。

⇒ 下一片（G4）：**Npl ≤ 4 时把同一行的两个 band 装进同一个 SG 批**（3 平面 × 2 band = 6 项 ≤ 8），
每行从 2 个 LAT 降到 1 个 ⇒ `Conv_0` 150.8 → ~75–85 ms ⇒ 整帧 **−5~6%**。
地址仍是纯加法（band2 = `wxPBB(p) + 32`）。
