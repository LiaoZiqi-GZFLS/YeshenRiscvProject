# y1 C4b-B4 报告 —— **conv（通道平面）↔ 旁路（NHWC）布局适配**（消费者侧 strided read）

**Status: DONE（2026-10-13）**：B3 冻结的"激活张量是**通道平面**（NCHW）"与旁路单元的"自然流是 NHWC"
（一拍一列 = 一个像素的 C 个通道）之间的**那一步**，改为在**旁路消费者侧**做（读侧按步长 gather、
写侧按平面散射）。新闸门 `y1/tools/run_layoutadapt_ab.sh` **GREEN**（`RESULT: PASS` / `exit 0`）：
**conv→bypass 与 bypass→conv 两向逐字节**（`COL_MISMATCH=0` 且 `DST_MISMATCH=0`），
**负对照实跑发火**并把**首个坏列**定出来（`COL_FIRST_BAD=0`），且这一刀是**外科式的**（同一突变体在
模式 0 档仍绿）。**描述符格式 / 寄存器契约 / 既有闸门黄金一字未改**。

- 计划：`docs/superpowers/plans/2026-10-11-y1-c4b-weight-dma-and-whole-frame.md` **Task B4**（条件任务）。
- 冻结契约：`y1/reports/c4b_input_layout.md`（B3, `0c47250`）§1.1（通道平面）+ §1.5-2（旁路是 NHWC，
  点名 B4）；`y1/rtl/BypassExec.scala` 文件头 "C4b-B4" 一节。
- H1 折进（`9a14e84`）修的是 **`SRC_ADDR` 折到生产者 `DST`**（连续读那一半）；**strided（按步长）
  那一半就是本任务**。

---

## 1) 谁适配 / 怎么适配（冻结口径）

冻结契约下，DDK 上激活的字节偏移是 `off(c,p) = c*HW + p`（`HW` = 本张量的像素数、`p = y*W+x`），
而四个旁路单元要的是 NHWC（**第 `p` 列 = `(x[0][p], …, x[C-1][p])`**）。**适配发生在旁路消费者侧**：

| 场景 | 生产者 | 消费者 | 适配动作 | 开关 |
|:--|:--|:--|:--|:--|
| **conv→bypass** | conv（写平面） | 旁路单元 | **读侧 gather**：RD 通路按步长 `HW` 取数（32 像素一组、逐平面一笔 32 B RD、转置缓冲、逐列吐） | `src_planar=1`（`+SPLANAR`） |
| **bypass→conv** | 旁路单元 | 下一个 conv（宽通路读平面） | **写侧散射**：WR 通路的列流按**平面**写（每平面一笔 WR 事务、逐拍发 8 像素的第 `c` 道） | `dst_planar=1`（`+DPLANAR`） |
| conv→conv / bypass→bypass | — | — | **不进本档**（前者从不进本模块；后者两位都是 0 ⇒ 线性 NHWC 逐字节不变） | 两位 = 0 |

- **开关投递（不改描述符 / 不改寄存器契约）**：**每层两位**，由 `LayerSched` 从**既有权重信箱的区域 7
  道 2**（`WGT_ADDR[23:20]=0x7`、`WGT_ADDR[15:8]=LAYER_ID`、`WGT_ADDR[1:0]=2`）按 `LAYER_ID` 索引后
  送到 `BypassExec.io.src_planar/dst_planar`（与 B2 的 `M/z_pad/bias_adj`、B3 的 `XDMA_EN` 同一手法）。
  **上电值 0** ⇒ 默认 = C3/C4a 的线性 NHWC ⇒ 既有闸门逐字节不变。
- **只搬字节**：四个单元的端口/数值通路、`outMem`「一字 = 一个像素的 C 个通道」的口径一字未改；
  转置缓冲 `pgBuf`/`woBuf` 只做字节重排，**没有第二条算术路径**；地址只用移位与加法（无乘法器）。
