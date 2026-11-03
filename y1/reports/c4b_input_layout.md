# Y1-C4b-B3 报告 —— **输入布局契约**（DDR → NPU 读到的 ci-block 列流）

**Status: DONE（2026-10-12）**：契约**冻结并写进 `rtl/UnitExec.scala` 文件头/代码注释**；
**宽层激活的 DDR gather 已在 RTL 里实现并接线**（不再是 `LayerSched` 钉 0 的死列流）；
新闸门 `y1/tools/run_inlayout_ab.sh` 全绿（`RESULT: PASS` / `exit 0`），**正对照逐列逐通道字节级对账**
（`COL_MISMATCH=0`、`DST_MISMATCH=0`）+ **负对照实跑发火**（通道序反 ⇒ 列流与输出都变，可定位到首列/首道）。
描述符格式、寄存器契约、既有闸门的黄金**一字未改**。

- 计划：`docs/superpowers/plans/2026-10-11-y1-c4b-weight-dma-and-whole-frame.md` **Task B3**。
- 上游口径：`y1/reports/c4a_multipass.md` §2 的 C4a.5b 三条缺陷 + `y1/reports/c4a_coverage.md` §4（C4a.7 布局折进
  G5 的 `(src_stride, src_order)` 元数据）、`y1/rtl/UnitExec.scala` 的「C4a.5b」与「C4b-B1c」两节。
- 依据：`y1/rtl/LayerSched.scala:500-503`（旧口径：`wide_x` 钉 0，且注释明写"DDR → ci-block 平面布局的
  gather 是 C4b（G6）项"）—— 本任务**就是**把这一条落地。

---

## 1) 冻结的输入布局契约（逐条，带引用）

### 1.1 张量布局 = **通道平面（NCHW / channel-planar）**

DDR 上激活张量的元素 `(c, y, x)` 落在

```
byte_offset = c*H*W + y*W + x          （H/W = 该张量自己的高/宽；`p = y*W + x` ⇒ 等价于 c*H*W + p）
```

依据（**三处独立同源**，不是本任务新定的口径）：

1. `tools/y1_convert.py` 的 `compute_layout_fold` / `layout_addressing`（C4a.7/G5）给的消费侧步长表
   就是"源头张量按**行主序 NCHW** 存放、消费者按 `src_stride` 直接 strided 读"：
   `src_shape=[1,1,80,80] → view [1,80,80,1] stride=[6400,80,1,6400]`（= `permute(0,2,3,1)` 的源头步长）
   ⇒ 源头缓冲的步长是 `(C*H*W, H*W, W, 1)`（见 `reports/c4a_coverage.md` §3 的 `layout_fold` 表）。
2. 宽通路的**写出**侧本来就写这个形状：`rtl/UnitExec.scala` 的「缺陷修-2」段（`wOutMem` 逐字节重排成
   `[co-block][cl][pixel]` = `[co][y][x]`）。
3. 多趟参考的向量生成器 `tools/multipass_ref.py:194` 落盘的 `x.hex` 就是 `xq.reshape(-1)`（`xq` 形状
   `(1, C_in, H, W)`）⇒ **C4a.4 的整层黄金本来就是按通道平面喂的**。

★ **`DDR → ci-block 列流` 是一次"按固定步长的重排"，不是换布局**：列流的第 `p` 列 = 同一个像素在
8 个平面上的 8 个字节（见 1.3）；这**正是** C4a.7 A1 那条"消费者按 `(base, stride, shape)` 直接
strided 读生产者缓冲"在"布局算子"这一档上的特例（`Transpose(NCHW→NHWC)` 折进寻址）。

### 1.2 `SRC_ADDR` / `DST_ADDR` 的映射（C3 约定，H1 已折进）

