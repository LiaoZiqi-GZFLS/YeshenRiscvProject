# Y1-NPU B1-T1 设计地图：宽层输入 tile 跨 co-block 复用

**基线**：`master` @ `ed4ec94`（B1-T0 + plan 之后）。**性质**：只读代码勘察，不改 RTL / 不重生成网表 / 不碰板。
**一句话结论**：B1 的 RTL 改造可以**完全落在 `UnitExec.scala` 内**（产品路径的宽层输入本来就是 `UnitExec` 自己的 DDR gather，不是外部 `wide_x`）；但 B1-T0 的 4.50× 基线把 20 个 depthwise 单元按“co-block 重读”计了账，而 RTL 的 depthwise 是**对角趟**（每个 ci-block 只读一次）——真实逻辑读放大是 **2.55×（38.84 MB）**，B1 可消掉的是 **23.60 MB**，不是 53.41 MB；再叠加 tile halo 与 32 B band 粒度，`reuse = nominal` 在 tiled 产品路径上也不成立。故 **AMBER：实现范围绿、收益前提红**。

---

## 1. 谁生成宽层每趟的输入流（`UnitExec.io.wide_x`）？

### 1.1 外部 `wide_x` 端口在产品拓扑里是**死的**
- 端口定义：`y1/rtl/UnitExec.scala:602-604`（`wide_x: Vec(SInt(8),C)`、`wide_x_valid`、`wide_x_ready`）。
- 集成侧 `LayerSched` 把它**钉 0**：`y1/rtl/LayerSched.scala:672-675`
  （`unitExec.io.wide_x_valid := False`；8 个通道全 `S(0,8)`）。
- 因此“host CPU 写 DDR → 喂 `wide_x`”不是产品路径；`wide_x` 只在 `XDMA_EN=0` 的单元装置/TB 里由 TB 驱动。

### 1.2 产品路径：`UnitExec` 自己的 `DdrMaster` gather（`XDMA_EN=1`）
逐步链路（每一跳都有代码锚点）：

1. **主机只写 DDR + 编 mailbox，不产生逐拍列流**：驱动默认 `XDMA_EN=1`，
   `y1/tools/npu_frame_run.py:1135-1141`（`--xdma-en` 默认 True），写入区域 7 道 0：
   `y1/tools/npu_frame_run.py:409-412`；板级 payload 也以 `xdma_en=True` 生成：
   `y1/tools/build_board_payload.py:75`。
2. **`UnitExec` 锁存开关**：`xDmaOnR` 由信箱区域 7 道 0 的 bit0 写入，
   `y1/rtl/UnitExec.scala:1529-1532`。
3. **tiled 宽路资格**：`tilingWideC` 显式要求 `xDmaOnR`，
   `y1/rtl/UnitExec.scala:1650-1655`；`go` 那拍把结果闩进 `tilingW`，
   `y1/rtl/UnitExec.scala:1979`。
4. **每趟 gather 启动**：`WIDERUN` 的 `wSt==2` 拍给 `xgTripGo`，
   `y1/rtl/UnitExec.scala:1570-1576`；tile 路径在同一拍复位 gather 指针，
   `y1/rtl/UnitExec.scala:2131-2135`。
5. **gather 主口驱动**：
   - 非 tiled 宽路：`y1/rtl/UnitExec.scala:2286-2291`（`start=xgStartPulse`、`mode=RD`、`len=32`）；
   - tiled 宽路（产品）：`y1/rtl/UnitExec.scala:2304-2311`
     （`wxRun` → `ddrMaster.io.start/mode/src/len`），`rd_ready` 在
     `y1/rtl/UnitExec.scala:2436-2437`。
6. **数据落 band 缓冲**：非 tiled 落 `xbuf`（`y1/rtl/UnitExec.scala:1544`），
   tiled 落 `xwBuf`（`y1/rtl/UnitExec.scala:1663`），收拍在
   `y1/rtl/UnitExec.scala:2329-2331`。
