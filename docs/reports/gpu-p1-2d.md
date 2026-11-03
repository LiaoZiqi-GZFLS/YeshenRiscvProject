# GPU P1（2D 引擎 + 双缓冲）实施记录

> 规格：`docs/superpowers/specs/2026-10-30-simple-gpu-design.md`
> 计划：`docs/superpowers/plans/2026-10-31-gpu-p1-2d-engine.md`
> 日期：2026-10-31

## 1. 已完成（T0–T5）

| 任务 | 交付物 | 判据 |
|---|---|---|
| T0 接口冻结 | `rtl/gpu/gpu_regs.vh` + `YeshenGui/platform/gpu_regs.h` | `sim/gpu/check_gpu_regs.py` 逐项一致 |
| T1 黄金 | `sim/gpu/gpu2d_ref.c` + 6 个固定用例 | 每个用例 1,228,800 B 帧存与 RTL 逐字节相同 |
| T2 读写引擎 | `rtl/gpu/gpu_mem.v` | `sim/gpu/run_mem.sh` PASS（含负对照） |
| T3 CSR/FIFO | `gpu_csr.v` / `gpu_cmd.v` | `sim/gpu/run_csr.sh` PASS |
| T4 2D 四算子 | `gpu_2d.v`（FILL / ROUND_FILL / SCISSOR / BLIT+混合 / GLYPH） | `sim/gpu/run_2d.sh` 六例逐字节 |
| T5 顶层/集成 | `gpu_top.v`、glue GPU 窗（0xF000_5000）+ 第 4 AXI 主口、SoC 例化、视频 `gui_bank`/`frame_rd_toggle` | 见 §2 |

## 2. T5 集成闸门（全部 PASS）

| 闸门 | 命令 | 结果 |
|---|---|---|
| glue 窗（0xF000_5000 / 窗外 DECERR / 不误发 ETH、VIDEO） | `bash sim/glue_pbus/run_unit.sh` | TEST PASSED |
| 端点级（glue + gpu_top + RAM 模型） | `bash sim/glue_pbus/run_gpu_unit.sh` | `GPU-GLUE PASS` |
| 负对照（读窗基址单行变异） | `bash sim/glue_pbus/negctl_gpu_pbus.sh` | TEST FAILED（期望），复原 md5 `53b4ec75…` |
| npu/dma_pbus/memmerge/memarb 回归 | 对应 `run_*_unit.sh` | 全 PASSED |
| 视频链（U1/U1b/U3/U4/U5/U6/U7/U2/U8） | `bash sim/video/run_video_gates.sh` | `VIDEO_GATES: ALL PASS` |
| 结构闸门 | `check_no_xilinx.sh rtl/gpu` / `check_dangling.py`（5 文件拼接）/ `check_addr_map.py` | 0 命中 / 0 悬空 / 21 处一致 |
| SoC lint | Verilator `--top-module yeshen_mini_soc`（23 文件 + Pango 桩） | 0 error |

端点级装置覆盖的链路：CPU pIo → glue 译码 → `gpu_csr` → `gpu_cmd`（16 项 FIFO）→ `gpu_2d`
→ `gpu_mem` 写合并 → `MemArbiter` 第 4 组 → `io_mem` → RAM 模型。判据含：
`GPU_ID` / `FIFO_FREE` / SCISSOR 回环 / `FENCE(seq=0x1234)` / `FILL 8×2` 逐 8 B 字
（行 stride 生效 + 行外与行间保持 0 的负对照）/ `FLIP` 与 vsync 握手（无 vsync 时
`flip_pending` 保持）/ 窗外 DECERR / 窗内未映射偏移 OKAY+rdata=0。

## 3. T6 dev_map（tag `gpu1`，cpu_clk 10.000 ns）

与 P0 基线（tag `gpu0`）逐项对比：

| 项 | gpu0 | gpu1 | Δ |
|---|---|---|---|
| LUT | 88,172.5 | **91,426** | **+3,253.5**（预算 +8 K） |
| FF | 119,661 | 123,733 | +4,072 |
| DRM | 312 | 313 | +1（上限 315） |
| APM | 257 | 270 | +13（`gpu_2d` 的行基址/缩放乘法） |
| Distributed RAM | 8,079 | 8,169 | +90 |
| errors | 0 | **0** | — |

> 说明：综合日志里有 `gpu_2d.v:191 Unused register p_2/p_3/p_4 was removed` 一类
> Sdm-2020 提示。它们与 `gpu_csr.v` 的 `rdata_q`（块内临时量）同类，是折叠提示；
> **LUT 增量 +3.25 K 证明 GPU 逻辑没有被整块剪掉**。

## 3b. T7 用户态（YeshenGui，独立提交链）