- **几何前提（`go` 那一刻响亮 err，绝不静默读错）**：`inCols % 32 == 0`、`outPix % 32 == 0`、
  且非 Add（Add 两路列交织、布局可不同 ⇒ 本代不支持，响亮 err）。

---

## 2) 参考的 bug + 修复（`tools/layout_adapt_ref.py`）

**Bug**：条带（`--img-h` 覆盖）分支往描述符 `w1` 里打包 `IMG_W/IMG_H` 时**打包反了**。契约
（`rtl/DescDefs.scala:93-95`）= `w1[15:0] = IMG_W`、`w1[31:16] = IMG_H`。反打包会让 DUT 把
输入几何算成 `2·IMG_H × 2·IMG_W`（行列对调）⇒ 平面步长 `HW` 与参考不一致。

**为什么全尺寸档（`IMG=40×40`）没暴露它**：`MaxPool_25` 的 `IMG_W == IMG_H == 40` ⇒ **打包对称**，
反不反一个样。条带档（`IMG=40×8`）**不对称**才把它抓出来。

**修复**（现盘已落）：
```python
words[1] = ((img_h & 0xFFFF) << 16) | (img_w & 0xFFFF)   # w1 = [15:0]IMG_W [31:16]IMG_H
```
**验证**：条带档 `job.json` 的 `desc[1] = 0x00080028` ⇒ 低 16 位 = `40`（IMG_W）、高 16 位 = `8`（IMG_H），
与 DUT 的 `imgW=w1[15:0] / imgH=w1[31:16]` **逐位一致**。

---

## 3) 正对照：conv↔bypass **逐字节**（真表几何）

供料 `tools/layout_adapt_ref.py` **消费真表**（`gen/wgt_index.json` + `gen/desc.bin` 的 `MaxPool_25`
= `idx 17`）：`IMG_W/IMG_H`（输出几何）**逐字来自描述符**，`C_IN/C_OUT` 投影到本代旁路档位 `C=8`
（一个通道块），`SRC/DST` 重定位进仿真镜像（几何口径不受影响）。装置 `LayoutAdaptTb` 只把那张**平面
张量**写进内存镜像，其余全由 DUT 自己搬。

| 用例 | 真表几何 | 网表 | `COL_MISMATCH` | `DST_MISMATCH` | 结果 |
|:--|:--|:--|:--|:--|:--|
| **A（全尺寸）** | `IMG 40×40`（IN 80×80，NPIX=6400，OUTPIX=1600） | `gen/BypassExec.v`（C=8 W=80 HMAX=40） | **0**（6400/6400 列） | **0** | **PASS** |
| **B（条带）** | `IMG 40×8`（IN 80×16，NPIX=1280，OUTPIX=320） | 同上 | **0**（1280/1280 列） | **0** | **PASS** |

- **conv→bypass**：`+SPLANAR=1` ⇒ DUT 从**平面**张量 gather 出列流；判据 = **被单元收下的每一列**
  （8 个通道字节）逐字节 == 参考的 `colb.hex`（`p` 行 = 第 `p` 个像素的 8 个通道）。
- **bypass→conv**：`+DPLANAR=1` ⇒ DUT 主口**真实写出的字节**（独立观察路径：按 `awaddr+8·beat` 重建）
  在 `DST` 区按**平面序** == `goldb.hex`。⇒ 两个交接面的字节两边都验过。
- **回归锚（模式 0 = 今天的线性 NHWC）**：同一几何、源按 NHWC 摆、`+SPLANAR=0 +DPLANAR=0` ⇒
  `DST_MISMATCH=0` 且**列流逐字节相同** ⇒ 本片是**加法**。
- **真表交接面**（闸门 §8）：`HANDOFF MaxPool_25 DST=0x018a8000 -> Conv_26 SRC=0x018a8000 **SAME**`
  （4 个 `MaxPool→Conv` 对全部 `SAME`）⇒ 旁路写出的那张平面，正是下游 conv 读的源。

---

## 4) 负对照（**必须发火**，且是外科式的）