7. **拼成一列喂 `mpu`**：列来源二选一在
   `y1/rtl/UnitExec.scala:1613-1614`；tiled 的 pad 列 / 真列在
   `y1/rtl/UnitExec.scala:1696-1704`；最终 `mpu.io.x` 在
   `y1/rtl/UnitExec.scala:2358-2360`（tiled）或 `1789-1790`（非 tiled）。
8. **AXI AR/R**：`UnitExec.io.ddr <> ddrMaster.io.axi`
   （`y1/rtl/UnitExec.scala:677-678`）；`DdrMaster` 对 `mode==1` 在 CHK 进入
   `QRUN`（`y1/rtl/DdrMaster.scala:455-466`），AR 在
   `y1/rtl/DdrMaster.scala:618-626`（valid/payload）与 `359-367`（地址/长度），
   R ready 在 `y1/rtl/DdrMaster.scala:370`。
9. **出 `UnitExec` 后的 AXI 复用**：`LayerSched` 在 `useUnit` 相位选 `unitExec.io.ddr`
   （`y1/rtl/LayerSched.scala:493-496`、`693-724`）；`NpuTop` 再把 `schedAxi` 按
   `axiMuxSel` 接到顶层 `io.axi`（`y1/rtl/NpuTop.scala:169-171`、`185-210`）。
   `NpuTop` 自己的块拷贝 `DdrMaster` 在 `DESC_COUNT != 0` 时不启动
   （`y1/rtl/NpuTop.scala:254`、`284-286`），所以激活读不走它。

### 1.3 `DescFetch` 不是激活生产者
- `DescFetch` 有独立 `DdrMaster`，只读 **32 B 描述符**
  （`y1/rtl/DescFetch.scala:115`、`117-126`）。
- `LayerSched` 在取表相位（`useDesc`）选它，在 RUN 相位（`useUnit`）选 `UnitExec`
  （`y1/rtl/LayerSched.scala:493-496`）。描述符读与激活读是**同一 AXI 口的时分复用**，
  不是同一数据流。

### 1.4 代码与注释矛盾（必须记录）
- 文件头仍写“宽层多趟 **不走 DDR 读**，由 `wide_x` 列流喂”
  （`y1/rtl/UnitExec.scala:8`），端口注释还写“DDR→ci-block 平面布局的 gather 是 C4b 项，
  本片只证已接通路”（`y1/rtl/UnitExec.scala:598-601`）；
- 但 `C4b-B3` 已实现该 gather（`y1/rtl/UnitExec.scala:1510-1611`、`2286-2311`），
  且 `tilingWideC` 要求 `xDmaOnR`（`1650-1655`）。**注释是旧口径，代码是新产品路径。**

**1 的结论**：主机 CPU 只负责把输入张量/描述符/权重 blob 放进 DDR；每趟的宽层输入流由
`UnitExec` 的 `DdrMaster` gather 从 DDR 主动拉取。`wide_x` 是遗留外部口，产品里被 `LayerSched` 钉 0。

---

## 2. 趟循环在哪里？谁决定趟序、谁发 `start`/`cob`？

- 趟数：`nCi = ceil(C_in/8)`、`nCo = ceil(C_out/8)`，
  `y1/rtl/UnitExec.scala:952`、`956`。
- 趟状态：`wCi`（当前 ci-block）与 `wCob`（当前 co-block），
  `y1/rtl/UnitExec.scala:1486-1487`；趟号 `wPassIdx = wCob*nCi + wCi`，
  `y1/rtl/UnitExec.scala:1804`。
- **每趟的 `start` 与 `cob`**：
  - `mpu.io.start := wSt === U(2,3)`（每趟一拍），`y1/rtl/UnitExec.scala:1823`；
  - `mpu.io.cob := wCobP`（`wCob` 的寄存副本），`y1/rtl/UnitExec.scala:1777`、`1793`。