- 描述符的 `IMG_W/IMG_H` = **输出**（本层写的）张量的高/宽；`SRC_ADDR`/`DST_ADDR` = 输入/输出张量在
  DDR 的 32 B 对齐起点。**本代 RTL 的 conv 是 stride-1**（`Conv3x3Slice` 没有 stride 端口；
  `DescWords.stride` 只译码不使用）⇒ 对**本任务覆盖的层**：`本层输入张量尺寸 == 本层输出张量尺寸`，
  于是"上一层的 `DST` 就是下一层的 `SRC`"在**形状上**天然成立。
- `SRC_ADDR` 已由 **H1 `9a14e84`** 折到"生产者真正写过的 `DST`"（`apply_src_addr_fold` +
  正判据 `SRC_WRITTEN`）⇒ 每个源都指向**被写过**的缓冲，且**布局同 1.1**（写与读是同一套通道平面）
  ⇒ **不存在"输出布局 ≠ 输入布局"的转置需求**（这是本任务把契约定下来时最先确认的一件事）。
- **通道分块（blocking）**：宽通路（`C_in>8` 或 `C_out>8`）把通道按 **8 个一组**（`ci-block`/`co-block`）
  分块处理：`n_ci = ceil(C_in/8)`、`n_co = ceil(C_out/8)`（`tiling_ref.TILE = 8`）。
  **分块不改变 DDR 布局**：块只是"寻址与趟编排"的单位，平面仍是 `c*H*W + p`（`c = ci*8 + cl`）。

### 1.3 `wide_x` 列流（宽通路的输入侧口径，**冻结**）

`MultiPassUnit.io.x` 一拍收**一列** = **一个像素在该 ci-block 上的 8 个通道**（`cl = 0..7` 落
`x(cl)`）。趟序（`rtl/UnitExec.scala` WIDERUN 子 FSM）= **co-block 外、ci-block 内**；每趟喂
`H*W` 列（行主序 `[y][x]`），第 `H` 行（下边 pad 行）由本单元**自己合成 `z_pad`**、调用方不喂。
行主序列序与"每列 8 通道"这两条在 `tools/wide_exec_ref.py:153-156` 与 `rtl_test/UnitExecWideTb.v:9-12`
里都写着（C4a.5b 冻结）。

⇒ **本任务的 gather 就是把 1.1 的平面张量按 1.3 的列序取出来**：

```
列 p（ci-block i 的第 p 个像素）的第 cl 个通道 = DDR[ SRC_ADDR + (i*8 + cl)*H*W + p ]
```

### 1.4 `C_in = 3`（真表 `Conv_0`）的激活侧口径 —— **与 B1c 的权重零填充同一条**

- 权重侧（B1c 已冻结）：`C_in % 8 != 0` 时，超出的输入通道（`cl ≥ C_in - 8*ci`）那一块权重
  **填真零**（`w = 0`）⇒ 对累加器贡献恒 0。
- **激活侧（本任务冻结）**：同一个"不存在的通道"上，`wide_x` 的对应**通道字节取 0**。
  两条合起来 = `0 × 0 = 0` ⇒ 该趟的数值与"整层 3 通道卷积"完全一致（不需要宿主把图补成 8 通道）。
  实现口径：gather **不发起**那些平面的 RD（读地址绝不越出张量），而是把它们在 `xbuf` 里的
  那一格**每趟清 0**（`rtl/UnitExec.scala` 的 `xgNPl` + `xgTripGo` 清零）。
  ★ 为什么**不**让宿主把 `C_in=3` 的图补成 8 平面：那样输入搬运量会从 `3*H*W` 涨到 `8*H*W`
  （首层 2.67×），而且"补的 8 个平面里哪几个是真的"这条信息在硬件侧就丢了。零填充口径
  与权重的零填充**同源**（同一处几何 `C_in`、同一条"缺的通道贡献 0"）。

### 1.5 `DST → 下一个单元的 SRC`（多趟通路）

- 宽通路的**输出** = `[co][y][x]`（通道平面，1.1 第 2 条），写满 `C_out*H*W` 字节
  （`C_out % 8 != 0` 时按 `wideCoRows = C_out` 截断，C1 已冻结）。