外科式**网表突变**（scratch 拷贝，绝不动 `gen/`）：把 gather 的**平面步长丢掉**（改成连续读）

```
- pgAddrR <= (pgAddrR + inColsR);     // 正确：下一平面 = +H*W
+ pgAddrR <= (pgAddrR + 32'd32);      // MUT：连续读（步长失效）
```

| 打在哪个用例 | 期望 | 实测 |
|:--|:--|:--|
| B + 突变体（`+SPLANAR=1` 平面档） | **RED** | `COL_MISMATCH=8960`、`COL_FIRST_BAD=0`、`DST_MISMATCH=2239`、`DST_FIRST_BAD=320` ⇒ **FAIL（首坏列 0）** ✓ |
| B + **同一突变体**（模式 0 档） | **GREEN**（不走 gather） | `DST_MISMATCH=0` / **PASS** ✓ **外科式** |

⇒ 判据确实抓"按步长取数"，且突变**只**切掉 gather 的步长、其余通路一字未动（= "模式 0 逐字节不变"的
反面对照）。供料 `--selftest` 另有"**负对照不可能是橡皮章**"的守卫（源非常数 / 列流 != 连续读预测 /
黄金 != 负对照黄金，三条断言在 4 组几何上全过）。

**H1 的 `SRC` 自洽**（本任务第三条 DoD）：闸门 §7 重跑 `tools/run_convert_ab.sh` ⇒
`SRC_WRITTEN ok=1 checked=67 offenders=0`、该闸门整体 `RESULT: PASS` ⇒ **本片没有动描述符/地址折进**。

---

## 5) 回归 / 确定性 / 结构判据

**闸门尾巴**（`bash y1/tools/run_layoutadapt_ab.sh`）：
```
LADAPT_SELFTEST cases=4 fails=0
---- [3] 正对照 A/B：COL_MISMATCH=0 DST_MISMATCH=0  … RESULT: PASS
---- [4] 回归锚 模式0：DST_MISMATCH=0 … RESULT: PASS
---- [5] 负对照：MUT 「+inColsR -> +32」⇒ B 平面档 COL_MISMATCH=8960 COL_FIRST_BAD=0 FAIL；模式0 仍 PASS
---- [6] total dangling instances: 0  |  DETERMINISM_2X_OK md5(gen/BypassExec.v)=a53f6e5d47419e811d7d98a5940d1d0a
---- [7] SRC_WRITTEN ok=1 checked=67 offenders=0  RESULT: PASS
RESULT: PASS
```

**既有闸门（全绿）+ 台账 + 悬空**：`y1/tools/run_*_ab.sh`（42 个）**41 绿**（`RESULT: PASS` 或
`JUDGE-GREEN` / `exit 0`）；唯一 **`run_numeric_ab.sh` rc=1** 是**带参探针**（`<mode> <cin> <cout> <H> <W>
<seed>`），无参跑报 `usage` 属**预期**（与 B3 报告同口径）。`scripts/check_addr_map.py` ⇒
`PASS: address ledger consistent (16 sites reconciled)`；`check_dangling.py` 对 `gen/*.v`（36 份）**全 PASS**
（0 悬空实例）。

**网表确定性 2×**（B4 触及 `BypassExec.scala` / `LayerSched.scala` ⇒ 受影响网表重生成两次）：

| 网表 | md5 |
|:--|:--|
| `gen/BypassExec.v` | `a53f6e5d47419e811d7d98a5940d1d0a` |
| `gen/LayerSched.v` | `acc0393e235074a25fa7aaf212a009e5` |
| `gen/NpuTop.v` | `900dee8bc4d161d97228db08a3ca9c08` |

两次生成**逐字节相同**（`DETERMINISM_2X_OK`）。`gen/` 在 `.gitignore` 里、**不入库**。

---

## 6) 交付物 + 指纹