- **趟序由 `UnitExec` 的 `WIDERUN` 子 FSM `wSt` 决定**，换趟在
  `y1/rtl/UnitExec.scala:2154-2168`：
  - dense：`wCi` 先自增，到 `nCi-1` 回 0 并 `wCob++`（
    `y1/rtl/UnitExec.scala:2160-2167`）⇒ **co-block 外、ci-block 内**；
  - depthwise：`isDwW` 分支直接 `(wCob+1, wCi=wCob+1)`（
    `y1/rtl/UnitExec.scala:2157-2159`）⇒ **对角趟**，每 co-block 只跑一趟。
- `LayerSched` **不决定趟**：它一个描述符只发一次 `unitExec.io.go`（
  `y1/rtl/LayerSched.scala:920-925`），然后等 `done`（`928-945`）。
- `MultiPassUnit` **没有趟状态机**：它只提供 `start`（= 切片 `prime` + PSB 读地址回段首）与
  `cob`（PSB 段基址），趟的切分完全由 `UnitExec` 给（
  `y1/rtl/MultiPassUnit.scala:20-29`、`83-86`、`157`、`169`）。
- 自报：`io.wide_passes = Mux(isDwW, nCo, nCi*nCo)`
  （`y1/rtl/UnitExec.scala:2721`）；`wide_on` 在 `go` 锁存（`2625`、`2718`）。

**2 的结论**：趟序、每趟 `start`、`cob` 全部在 `UnitExec` 内；B1 只需要改这一处，不涉及调度器。

---

## 3. 一趟的输入 tile 驻留在哪里？现有缓冲能否装下 8 ch × tile？

### 3.1 现有存储盘点（宽层产品路径）
| 存储 | 位置 | 容量 | 用途 / 能否装 tile |
|---|---|---|---|
| `xbuf`（非 tiled gather） | `UnitExec.scala:1544` | 32 × 64 bit = **256 B** | 一个 32 像素 band 的 8 个平面；**只有 1 行**，不能装 tile |
| `xwBuf`（tiled gather） | `UnitExec.scala:1663` | 32 × 64 bit = **256 B** | 同上；每个 band 重填 |
| `LineBuffer`（切片内） | `LineBuffer.scala:88-89` | 2 行 × `WIDTH` × `C_IN` 寄存器 = 2×34×8 = **544 B** @WIDTH=34 | 3×3 窗口的 2 行历史；不是 tile |
| `FusionBuf`（窄路） | `FusionBuf.scala:121`、`153` | `3*WIDTH` 字 × 8 B = **816 B**/实例 @WIDTH=34 | 3 行环窗；窄路专用，宽路单元里空闲 |
| `wRam` | `UnitExec.scala:803` | **36,864 B** | 权重趟瓦片；8×8 趟时**正好用满**（`WGT_RAM_BYTES` `511`） |
| `wOutMem` | `UnitExec.scala:1477` | `PIXW*NCOB` 字 × 8 B = 1088×8×8 = **69,632 B** | 输出存储（8 个 co-block 段）；不是输入 |
| `PartialSumBuf` | `PartialSumBuf.scala:60`、`70` | 8×1122 字 × 32 B = **287,232 B** | 部分和；不是输入 |
| `outMem`/`outMemT`（窄路） | `UnitExec.scala:1327`、`1356` | 1088 字 × 8 B = **8,704 B**/个 | 窄路输出；宽路不用；LUTRAM 形态 |

**没有任何现成缓冲能装 8 ch × 一整个 tile**。全仓搜索 `tileBuf/tile_buf` 只命中文档
（`y1/tools/read_account.py:11`、`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md:17,23,30,37`、
`docs/superpowers/plans/2026-10-20-y1-npu-b1-input-reuse.md:11-12`），RTL 里没有实现。
窄路空闲的 3 个 `FusionBuf` 合计也只有 3×816 = 2,448 B，且每个只有 3 行，仍装不下一个 34 行窗口。