| 件 | 内容 | 判据 |
|---|---|---|
| `platform/gpu.{h,c}` | FILL/ROUND_FILL/SCISSOR/BLIT/GLYPH/FENCE/FLIP 命令封装；板端 MMIO（FIFO_FREE 限流 + `SEQ_DONE` 超时 + `flip_pending` 握手），主机同语义模拟 | `GPU_HOST: PASS`（重放六个黄金用例，帧存逐字节） |
| arena | 板端 DDR `0x9320_0000` 1 MiB（`/dev/mem` 非缓存）；主机 malloc + `host_bind` | — |
| `ui/gpu_draw_unit.c` | LVGL 9.2 draw unit：接管**实心矩形**与**整幅 RGB565 图像**（无变换/无掩码/不着色，源复制进 arena）；圆角/半透明/文本/A8 图像在 `evaluate` 拒绝、交回 SW | `GPU_UNIT_HOST: PASS`（单元级 8 任务逐字节 + 整机截图逐字节） |
| `ui/app.c` | `YESHEN_GUI_GPU_UNIT` 时切 DIRECT（LVGL 直接画 GUI 帧存），每帧末 `FENCE` + `flip_async`；无直写帧存则退回 PARTIAL | 两种构建截图一致 |
| 板端构建 | `GUI_VARIANT=mainline_gpu`（mainline + GPU 单元） | 交叉编译通过，`yshell` 1,325,244 B |

地址安全域（已核对 DTS）：`memory@80400000` 只声明 `0x80400000..0x8FFFFFFF`（252 MB）为 Linux 可用内存；
GUI 帧存 `0x9200_0000/0x9220_0000`、GPU arena `0x9320_0000`、gputest 暂存 `0x9340_0000` 全部在**内核 RAM 之外**
（DDR 1 GB），因此 `/dev/mem` 直写不会踩到内核页缓存。

已知取舍：**A8 图像**实测与 LVGL 的"掩码 + 着色"混合口径有逐像素差异 ⇒ 明确拒绝（交回 SW），
不做近似；`LABEL` 同理（字形遍历收益小）。这两类在 GUI 里由软件单元绘制，结果正确、只是不走硬件。

## 3c. T6 时序返工（2026-10-31）

第一次 PnR（tag `gpu1`，strategy 1）seed 0 报 `soc_clk WNS = -4.088 ns`（基线 `gpu0` 是 +0.606），
头号路径全在 GPU：

```
u_gpu/u_2d/m_idx → s_cov → APM(cov*alpha) → APM((fg-bg)*a) → obuf   （16.8 ns / 10 ns，16 级）
```

即**一拍的混合链路里串了 3 个乘法**。修法（逐位等价，黄金闸门复验）：

1. 混合像素拆两拍：`S_B_MERGE` 只算 alpha 并寄存（`mix_a/mix_fg/mix_bg/mix_wi/mix_lane`）→
   新增 `S_B_MIX` 再算 `mix565` 写 obuf；不混合的 FILL / 不透明 BLIT / alpha≥253 仍 1 拍/像素。
2. `mix_chan` 收窄到 16 位算术（`x = 255*bg + (fg-bg)*a ∈ [0,16065]`），乘法器从 32 位降到 9 位。

代价：混合类像素 2 拍/像素（FILL 不受影响）。
复验：六个 2D 黄金用例仍逐字节吻合；端点级 `GPU-GLUE PASS`。

dev_map 复测（tag `gpu2`）：LUT **91,624**（+3,451.5 vs 基线 88,172.5）、DRM 313、APM 270、0 error。
PnR 用 `gpu2` 重跑（`YESHENMINI_PNR_TAG=gpu2 YESHENMINI_STRATEGY=1`）。
gpu2 PnR seed 0 的时序已收敛（soc_clk **+0.053** / cpu +0.587 / npu +0.376 / core +0.560，
余下只有继承的 `phy_dq_sysclk_0` 弧 −0.027/−0.011），**但该轮输入不含下述 `gpu_cmd` 修复，作废**。

## 3d. `gpu_cmd` 参数握手缺陷（2026-10-31，gpu3 起生效）

CSR 单元闸门（消费者在 `S_PAR` 首拍即给 `par_ready`）抓出两处契约缺陷：

1. `pop_par` 只看 `par_ready` 不看 `par_valid` ⇒ 当消费者早 ready 时，第一拍的
   `par_valid` 尚未置起（寄存器），计数却前进 ⇒ **静默丢首参**（实测 3 条判据红）。
   修：`pop_par = (state==S_PAR) && (left!=0) && par_valid && par_ready`，
   `S_PAR` 内计数/前进也以 `par_valid && par_ready` 为条件。
2. 末个参数握手后 `par_valid` 仍挂一拍，进 `S_DONE` 首拍消费者会**多收一个**
   （实测参数计数 6 vs 期望 5）。修：`left==1` 的握手拍内 `par_valid <= 0`。

为什么之前 2D 黄金门一直绿：`gpu_2d` 的 `par_ready` 恰好晚一拍，把 1 掩盖了；
2 则只在 `S_DONE` 与下一次参数阶段紧邻时显形。**修复后四门全绿**：

| 闸门 | 命令（WSL） | 结果 |
|---|---|---|
| CSR/FIFO | `bash sim/gpu/run_csr.sh` | `CSR PASS`（id, fill, fence, scissor, flip, unimpl, fifo-free） |
| 2D 黄金 ×6 | `bash sim/gpu/run_2d.sh` | 六例均 `2D PASS（逐字节吻合 153600 字）` |
| 读写引擎 | `bash sim/gpu/run_mem.sh` | `MEM PASS`（含 strb=0 负对照） |
| 端点级 | `bash sim/glue_pbus/run_gpu_unit.sh` | `GPU-GLUE PASS` |

