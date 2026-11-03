# 简易 GPU（2D 加速 + 3D 窗口）设计

- 日期：2026-10-30（2026-10-31 修订：采纳资源节省项 + CPU 顶点变换）
- 平台：盘古 676 200K MINI（PG2L200H-6FBB676）+ Vexii RV32 Linux
- 基线：`ctp2`（sbit `c01d6a6f…`，LUT 88,083/159,800、FF 119,648、DRM 312/415、APM 257/740、IO 166/400）

## 1. 目标与非目标

**目标**

1. **2D 加速**：GPU 作为 LVGL 9.2 的 draw 后端，硬件执行
   纯色填充、RGB565 图像 blit、A8 字形 alpha 混合、圆角矩形填充、裁剪。
   其余图元（阴影/渐变/弧线/变换/AA 圆角）由 LVGL 软件回退。
2. **3D 窗口**：**屏幕空间光栅器 + 16-bit Z-buffer**（顶点变换在 CPU），
   **640×480 窗口、≥30 fps**，嵌入桌面并可触摸交互（拖拽旋转 + 按钮缩放）。
3. **双帧存 + 帧级翻转**：消除一直存在的撕裂，并让 GPU/LVGL 都能"渲染后备、整帧切换"。

**非目标（本设计明确不做）**

- 硬件顶点变换 / 4×4 矩阵单元（归 CPU，见 §6.1）、纹理采样/UV、可编程着色器、
  MSAA、YUV/视频格式、blit 缩放旋转、硬件渐变/阴影/圆弧、多 GPU 实例。
- 不改板级 2:1 DDR 仲裁器（GPU 走 glue 侧 64-bit 通路）。

## 2. 硬约束（设计前提，均有出处）

| # | 约束 | 依据 / 影响 |
|---|---|---|
| C1 | **CPU D\$ 写回式，且核内没有 CACOP/cbo 指令** | `peripheral/UartLoader.scala` 文件头；⇒ 加上游 `zicbom` 才能让 GPU 读到 CPU 刚写的数据 |
| C2 | 上游 VexiiRiscv 自带 Zicbom（LsuL1 内生 CBM） | `Param.scala:701/1230`、`LsuL1Plugin.scala` 的 `withCbm`；⇒ 改 `scripts/gen_core.sh` 的 `GEN_ARGS` 即可 |
| C3 | glue 已有 `MemArbiter(3)`（CPU 组 / NPU / DMA），owner 4 bit 仅用 8 态 | `YeshenSocGlue.scala` §3.5；⇒ GPU 作第 4 组（10 态，仍 4 bit） |
| C4 | 板级 DDR 只有 **2:1** 仲裁（桥 64-bit / 视频 256-bit） | `board/cam/ddr_arbiter_2to1.v`；⇒ GPU 不接视频侧 |
| C5 | **DRM 312/415（75%）是第一资源瓶颈**；LUT 56%、APM 35% 尚有余量 | `ctp2` dev_map；⇒ 片上缓冲按 KB 计、优先 LUT-RAM（见 §12 节省项） |
| C6 | LCD 1024×600 @51.923 MHz，帧存行 60..659、步长 2048 B；GUI 读窗 4 MiB | `video_passthrough.v`、`gui-framebuffer.md` |
| C7 | 时钟：`soc_clk`=100 MHz；`cpu_clk` 独立；DDR 侧 `core_clk`=125 MHz；DDR 1 GB | 现有板级结构；GPU 全部跑 `soc_clk` |

## 3. 架构

```
                 ┌──────────────────── YeshenGpu (soc_clk) ─────────────────────┐
  pBus 0xF0005000│ CSR 文件 ──► 命令解析器 ──► 2D 引擎（fill/blit/glyph/round）─┐ │
  (glue 窗) ────►│                            └► 3D 光栅器（setup+raster+Z）───┼─┼─► 共用读引擎 ┐
                 │                                     ▲ 顶点列表（屏幕空间）  │ │              ├─► 64-bit AXI4 主口
                 │                                     └── tile 分桶（LUT-RAM）│ │  共用写合并 ◄┘
                 └───────────────────────────────────────────────────────────┘ │
                                                    │
                                    glue MemArbiter(N=4, 新组 GPU_RD/GPU_WR)
                                                    │
                                            DDR3Bridge(64-bit) ──► 板级 2:1 ──► DDR
```