### 3.2 真实 tile 几何
- 板级几何：`NpuTop` 实例化 `LayerSched(C=8, WIDTH=34, IMG_H_MAX=32, L_MAX=LMax)`
  （`y1/rtl/NpuTop.scala:154`，`LMax` 默认 2 见 `101`）；`LayerSched` 对 `UnitExec` 开
  `TILING=true`（`y1/rtl/LayerSched.scala:301`）。
- 输出 tile：`WT = WIDTH-2`（`UnitExec.scala:867`）、`HT = IMG_H_MAX`（`868`）；
  `s=1` ⇒ 32×32；`s=2` ⇒ `WT=(34-2)/2=16`，高仍 32（`913-915`）。
- 输入窗口：`tNCol = s*tw + 2`、`tNRow = s*th + 2`
  （`UnitExec.scala:892-894`）。满 tile 时：
  - `s=1`：窗口 **34×34**；
  - `s=2`：窗口 **34×66**（16 输出列 × 32 输出行 + 2 行/列 halo）。
- 真实表只有 `Conv_0` 是 `s=2`（`C_in=3, C_out=16`，输出栅格 320² / 输入 640²）。用 `read_account.py` 的冻结
  desc 位打包（`y1/tools/read_account.py:148-155`）解码 `y1/gen/desc.bin`，并用
  `y1/tools/read_account.py:241-245` 的 `align32(C_in*H*W*s^2)` 对账（CHECK 53/53 通过，
  运行输出 `CHECK mac_table_vs_wgt_index=OK(53/53)`）。其余 52 个 conv/dw 单元都是 `s=1`。
- **最大 tile 字节（本表）**：
  - `s=1`、8 ch：8 × 34 × 34 = **9,248 B**（= 9.03 KiB）；
  - `s=2`、`Conv_0`、3 ch：3 × 34 × 66 = **6,732 B**；
  - 若未来出现 8 ch 的 `s=2` 层：8 × 34 × 66 = **17,952 B**。

### 3.3 与 spec/plan 的数字冲突（重要）
- spec 说“32×32 tile 约 9 KB”（`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md:30`）——
  9,248 B 基本对；
- plan 说“8 KB tileBuf（8 ch × 34 × 34 B）”（`docs/superpowers/plans/2026-10-20-y1-npu-b1-input-reuse.md:11-12`）——
  **8 ch × 34 × 34 = 9,248 B，不是 8,192 B；plan 的 8 KB 少了 1,056 B**。
- 若 tileBuf 固定 8 lane 且要覆盖 `Conv_0` 的 `s=2` 66 行窗口，则需要 **17,952 B**；
  若只按 `Npl` 打包（`Conv_0` 只存 3 lane），9,248 B 够本表，但 buffer 的地址/字宽要随
  `Npl` 变。B1-T1 必须先定这一条，否则 `Conv_0` 会越界。

### 3.4 tile halo 与 band 粒度：`reuse = nominal` 在 tiled 路径上不成立
- tile halo：160×160 输出按 32×32 切 5×5 个 tile，每个窗口 34×34，
  总读列数 = 25×1156 = 28,900，而 nominal = 25,600 ⇒ **1.129×**；
  20×20 只有 1 个 tile，窗口 22×22 ⇒ **1.21×**。几何由 `UnitExec.scala:867-868`、`892-897` 定义。
- band 粒度：gather 按 32 B（32 像素）对齐突发，`wxBB = wxGAbs & ~31`
  （`UnitExec.scala:1683`），`wxNeedB` 在 band 未装时重取（`1696`），每笔 32 B
  （`UnitExec.scala:2311`）。一个 34 列窗口横跨 **2 或 3 个 band**：
  窗口起点 0（首 tile）只需 2 个 band（64 B/平面/行），起点 31/63/95 等内部 tile 需要
  3 个 band（96 B/平面/行）——有效列只有 34 ⇒ **1.88×–2.82×** 总线读（内部 tile 取 2.82×）。
  即使 B1 把 co-block 重读全部消掉，产品 tiled 路径的 DDR 读仍约为
  `nominal × 1.13 × (1.88…2.82)`；真正的 1× 要等 B2（halo 复用）
  与 B3（更宽 gather / 128 B）——spec §4 也把 B2/B3 列在后面
  （`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md:41-44`）。