- 下一个单元（无论宽窄、conv 还是旁路）读的 `SRC_ADDR` 就是这段缓冲 ⇒ **1.1 同形**。
  ⇒ 多趟通路**自洽**：`层 i 的 DST 布局 == 层 i+1 期望的 SRC 布局`（都是通道平面）。
- ★ **诚实记录（本任务查出的、超出 B3 范围的两条几何缺口）**：
  1. **stride ≠ 1**：真表 `Conv_0` 是 `strides=[2,2] pads=[1,1,1,1]`（输入 `1×3×640×640` → 输出
     `320×320`，实测见下 §5）。本代 RTL 的 conv **没有 stride 路径**（`DescWords.stride` 无人使用），
     所以 `Conv_0` 目前只能"按 stride 1"跑（= 读前 `320×320` 个像素）⇒ **真帧的第 0 层还差这一条**。
     这不是布局问题（布局契约对 stride≠1 依然成立，只是读取的**行/列步长**要再乘 stride）
     —— 它需要把 stride 接进 `FusionBuf`/`Conv3x3Slice` 的取数，属**另开一项**。
  2. **旁路单元是 NHWC**：`rtl/BypassExec.scala` 头注释冻结的是"一拍一列 = 一个像素的 C 个通道"
     （NHWC ^1）—— 与本任务冻结的**通道平面**不是同一件事。真网里 `conv → maxpool/resize/add/sigmoid`
     的相邻对正是 C4a.7 那 12 个 `Transpose` 折进寻址的位置（`layout_fold` 的 `src_stride` 就为此准备）
     ⇒ 旁路单元"按 `src_stride` 取数"这一条属计划里的 **B4**（条件任务），本任务只把它**点名**。
     ^1 注意：**`C=8` 且只有 1 个通道块**时，NHWC 与"平面"是同一个东西；真网所有 conv 层的
     `C_in ≥ 16`（`n_ci ≥ 2`）⇒ 两者不同，必须分开记。

---

## 2) 闸门开关（**描述符/寄存器契约零改动**）

宽层激活的来源二选一，用**既有权重信箱**的一个新区域投递（与 B1 的 `WGT_BLOB_BASE`(区域 6)、
B2 的 `M/z_pad/z_y/bias_adj`(区域 2..5) **同一手法**）：

| 区域 | 道 | 语义 |
|:--|:--|:--|
| `0x7` | `WGT_ADDR[1:0] == 0` | `XDMA_EN`：**0（上电值）= 外部 `wide_x` 端口喂**（= C4a.5b 行为，既有闸门逐字节不变）；**1 = 本单元从 `SRC_ADDR` 的通道平面张量 gather** |

- **不改**描述符格式、不改 `HostRegs` 的寄存器映射、不改 `NpuTop`/`LayerSched` 的端口
  （`UnitExec` 直接复用**它自己的** `DdrMaster`：宽通路在 `WIDERUN` 相位本来就**不读 DDR** ⇒ 主口空闲，
  不需要第四路子主口、也不动 AXI 复用结构）。
- **不做第二条算术路径**：gather 只搬字节（平面 → 列序），数值通路（MAC/部分和/requant）一字未动。
- ✓ **零乘法器**：地址只用移位与加法递推（`xgPlane0` / `xgAddrR` 两个 32 位寄存器）。
- ★ 新增两个**只观察**的输出口 `x_dbg[8]` / `x_dbg_ok`（把"本拍喂给 `mpu` 的列"与"该列被收下"引出，
  供闸门做**逐列逐通道**的字节级对账；无逻辑、不参与数据通路）。

---

## 3) 判据（`bash y1/tools/run_inlayout_ab.sh`，逐字收口）