- **共用读写引擎**：一套地址生成 + burst 读 FIFO + **写合并 FIFO**；2D/3D 只产出像素流。
- **RTL 分层（逻辑分开、硬件不复制）**：`gpu_csr.v` / `gpu_cmd.v`（FIFO+解析）/ `gpu_mem.v`
  （共用读写引擎）/ `gpu_2d.v` / `gpu_3d.v`（setup+raster+Z）各自独立文件、独立单测；
  **`GPU_WITH_3D` 综合开关**（默认 1；出 P1 比特流时置 0，把 3D 整块剪掉，2D 链路零改动）。
  **不**做两套读/写引擎或两个 AXI 主口：v1 里 2D 与 3D 从不同时运行（3D 先渲到离屏缓冲，
  再 `COMPOSITE3D` 拷进帧存），复制引擎只多 3–5 K LUT + 一套 FIFO，换不到任何并行度。
- **CSR 窗**：`0xF0005000`（4 KiB，当前 0x5000 段空闲）。
- **中断**：**v1 不接 PLIC**（纯轮询 `SEQ_DONE`）；GPU 预留 `irq` 输出，P2 若需要再接入源 6
  （省掉 `PlicAlite.NDEV` 5→6 与一条中断验证面）。
- **内存主口**：64-bit AXI4（与 NPU/DMA 同形），`MemArbiter(4)` 新增 `OWN_GPU_RD/GPU_WR`，
  owner 保持 4 bit，同一条"同一时刻只有一方被授予"的纪律。
- **时钟域**：全部 `soc_clk`。
- **固定 DDR 布局**（写在 RTL 常量里，v1 不做可编程基址，省寄存器/比较逻辑）：

| 用途 | 物理地址 | 大小 |
|---|---|---|
| GUI 后备帧存（bank 1） | `0x9220_0000` | 1,474,560 B（GUI 读窗 +2 MiB 内） |
| 3D 颜色缓冲（640×480 RGB565） | `0x9300_0000` | 614,400 B |
| 3D 深度缓冲（640×480 U16，0=近） | `0x9310_0000` | 614,400 B |
| GPU 顶点/动态缓冲 arena | `0x9320_0000` | 1 MiB |

## 4. 命令模型（v1：MMIO PIO FIFO）

- 32-bit 命令字，小端；**FIFO 深 16 项**（LUT-RAM）。
- 普通字写 `CMD_DATA`；**一条命令的最后一个字写 `CMD_PUSH`**（推入并触发执行）。
- 顺序执行；`FENCE seq` 完成后 `SEQ_DONE=seq`。
- 命令 = `{op[7:0], nwords[7:0], flags[15:0]}` + 参数（`nwords` 不含头）。
- 命令开销：整屏重绘 ≈ 200–800 条 × ≤12 字 ≈ 1 万字 → **100–200 µs @100 MHz**。

### 4.1 寄存器（CSR 窗偏移）

| 偏移 | 名称 | 读写 | 说明 |
|---|---|---|---|
| 0x000 | `ID` | RO | magic `0x59475055`（"YGPU"）、version、caps |
| 0x004 | `STATUS` | RO | [0] busy、[7:4] FIFO 占用、[8] err、[15:9] errcode、[16] flip pending（v1 不产生 err，恒 0） |
| 0x008 | `IRQ_EN` | RW | [0] done、[1] err（v1 默认 0） |
| 0x00C | `IRQ_CLR` | WO | 写 1 清 pending |
| 0x010 | `CMD_DATA` | WO | 推入一个命令字（不触发） |
| 0x014 | `CMD_PUSH` | WO | 推入最后一个字并触发 |
| 0x018 | `SEQ_DONE` | RO | 已完成命令序号（16 位） |
| 0x01C | `FIFO_FREE` | RO | 空闲项数（软件限流） |
| 0x020/0x024 | `SCISSOR` | RW | `x0\|y0<<16`、`x1\|y1<<16`（默认全屏） |
| 0x028 | `FLIP` | RW | 写 1 请求下一 LCD 帧起点切 GUI bank；读回 pending |
| 0x02C | `DBG` | RO | 最近 op / 耗时计数 |

> 不设矩阵/视口寄存器：顶点在 CPU 侧变换到屏幕空间（§6.1），视口固定 640×480。

### 4.2 命令集