- 因此 B1-T2 若断言 `gather_bytes == nominal`（plan `14-15`）在 tiled 产品路径上会红；
  应断言 `nominal × halo_factor`，或让计数器只数“唯一输入列”而不数重取的 band。

---

## 4. 部分和：8 个 co-block 段能否跨 ci 趟共存、且不清零？

**肯定（affirm），但依赖 `ps_clr` 的 tiled 路径。**

- 存储形状：`NCOB_MAX = 8`（`UnitExec.scala:515`）；`PIXW = WIDTH*IMG_H_MAX = 1088`
  （`517`）；tiled 下 `PIXMAX = PIXW + WIDTH = 1122`（`1476`）；
  `PartialSumBuf` 的 `DEPTH = NCOB * PIXMAX = 8*1122 = 8976` 字
  （`PartialSumBuf.scala:70`），16 位 depth 自报 8976 < 65535（`67-68`、`86`）。
- 分段地址：字地址 = `cob * PIXMAX + pix`（`PartialSumBuf.scala:20-24`）；
  `MultiPassUnit` 的段基址 `base = io.cob * PIXMAX`（`MultiPassUnit.scala:169`），
  读地址 `rdAddr`（`172-175`）、写地址 `base+pixIdx`（`184`）。
  8 个段**地址完全不重叠**，可同时驻留。
- 初值 0：`Mem(...).init(0)`（`PartialSumBuf.scala:101`）；“第 1 趟读到 0”由
  `MultiPassUnit.scala:177` 的 `ps_clr` 或上电初值承担。
- 产品 tiled 路径的清零门：`mpu.io.ps_clr := tilingW && Mux(isDwW, True, wCi===0)`
  （`UnitExec.scala:2364`）。ci-outer 重排后，`wCi==0` 正好是**每个 cob 的第 1 趟**
  （内层 cob 全跑一遍），所以每个段在 cib=0 都被清零，cib>0 保留部分和。
  `wBiasR` 的 `(wCi==0)||isDwW` 门（`UnitExec.scala:1786-1787`）也仍然正确。
- 收料门：`wCollectCiOk = Mux(isDwW, wCi===wCob, wCi===nCi-1)`
  （`UnitExec.scala:1845`），`wCollect`（`1846-1847`），写地址
  `wEmitCnt*NCOB + wCob`（`1833-1835`）。ci-outer 下，dense 只在**最后一个 cib**
  收所有 cob 的成品，`wOutMem`（`1477`）有 8 个 co-block 段（1088 像素/段），也够。
- **限制**：非 tiled 宽路的 `ps_clr` 恒 0（`UnitExec.scala:2364` 的 `tilingW &&`），
  它依赖“PSB 上电 0 + 单次 run”；B1 若跨 run/多 unit 复用同一 PSB 而不清零，必须补
  `ps_clr`。B1 应明确只改 `tilingW` 路径。
- depthwise 的 `ps_clr` 恒 1（`2364` 的 `Mux(isDwW, True, ...)`），每趟从 0 起；
  depthwise 本来就不需要跨 cob 复用（见 §6 的账）。

**4 的结论**：`NCOB=8` 段在物理上足够让全部 co-block 跨 ci 趟共存；ci-outer 重排不需要
改 `PartialSumBuf`，只要保留 `wCi==0` 的清零/偏置门和 `wCi==nCi-1` 的收料门。

---

## 5. 权重：`wRam` 是否已在趟循环前装好全部 (cob,cib) 瓦片？

**肯定。**