```
== run_inlayout_ab: 输入布局契约（DDR 通道平面 -> NPU 收下的 ci-block 列流）==
---- [0] wide_exec_ref.py --selftest（拆趟==整层 + 两条负对照都有牙）----
    SELFTEST Synth_16_16    tiled_eq=1 distinct=65   d_pad0=310    d_nobias=7      PASS
    SELFTEST Synth_16_24    tiled_eq=1 distinct=69   d_pad0=469    d_nobias=14     PASS
    SELFTEST Synth_24_16    tiled_eq=1 distinct=70   d_pad0=317    d_nobias=4      PASS
---- [1] 供料：真层 Conv_0（lid0，3->16，首次消费 + C_in=3 零填充）+ 合成宽层（16->16，n_ci=2）----
    WIDE_REF Conv_0     CIN=3  COUT=16 n_ci=1 n_co=2 NCOL=512
    WIDE_REF Synth_16_16 CIN=16 COUT=16 n_ci=2 n_co=2 NCOL=1024
---- [2] iverilog 编译（XLayoutTb + AxiMemModel + gen/UnitExec.v）: 编译 OK
    [lid0_Conv_0] TB XLAY: ... +XEXP=1536（区域 7 道 0 = 1 = XDMA_EN）
    [lid0_Conv_0] DONE_SEEN=1 ERR_SEEN=0 XDUMPN=512/512  WR_BYTES=4096 AR=48 AW=32 B=32
    [lid0_Conv_0] RESULT: PASS
    [lid0_Conv_0] MEM rd=1536(期望 1536) wr=4096(期望 4096) bursts=80
    COL_COUNT=512/512  COL_MISMATCH=0  COL_FIRST_BAD=-1  DST_MISMATCH=0      <- 正对照
    COL_COUNT=512/512  COL_MISMATCH=498 COL_FIRST_BAD=0  COL_FIRST_BAD_LANES=2
    DST_MISMATCH=73                                                        <- 负对照（发火）
    [synth_16_16] DONE_SEEN=1 ERR_SEEN=0 XDUMPN=1024/1024 WR_BYTES=4096 AR=256 AW=32 B=32
    [synth_16_16] RESULT: PASS
    [synth_16_16] MEM rd=8192(期望 8192) wr=4096(期望 4096) bursts=288
    COL_COUNT=1024/1024 COL_MISMATCH=0  COL_FIRST_BAD=-1  DST_MISMATCH=0      <- 正对照
    COL_COUNT=1024/1024 COL_MISMATCH=1024 COL_FIRST_BAD=0 COL_FIRST_BAD_LANES=8
    DST_MISMATCH=3544                                                      <- 负对照（发火）
==========================================================================
JOB Conv_0       CIN=3  COUT=16 C_out%8=0 n_ci=1 n_co=2 col=512  XEXP=1536 | POS col_mis=0 dst_mis=0 | NEG col_mis=498 (首列 2 道错) dst_mis=73
JOB Synth_16_16  CIN=16 COUT=16 C_out%8=0 n_ci=2 n_co=2 col=1024 XEXP=8192 | POS col_mis=0 dst_mis=0 | NEG col_mis=1024 (首列 8 道错) dst_mis=3544
RESULT: PASS   （exit 0）
```

**判据逐条**：

1. **正对照（逐列逐通道、字节级）**：装置把**被 DUT 收下的每一列**（8 个通道字节）导出，与参考的
   `x.hex`（= 冻结布局的预期列流）逐列比 ⇒ `COL_MISMATCH=0`；**同时** `DST` 区逐字节 == `gold.hex`
   （数值端到端）⇒ `DST_MISMATCH=0`。**两个用例**分别覆盖：
   - `Conv_0`（真层，`C_in=3`）⇒ **首次消费 + 零填充**这条；
   - `Synth_16_16`（`n_ci=2`）⇒ **多趟（跨 ci-block）**这条。
