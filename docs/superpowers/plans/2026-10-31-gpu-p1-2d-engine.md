# GPU P1：GPU 壳 + 2D 引擎 + 双缓冲 + LVGL 后端 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 上板能用硬件 2D 引擎跑通 LVGL 桌面：`FILL/BLIT/GLYPH/ROUND_FILL/SCISSOR` 走 GPU，帧存双 bank + 帧级 `FLIP` 不撕裂，判据是"固定图案逐字节对黄金 + 负对照"。

**Architecture:** `0xF000_5000` 4 KiB CSR 窗 + 16 项命令 FIFO；`gpu_mem` 一套共用读引擎/写合并引擎接 64-bit AXI 主口，经 glue `MemArbiter` 第 4 组（新增 `OWN_GPU_RD/WR`）；`gpu_2d` 逐像素增量光栅；显示侧 `video_passthrough` 加 `gui_bank`（`GUI_CTRL[1]`），在读帧起点锁存。**与 P0 的唯一接缝是驱动的 `gpu_mem_sync()`**：P0 通过则 `cbo.flush`，失败则 no-op + `/dev/mem` 非缓存映射（spec §13.3）。

**Tech Stack:** SpinalHDL glue（`YeshenSocGlue.scala`）、手写 Verilog（`rtl/gpu/`）、Verilator/iverilog 单元 TB、PDS dev_map/PnR、C（YeshenGui 板端 + host SDL 构建）。

**依据：** `docs/superpowers/specs/2026-10-30-simple-gpu-design.md` §3–§8、§11–§12。

> **进度（2026-10-31）**
> - **Task 0–4 已完成**（提交见 `git log --oneline -- rtl/gpu`）：`gpu_regs.vh` 单一来源、
>   独立 C 黄金 + 6 个固定用例（各 1,228,800 B 逐字节吻合）、`gpu_mem` / `gpu_csr` /
>   `gpu_cmd` / `gpu_2d`（FILL / ROUND_FILL / SCISSOR / BLIT+混合 / GLYPH）。
> - **Task 5 已完成**（61f439f）：glue GPU 窗 + 第 4 主口、`gpu_top`、SoC 例化、
>   视频 `gui_bank` / `frame_rd_toggle`、PDS 源列表；端点级闸门 `GPU-GLUE PASS`
>   （`sim/glue_pbus/run_gpu_unit.sh`）+ 负对照 `negctl_gpu_pbus.sh` 翻红、复原 md5 一致。
> - **Task 6 已完成**：dev_map `gpu4`（LUT 91,600 / DRM 313 / 0 error，见报告 §3e）；
>   PnR `gpu4` **seed 1 收敛 → All Constraints Met**（soc +0.466 / cpu +0.502 / npu +0.401 /
>   core +0.732），比特流 9,188,552 B、sha256 `9f5690ab…`。期间修了两处：`gpu_cmd` 参数握手
>   （`33145fa`）、`gpu_2d` 字形覆盖率拆第三拍（`42c5d36`，`soc_clk` 同种子 −0.846→+0.392）。
> - **Task 7 已完成**（YeshenGui 提交 `20e3838`/`56ac18e`/`0d7a4c0`/`e835d1f`/`71eb9cb`）：
>   驱动库 + 主机模拟（六例黄金逐字节）、arena（0x9320_0000）、LVGL draw unit
>   （**FILL + 整幅 RGB565 图像**；A8 图像与 LABEL 明确拒绝交回 SW —— A8 与 LVGL
>   的掩码/着色口径实测不一致，不做近似）、DIRECT 变体 `GUI_VARIANT=mainline_gpu`。
>   闸门 `scripts/run_gpu_unit_host_test.sh` = UNIT 帧存一致 + 整机截图一致 + 非退化。
> - **Task 8 前置已备**：`y1/tools/gputest.c`（上板逐像素自检 + scissor 负对照 +
>   *判据自证*）与 `y1/tools/cbotest.c`；`scripts/gpu_board_judge.py --test gpu|cbo`
>   统一驱动；板窗口按报告 §5b 的 runbook 一次跑完。
> - 与草案的偏差：`gui_bank` 由 GPU 的 `flip_toggle` 驱动（`GUI_CTRL[1]` 仅整体反相）；
>   vsync 走"翻转电平 + 2FF + 边沿"跨域；实际换 bank 落在 FLIP 后**第二个**帧起点。