- `wRam = Mem(Bits(8), WGT_RAM_BYTES)`，`WGT_RAM_BYTES = 8*8*NENTRY = 36,864 B`
  （`UnitExec.scala:511`、`803`）；最大 `nCi*nCo = 8*8 = 64` 趟 × 576 B = 36,864 B，
  正好装下（`NENTRY=576` 见 `487`；`WGT_SEG=NENTRY` 见 `527`）。
- 装载时机：`go` 那拍若 `dmaEn && isWide && wgtLoadOk`（`dmaWide`，`UnitExec.scala:1454`），
  主 FSM 先走 `WGTLD → WGTRUN`（`UnitExec.scala:1986-1991`），装载收工才进 `WIDERUN`
  （`WGTRUN` 收工分支 `2077-2081`）。
- 装载落点覆盖**全部 (cob,cib)**：`wlWidePass = cob*nCi + cib`
  （`UnitExec.scala:1065`），`wlWideDest = pass*576 + cl*72 + cil*9 + tap`
  （`1067-1069`），写口 `wRam.write`（`1079-1082`）；宽层零填充覆盖
  `[0, nCi*nCo*576)`（`wzEnd`，`968`）。
- 每趟只从 `wRam` 读当前 576 B 瓦片：`wPassIdx`（`1804`）、
  `wRam.readSync(...)`（`1819`），写进切片的 `WeightStore`（`1820-1822`）。
- 因此把执行趟序从 `cob` 外改成 `cib` 外**不需要任何新的权重装载**：`wRam` 的
  `(cob,cib)→地址` 映射与执行顺序无关；只要 `wPassIdx` 继续按 `wCob*nCi+wCi` 算即可。

**5 的结论**：权重已全趟常驻，B1 的重排是纯执行顺序变化，零额外权重读。

---

## 6. Go / No-Go

### 6.1 是否只需 `UnitExec`？
**（a）是，只需 `UnitExec`。** 理由：
- 输入生产者是 `UnitExec` 自己的 `DdrMaster`（§1），不是 `NpuTop`/`LayerSched`/`DescFetch`；
- 趟循环、`start`、`cob` 都在 `UnitExec`（§2）；
- PSB 与 `wRam` 的形状/装载都已满足跨 cob 复用（§4、§5）；
- `wide_x` 在产品里已被 `LayerSched` 钉 0（`LayerSched.scala:672-675`），保持原样即可；
- `NpuTop`/`LayerSched` 只做 AXI 2:1/3:1 复用（`NpuTop.scala:185-210`、
  `LayerSched.scala:693-724`），`DdrMaster` 是通用引擎（`DdrMaster.scala:455-466`、`618-626`），
  都不需要改；
- 主机驱动已经把 `XDMA_EN=1`、输入平面、desc、权重 blob 都放好
  （`npu_frame_run.py:409-412`、`1135-1141`；`build_board_payload.py:75`），B1 不新增
  寄存器/信箱语义 ⇒ **不需要驱动改动**。

### 6.2 主要风险
1. **外部 `wide_x` 流不可重放（这是 B1 必须绕开的真风险）**：
   `io.wide_x_ready := wXReadyBase`（`UnitExec.scala:1791-1792`），而
   `wXReadyBase = xgRdy = wFeedSt && (wRow < inRows) && mpu.io.x_ready`
   （`UnitExec.scala:1567`）——ready 是**切片当前需求**的组合函数，不是“缓冲可收”信号；
   tiled 版同样把 ready 绑到 gather 的 EMIT 相位（`UnitExec.scala:2362`）。
   外部流在整个单元里是 `wide_passes*H*W` 列（dense = `nCi*nCo*H*W`），单次消费、带背压；
   若 tileBuf 在后续 cob 停止接收，会改变外部流的节拍/契约；若全部接收，则要缓存
   **整个单元的外部流**（`nCi*nCo*H*W` 列），不是 9 KB。
   ⇒ **B1 只能作用于 `xDmaOnR=1` 的内部 gather 路径**（正是产品路径）；`xDmaOnR=0`
   的 legacy `wide_x` 路径保持直通、不缓冲。