2. **独立计数对账**（两处独立）：内存模型数出的 `MEM rd` == 参考算出的 `XEXP`
   （`Σ_趟(本趟有效平面数 × H*W)`，`Conv_0`=1536、`Synth`=8192）、`MEM wr` == `C_out*H*W`；
   装置侧 `AR` 突发数 == `XEXP/32`（`Conv_0`=48、`Synth`=256）⇒ **一笔不多、一笔不少**。
3. **负对照（必须发火）**：把同一张图按**通道序反**（平面序反转）写进 DDR ⇒ 列流 != 预期
   （`COL_MISMATCH=498 / 1024`）**且** `DST != 黄金`（`dst_mis=73 / 3544`），并把**首列错几个通道**
   （`COL_FIRST_BAD_LANES=2 / 8`）报出来 ⇒ **可定位**。
4. **结构性判据**：装置**不驱动** `wide_x`（`wide_x_valid ≡ 0`）。若 DUT 误走外部端口，列流会全 0
   ⇒ 判据 1 当场红（这条把"列来源确实在 DUT 内部的 DDR gather 通路上"证死）。
5. **退化守卫**：`XDUMPN == NCOL`（收下的列数 == `n_co*n_ci*H*W`，少一列或回绕都会被抓住）。

**红证据（"先红"的方式）**：负对照不是"预测"，而是**装置实跑出来的第二份向量**（`xin_bad.hex` ⇒
同一套硬件 ⇒ 列流与 DST 都对不上黄金）。另外实现期间闸门**真的抓到过两个 bug**（见 §4），
两个都是**逐列定位**出来的 ⇒ 判据的分辨度是实测过的，不是推断的。

---

## 4) 实现（RTL）与为什么选 RTL 而不是"宿主预先摆好"

**选 RTL gather（而不是"宿主把图按列流摆进 DDR、RTL 连续读"）的理由，逐条**：

- **中间张量是 NPU 自己写的**：`层 i+1` 的输入 = `层 i` 的 `DST`。宿主管不到它。若把"列流形状"
  当作 DDR 上的冻结布局，那么**宽通路的写出侧也必须改成列流形状** ⇒ 要动 `wOutMem` 的 WR 出料序，
  而那个出料序是 **6 个既有闸门**（`run_unitexec_wide_ab` / `run_wgtdma_wide_ab` / `run_nonwide_wide_ab` /
  `run_wide_tail_ab` / `run_dw_wide_ab` / `run_paramdel_ab`）的黄金口径 ⇒ 是"改契约 + 重锚 6 个闸门"。
- 反过来，**通道平面**已经是"转换器 C4a.7 的步长表 + 宽通路写出侧 + C4a.4 整层参考"三处同源的既成事实
  （§1.1）⇒ 把 gather 放进**读侧**，**一个字都不用改既有黄金**，且
  **既有宽层闸门 `RD_PEAK == 0` 那条判据在 `XDMA_EN=0` 时逐字节不变**（实测见下）。
- gather 落在 `UnitExec` 里（而不是 `LayerSched`）：趟编排（`wCob/wCi`）、`mpu.start` 相位、
  喂列握手全在这里；`DdrMaster` 在 `WIDERUN` 相位**本来就空闲** ⇒ **复用同一个主口**。

**实现要点**（`rtl/UnitExec.scala`，全部在"`C4b-B3`"注释块内）：

| 机制 | 说明 |
|:--|:--|
| 32 像素一组 | 每个平面发**一笔 32 B RD**（`DdrMaster` 的 32 B 最小粒度），4 拍灌进 `xbuf(cl*4 + w)`（8 平面 × 32 B = 256 B 的转置缓冲，32 个 64 位寄存器） |
| 行主序吐出 | 第 `j` 列（像素 `32g+j`）的第 `cl` 个通道 = `xbuf(cl*4 + j/8)` 的第 `j%8` 个字节（**8 个 4:1 mux**，无桶形移位器） |
| 地址 | `xgPlane0`（本趟 ci 的平面 0 地址，每趟递推 `+8*H*W`）+ 组 `+32` + 平面 `+H*W` —— **只有移位与加法**（无乘法器） |
| 缺通道 | `xgNPl = min(8, C_in - ci*8)`：不发起那些平面的 RD，`xbuf` 对应格**每趟清 0**（§1.4） |
| 几何前提 | `H*W % 32 == 0`（32 B 突发 + 平面步长 32 B 对齐）—— 不合 ⇒ `go` 那一刻**响亮 `err` + 零搬运**（`XDMA_EN=0` 时该子句恒真） |
| 与既有行为 | `XDMA_EN=0` ⇒ `xSrcCol/xSrcVal` 退化成 `io.wide_x / io.wide_x_valid` ⇒ **逐字同形** |