因 `gpu_cmd.v` 变动，dev_map/PnR 以 **tag `gpu3`** 重跑（源码 == 投产网表）。

## 3e. 时序：字形覆盖率链再拆一拍（tag `gpu4` 起）

`gpu3` PnR seed 0 报 `soc_clk −0.846 ns`，违例**不在**继承的 PHY 弧，而是在 `u_2d` 内部：

```
Startpoint: u_soc/u_gpu/u_2d/s_lead[2]      （15 级逻辑，Logic 4.295 ns / Route 6.129 ns = 58.8%）
Endpoint  : u_soc/u_gpu/u_2d/obuf[5][42]/CE
链路      : s_lead → s_boff/s_wi → sbuf 16:1 mux → s_cov → APM(cov*alpha) → udiv255 → do_write → obuf/CE
```

基线余量本来就接近 0（`gpu2` 同一张网表 seed 0 只有 **+0.053**），所以这是一条"靠布局运气"的路径；
`gpu3` 的其余种子更差（seed 1 布线 60 min 后仍有 49,619 条未布通，已弃跑）。

修法（`42c5d36`，逐字节等价）：字形路径拆成三拍 ——
`S_B_MERGE` 只锁存 `s_cov` → 新增 `S_B_COV` 算 `eff_a = udiv255(cov*alpha)` 并判 `a_eff >= 2`
→ `S_B_MIX` 算 `mix565` 写出。`a_eff >= 253` 时用 `mix_direct` 直写前景色，保持与旧版逐字节一致。
非字形混合/不透明 BLIT 的路径不变，FILL 不受影响。

复验：2D 六用例（含 `glyph` / `round32`）逐字节 PASS（独立 C 黄金）、`GPU-GLUE PASS`、lint 0 error。
另做**计数器级 A/B**（同一 glyph 用例，改前 `42c5d36^` vs 改后，各跑一次）：
`cmds_words=54 / aw=80 / w=563 / npx=2184 / nflush=563 / beats=563 / wr_cyc=563` **逐项相同**
——不只帧字节一致，像素计数与写回笔数也一致。
代价：仅字形从 2 拍/像素变 3 拍/像素（A8 图像本就走 SW，文本量级可忽略）。

dev_map `gpu4`（修后网表）：LUT **91,600**（+34 vs gpu3）、FF 123,774（+4）、DRM 313、APM 270、0 error。
PnR 用 `gpu4` 重跑（`YESHENMINI_PNR_TAG=gpu4 YESHENMINI_STRATEGY=1`）。

**gpu4 PnR seed 0 结果（修复有效）**：soc_clk **+0.392 ns**（修前同种子 −0.846，**+1.238 ns**）、
cpu_clk +0.505、npu_clk +0.465；`Design Summary` 仍报 `Some Constraints Violated`，但唯一违例是
**继承的 DDR PHY 内部弧** `phy_dq_sysclk_1 → u_ddr3/…/TSERDES_731_1076`，slack **−0.001 ns**
（逻辑 0.549 ns / 布线 5.440 ns，与本轮改动无关；同族弧在 gpu2 上是 −0.027/−0.011）。
判"是不是我引入的"按 per-clock WNS 表：本轮动的只有 `soc_clk` 域，现已 +0.392。

**交付口径先例**：`ctp1`（此前上板的 KEY4 版）也是 `Some Constraints Violated`，唯一违例同样在
`phy_dq_sysclk_0`（−0.010），设计时钟 soc +0.653 / cpu +0.491 / npu +0.309；`ctp2` 才是 All Met。
即"仅剩继承的 DDR PHY 内部弧"在本项目已有先例，属可交付状态；`gpu4` 若最终仍只剩这一类弧，
按同一口径交付，并在上板记录里注明。

dev_map `gpu3`（cpu_clk 10.000 ns、strategy 默认）：LUT **91,566**、FF 123,770、DRM 313、APM 270、
Distributed RAM 8,169、**0 error**。相对 `gpu2`（91,624）LUT −58 —— 修复只改了握手条件，
面积几乎中性，也反过来证明这版网表确实由修后源码生成（若同一输入，dev_map 结果确定）。
gpu3 启动时间 07:06:34 > 全部 RTL 的 mtime（最新 `gpu_cmd.v` 07:01:16）。

## 3f. **上板抓到的真缺陷**：FENCE 的完成语义（tag `gpu5` 起）

`gpu4` 比特流上板跑 `gputest` 报 `MISMATCH=5764 first@(0,8)`：第 0 行只落地前 8 个像素，
其余全是期望值以外的内容。用 `gpudiag`（单条 64×4 FILL，紧跟 FENCE，然后回读）定位：
**FENCE 返回时 DDR 里一个像素都没写**。

根因在 `gpu_cmd.v`：`S_DONE` 里**无条件**用 `fence_seq` 发布 `seq_done`，没等引擎的 `cmd_done`：