2. **行号冻结纪律**：SpinalHDL 把源码行号编进内部网名，`TILING=false` 的三份冻结网表要求
   逐字节不变，所以新增 prose/代码只能放在文件末尾或做行数中性编辑
   （`PartialSumBuf.scala:118-123` 明确记录这条；plan `16-17` 要求 `TILING=false` md5 不变）。
   B1 的 tileBuf + 重放 FSM 若在 `UnitExec.scala` 中**插入新行**，重生成的
   `TILING=false` 网表 md5 会变 ⇒ plan B1-T3 的冻结检查会红。这是**实现层面的硬约束**：
   要么把新逻辑追加在类体最后并覆盖前面的 driver 赋值，要么接受另立
   `UnitExecTiled` 类/文件；不能简单“在 2304 行插 50 行”。
3. **B1-T0 基线对 depthwise 计错（最重要的收益风险）**：
   - `read_account.py` 的模型对**每个**单元都用 `current = nominal * nCo`
     （`y1/tools/read_account.py:30-34`、`159-166`），没有 depthwise 例外；
   - RTL 里 `isDwW = group==C_in==C_out`（`UnitExec.scala:1406`），趟循环走**对角**
     `(wCob,wCi=wCob)`（`2157-2159`），收料门 `wCi==wCob`（`1845`）；gather 的平面基址
     按当前 `wCi` 取（tiled：`1680` 的 `wxPl0 = srcA + wCi*(tInPixW<<3)`；非 tiled：
     `1554` 的 `xgTripBase`），所以第 b 趟只读第 b 个 ci-block ⇒ **每个输入字节只读一次**。
   - 用同一张 53 行表、把 20 个 dw 单元按 RTL 对角趟重算：
     | 口径 | nominal | current | amp |
     |---|---:|---:|---:|
     | `read_account.py` | 15,238,400 | 68,647,200 | 4.5049× |
     | RTL-aware（dw=1×） | 15,238,400 | **38,841,600** | **2.5489×** |
     | 其中 dense（33 单元） | 8,183,200 | 31,786,400 | 3.8843× |
     | 其中 dw（20 单元） | 7,055,200 | 7,055,200 | 1.0× |
   - B1 只对 dense 有效：18 个 `nCo>1` 的 dense 单元 nominal 6,553,600、current
     30,156,800 ⇒ **B1 逻辑上最多省 23,603,200 B**（不是 53,408,800 B）。
   - 按工具自己的 `ALT_TRUE_IN_*` 口径（`wgt_index.json` 的 `in_bytes`，含 `Conv_0` 的
     s=2 真实 4× 输入与 32 B 补位；`y1/tools/read_account.py:306-315`）再剔掉 dw 重读：
     nominal 16,160,032、current 40,684,832、amp **2.5176×**，B1 可省 **24,524,800 B**。
     两个口径结论一致：B1 的真实收益约 24 MB，不是 53 MB。
   - 叠加 §3.4 的 halo（约 1.13×）与 band（2–3 个 32 B band，1.88×–2.82×），
     B1 后“输入读回到 1× nominal”不成立；B1 的收益应重新表述为“消掉 dense 的 `nCo` 重读”，
     而不是“4.50×→1×”。
     spec §1 的 `4.66 s → 1.7–2.1 s（0.47–0.60 fps）`
     （`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md:11-12`）
     建立在这个被高估的 53.4 MB 上，**不能直接作为 B1 的验收目标**。
4. **tileBuf 尺寸**：plan 的 8 KB 装不下 9,248 B 的 s=1 满 tile；固定 8 lane 覆盖
   `Conv_0` 的 s=2 需要 17,952 B（§3.3）。B1-T1 的第一步应是定尺寸，而不是直接写 8 KB。