| op | 名称 | 参数 | 语义 |
|---|---|---|---|
| 0x01 | `NOP` | — | — |
| 0x02 | `FILL` | dst, stride_px, x, y, w, h, rgb565 | 纯色填充（受 SCISSOR） |
| 0x03 | `BLIT` | src, src_stride, fmt, sx, sy, w, h, dst, dst_stride, dx, dy, flags, alpha | 位块；**v1 只做 fmt=RGB565**（A8 位块走 GLYPH，它带 fg）；flags.bit0=blend |
| 0x04 | `GLYPH` | src(A8), stride, sx, sy, w, h, dst, dst_stride, dx, dy, fg, alpha | `dst = lerp(dst, fg, a*alpha/255)` |
| 0x05 | `ROUND_FILL` | dst, stride_px, x, y, w, h, radius, rgb565 | 圆角矩形（无 AA，Bresenham 增量求内缩） |
| 0x06 | `SET_SCISSOR` | x0, y0, x1, y1 | 设置裁剪 |
| 0x07 | `FENCE` | seq | 屏障 |
| 0x10 | `CLEAR3D` | rgb565, z | 清 3D 颜色 / 深度（写引擎） |
| 0x11 | `DRAW_TRIS` | vbuf, count, flags, color | `count` 个屏幕空间三角形；flat 颜色统一由 `color` 给；flags = 剔除/深度函数 |
| 0x12 | `COMPOSITE3D` | dst, dst_stride, dx, dy, w, h | 3D 颜色缓冲 → 帧存（opaque blit） |

`FLIP` 不占命令，直接写寄存器（可与 `FENCE` 配合）。

## 5. 2D 引擎

- **目标格式**：固定 RGB565。**源格式 v1：RGB565 + A8**；ARGB8888 为综合开关（默认关，
  带透明的图标在构建期转"RGB565 + A8 两平面"，复用 GLYPH 的混合路径）；1bpp 字形在加载时展开为 A8。
- **写路径**：按行处理，内部 64-bit 组包 + 写合并 FIFO（≥ 8×64 bit），对 DDR 发 16-beat burst；
  `stride_px` 允许 ≠ 宽度。
- **混合近似**（不建 LUT）：
  `t = src*a + 128; dst = (t + (t>>8)) >> 8`（等价 `(x*a + 127)/255` 的 ±1 近似）。
  黄金取 LVGL `lv_color_mix`，±1 内接受，超出则以黄金为准修 RTL。
- **圆角矩形**：每角用**整数精确判据**逐行求内缩量（`A²+B²≤4r²`，A/B 为像素中心相对圆心；无 sqrt、无除法）；
  `r` 先 clamp 到 `min(w,h)/2`，与黄金同口径。
- **裁剪**：全局 SCISSOR；整块越界直接跳过。
- **性能**：填充 ≥ 1 px/cycle，混合 ≥ 0.5 px/cycle；全屏 614 K 像素填充 ≈ 6 ms。

## 6. 3D 引擎（屏幕空间光栅器 + Z）

### 6.1 分工：顶点变换在 CPU

- CPU 每帧：MVP 变换（128 三角形 × 3 顶点 ≈ 6 K MAC）、背面剔除、透视除法（每顶点 1 次 `div`）、
  近平面裁剪、视口变换；输出**屏幕空间顶点**写进 arena。
- 实测预算：**0.4–0.7 ms/帧**（33 ms 帧预算的 2%）。
- GPU 只做：屏幕上三角形 setup（边系数 + 增量）→ 扫描线/tile 光栅 → Z 测试。

### 6.2 顶点与三角形

- 顶点 8 B：`{int16 x_q8_8, int16 y_q8_8, uint16 z, uint16 pad}`，`z∈[0,65535]`（0=近）。
- 三角形 3 个连续顶点；`count` 为三角形数（≤ 255/命令）。
- setup（每三角形一次）：3 条边的 `A/B/C` 与逐像素增量，用**一个 24-bit 乘加单元串行**算
  （≈ 30 次乘加/三角形，全部走同一个 MAC）。

### 6.3 光栅化与 tile

- 32×32 tile（20×15=300 个，覆盖 640×480）；**逐像素只用加法**（边函数增量 + Z 增量）。
- **tile 分桶**：每帧先把三角形按 tile 建索引表（300 × 8 项 × 8 bit ≈ 2.4 KB，1 块 DRM36K）；
  溢出 tile 走"逐三角形即时 RMW"回退（罕见）。
- tile 处理：读颜色 2 KB + 读 Z 2 KB → 光栅（BRAM 各 1 块 DRM36K）→ 写回颜色 + Z。
  每 tile 每帧只 RMW 一次 ⇒ 3D 往返 ≈ (2 KB+2 KB+2 KB+2 KB) × 300 ≈ 2.4 MB/帧 ≈ **72 MB/s @30 fps**。
- 深度：`LESS`（默认）/`LEQUAL`/`ALWAYS` 由 `DRAW_TRIS.flags` 选；无模板、无混合。