**实现期间闸门抓到的两个 bug（都是"逐列定位"出来的，记下来）**：

1. **动态位选写成 `xgPl*4 + xgJw` 但外层 `Vec` 索引被当常量**——实测签名：**每一列 8 个通道全等于
   平面 0 的同一个字节**（`COL_FIRST_BAD_LANES=0`… 逐列全错）。根因：位数 `xgJ(4 downto 3)` 是
   `Bits` 切片，与外层动态索引混用后被隐式转成了常量锥。改成显式 `.resize(5)` 的 `UInt` 后逐字节对。
2. **"本趟基址"用了组合量而不是寄存器**——实测签名：`n_ci ≥ 2` 的层**每趟只有第 0 组对、其后全错**
   （坏列区间 `[288,511] [800,1023]`，正好是 `wCi=1` 那两趟的第 1..7 组）。根因：`xgTripBase` 是
   `Mux(wCi==0, SRC, xgPlane0 + 8*H*W)` 的**组合**量，而 `xgPlane0` 在趟首已被写成"本趟基址" ⇒
   换组时它算出来的是**下一个 ci** 的基址，把基址多加了一份 `8*H*W`。改成从**寄存器** `xgPlane0` 递推。

  ★ 这两条都不是"猜"出来的：闸门打印 `COL_FIRST_BAD` / `COL_FIRST_BAD_LANES` / 坏列区间，
  直接把范围压到"某一趟的第 1..7 组"。

---

## 5) 交付物 + 指纹

| 文件 | 说明 | md5（B3 收口时） |
|:--|:--|:--|
| `y1/rtl/UnitExec.scala` | **改**：C4b-B3 gather（`XDMA_EN` 区域 7 + `xbuf` 转置 + 地址递推 + `x_dbg` 观察口） | `5272b11c0c15b712e4a685425e092740` |
| `y1/rtl_test/XLayoutTb.v` | **新**：输入布局装置（宿主只写图；DUT 自己 gather；导出"被收下的列流"） | `a0bf733edb57bf6b69945ec0e5c88dab` |
| `y1/tools/run_inlayout_ab.sh` | **新**：B3 闸门（正/负对照 + 两处独立计数 + 自报） | `5ff0556f7d350b35f25c2921e45823e9` |
| `y1/tools/wide_exec_ref.py` | **改**（**只增**）：落 `xin.hex`（宿主的那张图，`C_in*H*W` B）+ `xin_bad.hex`（负对照）+ `job.txt` 尾追加 `XEXP` | `5fc9e6120aa150538af56d2acbd4e061` |
| `y1/gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop}.v` | **重生成**（`gen/` 在 `.gitignore` 里、**不入库**；确定性 2× 见 §6.1） | §6.1 |
| `y1/gen/c4a_wide/{lid0_Conv_0,synth_16_16}/xin.hex`、`xin_bad.hex` | 供料（**只增**两个文件；既有 `x/w/b/gold` 逐字节不变、`job.txt` 只**追加**一行 `XEXP`） | — |
| `y1/reports/c4b_input_layout.md` | 本报告（契约 + 证据 + 开口项） | — |