```verilog
// 修前
if (is_fence) seq_done <= fence_seq;      // 命令刚下完就报"引擎已完成"
```

即 FENCE 只保证"参数收完"，不保证"2D 引擎把写回排空"。软件按 `SEQ_DONE` 轮询后立刻
回读 DDR ⇒ 读到半成品。修法（`48c8b23`）：`S_DONE` 里先 `if (cmd_done)` 再发布，
两类命令统一到"引擎确认完成才进 `seq_done`"。

**闸门（先红后绿）**：`sim/gpu/tb_gpu_csr.v` 新增用例 ⑧ —— 执行器 stub 加可编程延迟
（`hold=60`），慢 FENCE 之后紧发一条 `0x2222`，在参数握手中/后 10 拍检查 `seq_done`
不得提前等于 `0x2222`。

```
修前（git 48c8b23^）：MISMATCH FENCE 提前发布（引擎未完成时 seq_done=2222） / CSR FAIL errors=1
修后（HEAD）        ：CSR PASS（id, fill, fence, scissor, flip, unimpl, fifo-free）
```

`gpu4` 比特流是修前网表，**不可用于 2D 上板判据**；以 `gpu5`（dev_map 启动 13:15:0x >
`gpu_cmd.v` mtime 13:14:24）重出。

dev_map `gpu5`：LUT **91,596**（gpu4 91,600 / gpu3 91,566）、FF **123,776**、DRM 313、
APM 270、Distributed RAM 8,169、**0 DRC error**。FENCE 只是把 `seq_done` 的发布条件
加了 `cmd_done`（多一级与门），面积几乎中性（+30 LUT vs gpu3）。

## 3g. **第二个上板真缺陷**：PDS 把 sbuf/dbuf 推断成 RAM（tag `gpu6` 起）

`gpu5` 上板（FENCE 已修）仍有 `MISMATCH=5767`，分区统计把它切成：

| 区域 | 失配 |
|---|---|
| 棋盘 FILL | 1125（含 CPU/GPU 同址竞争成分） |
| ROUND_FILL | 668 |
| **BLIT 64×48** | **3072 = 全区** |
| **GLYPH 32×32** | 899 / 1024 |

而 `gpudiag` 的整屏 FILL 是 **131072/131072**。即"**只写不读的算子全对，要读源的算子全错**"。

逐 y/x 扫描（`gpudiag` 用唯一色 `0x8000|(y<<6)|x` 编码源）得到精确规律：

```
sx=0 dx= 0 → 源下标 0      sx=4 dx=0 → 4      sx=4 dx=8 → 12
dx=2→0  dx=6→4  dx=10→8  dx=14→12  dx=16→0
```

即 **BLIT 的源像素起点 = s_sx + ((目标字节地址 & 0x18) >> 1)** —— 源指针跟着**目标**地址的
8 B 字索引走（0/1/2/3 字，32 B 回绕），与源自己的地址无关。

仿真对同一条命令是干净的：golden `blit565` 用的就是 `dx=100`（dev_map/2D 闸门历来全绿）。
差异只能在综合侧。dev_map 日志给出物证：

```
I: Sdm-0001: [.../rtl/gpu/gpu_2d.v(line 202)] Found Ram sbuf, depth=16, width=64.
I: Sdm-0001: [.../rtl/gpu/gpu_2d.v(line 202)] Found Ram dbuf, depth=16, width=64.
```

`sbuf`/`dbuf`（以及 `obuf`/`ostb`）是 16 深的寄存器数组，仿真按普通数组语义；PDS 把
它们推断成 RAM 后，**读出行为与仿真不再等价**。这也解释了为什么 FILL 全对——FILL 走
`acc_data/acc_strb` 那条纯寄存器路径，根本不碰这四个数组。

### 试解 ①：把 sbuf/dbuf 钉成寄存器（`gpu6`）——**无效**，但排除了一条**

按 PDS 文档 `UG990102 §8.2.18 syn_ramstyle`，给 `sbuf/dbuf/obuf/ostb` 加
`(* syn_ramstyle = "registers" *)`。dev_map `gpu6` 的 FF **123,776 → 125,820（+2,044 ≈
sbuf+dbuf 的 2,048 位）**、LUT +457、Distributed RAM −64 ⇒ 数组**确实**变成寄存器了。
但板上重跑 `gputest` 的失配数与 gpu5 **逐项相同**（5764 / board=1125 / round=668 /
blit=3072 / glyph=899）⇒ **RAM 推断不是这条偏移的成因**（照样保留寄存器化：
它让网表语义与仿真一致，本身是对的）。

### 试解 ②（真正命中）：clocked 块里的块内局部变量被当寄存器（`gpu7`）

翻 dev_map 日志找依据时抓到物证：

```
W: Sdm-2020: [rtl/gpu/gpu_2d.v] Unused register calc.d_byte was removed.
W: Sdm-2020: [rtl/gpu/gpu_2d.v] Unused register calc.s_byte was removed.
```