### 6.3 最小编辑集（5 行）
1. `y1/rtl/UnitExec.scala:2304-2360`：新增 tileBuf（s=1 满 tile 至少 1,156 字 × 64 bit = 9,248 B；若固定 8 lane 覆盖 s=2 则 2,244 字 = 17,952 B）+ fill/replay 逻辑；保留 `io.wide_x_ready`（`1791-1792`、`2362`）与 `mpu.io.x`（`2358-2360`）契约，只在 `xDmaOnR=1 && tilingW && !isDwW` 生效。
2. `y1/rtl/UnitExec.scala:2154-2168`：dense 趟序改为 **cib 外、cob 内**；depthwise 对角分支（`2157-2159`）原样保留；`ps_clr`（`2364`）、`wCollectCiOk`（`1845`）、`wBiasR`（`1786-1787`）不动。
3. `y1/rtl/UnitExec.scala:2436-2437`（及 `2304-2311`）：gather 的 `start`/`rd_ready` 只在“某 cib 的首个 cob”发 AR；其余 cob 的 `mpu.io.x` 从 tileBuf 重放，不再发 DDR 读。
4. `y1/rtl/UnitExec.scala:2721` + 新增 `gather_bytes` 观察口（B1-T2 计数；输出口可悬空，`LayerSched` 无需接线）：按“实际 AR 字节”计数，负对照（每 cob 重读）必须红。
5. `y1/rtl_test/UnitExecGen.scala` / `y1/rtl_test/UnitExecTb.v` / `y1/tools/run_*_ab.sh`：加 Conv_15 tiled 形状的逐字节黄金与 `gather_bytes` 判据；`TILING=false` 三网表按 `PartialSumBuf.scala:118-123` 的行号中性纪律保持 md5 不变；不改 `NpuTop`/`LayerSched`/`DdrMaster`/`DescFetch`/host driver。

### 6.4 判定
**AMBER（条件 go）**：
- **绿**：实现范围确实只在 `UnitExec`，外部 `wide_x` 契约可保持不动；PSB/`wRam` 已具备跨 cob 复用条件。
- **红**：B1-T0 的 68.65 MB / 4.50× 把 20 个 depthwise 单元按重读计账，而 RTL 已是对角趟；真实逻辑读放大 2.55×，B1 可省 23.60 MB，不是 53.41 MB。tile halo（1.13×）与 32 B band（1.88×–2.82×）又使“回到 nominal”不成立；plan 的 8 KB tileBuf 也小于 9,248 B 的 s=1 满 tile。
- **建议**：先重发 B1-T0（加 dw 对角趟、halo、band 三项，给出 RTL-aware 的 current/reuse 与帧时预测），并把 tileBuf 定为 ≥9,248 B（或 17,952 B 覆盖 s=2），再进 B1-T1；否则会按一个高估 2.2 倍的收益去做 RTL 和 0.5 fps 目标。

---

### 附：可复算命令（只读）
- 基线：`cd y1 && python tools/read_account.py` ⇒ `TOTAL_CURRENT_BYTES=68647200`、`AMPLIFICATION=4.504882`（本机已跑，`TOOL_RESULT: PASS`）。
- RTL-aware：同一 `y1/gen/desc.bin` + `y1/gen/wgt_index.json`，对 `TYPE=0x03` 且 `GROUP==C_IN==C_OUT` 的 20 个单元把 `nCo` 因子改为 1；其余照 `read_account.py:159-166` ⇒ 38,841,600 B / 2.5489×（主表口径）；按 `ALT_TRUE_IN_*` 口径 ⇒ 40,684,832 B / 2.5176×，B1 可省 24,524,800 B。
- tile 尺寸：`WIDTH=34`（`NpuTop.scala:154`），`tNCol=tNRow=34`（`UnitExec.scala:892-894`），8×34×34 = 9,248 B；`s=2` 时 34×66，3×34×66 = 6,732 B（`Conv_0`），8 lane 则 17,952 B。