**`third_party/**` 与冻结工具**（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/
`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**一字未改**。

---

## 6) 回归、确定性、结构判据

### 6.1 网表确定性 2× + 结构判据

```
DETERMINISM_2X_OK
2bdd604c958ee17d106b2fe86fd5c5e5 *gen/UnitExec.v          （两次生成逐字节相同）
55791873a91c970686544dbcb6cf81a0 *gen/UnitExec_w32.v
73158ee1df4f4391984fdb4bc779111a *gen/LayerSched.v
9d112309de852076d84ad1def1d47049 *gen/NpuTop.v
check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop}.v  ⇒ 4/4 PASS（0 悬空实例）
check_no_xilinx.sh gen                                             ⇒ PASS（0 残留）
```

### 6.2 既有闸门（全绿；本任务是**加法**：`XDMA_EN=0` 时逐字节不变）

```
run_unitexec_ab          PASS   run_fuse_ab         PASS   run_fuse_head_ab   PASS
run_sched_ab             PASS   run_chain_ab        PASS   run_unitexec_wide_ab PASS
run_multipass_ab         PASS   run_dw_ab           PASS   run_nputop_ab      PASS
run_nputop_sched_ab      PASS   run_bypass_ab       PASS   run_fusionbuf_ab   PASS
run_weightstore_ab       PASS   run_twoclock_ab     PASS   run_axilite_cdc_ab PASS
run_irqrst_cdc_ab        PASS   run_mem_cdc_ab      PASS   run_hostregs_ab    PASS
run_wgtdma_ab            PASS   run_wgtdma_geom_ab  PASS   run_wgtdma_wide_ab PASS
run_nonwide_wide_ab      PASS   run_wide_tail_ab    PASS   run_dw_wide_ab     PASS
run_paramdel_ab          PASS   run_desc_ab         PASS   run_layout_ab      PASS
run_convert_ab           PASS   run_quant_ab        PASS   run_quant_ref      PASS
run_tiling_ab            PASS   run_ddrcopy_ab      PASS   run_ddrread_ab     PASS
run_ddrwrite_ab          PASS   run_ddrmaster32_ab  PASS   run_macarray_ab    PASS
run_grouped_ab           PASS   run_linebuffer_ab   PASS   run_frame_ab       PASS
```
`scripts/check_addr_map.py` ⇒ `PASS: address ledger consistent (16 sites reconciled)`（SoC 台账未动）。

（`run_macarray_ab`/`run_grouped_ab`/`run_linebuffer_ab`/`run_weightstore_ab`/`run_twoclock_ab` 用
`JUDGE-GREEN` 口径、不打印 `RESULT:` 行；`exit=0` + 日志尾的 `JUDGE-GREEN` 即绿。`run_numeric_ab` 是
**带参**的探针（`run_numeric_ab.sh <mode> <cin> <cout> <H> <W> <seed>`），不是独立闸门 ⇒ 直接跑报
`usage` 是预期行为。）

（`run_nonwide_wide_ab` 在第一轮里报 `exit=3`：**本任务**改 `wide_exec_ref.py` 时把
`os.makedirs(outdir)` 排到了新加的两条落盘**之后** ⇒ 该闸门的 `gen/c4b_nonwide/...` 目录还没建就写
`xin.hex`，`FileNotFoundError` ⇒ 前置缺失 `exit=3`。**已修**（`makedirs` 提到落盘之前）⇒ 复跑 `PASS`。
这是"改共享供料器**必须**跑全套回归"的现成例子 —— 该闸门自己也因此变成一条纪律检查。）

### 6.3 B3 新闸门

`bash y1/tools/run_inlayout_ab.sh` ⇒ **PASS / exit 0**（逐字证据见 §3）。

### 6.4 PnR

**RTL 改了 ⇒ PnR 由控制方重跑**（本任务不跑 PDS；新增面积：`xbuf` 32×64 位 = 2048 FF +
8 个 4:1 的 64 位 mux + 一个 2 位子 FSM，**零乘法器**；`XRUN` 只在 `WIDERUN` 相位活跃）。

---

## 7) 能证 / 不能证（诚实标注）

**能证**：

- 冻结布局（通道平面 + ci-block 列序）**逐列逐通道**被 RTL 取对（`COL_MISMATCH=0`，两个用例），
  且数值端到端 == 黄金（`DST_MISMATCH=0`）。
- `C_in=3`（真表 `Conv_0`）的**激活侧零填充**与 B1c 的**权重侧零填充**合起来等价于整层 3 通道卷积
  （`Conv_0` 用例逐字节 0 差）。
- gather 从 DDR 读回的**字节数与突发数**与"每趟每个有效平面各一笔 32 B"**逐笔对得上**
  （内存模型独立计数 = `XEXP`；`AR` = `XEXP/32`）⇒ 没有多读/漏读、没有越出张量。
- 负对照**实跑发火**且能定位（首列 + 首道）。

**不能证 / 未做（明写）**：

1. **真帧的第 0 层还差 `stride=2`**（§1.5-1）：`Conv_0` 是 `strides=[2,2] pads=[1,1,1,1]`
   （本报告实测：`onnx` 直读 `Conv_0 strides [2, 2] pads [1, 1, 1, 1] group 1 in 1×3×640×640`），
   本代 conv 是 stride-1。**布局契约对 stride≠1 不变**（只是取数的行/列步长要乘 stride），
   但"真帧端到端"必须先补这一条 —— 属**另开一项**（不改描述符：`DescWords.stride` 已有字段、
   只是没人用）。
2. **旁路单元是 NHWC、conv 是平面**（§1.5-2）：真网 `conv → maxpool/resize/add/sigmoid` 的相邻对
   （= C4a.7 的 12 个 `Transpose`）需要"按 `src_stride` 取数"，属计划里的 **B4（条件任务）**。
   本任务**只把这条点名**，没有动 `BypassExec`。
3. **性能/吞吐没测**：gather 的判据是**数值/字节**，不是吞吐（每 32 像素 8 笔突发 + 逐列吐，
   比"带宽最优"实现慢；真实设计应"平面数据直进 `PartialSumBuf` 的 8 个银行"或"边产边流"）。
4. **上板未做**：本任务全部离线（iverilog）。真帧的 DDR 流量归 B6 与 `ddr_traffic` 合账。
5. **大几何未跑**：闸门用例是 `H*W = 256`（`4×64`，与既有宽层闸门同一套定点几何）；真层
   （`320×320`、`H*W % 32 == 0` ✓）的**结构性前提**已由 `xgGeomOk` 在 `go` 那一刻把住，
   但**没有真跑**（仿真时间与内存镜像规模）。
6. **`LayerSched` 级端到端未跑**：本任务在 `UnitExec` 级证（与既有宽层闸门同一层）；`NpuTop`
   整帧（B5/B6）另算。

---

## 8) 相关文件 / 行号（便于复核）

- 契约与实现：`y1/rtl/UnitExec.scala` 的 `C4b-B3` 注释块（`XDMA_EN`/`RGN_XDMA`、`xgSt` 子 FSM、
  `xbuf`、`xSrcCol/xSrcVal`、主口覆盖 `when((state===WIDERUN) && xDmaOnR)`、`ddrMaster.io.rd_ready |= xgTake`）。
- 旧口径（本任务改掉的）：`y1/rtl/LayerSched.scala:500-503`。
- 供料/黄金：`y1/tools/wide_exec_ref.py`（`build_one` 尾部新增两条落盘 + `job.txt` 的 `XEXP`）。
- 装置：`y1/rtl_test/XLayoutTb.v`。
- 闸门：`y1/tools/run_inlayout_ab.sh`。
- 上游口径：`y1/reports/c4a_multipass.md` §2、`y1/reports/c4a_coverage.md` §3/§4（G5 步长表）、
  `y1/reports/c4b_wgtdma.md`（B1/B1c 的权重零填充）。