### 6.4 着色

- **flat**（P2a）：`DRAW_TRIS.color` 统一颜色。
- **Gouraud**（P2b，综合开关默认关）：顶点带 RGB565，光栅内 8-bit 增量插值。

### 6.5 交互与场景

- 场景：低面数（立方体 / 20 面体 / 8×8 球）；CPU 每帧只更新顶点与命令。
- 触摸：拖拽 = yaw/pitch；窗口内 "+/−" 按钮 = 缩放；双击 = 自动旋转。
- 每帧：`CLEAR3D` → `DRAW_TRIS` → `FENCE` →（`COMPOSITE3D` + `FLIP`）。

## 7. 显示与双缓冲

- `video_passthrough` 新增 **`gui_bank`**：
  `ar_gui = GUI_BASE_WORD + gui_bank*0x0020_0000 + {6'd0, axi_araddr[21:0]}`，
  与 `gui_src` 同样在**读帧起点**锁存 ⇒ 切换不撕裂。
  **bank 的唯一主人是 GPU**：`gui_bank = gpu_csr.flip_toggle ^ GUI_CTRL[1]`，正常用法
  `GUI_CTRL[1]=0`（`FLIP` 每生效一次翻一次）；`GUI_CTRL[1]=1` 只是整体反相（诊断用）。
- `FLIP`：GPU 置位 → 下一个读帧起点把 `flip_toggle` 翻转并清 `STATUS.flip_pending`。
  跨域用**翻转电平**（`video_passthrough.frame_rd_toggle`，ddr_clk 域）→ SoC 内 2FF + 边沿
  检测成 soc_clk 单拍脉冲；不用单拍脉冲跨域（8 ns 会被 100 MHz 的 2FF 漏采）。
  视频侧 `gui_bank` 也在同一读帧起点锁存 ⇒ **实际换 bank 落在 FLIP 之后的第二个帧起点**
  （比"下一帧生效"晚一帧；有 `flip_pending` 可观测，不影响画面正确性）。
- yshell（mainline 变体）：`platform_flush` 写**后备 bank**，一帧最后一次 flush 后 `FLIP`；
  现有异步 flush 线程保留，退化为"写后备 bank"。

## 8. 驱动与 LVGL 接入

- **内核**：不需要新驱动（只用 `/dev/mem` MMIO 窗）。
- **用户态 `gpu` 库**（YeshenGui `platform/`）：
  `gpu_fill/blit/glyph/round_fill/scissor/fence/flip/clear3d/draw_tris/composite`，
  负责命令封装、`FIFO_FREE` 限流、超时与错误上报。
- **LVGL draw unit**（9.2）：`evaluate` 认填/图/字母；`dispatch` 翻译成 GPU 命令；
  不支持的任务返回 0 分让软件单元接管。
- **Cache 一致性**（依赖 §9）：字体/图片加载后 flush 一次；动态源每次 dispatch 前 flush 范围；
  GPU 写帧存不需要 CPU flush。
- **CPU 侧 3D**：顶点变换/剔除/投影在应用里（整数定点），输出到 arena 后 `cbo.flush` 该段。

## 9. 先决条件：核加 Zicbom（P0）

- `scripts/gen_core.sh` 的 `GEN_ARGS` 加 `zicbom`（等价 `--with-rvZcbm`），其余不动；
  连跑两次比对 `rtl/vexiiriscv/VexiiRiscv.v` md5（确定性）。
- 代价：LsuL1 增加 CBM 逻辑（预计 **LUT +1–3 K**）；ISA 字符串/DTS 不改（内核 5.10 不认也不需要）。
- **承重判据（过不了退回 uncached arena）**：
  1. CPU 写图案到普通内存 → `cbo.flush` → **eth_memread（硬件 DMA）读回**逐字节一致；
  2. 负对照：去掉 flush 必须读到不一致。
- 顺带关闭 UartLoader/SdLoader 记下的"软件 loader 无法 flush"这条老债。

## 10. 验证计划

| 层 | 判据 |
|---|---|
| 核 | 两次重生成 md5 相同；`check_addr_map`/`check_no_xilinx`/`check_dangling`；既有 glue 单测不动 |
| Zicbom | §9 正/负对照上板通过 |
| 单元 TB | 命令解析回显；FILL/BLIT/GLYPH/ROUND_FILL 逐像素对 C 黄金；3D 覆盖/Z/Gouraud 对 C 参考 |
| glue 集成 TB | 0xF0005000 窗解码 + AXI burst 形状 + owner 仲裁（照 DMA 闸门） |
| 上板 2D | 固定图案 → eth_memread 读回 → 与主机黄金逐字节；负对照：改一个像素 |
| 上板 LVGL | 与 host 模拟器截图逐像素比对；滑动/开窗帧率与 CPU 占用 |
| 上板 3D | 固定相机/矩阵 → 单帧逐像素对 C 黄金；交互目视 + 帧率（含 NPU 同时跑的一档） |
| 回归 | CoreMark（ITERS=10 的 CRC 不变）、y1run 12/12、相机/触摸/KEY4 既有判据 |