---

## 文件与职责

| 文件 | 动作 | 职责 |
|---|---|---|
| `rtl/gpu/gpu_regs.vh` | 新建 | 寄存器偏移/命令 op 的**单一来源**（Verilog + C 共用同一张表） |
| `rtl/gpu/gpu_csr.v` | 新建 | 窗内寄存器：ID/STATUS/CMD_*/SEQ_DONE/FIFO_FREE/SCISSOR/FLIP/DBG |
| `rtl/gpu/gpu_cmd.v` | 新建 | 16 项命令 FIFO、字计数、命令字解包、`FENCE`/`SEQ_DONE` |
| `rtl/gpu/gpu_mem.v` | 新建 | 共用读引擎（burst 读 FIFO）+ 写合并 FIFO（16-beat burst）+ AXI 主口适配 |
| `rtl/gpu/gpu_2d.v` | 新建 | FILL/BLIT/GLYPH/ROUND_FILL 像素流发生器 + SCISSOR |
| `rtl/gpu/gpu_top.v` | 新建 | 把上面四个连起来（P2a 再加 `gpu_3d`，由 `GPU_WITH_3D` 包住） |
| `board/cam/video_passthrough.v` | 修改 | `gui_bank` 读源偏移，帧起点锁存 |
| `board/cam/video_regs.v` | 修改 | `GUI_CTRL[1] = gui_bank` |
| `src/YeshenSocGlue.scala` | 修改 | `YeshenMap.GPU_*`、`isGpuR/W` 窗解码、第 4 主口 `io.gpuMem`、`OWN_GPU_RD/WR` |
| `board/yeshen_mini_soc.v` | 修改 | 实例化 `gpu_top`、接 `io.gpuMem` / `gui_bank` / `gpuFlip` |
| `pds/*` 源列表 | 修改 | 加 `rtl/gpu/*.v` |
| `YeshenGui/platform/board_gpu.c` | 新建 | 用户态命令封装、`FIFO_FREE` 限流、`FLIP`、`gpu_mem_sync()` |
| `YeshenGui/platform/host_gpu.c` | 新建 | **软件模拟**同一命令集（host 构建用，先行验证 LVGL 后端） |
| `YeshenGui/ui/gpu_draw_unit.c` | 新建 | LVGL 9.2 `lv_draw_unit_t`：evaluate/dispatch |
| `sim/gpu/` | 新建 | TB、AXI RAM 模型、黄金生成器、闸门脚本 |

**任务顺序说明**：T1/T2（黄金 + 接口头）→ T3–T6（RTL 四条线，可并行）→ T7（glue/板级）→ T8（dev_map/PnR）→ **T9（软件，可与 T3–T8 完全并行）** → T10（上板）。

---

## Task 0：接口冻结（两路并行的前提）

**Files:** Create `rtl/gpu/gpu_regs.vh`

- [ ] **Step 1: 写单一来源头文件**

```verilog
// gpu_regs.vh —— 寄存器偏移与命令 op 的唯一定义。C 侧对应 YeshenGui/platform/gpu_regs.h（逐字镜像）。
`define GPU_ID          12'h000
`define GPU_STATUS      12'h004
`define GPU_IRQ_EN      12'h008
`define GPU_IRQ_CLR     12'h00C
`define GPU_CMD_DATA    12'h010
`define GPU_CMD_PUSH    12'h014
`define GPU_SEQ_DONE    12'h018
`define GPU_FIFO_FREE   12'h01C
`define GPU_SCISSOR0    12'h020   // {x0[15:0], y0[15:0]} = y0<<16 | x0
`define GPU_SCISSOR1    12'h024   // {x1, y1}，右下**开区间**
`define GPU_FLIP        12'h028   // 写 1 请求；读回 pending
`define GPU_DBG         12'h02C
`define GPU_ID_MAGIC    32'h5947_5055   // "YGPU"