`S_B_CHUNK` 里把地址算成**块内局部变量**（`begin : calc reg [31:0] d_byte; ...` 的
blocking 赋值），仿真语义是"块内立即生效"，但 PDS 把这种写在 clocked 块里的局部变量
**建模成寄存器**，随后又作为"未使用"删掉 —— 于是 `d_cbase/s_cbase/d_lead/s_lead`
拿到的不是仿真里那个值。同一模块里 `S_ROW` 的 `merge.nd` 也报同样告警，但 FILL 用的是
另一套 `acc_data/acc_strb` 直算路径，所以 FILL 一直是对的（131072/131072）。

修法：把这些量全部提到**模块级组合逻辑**（不再有块内局部变量）——
`d_byte_c/s_byte_c/c_px_c` 用 `always @(*)`，`cov_a` 用 `wire`，
混合写回改用 `set_px()/set_stb()` 两个函数直接算 64 位字与自节选通。

dev_map `gpu7`（对 gpu6 的差分 = 这条修复）：FF 125,820 → **125,882**（+62）、
LUT 92,053 → **92,665.5**（+612.5，函数化的写回比原来多一级选择）、DRAM/DRM/APM 不变。
**但 `gpu7` 上板后 `gputest` 的失配数与 gpu5/gpu6 逐项完全一致**
（5764 / 1125 / 668 / 3072 / 899）——**三张不同网表给出同一结果 ⇒ 不是逻辑表达式的问题**。

## 3h. **第三个上板真缺陷**：读拍被丢（简化 AXI 桥不保持早到的 rvalid）

把三张网表的"完全相同"当成线索反推：如果偏移来自逻辑式，改 RTL 必然改变数字。
数字不动 ⇒ 丢的是**拍**，不是值。于是做了一次"尾部判别"探针（源 128 px 唯一编码，
BLIT 64 px @ dx=8）：`dst[56..63]` **全是 0** —— 既不是 `src[64..71]`（读地址整体 +16 会这样），
也不是 `src[0..7]`（sbuf 索引回绕会这样），而是"**从未被写过的 sbuf 项**"。
⇒ 读回的 **beat0/beat1 根本没进 sbuf**，后面每一拍都提前两格落位，最后两格空着。

根因在 `gpu_mem.v` 的读 FSM：

```verilog
assign m_rready = (rds == RD_DATA);   // 比 AR 握手晚一拍才拉高
```

本工程的简化 AXI（MemArbiter / DDR3Bridge）**不会在 rready=0 时保持 rvalid**——数据可能
在 AR 握手的同一拍或下一拍就到，于是头两拍被直接丢掉。仿真的 AXI RAM 模型严格等
rready，所以 `MEM PASS` / 2D 六例一直全绿。这正是"简化 AXI 契约不能按标准 AXI 想当然"
那条纪律的又一例。

修法：

```verilog
assign m_rready = 1'b1;   // 读口常 ready
// 数据拍不按状态门控：AR 之后随时可能来（含与 AR 握手同拍的首拍）
if (m_rvalid && (rds != RD_IDLE)) begin ... end
```

（第一版改动把 `RD_DATA` 落进了 `default: rds <= RD_IDLE`，MEM 闸门立刻报 timeout——
闸门确实会响；补上 `RD_DATA: ;` 后 MEM/2D×6/CSR/GPU-GLUE 全绿。）

> 教训（已折进 `feedback-inferred-ram-mapping-check`）：本项目"仿真全绿"**不覆盖**
> RAM 推断带来的语义变化。凡是仿真里当寄存器数组用的小缓冲，都要么显式钉
> `syn_ramstyle="registers"`，要么在 dev_map 日志里核对没有被 `Found Ram` 收走。

## 3i. 卡片内容复核 + 板侧当前状态（2026-11-01）

`sim/board/verify_sd.ps1 -Disk 2 -Img sw/images/sd_gpu0.img`（只读；读 `\\.\PhysicalDriveN`
必须**管理员**，非提权会 `访问被拒绝`）：

| 项 | 值 |
|---|---|
| 镜像 | 14,626,304 B，sha256 `0d09ce688c954bc9e958326dd7f07db19b6babae8b23fcaa0a3cd5073cbfe113`，md5 `70c2d8c3…` |
| 卡前 14,626,304 B | sha256 **同上**，md5 `70c2d8c3…` |
| 判据 | **`CARD MATCH`**，`EXIT=0` |

即卡内容与仓内镜像逐字节相同（header + 5 段 CRC 与 payload 都在同一份镜像里）。

板侧状态：`gpu9` 已烧（sbit 9,188,552 B，sha256 `5d0eb1a5b0c2b16d…`，**All Constraints Met**：
soc +0.534 / cpu +0.614 / npu +0.520 / core +0.749）。2D 判据仍红在 BLIT/GLYPH 的源偏移
（§3g/§3h 已排除 RAM 推断、块内局部变量、rready/桥保持三类）；gpu9 里已带读路径边界探针
CSR `0x030`(AR) / `0x034`(len,cnt) / `0x038`/`0x03C`(前四拍低 16 位)，下一次板窗口先读这组
数：AR 错 ⇒ 地址侧；AR 对而 b0/b1 不对 ⇒ 数据侧落位。