## 11. 分批交付

> 本 spec 覆盖四批；**实施计划按批分别出**（先 P0），每批单独验收、单独出比特流/镜像。

- **P0**：核加 Zicbom + §9 判据（风险最高、最便宜）。
- **P1**：GPU 壳（CSR/仲裁第 4 组）+ 共用读写引擎 + 2D 引擎 + 第二 GUI bank/flip + LVGL 后端 + 上板 2D 判据。
- **P2a**：3D 光栅器（CPU 顶点 + flat + Z + tile 分桶）+ 3D 窗口应用 + 触摸交互
  （`GPU_WITH_3D` 由 0 置 1，其余模块不动）。
- **P2b（可选）**：Gouraud、更多模型/场景。

## 12. 资源预算与节省项

### 12.1 已采纳的节省项

| # | 改法 | 省 |
|---|---|---|
| 1 | 2D/3D **共用**一套读引擎 + 写合并引擎 | 3–5 K LUT、1 套 FIFO |
| 2 | 光栅逐像素**只用加法**（setup 才算乘） | 2–3 K LUT |
| 3 | 圆角用 **Bresenham 增量**（无 sqrt LUT/除法） | ~0.3 K LUT + 一个小 RAM |
| 4 | 混合用**移位近似**（无 64K LUT） | 大块 LUT/DRAM |
| 5 | 源格式收敛 **RGB565 + A8**（ARGB8888 作开关） | 1–2 K LUT + 25% 读带宽 |
| 6 | 视口固定 640×480（常量除法/移位） | ~1 K LUT |
| 7 | 命令 FIFO **16 项**、SEQ/DBG 16 位、**v1 不上 IRQ** | ~0.5 K LUT、少一条中断验证面 |
| 8 | **tile 分桶**（每 tile 每帧只 RMW 一次） | DDR 3D 带宽 4–10× |
| 9 | P2a 只综合 **flat + LESS**（Gouraud/LEQUAL 作常量开关） | 1–2 K LUT |
| 10 | **顶点变换在 CPU**（无矩阵单元/1÷w/顶点变换 FSM） | 6–10 K LUT；代价 CPU 0.4–0.7 ms/帧 |

### 12.2 预算

| 项 | 估计 |
|---|---|
| 2D 引擎（含共用读写引擎的一半） | 5–8 K LUT |
| 3D 光栅器（setup + raster + Z + 分桶） | 4–8 K LUT |
| 片上 RAM | +3 DRM36K（tile 颜色 / tile Z / 分桶表） |
| APM | +2–4（setup 的乘加，串行复用） |
| 核（Zicbom） | +1–3 K LUT |
| **合计（相对 ctp2）** | **LUT 98–107 K（61–67%）**、DRM 315/415、APM ~260 |

### 12.3 退路（不进 v1，写在这里备查）

- 砍 Z 改画家算法（CPU 排序）：省 2–4 K LUT + 2 DRM + 50% 3D 带宽；相交几何会穿帮。
- 3D 内部 320×240 再 2× 放大合成：像素/带宽/时序压力 ÷4；画面变糊。

## 13. 风险

1. **PnR 100 MHz**：光栅器的 24-bit 地址/边函数链、写合并 FIFO 到 AXI 的时序 → 关键路径各打一拍，
   乘法走 APM；P1 完成先 dev_map 记账再决定 P2a 的 tile 规模。
2. **DDR 争用**：NPU 同时跑时 GPU 帧率下降 → 允许降到 15 fps，并在报告里记账。
3. **Zicbom 未按预期工作** → 退回 uncached arena（软件侧已留接口）。

## 14. 术语

- **bank**：1024×720 RGB565 帧存；GUI 两块（`0x9200_0000` / `0x9220_0000`），LCD 只读其中一块。
- **flip**：LCD 读帧起点把读源切到另一块 bank。
- **tile**：3D 光栅的 32×32 工作块（片上）。
- **CBM/Zicbom**：RISC-V 缓存块维护指令（clean/flush/invalidate）。