`define OP_NOP          8'h01
`define OP_FILL         8'h02
`define OP_BLIT         8'h03
`define OP_GLYPH        8'h04
`define OP_ROUND_FILL   8'h05
`define OP_SET_SCISSOR  8'h06
`define OP_FENCE        8'h07
// 0x10..0x12 留给 P2a 的 3D

`define GPU_GUI_BANK1   32'h9220_0000
`define GPU_ARENA       32'h9320_0000
```

- [ ] **Step 2: 写 C 镜像头**（`YeshenGui/platform/gpu_regs.h`，同样内容用 `#define`，加一行注释"改动必须同步 `rtl/gpu/gpu_regs.vh`"）

- [ ] **Step 3: 一致性闸门**

```bash
python - <<'PY'
import re
v = dict(re.findall(r"`define\s+(\w+)\s+([0-9A-Fa-f_']+)", open('rtl/gpu/gpu_regs.vh').read()))
h = dict(re.findall(r"#define\s+(\w+)\s+([0-9A-Fa-f_x]+)", open('../YeshenGui/platform/gpu_regs.h').read()))
norm = lambda d: {k: int(v2.replace("'h", "0x").replace("_",""), 0) for k, v2 in d.items()}
a, b = norm(v), norm(h)
assert set(a) == set(b), (set(a) ^ set(b))
bad = [k for k in a if a[k] != b[k]]
assert not bad, bad
print("GPU-REGS-MIRROR OK", len(a), "entries")
PY
```

Expected：`GPU-REGS-MIRROR OK 20 entries`。

- [ ] **Step 4: 提交** `feat(gpu): 寄存器/命令 op 单一来源头 + C 镜像`

---

## Task 1：2D 黄金生成器（C，独立参考实现）

**Files:** Create `sim/gpu/gpu2d_ref.c`, `sim/gpu/run_golden.sh`

- [ ] **Step 1: 写参考实现**（只做 spec §5 的四条语义）

```c
/* 输入：一个命令脚本（文本），输出：RGB565 帧存 + 每步 CRC。与 RTL 无关，独立写。 */
/* 命令：fill dst stride x y w h rgb | blit src ss fmt sx sy w h dst ds dx dy flags alpha
 *       glyph ... | round dst stride x y w h r rgb | scissor x0 y0 x1 y1 */
static inline void put(uint16_t *fb, int stride, int x, int y, uint16_t c) {
    fb[y * stride + x] = c;
}
static uint16_t blend(uint16_t d, uint16_t s, unsigned a) {  /* a: 0..255 */
    unsigned dr = (d >> 11) & 31, dg = (d >> 5) & 63, db = d & 31;
    unsigned sr = (s >> 11) & 31, sg = (s >> 5) & 63, sb = s & 31;
    unsigned t;
    t = sr * a + 128; sr = (t + (t >> 8)) >> 8;   /* spec §5 的 ±1 近似 */
    t = sg * a + 128; sg = (t + (t >> 8)) >> 8;
    t = sb * a + 128; sb = (t + (t >> 8)) >> 8;
    return (uint16_t)(((dr + sr) << 11) | ((dg + sg) << 5) | (db + sb));  /* 混合公式见 Step 2 */
}
```

> 混合公式以**本实现**为准（spec 规定"黄金先落，RTL 向黄金对齐"）：`out = d + ((s - d) * a)/255` 的 ±1 近似；Step 2 里把三条分支（a=0/255/中值）写成断言，避免"两边同错"。

- [ ] **Step 2: 边界断言（防退化）**

写 `assert(bridge)`：`a=0` 时输出必须**逐位等于 dst**；`a=255` 时必须**逐位等于 src**；`w=h=0` 时不得写任何字节。这三条是"黄金自己也有判据"。

- [ ] **Step 3: 生成固定用例**

```bash
cd sim/gpu && gcc -std=c11 -O2 -Wall -Wextra -o gpu2d_ref gpu2d_ref.c && \
  ./gpu2d_ref --case fill_rect  --fb 1024x600 --out gold/fill_rect.bin && \
  ./gpu2d_ref --case blit565    --fb 1024x600 --out gold/blit565.bin && \
  ./gpu2d_ref --case blit_a8    --fb 1024x600 --out gold/blit_a8.bin && \
  ./gpu2d_ref --case glyph      --fb 1024x600 --out gold/glyph.bin && \
  ./gpu2d_ref --case round32    --fb 1024x600 --out gold/round32.bin && \
  ./gpu2d_ref --case scissor    --fb 1024x600 --out gold/scissor.bin
md5sum gold/*.bin
```

Expected：6 个 `.bin` 各 1,228,800 B（1024×600×2）；md5 记进 `sim/reglogs/gpu_golden_md5.txt`。
**负对照**：把 `--fb 1024x600` 改成 `--fb 64x64` 重跑，md5 必须变（证明不是恒空）。

- [ ] **Step 4: 提交** `test(gpu): 2D 独立黄金参考 + 6 个固定用例`

---

## Task 2：`gpu_mem.v` —— 共用读/写引擎 + AXI 主口

**Files:** Create `rtl/gpu/gpu_mem.v`, `sim/gpu/axi_ram_model.v`, `sim/gpu/tb_gpu_mem.v`, `sim/gpu/run_mem.sh`

- [ ] **Step 1: 写 TB（先红）**

TB 用 `verilator --binary --timing`；AXI RAM 模型 64 KiB，**读数据里带地址指纹**（`rdata = {addr[15:0], addr[15:0], ...}`），这样"读到别的地址"必错。
用例：
1. 写 16 beat burst（地址 0x100，`wstrb=0xFF`）→ 读回逐字节一致；
2. 写合并：连续 8 个 32-bit 写到相邻地址 ⇒ 线上必须只出现 **1 次 AW + ≥1 次 16-beat W**（统计 `awvalid` 次数）；
3. 负对照：`wstrb=0x00` 的一拍不得改变 RAM 内容。

```bash
MSYS_NO_PATHCONV=1 wsl bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && \
  verilator --binary --timing -Wall -Wno-fatal -Isim/gpu -Irtl/gpu \
  --top-module tb_gpu_mem sim/gpu/tb_gpu_mem.v sim/gpu/axi_ram_model.v rtl/gpu/gpu_mem.v \
  -Mdir /tmp/obj_gpu_mem -o tb && /tmp/obj_gpu_mem/tb'
```

Expected（Step 1 时）：`FAIL: gpu_mem.v not found`（先红）。

- [ ] **Step 2: 写 `gpu_mem.v`（最小实现）**

端口：`clk/rst`、读请求 `rd_valid/rd_addr/rd_len/rd_ready/rd_data/rd_valid_out`、写请求 `wr_valid/wr_addr/wr_data/wr_strb/wr_ready`、AXI4 主口（与 `io.dmaMem` 同形：`ar/aw/w/b/r` + 64-bit）。

关键约束（写进文件头）：
- 同一时刻只有一类事务在飞（读或写），由上层 `gpu_cmd` 串行保证；`gpu_mem` 内部**不做**读写并发。
- 写合并 FIFO ≥ 8×64 bit；凑满 16 beat 或遇 `FLUSH` 就发 burst。
- `rlast` 必须回到 `rd_len` 个 beat 后释放读引擎（**不能**靠 `rready` 自释放）。

- [ ] **Step 3: 跑绿 + 负对照**

```bash
bash sim/gpu/run_mem.sh   # 内部执行 Step 1 的命令 + 三条用例
```

Expected：`MEM PASS（burst=1, combine=1, wstrb-neg=ok）`。

- [ ] **Step 4: 提交** `feat(gpu): 共用读写引擎（16-beat burst + 写合并 + 严格 rlast 释放）`

---

## Task 3：`gpu_cmd.v` + `gpu_csr.v` —— CSR 窗与命令 FIFO

**Files:** Create `rtl/gpu/gpu_csr.v`, `rtl/gpu/gpu_cmd.v`, `sim/gpu/tb_gpu_csr.v`, `sim/gpu/run_csr.sh`

- [ ] **Step 1: TB（先红）——按 spec §4.1 逐项**

1. `ID` 读回 `0x59475055`；
2. `CMD_DATA` 连写 3 个字 + `CMD_PUSH` ⇒ `FIFO_FREE` 从 16 变 13；`SEQ_DONE` 在 `FENCE` 完成后等于 seq；
3. `SCISSOR` 读写回读一致；
4. `FLIP` 写 1 ⇒ `STATUS[16]=1`，收到 `vsync` 后置 `gui_bank=1` 且 `STATUS[16]=0`；
5. **负对照**：写 `0x400`（窗外）不得改变任何寄存器（窗掩码 0xFFFF_F000）。

- [ ] **Step 2: 实现**

- `gpu_csr`：`pBus` 从口（`awvalid/wvalid/arvalid` 分别选通，读用读地址），窗内 12 位偏移；`CMD_DATA/CMD_PUSH` 转成 FIFO 写；`SEQ_DONE` 来自 `gpu_cmd`。
- `gpu_cmd`：16×32 FIFO（LUT-RAM 推断）、`nwords` 计数、命令字 `{op,nwords,flags}` 解包；`FENCE` 直接把 `seq` 送到 `SEQ_DONE`（写路径静默后）。
- `STATUS[0]=busy`、`[7:4]=fifo_used`、`[8]=err`、`[15:8]=errcode`。

- [ ] **Step 3: 跑绿**

```bash
bash sim/gpu/run_csr.sh
```

Expected：`CSR PASS（id, fifo, scissor, flip, out-of-window-neg）`。

- [ ] **Step 4: 提交** `feat(gpu): CSR 窗 + 16 项命令 FIFO + FLIP 帧级锁存`

---

## Task 4：`gpu_2d.v` —— FILL / BLIT / GLYPH / ROUND_FILL

**Files:** Create `rtl/gpu/gpu_2d.v`, `sim/gpu/tb_gpu_2d.v`, `sim/gpu/run_2d.sh`

- [ ] **Step 1: TB 用 Task 1 的黄金**

TB 流程：预载 RAM 模型（等于黄金用例的初始帧存）→ 发一条命令 → `FENCE` → 把 RAM 的 1024×600×2 区域与 `gold/<case>.bin` 逐字节比。

```bash
bash sim/gpu/run_2d.sh   # 六个用例 + 一个 1 像素负对照（改 src 一个像素，必须红）
```

Expected（实现前）：六项全 `MISMATCH`（先红）；实现后：`2D PASS（6/6）`，负对照 `NEG ok`。

- [ ] **Step 2: 实现要点（照 spec §5）**

- **FILL**：`x` 增量、`y` 行进；每行产出 `w` 个 RGB565；`stride_px` 与宽解耦。
- **BLIT**：源 RGB565 或 A8；`flags.bit0` 混合；混合用 spec 的移位近似（**不要** 64K LUT）。
- **GLYPH**：源 A8，`dst = lerp(dst, fg, a*alpha/255)`。
- **ROUND_FILL**：每角 Bresenham 增量圆求内缩；`radius=0` 退化为 FILL。
- **SCISSOR**：全局；整块越界直接跳过（不得发任何写 burst —— TB 统计 `awvalid` 必须为 0）。

- [ ] **Step 3: 性能冒烟**（TB 里数周期）：全屏 FILL 614,400 px 必须 ≤ 700 K 周期（≥0.85 px/cycle）。

- [ ] **Step 4: 提交** `feat(gpu): 2D 引擎四算子 + SCISSOR（逐像素对黄金）`

---

## Task 5：`gpu_top.v` + glue/板级集成

**Files:**
- Create: `rtl/gpu/gpu_top.v`
- Modify: `src/YeshenSocGlue.scala`（`YeshenMap.GPU_*`、`isGpuR/W`、`io.gpuMem`、`OWN_GPU_RD/WR`、`MemArbiter(4,…)`）
- Modify: `board/yeshen_mini_soc.v`、`pds/run_devmap_yeshen.tcl` 与 `pds/run_pnr_yeshen.tcl` 的源列表
- Test: `sim/glue_pbus/run_gpu_unit.sh`（新）

- [ ] **Step 1: glue 改动清单（逐条，照 NPU/DMA 的既有写法）**

1. `YeshenMap`：`GPU_BASE=0xF0005000`、`GPU_MASK=0xFFFF_F000`（4 KiB）；
2. `isGpuR/W` 选通 + `gpuAxi` 端口（`VexiiAxiLite32`）+ 接线；
3. 第 4 主口：`io.gpuMem`（64-bit AXI4，与 `io.dmaMem` 同形）；
4. `MemArbiter(3→4)`，加 `OWN_GPU_RD=8.U / OWN_GPU_WR=9.U`，`gpuPend` 与 `Mux` 链；
5. 地址台账 `scripts/check_addr_map.py` 加 GPU_BASE 一项。

> ⚠️ 既有经验：`MemArbiter` 的 `N`/权重是参数，**仲裁器本体一字不改**；改的是 owner 状态机与 Mux 链。

- [ ] **Step 2: glue 闸门（先红后绿）**

`sim/glue_pbus/run_gpu_unit.sh`：
1. 写 `0xF0005010/0x14`（命令）→ 读 `0xF0005000` 得 magic；
2. 读 `0xF0005004` 的 busy 位在 FENCE 后回 0；
3. **负对照（分两处，别混）**：
   - **窗外** `0xF0006100` 必须 DECERR（不是 0x5100 —— 它在 4 KiB 窗内）；
   - **窗内未映射** `0xF0005100` 必须 OKAY 且 rdata=0（读到 0 而不是 x）。
   - 判据能翻红：`sim/glue_pbus/negctl_gpu_pbus.sh` 把读窗基址 `20'hF0005` 改掉 ⇒ GPU 判据当场红。

```bash
MSYS_NO_PATHCONV=1 wsl bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && bash sim/glue_pbus/run_gpu_unit.sh'
```
Expected：`GPU-GLUE PASS`。

- [x] **Step 3: 视频侧 `gui_bank`**（2026-10-31 落地）

`video_regs.v` 加 `GUI_CTRL[1]`（复位 0）；`video_passthrough.v` 的 GUI 读地址改成
`GUI_BASE_WORD + {gui_bank_ddr, 21'd0} + {6'd0, araddr[21:0]}`，并在**读帧起点**锁存。
TB：切换 `gui_bank` 时，帧内地址不得混用两 bank（统计一帧内 bank 变化次数必须为 0）。

**落地方案**（与上面的草案差两点，原因写在 spec §7）：
- `gui_bank` 的**主人是 GPU**：板级接 `gui_bank = gpu_csr.flip_toggle ^ GUI_CTRL[1]`；
  `GUI_CTRL[1]` 只做整体反相（诊断用），避免"软件寄存器 / GPU 翻转"两个主人抢同一状态。
- vsync 跨域用 `video_passthrough.frame_rd_toggle`（ddr_clk **翻转电平**）→ SoC 内 2FF +
  边沿检测成 soc_clk 单拍；单拍脉冲跨域会被 100 MHz 的 2FF 漏采。
- U8（tb_gui_src）加第三档 `src=1/bank=1`，bank1 用专有像素 `0x3C3C`，
  且 `mixed_frame` 判据扩成"帧内跨区（cam/gui0/gui1）都算混用"。

- [x] **Step 4: lint + 结构闸门**

```bash
bash y1/tools/check_no_xilinx.sh rtl/gpu | tail -2                 # xilinx-residual hits: 0 / PASS
cat rtl/gpu/*.v > /tmp/gpu_all.v && python3 y1/tools/check_dangling.py /tmp/gpu_all.v | tail -2
python3 scripts/check_addr_map.py | tail -2                        # PASS 21 sites
# SoC 级 Verilator lint（0 error；ASSIGNIN 是 axi4_cdc_io 的继承告警）
verilator --lint-only -Wno-fatal -Wno-ASSIGNIN --top-module yeshen_mini_soc \
  board/yeshen_mini_soc.v board/cpu_domain_cdc.v board/axi4_cdc_{fetch,lsu,io}.v board/dcfifo.v \
  board/liteeth_wrap.v board/eth/eth_service.v board/eth/eth_memread.v \
  third_party/liteeth_mac/liteeth_mac_top.v third_party/eth_stack_2_11/source/rgmii_interface.v \
  rtl/YeshenSocGlue.v rtl/gpu/*.v rtl/vexiiriscv/VexiiRiscv.v \
  y1/gen/{NpuTop,DmaEngine,NpuAxiLiteCdc,NpuMemCdc,NpuIrqCdc,NpuResetSync}.v \
  sim/pango_prim_sim_stubs.v
```

> `check_dangling.py` 是**逐文件**口径（每份文件单独算定义集）⇒ 多文件设计要先 cat 成一个再判。

- [x] **Step 5: 提交** `feat(gpu): 顶层 + glue 第 4 主口/窗解码 + gui_bank 双缓冲`（61f439f）

---

## Task 6：dev_map / PnR（排在 `gpu0` 之后，PDS 单实例）

- [ ] **Step 1:** `YESHENMINI_DEVMAP_TAG=gpu1 pds_shell.exe -file pds/run_devmap_yeshen.tcl`
- [ ] **Step 2:** 判据：0 error；LUT ≤ 88,172.5 + **8 K**（spec 预算 5–8 K），DRM ≤ 315/415
- [ ] **Step 3:** `YESHENMINI_PNR_TAG=gpu1 YESHENMINI_STRATEGY=1 …`；All Constraints Met + 出比特流
- [ ] **Step 4:** 提交记账（报告里写 LUT/DRM/时序）

---

## Task 7：用户态驱动 + LVGL draw unit（**可与 T2–T6 并行**）

**Files:**
- Create: `YeshenGui/platform/board_gpu.c`, `YeshenGui/platform/host_gpu.c`, `YeshenGui/platform/gpu_regs.h`
- Create: `YeshenGui/ui/gpu_draw_unit.c`
- Modify: `platform/platform.h`、`board/CMakeLists.txt`、`host/CMakeLists.txt`

- [ ] **Step 1: 命令封装（板端）**

```c
static int gpu_wait_free(int need);           /* 轮询 FIFO_FREE，超时 100 ms ⇒ err */
int gpu_fill(uint32_t dst, int stride, int x, int y, int w, int h, uint16_t c);
int gpu_blit(uint32_t src, int ss, int fmt, int sx, int sy, int w, int h,
             uint32_t dst, int ds, int dx, int dy, int flags, int alpha);
int gpu_glyph(uint32_t src, int stride, int sx, int sy, int w, int h,
              uint32_t dst, int ds, int dx, int dy, uint16_t fg, int alpha);
int gpu_round_fill(uint32_t dst, int stride, int x, int y, int w, int h, int r, uint16_t c);
void gpu_set_scissor(int x0, int y0, int x1, int y1);
int gpu_fence(void);        /* 推 FENCE，等 SEQ_DONE */
int gpu_flip(void);         /* 写 FLIP，等 STATUS.flip_pending==0 */
void gpu_mem_sync(void *p, size_t len);   /* ← P0 接缝 */
```

`gpu_mem_sync()` 用**编译期一次选择 + 运行期一次探测**：
- `CONFIG_GPU_CBO=1`（P0 通过）：`for (off) cbo.flush(p+off)`；
- 否则 no-op（调用方已用 `/dev/mem` 非缓存映射）。

- [ ] **Step 2: host 软件模拟器** `host_gpu.c`：同一套 API，在 CPU 上直接改内存（复用 Task 1 的黄金实现，链接 `sim/gpu/gpu2d_ref.c` 的算法函数）。

- [ ] **Step 3: LVGL draw unit**

```c
static int32_t gpu_evaluate(lv_draw_unit_t *u, lv_draw_task_t *t);
static int32_t gpu_dispatch(lv_draw_unit_t *u, lv_layer_t *layer);
void gpu_draw_unit_init(void);   /* lv_draw_create_unit(sizeof(gpu_unit_t)) */
```

`evaluate`：认 `LV_DRAW_TASK_TYPE_FILL`（矩形、无渐变）、`LV_DRAW_TASK_TYPE_IMAGE`（RGB565/A8，不缩放不旋转）、`LV_DRAW_TASK_TYPE_LABEL`（A8 字形，无旋转）；其余返回 0（SW 单元接管）。
`dispatch`：把任务翻成命令序列 + `FENCE`；**不支持的属性（渐变/变换/阴影）在 evaluate 就拒绝**，不要半途降级。

- [ ] **Step 4: host 验证（不需要板子）**

```bash
bash scripts/build_host.sh && SDL_VIDEODRIVER=dummy YESHEN_GUI_SCREENSHOT=/tmp/gpu_host.png \
  $HOME/yeshen-gui-build/host/yshell --no-uart
```

Expected：截图与"软件单元渲染"的同一场景**逐像素相同**（用 `build/present_test.c` 的风格写一个 `build/gpu_diff.c` 做比对，差 >0 像素即失败）。

- [ ] **Step 5: 提交** `feat(gui): GPU 驱动库 + host 模拟器 + LVGL draw unit（host 逐像素对账）`

---

## Task 8：上板 2D 判据（**需用户板窗口**）

- [ ] **Step 1: 固定图案**：用 GPU 画 `FILL` 棋盘 + 一条 `ROUND_FILL` + 一段 `GLYPH` 文本（颜色/坐标写死）。
- [ ] **Step 2: 硬件读回**：`scripts/eth_memread.py` 读 `0x9220_0000` 的整帧 → 与主机黄金逐字节比。
  判据：`MATCH 1,228,800/1,228,800`；同时读 `STATUS` 确认 `err=0`。
- [ ] **Step 3: 负对照**：黄金里改一个像素重比，必须 `MISMATCH=1`（证明判据不是恒绿）。
- [ ] **Step 4: 实况**：跑 LVGL 桌面 30 s，看 `DBG` 的命令/周期计数与目视流畅度；`/proc/stat` 的 CPU 占用应比纯 SW 渲染明显下降。
- [ ] **Step 5: 收口报告** `docs/reports/gpu-p1-2d.md` + spec §7/§8 回填实测。

---

## 判据汇总（P1 的"完成"定义）

1. `gpu_regs.vh` 与 `gpu_regs.h` 镜像一致（Task 0 闸门）；
2. `gpu_mem` / `gpu_csr` / `gpu_2d` 三个 TB 全 PASS，且各带**会变红**的负对照；
3. 2D 六个黄金用例逐字节一致；SCISSOR 越界时零写 burst；
4. glue 窗闸门 PASS + `check_addr_map` PASS；
5. dev_map 0 error、LUT 增量 ≤ 8 K、DRM ≤ 315；
6. PnR All Constraints Met + 比特流；
7. 上板 `FILL/ROUND/GLYPH` 硬件读回逐字节 MATCH + 负对照红；LVGL 桌面跑起来。

## 回退分支

| 现象 | 处理 |
|---|---|
| P0 上板 `POS=0/SIGILL` | `gpu_mem_sync` 走 no-op + arena 改 `/dev/mem` 非缓存；RTL 不动 |
| `gui_bank` 切换撕裂 | 退回单 bank（`FLIP` 当作 `FENCE`），双缓冲留 P2a |
| LUT 超 8 K | 先砍 `ROUND_FILL`（用 FILL 拼）与 A8 混合，再砍 BLIT 的 A8 源 |
| 时序不收敛 | 光栅器地址/边函数各打一拍；必要时 `GPU_WITH_3D=0`（P1 本来就是 0） |