## 3j. **第四个上板真缺陷**：GPU 突发没按 32 B 对齐（DDR 用户口粒度）

§3i 里那组探针读出来的结果（gpu9 + `gpudiag`，BLIT 64×1 @ d=(8,8)，源 128 px 唯一编码）：

```
ID=0x59475055  FILLBAD=0                       ← 整帧 FILL 正确（只写不读）
AR=0x93500000 R34=0x000F10A5                   ← AR 对；len=15 ⇒ 16 拍；cnt=16
R38=0x80048000 R3C=0x800C8008                  ← 交付的第 0..3 拍 = 8000/8004/8008/800C
                                                  （8 B/拍 ⇒ src[0]/[4]/[8]/[12]，正确）
hit[0] idx=4096 (x=0,y=8) val=8000 ... NONFILL=64
```

即：**读侧完全正确，写侧 64 个像素一个不少、值也对，但整段从 x=0 开始写**（dx=8 被吃掉）。
再做一组 dx 不同的判别（同一批 BLIT，w=8）：

| dx | 落点 x | 字节地址 |
|---|---|---|
| 40 | **32** | 0x50 → 0x40 |
| 8 | **0** | 0x10 → 0x00 |
| 4 | **0** | 0x08 → 0x00 |
| 0 | 0 | 对齐，正确 |

落点 = 把起始字节地址按 **32 B 块**向下取整。契约上也对得上：
`io_ddrWData` 是 **256 bit = 32 B/拍**、`io_ddrAwAddr` 是 28 bit 的 **32-bit 字地址**
（`video_passthrough.v` 的 `FB_ADDR_WORD 0x0400_0000 字 = 0x1000_0000 字节` 就是这个口径），
`DDR3Bridge` 把 AXI 首拍的 `awaddr[29:2]` 直接当组基址 `wqAddr`、组内填充从 0 拍起，
**不补偿非 32 B 对齐的首拍** ⇒ 整段数据下移 (addr & 0x1F) 字节。
FILL 之所以一直全对：行首地址 = base + y*stride（512×2=1024 B）天然 32 B 对齐。
这也解释了 §3h 里"五张网表错点数完全一样"——它不是逻辑式，是总线契约。

修法（`a698c34`，对外仍是 8 B 粒度，全部收在 `gpu_mem.v` 一层）：

* **写**：burst 基址向下取 32 B，前补 `pad = addr[4:3]` 个 `wstrb=0` 的空拍
  （缓冲仍 16 字，总线最多 19 拍）；
* **读**：从 32 B 基址取，多取 `pad` 拍、交付前丢掉，`rd_last` 按交付拍数计；
* `gpu_2d.v` 补一条**源窗口夹紧**：`s_lead + c_px*bpp ≤ 128 B`。原来只按目标对齐夹，
  `s_lead=7` 且 `c_px=64` 时会算出 17 拍，sbuf（16 深）会回绕——是潜伏缺陷。

闸门（`a698c34` 后全绿）：`run_2d.sh` 七例 `2D PASS（逐字节吻合 153600 字）`、
`run_mem.sh` `MEM PASS`、`run_csr.sh` `CSR PASS`、`run_gpu_unit.sh` `GPU-GLUE PASS`、
`negctl_gpu_pbus.sh` 负对照当场翻红并复原（md5 一致）。

**新增永久闸门 `sim/gpu/run_2d_trunc32.sh`**：给 AXI RAM 模型加 `TRUNC32=1`——
读写突发的起始地址按 32 B 块向下取整（= 板级 DDR 用户口的真实行为）。两臂实测：

| 臂 | gpu_mem | 结果 |
|---|---|---|
| 红 | `a698c34^`（旧） | `blit8` / `blit565` 均 `2D FAIL`，mismatch 呈整段下移特征 |
| 绿 | 当前 | 七例全 `2D PASS（逐字节吻合 153600 字）` |

> 这条闸门现在能离线抓住这次上板才发现的缺陷——以后改 `gpu_mem` 不会再"仿真全绿、上板偏移"。

> 教训：**"上层按 8 B 写字、下层按 32 B 搬块"这种粒度转换必须显式做**。
> 仿真的 AXI RAM 模型逐拍按地址放数，天然"支持"任意对齐，所以七道闸门全绿；
> 只有真 IP 的 256-bit 用户口会把低 5 位吃掉。这条已折进
> `feedback-simplified-axi-contract`（简化 AXI 不能按标准 AXI 想当然）。

### 3j-1. 上板复验（gpu10，2026-11-01）

`gpu10` = 32B 对齐修复 + 新判据的网表（soc_clk **All Constraints Met**，+0.426 ns；cpu +0.579 / npu +0.232 / core +0.436；
sbit 9,188,552 B，sha256 `2e71d89a67f53364…`，md5 `6179dbfd…`）。

```
gputest: ID=0x59475055（期望 0x59475055）
gputest: 分区失配 board=0 round=0 blit=0 glyph=0 blit2=0
gputest: err=0 seq=2 DBG=0x07000006 => PASS     RC=0
```