| 文件 | md5 | 说明 |
|:--|:--|:--|
| `y1/rtl/BypassExec.scala` | `1669796ee79e2195229c3d5890925d4b` | **改**：`src_planar/dst_planar` 两条线 + 读侧 gather 子 FSM + 写侧散射子 FSM + `col_dbg/col_dbg_ok` 观察口 |
| `y1/rtl/LayerSched.scala` | `452109a02388ab4dbeff5bc88efd0193` | **改**：布局模式表（信箱区域 7 道 2、按 `LAYER_ID` 索引）+ 扇出两根线 |
| `y1/rtl_test/BypassExecGen.scala` | `b8220f6f5055a8ce20351a6eb81b4bbc` | **新**：单出 `gen/BypassExec.v`（缺省 C=8 W=80 HMAX=40） |
| `y1/rtl_test/LayoutAdaptTb.v` | `5cad3c60377db94e3127426ebce5b29c` | **新**：布局适配装置（逐列 + 主口真实写出字节独立对账） |
| `y1/tools/layout_adapt_ref.py` | `a0b6cfe45a3e6d41d5fc92520ebbcb69` | **新**：钻真表的供料 + 黄金（两套实现互证 + 三条非退化断言）；**本任务修了条带 `w1` 打包** |
| `y1/tools/run_layoutadapt_ab.sh` | `b39b3351aa6a58da8bff4268d3da781a` | **新**：B4 闸门（正/负对照 + 外科式 + 结构 + 确定性 + H1 复跑） |
| `y1/reports/c4b_layout_adapt.md` | 本报告 | — |

**`third_party/**` 与冻结工具**（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/
`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**一字未改**；描述符格式 / 寄存器契约**未改**。

---

## 7) 能证 / 不能证（诚实清单）

**能证**：conv→bypass（读侧按步长 gather）与 bypass→conv（写侧按平面散射）**逐字节**正确（A/B 两档，
`COL_MISMATCH=0`/`DST_MISMATCH=0`）；模式 0 与改动前**逐字节同形**（回归锚）；负对照**实跑发火且可定位**
（首坏列 0）且**外科式**（模式 0 仍绿）；H1 的 `SRC` 折进仍自洽。

**不能证 / 未做**：

1. **大几何未跑**：闸门用例是 `MaxPool_25`（`40×40` 与 `40×8` 条带，`NPIX ≤ 6400`）；真网最大旁路层
   （`MaxPool_5` `160×160`）**没跑**（仿真时间 + 内存镜像规模），但其**结构性前提**（`%32`、非 Add）
   已由 `planarOk` 在 `go` 那一刻把住。
2. **只覆盖 maxpool 的数值**：`layout_adapt_ref.py` 的黄金只对 `maxpool` 出（其余算子"逐列"这条
   与算子语义无关，但**没有**逐算子黄金）⇒ 本片证的是"**列流取对 + 平面写对**"这条布局链，不是四算子几何。
3. **`LayerSched` / `NpuTop` 级端到端未跑**（同既有闸门：本片在 `BypassExec` 单元级证）；
   整帧 `conv → maxpool → conv` 的真交接归 **B6**（上板）。
4. **性能/吞吐没测**：判据是**数值/字节**，不是吞吐（每 32 像素每平面一笔 + 逐列吐）。
5. **Add 的布局模式不支持**（两路列交织）⇒ 响亮 err（本代明写）。

## 8) 控制方要重跑 / 上板项

- **PnR**：`rtl/BypassExec.scala` 与 `rtl/LayerSched.scala` 改了 ⇒ **PnR 由控制方重跑**（本任务不跑 PDS）。
  新增面积：`pgBuf` = `C*4` = 32 × 64 位、`woBuf` = 32 × 64 位（共 64 个 64 位寄存器）+ 少量 mux 与两个
  2 位子 FSM + `layer` 表（256×2 位 ROM，`inlineRom`），**零乘法器**。
- **B6 上板**：整帧 `conv→bypass`（`MaxPool`/`Resize`/`Add`/`Sigmoid`）的真交接、与 `ddr_traffic` 合账、
  帧时/IoU 判据 —— 见计划 B6。