五个分区（棋盘 FILL / ROUND / BLIT / GLYPH / **非对齐 blit2**）逐像素失配全 0；scissor 负对照与
判据自证（改一个期望像素必须报 MISMATCH=1）都包含在 `err=0` 内。板上 `/tmp/gputest` md5
`6859c9cc…` 与仓内 `y1/build/gputest` 一致。**P1-T8 收口。**

## 4. T6 PnR

> **PnR 约定（2026-11-01 起）**：`YESHENMINI_PNR_TAG=<tag> YESHENMINI_STRATEGY=1
> YESHENMINI_PNR_SEEDS=1 YESHENMINI_PNR_GSEED=<n>` —— **单种子**。
> 只给 `SEEDS=1` 还不够：`-pick_first_timing_convergence_seed true` 会一直换种子直到全约束满足，
> 单跑要 ~40 min/颗；走 `GSEED` 入口才是"只跑这一颗 + `-force_to_run`"。
> 轻微违例（如只剩继承的 DDR PHY 内部弧）按既有口径可交付。

`YESHENMINI_DEVMAP_TAG=gpu4` → `YESHENMINI_PNR_TAG=gpu4 YESHENMINI_STRATEGY=1`
（`-gplace_times 4 -saved_outcome 4 -pick_first_timing_convergence_seed true`）。
判据 = `.rtr` 的 `Design Summary`（All Constraints Met，或仅剩继承 PHY 弧）+ `YESHENMINI_PNR_DONE`
+ 比特流尺寸/指纹（用 `bash scripts/pnr_verdict.sh gpu4` 一键取）。

seed 0 已回（正文 §3e）：`soc_clk +0.392` / `cpu +0.505` / `npu +0.465`，仅 `phy_dq_sysclk_1`
内部 TSERDES 弧 −0.001。seed 1–3 继续跑，第一个全约束满足的种子会提前收束并出比特流。

**最终结果（seed 1 收敛，流程在此收束，`Best Seed = 1`，`PNR_RC=0`）**：

| 项 | 值 |
|---|---|
| Design Summary | **All Constraints Met** |
| soc_clk | 104.888 MHz @ 10 ns 约束，slack **+0.466** |
| cpu_clk | 105.285 MHz，slack **+0.502** |
| npu_clk | 61.478 MHz，slack **+0.401** |
| core_clk | 137.589 MHz，slack **+0.732** |
| 比特流 | `generate_bitstream/yeshen_mini_board_top.sbit` **9,188,552 B**，sha256 **`9f5690ab91c557c01ae56650139ce5ff…`**，md5 `f0a363d9…` |

源码 → 网表 → 比特流的新鲜度链：`gpu_2d.v` mtime 09:06:57 < dev_map gpu4 首条时间戳 09:09:18
< PnR gpu4 09:25:58 < sbit 11:34；`git status rtl/ board/ src/` 为空（净源码 == HEAD）。
`seed 0` 的 −0.001 物证保留在 §3e（说明"同网表下这条 PHY 弧随布局漂"，seed 1 直接满足）。

## 5b. 上板 runbook（一次窗口做完；需用户给板窗口）

前置：板子空闲（同 cwd 无其它 running 会话在烧板/收串口）；卡 `sw/images/sd_gpu0.img`
（14,626,304 B，sha256 `0d09ce68…e113`，header+5 段 CRC 已独立复验）。

**① P0 放行位（CBO）**

```bash
python -u scripts/flash_and_verify.py --tag gpu0 --no-net     # 判据：启动 marker 8/8
python scripts/gpu_board_judge.py --test cbo                  # 判据：CBO POS=1 NEG=1 ⇒ PASS
```
`CBO SIGILL (cbo.flush 在该特权级被拒)` + rc=132 ⇒ 放行位没生效：按 `docs/reports/gpu-p0-zicbom.md`
§4 的方法扫镜像里的 `senvcfg`/`menvcfg` 指令（2 字节步长），别改 RTL。

**② GPU 2D**

```bash
python -u scripts/flash_and_verify.py --tag gpu10 --no-net    # 判据：启动 marker 8/8
python scripts/gpu_board_judge.py                             # 判据：=> PASS
```
`gputest` 内含 scissor 负对照与**判据自证**（改一个期望像素必须报 `MISMATCH=1`）。
`gpu10` 起 `gputest` 还带一条**非对齐源/目标 BLIT**（src (4,2) → dst (17,200)，40×8），
分区统计里多一桶 `blit2`——这一桶必须为 0（它专测 32 B 对齐的两条新路径）。
若整片仍偏移，先跑 `/tmp/gpudiag`（BLIT dx=18/4 + sx=4）看落点，再判是地址侧还是数据侧。

**③ 可选：GFX 实况**：把 `YeshenGui/board/variants/mainline_gpu/yshell` 推上去跑 30 s，
看日志 `GPU-UNIT-ON` 与 `DBG` 计数；屏幕 GUI 应与旧版逐像素一致（host 已证一致，板上复核实况）。

⚠️ 出图前提：`video_passthrough` 读到的是 GUI bank，需软件把 `GUI_CTRL[0]=1`（`gui_src`），
`FLIP` 才会切 bank（本版 `gui_bank = flip_toggle ^ GUI_CTRL[1]`）。

## 5. 与 spec 的偏差记录

1. `gui_bank` 的唯一主人是 GPU（`flip_toggle ^ GUI_CTRL[1]`）；`GUI_CTRL[1]` 只做整体反相。
2. vsync 跨域 = `frame_rd_toggle`（ddr_clk 翻转电平）+ SoC 内 2FF + 边沿检测；
   单拍脉冲会被 100 MHz 的 2FF 漏采。
3. 实际换 bank 落在 FLIP 之后**第二个**读帧起点（视频侧同拍锁存所致，晚一帧；
   `flip_pending` 可观测，不影响画面对齐）。
4. 上板 2D 判据实现为**板上自检** `y1/tools/gputest.c`（逐像素期望在 C 里独立算，
   含 scissor 负对照与"改一个期望像素必须报 MISMATCH=1"的判据自证），
   而不是计划 Task 8 的 `eth_memread` 读回 + 主机黄金。理由：少一次大数据回传、
   判据自证更强、失败定位在板上一次完成；`scripts/gpu_board_judge.py` 统一驱动
   （`--test gpu|cbo`）。`eth_memread` 读 `0x9220_0000` 整帧保留作可选复核。

## 6. 上板前完成度（2026-10-31 收口，逐项对证据）

| # | 交付物 | 证据（当日重跑/现物） |
|---|---|---|
| 1 | 核带 Zicbom | `gen_core.sh:--with-isa …,zicbom`；网表 md5 `54931ad7…`；CBM 信号在网表里 |
| 2 | M 态放行位 | `fw_jump.bin` md5 `1e809d43…`；menvcfg `csrrs` 旧 5 → 新 6 条（2 B 步长扫描 + 旧件 A/B） |
| 3 | U 态放行位 | `Image` md5 `45ac4f04…`；senvcfg 0 → 1 对 `csrrs`+`csrrw`（@0x2383E/0x23846） |
| 4 | P0 比特流 | `gpu0` sbit sha256 `cf3838c2…`，**All Constraints Met**（cpu +0.509 / npu +0.694） |
| 5 | P0 卡 | `sd_gpu0.img` 14,626,304 B，sha256 `0d09ce68…`，header+5 段 CRC 独立复验 PASS |
| 6 | 寄存器单一来源 | `check_gpu_regs.py`：`GPU-REGS-MIRROR OK 24 entries` |
| 7 | 2D 黄金 | `run_2d.sh` 六例（fill_rect/blit565/glyph/round32/scissor/edge）逐字节 PASS |
| 8 | 读写引擎 | `run_mem.sh`：`MEM PASS`（write16/read16/combine32/strb0-neg） |
| 9 | CSR/FIFO/命令 | `run_csr.sh`：`CSR PASS`（id/fill/fence/scissor/flip/unimpl/fifo-free） |
| 10 | 端点级集成 | `run_gpu_unit.sh`：`GPU-GLUE PASS`；负对照 `negctl_gpu_pbus.sh` 翻红后复原 md5 |
| 11 | 结构闸门 | 悬空 0 PASS / Xilinx 残留 0 PASS / 地址台账 21 处 PASS / 布局 lint 0 error |
| 12 | dev_map gpu4 | LUT 91,600 / FF 123,774 / DRM 313 / APM 270 / **0 error** |
| 13 | PnR gpu4 | **All Constraints Met**（soc +0.466 / cpu +0.502 / npu +0.401 / core +0.732） |
| 14 | GPU 比特流 | sbit 9,188,552 B，sha256 `9f5690ab91c557c01ae56650139ce5ff…`，md5 `f0a363d9…` |
| 15 | 用户态驱动 | `run_gpu_host_test.sh` 当日重跑：`GPU_HOST: PASS (6/6 例)` |
| 16 | LVGL draw unit | `run_gpu_unit_host_test.sh` 当日重跑：`GPU_UNIT_HOST: PASS`（帧存一致 81,920 B、GPU 接管 8 任务 / 58,518 px、整机截图一致 1,843,216 B） |
| 17 | GUI 板端构建 | `YeshenGui/board/variants/mainline_gpu/yshell` 1,325,244 B，md5 `1c23ed87…`（树干净 @`71eb9cb`） |
| 18 | 上板判据工具 | `y1/build/gputest` md5 `daa6364e…`、`y1/build/cbotest` md5 `3e1fa575…`；`gpu_board_judge.py --test gpu\|cbo` 离线自测 6/6 |
| 19 | 一键 PnR 判据 | `scripts/pnr_verdict.sh`（正例 gpu0/gpu4、违例例 ctp1、缺件负例均验过） |
| 20 | 文档 | 本报告 + `gpu-p0-zicbom.md` + 计划进度块 + 上板 runbook（§5b） |

**未完成（需用户板窗口，属"上板"而非"上板前"）**：① P0 `cbotest`（`CBO POS=1 NEG=1`）；
② GPU `gputest`（`=> PASS`）；③ 可选 GFX 实况复核。
**不在本批范围**：P2a 3D（spec §11 的下一批，按用户"这一版上板没问题后再并行加速"的约定）。
