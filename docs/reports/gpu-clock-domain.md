# GPU 独立时钟域（gpu_clk）

**日期**：2026-11-01
**裁决**：用户「我希望后面GPU还是要有单独时钟，方便后续优化。」
**状态**：设计 + 仿真闸门已收口（14/14 逐字节 + 2 个红臂）；dev_map/PnR/上板见 §6–§8。

---

## 1. 为什么要做（不是"为了好看"）

`gpu10` 那次 PnR 的时序报告里，**soc_clk 的头号路径就在 GPU 里面**：

```
Startpoint : u_soc/u_gpu/u_2d/mix_bg[13]/opit_0_L6Q_perm/CLK
Endpoint   : u_soc/u_gpu/u_2d/obuf[7][25]/opit_0_L6Q_perm/I3
路径       : blend 选通 → 减法 → APM 乘法(P[33]) → 进位链 → 加法树
Slack      : +0.426 ns（soc_clk est 104.4496 MHz / req 100.000 MHz）
```

也就是说：**GPU 的 blend 通路在给整个 SoC 的主频封顶**。把它搬进独立域，两个方向都解耦：

* 往上提 `gpu_clk` 时，不再被 SoC 侧的 CPU/外设/视频逻辑拖住；
* 反过来，SoC 侧若哪天要提 `soc_clk`，也不必先等 GPU 的 blend 路径被打断。

本档取 **`gpu_clk` = 100.000 MHz（与 soc_clk 同频）** —— 改时钟域这一步的验收标准是
**零行为变化**；提频是独立的下一次 PnR（格点见 §3.1 的表）。

---

## 2. 结构

```
                    ┌──────────────────── gpu_clock_domain ────────────────────┐
  glue (soc_clk)    │  gpu_axil_cdc        gpu_top (gpu_clk)      gpu_mem_cdc  │  glue (soc_clk)
  io_gpuAxi_* ──────┼─► 5×dcfifo ─► s_* ─► CSR/CMD/2D/3D ─► m_* ─► 5×dcfifo ─┼──► io_gpuMem_*
  vsync (电平) ─────┼─► 2FF(soc) ──► 2FF+异或沿(gpu) ─► vsync 脉冲              │
  flip_toggle ◄─────┼── 2FF(soc) ◄── flip_toggle(gpu)                          │
  glue_reset ───────┼─► gpu_rst = 异步置位(async_rst|soc_rst) / gpu_clk 同步释放│
                    └──────────────────────────────────────────────────────────┘
```

### 2.1 时钟源（`board/pll_gpu.v`）

第五颗板级 `GTP_GPLL`（GPLL 用量 6/10 → **7/10**）：

| 项 | 值 | 约束窗口 |
|---|---|---|
| PFD  | 27 / 1 = **27 MHz** | ∈ [10, 450] ✓ |
| VCO  | 27 × 1 × 25 = **675 MHz** | ∈ [600, 1200] ✓ |
| clkout0 | 675 / 6.75 = **100.000 MHz 精确** | ≤ 800 ✓ |

`RATIO0 = 6.75 = 6 + 6/8` 落在该 IP 的 **1/8 分频格点**上；`STATIC_DUTY0 = 6`
（口径同 `pll_50m.v`：`DUTY = int(RATIO)`）。PLL 输出经 `GTP_CLKBUFG`（`u_gpuclk_bufg`）
进 `u_soc.gpu_clk`，fdc 的 `create_clock` 建在 **`u_pll_gpu/u_gpll/CLKOUT0`**（与
soc/npu/cpu/lcd 同姿，名字确定、不依赖综合器改名）。

### 2.2 两座桥

| 桥 | 通道 | 载荷宽度 | 深度 | 备注 |
|---|---|---|---|---|
| `gpu_axil_cdc` | AW / W / B / AR / R | 12 / 36 / 2 / 12 / 34 | 4 | AXI4-Lite；**不带 prot**（gpu_csr 只吃窗内 12 位偏移，prot 是装饰位） |
| `gpu_mem_cdc`  | AW / W / B / AR / R | 45 / 73 / 2 / 45 / 67 | 8 / **32** / 4 / 8 / **32** | AXI4 64-bit；**W/R 深度 32**，见下 |

**为什么 W/R 要 32 深**：`gpu_mem` 会把 8 B 粒度 burst 对齐到板级 32 B 块，最坏
`rd_beats(≤15) + pad(≤3) = 19 拍`；而 glue 的简化 AXI 从口在 `rready=0` 时**不保持
rvalid**（`gpu_mem.v` 文件头记着这条上板实测：BLIT 源少 2 拍）。⇒ **R 侧 FIFO 必须在
一整笔 burst 内永不为满**，否则会丢拍。16 深不够（19 > 16），32 深安全。
W 侧本来有 `wready` 反压不会丢，取同深度只为对账方便。

**为什么两座桥都基于 `board/dcfifo.v`**：它是本仓 CPU 三条 AXI 主口（`axi4_cdc_lsu`
等）已在板上跑了两周的同一件东西 —— Gray 指针、当前指针判满空、**自带
`DCFIFO_BAD_SYNC` / `DCFIFO_BAD_DATA` 两个负对照宏**（§4 的红臂就是用它）。

### 2.3 显示握手：只跨电平，不跨脉冲

旧写法在 soc 域做 `gpu_vsync_pulse = gpu_vs2 ^ gpu_vs3`，把**单拍脉冲**喂给 gpu_top。
一旦 GPU 换到更慢的钟，这个脉冲会被整拍漏采。改成：

* `vsync` 输入本来就是**每读一帧翻转一次的电平** ⇒ soc 域 2FF（`gpu_vs1/2`）后，
  把电平送进 wrapper；**异或沿检测搬进 gpu 域**（`vs1 ^ vs2` 在 gpu_clk 上做）。
* `flip_toggle` 是 gpu 域电平 ⇒ soc 域 2FF 后输出（原本就是电平语义，gui_bank 在帧首锁存）。

### 2.4 复位

`gpu_rst` = **异步置位 / gpu_clk 同步释放**（2FF），异步源 = `async_rst | soc_rst`。
把 `soc_rst`（= `glue_reset`）也 OR 进异步源，是为了保证 **gpu 域的释放永远不早于
soc 域** —— 两座桥的 dcfifo 两侧指针必须同时被扣住，不能"一侧先跑"。

---

## 3. 后续提频怎么改（已算好的格点）

VCO 固定 675 MHz，只改 `pll_gpu.v` 的 `STATIC_RATIO0/STATIC_DUTY0` 与 fdc 的
`create_clock -period`：

| gpu_clk | RATIO0 | DUTY0 | fdc period |
|---|---|---|---|
| **100.000 MHz（本档）** | 6.75 | 6 | 10.000 |
| 112.5 MHz | 6.0 | 6 | 8.889 |
| 120 MHz | 5.625 | 5 | 8.333 |
| 125 MHz | 5.4 | 5 | 8.000 |
| 133.333 MHz | 5.0625 | 5 | 7.500 |

纪律（沿用 `pll_50m.v` 立下的认证关系）：**板钟 ≤ PnR est**，且提频前先看 `.rtr`
里 `u_gpu` 自己的余量 —— 本档这一轮的意义之一，就是把"GPU 能不能到 125MHz"
从"soc_clk 混在一起看不出来"变成**一条独立的、可量化的路径**。

---

## 4. 仿真闸门（`sim/gpu/tb_gpu_cdc.v` + `run_2d_cdc.sh`）

装置：`gpu_clock_domain`（真 `gpu_top` + 两座桥 + 复位同步）+ `axi_ram_model`。
命令**从 CSR 窗推进去**（`CMD_DATA` / 最后字 `CMD_PUSH`，与板上 `gputest.c` 逐字一致）
⇒ 顺带把 CSR 跨域也验了；像素结果在 soc 侧 RAM 里**逐 8 B 字对黄金**（复用
`mk_hex.py` 的 7 个 2D case，与 `run_2d.sh` 同一套 `.init/.exp/.cmds`）。

| 臂 | soc_clk | gpu_clk | 目的 | 结果 |
|---|---|---|---|---|
| slow | 10 ns（100 MHz） | 14 ns（**71.4 MHz**） | gpu 更慢、与 soc 非整数比 | 7/7 PASS |
| fast | 10 ns | 6 ns（**166.7 MHz**） | gpu 更快（提频方向预演） | 7/7 PASS |

逐案证据（`sim/reglogs/gpu_cdc_{slow,fast}_<case>.log`）：
`fill_rect / blit565 / glyph / round32 / scissor / edge / blit8` 全部
`CDC PASS（逐字节吻合 153600 字）`。例：

```
== case blit565 [slow] ==
cdc: soc=10ns gpu=14ns aw=9649 w=154482 ar=49 seq=1 flip=0
CDC PASS（1 命令，逐字节吻合 153600 字）
```

**红臂（灵敏度自证，缺一不可）**：

| 红臂 | 做法 | 期望 | 实测 |
|---|---|---|---|
| ① `-DDCFIFO_BAD_SYNC` | 跳过 dcfifo 指针同步器 = "忘了做 CDC" | FAIL | **CDC TIMEOUT**（CSR 读 ID 就断了）→ 如期 FAIL |
| ② `-DDCFIFO_BAD_DATA` | FIFO 数据位取反 | MISMATCH | **CDC FAIL errors=2561** → 如期 FAIL |

⇒ "全绿"不是没覆盖：把 CDC 拆掉（①）或把数据打坏（②），这个闸门都会红。

**覆盖边界（如实记）**：本闸门只跑 2D 命令。3D 引擎**没有**单独的 CDC 仿真臂 ——
理由：桥看到的是同一套 AXI 读写流（2D 已覆盖 R/W 两条路、含 19 拍长 burst），
3D 的差异在引擎内部而不在桥上；**3D 过 CDC 的验收放在板上做**（§8 的 `gputest3d`）。

---

## 5. 改动清单

| 文件 | 作用 |
|---|---|
| `board/pll_gpu.v` | 新增：第五颗 GPLL（100.000 MHz） |
| `board/yeshen_mini_board_top.v` | `u_pll_gpu` + `u_gpuclk_bufg` → `u_soc.gpu_clk` |
| `board/yeshen_mini_soc.v` | 新增 `gpu_clk` 端口；`gpu_top u_gpu` → `gpu_clock_domain u_gpu`；vsync 改电平跨域 |
| `rtl/gpu/gpu_clock_domain.v` | 新增：时钟域唯一入口（桥 + 复位同步 + vsync/flip） |
| `rtl/gpu/gpu_axil_cdc.v` | 新增：AXI4-Lite 五座 dcfifo |
| `rtl/gpu/gpu_mem_cdc.v` | 新增：AXI4 五座 dcfifo（W/R 32 深） |
| `constraints/yeshen_mini.fdc` | `create_clock gpu_clk` + soc↔gpu 异步组 |
| `pds/run_{devmap,pnr}_yeshen.tcl` | 源列表 +4 |
| `sim/gpu/tb_gpu_cdc.v` / `run_2d_cdc.sh` | 新增：两时钟像素闸门 + 两个红臂 |

`gpu_top` 及其以下**一行未改** —— 所有既有单元闸门（`tb_gpu_2d` / `tb_gpu_3d` /
`tb_tri_raster`）仍按单时钟直接例化引擎，不需要跟着改。

---

## 6. dev_map 资源账

### 6.1 先修了 3D 的 tile 阵列（顺带，用户提议）

`gpuclk0` 的 dev_map 第一次把 3D 引擎带进映射，立刻暴露两块"白送"的资源：

```
W: Sdm-2010: gpu_3d.v(96/97) Not support multi-write simultaneously for RAM ctile/ztile
```

`ctile/ztile` 各 1024×16，而**装载一拍要写 4 个连续地址** ⇒ 推断不成 RAM，
落成 **32 k 触发器 + 巨大读 mux**。改法：按下标 mod 4 交错成 8 个 256×16 小阵列
（`ct{i[1:0]}[i[9:2]]`），装载/写回天然 4 像素对齐 ⇒ 每个小阵列每拍 1 项、单写口；
光栅单点读写按 `[1:0]` 选阵列；**读仍是组合读，光栅时序不变**。

| 资源 | 修之前（gpuclk0） | **修之后（gpuclk2）** | Δ |
|---|---|---|---|
| FF | 162,137 (51%) | **129,387 (41%)** | **−32,750** |
| LUT | 111,614 (70%) | **97,040.5 (61%)** | **−14,573** |
| Distributed RAM | 8,251 | 8,507 | +256（阵列落进了 LUTRAM） |
| DRM | 314 | 316 | +2 |
| APM | 293 | 293 | 0 |

3D 子系统闸门 `run_3d_ab.sh` 改后 **4/4 PASS**（逐字节，与改动前一致）。

### 6.2 与 2D-only 基线的总账

| 资源 | gpu10（无 3D、无 GPU 时钟） | gpuclk2（3D 修好 + GPU 时钟） | Δ |
|---|---|---|---|
| LUT | 92,878.5 (59%) | 97,040.5 (61%) | +4,162 |
| FF | 126,018 (40%) | 129,387 (41%) | +3,369 |
| APM | 270 | 293 | +23 |
| DRM | 313 (76%) | 316 (77%) | +3 |
| GPLL | 6 | 7 | +1（第五颗 PLL，后改路线，见 §7.1） |

DRC 行：**0 条**（`grep -E "^E:|DRC-"` 空）。


## 7. PnR 时序（单种子）

### 7.1 ⛔ 卡点：PDS 的 `pre clock plan` 拒绝第 5 颗 PLL 的时钟

第五颗 GPLL 版本（`board/pll_gpu.v`，100.000MHz）能过 synthesis + dev_map（DRC 0 条），
但 PnR 在 **`Stage 2.1 pre clock plan`** 阶段内部报错、四个种子全挂：

```
I: Start running PnR with seed 0. Total:1/4.
E: s0>Place-0135: Internal error: clock planning: complete solution has invalids when solving clock target.
Run process "Place & Route" failed
```

排除过程（每条都是一次真实构建）：

| 变量 | 结果 |
|---|---|
| strategy 1 / 3 | 都失败，报错逐字相同 |
| 显式 `GTP_CLKBUFG` vs 让 PDS 自动插 | 都失败 |
| GPU 面积（把 tile 阵列修成 RAM，FF −32.7k） | 仍失败 ⇒ **不是器件占用/扇出问题** |
| 时钟统计 | 13 USCM（gpu10，过）→ **14 USCM（挂）** |

`strings pds_shell.exe` 里有一批 `plc_clock_plan_*` 内部开关
（`strict_check` / `network_ports_allow_conflict` / `splc_pbm_enable_multi_clock_planning`），
但它们**不是 pnr 任务的合法 option**（`UiCommand-0256: The option 'plc_clock_plan_strict_check'
does not exist in object 'pnr_1'`），无法从 tcl 注入。

### 7.2 改走 `u_pll` 的 clkout1（当前构建，tag `gpuclk3`）

不再新增 PLL：`pll_100m_125m` 的 **clkout1**（整数分频器，RATIO1 8→**10**）
⇒ 1012.5 / 10 = **101.25 MHz**，经 `u_gpuclk_bufg` 进 `u_soc.gpu_clk`；
fdc 的 `create_clock` 落在 `u_pll/u_gpll/CLKOUT1`，周期 **9.8765 ns**（板钟周期）。

* 代价：与 soc_clk 同 VCO（相位锁定、不同分频 ⇒ 两域**漂移**，仍按异步处理）；
  可选的 gpu_clk 只剩整数格点（101.25 / 112.5 / 126.5625 / 144.64 MHz…）——
  对"提 GPU 频率"这个用途够用。
* `board/pll_gpu.v` 保留在仓库（已从 PDS 源列表注释掉），等 PDS 侧能过 clock planning 再切回。

**✅ 已验证卡点就在"第 5 颗 PLL"本身**（`gpuclk3` 的 PnR 日志）：

```
Stage 2.1 pre clock plan start.
I: Clock statistic: 14 USCM, 2 RCKB.
Stage: after pre clock plan | Time (s): real = 0h:0m:57s      ← 之前在这里 E: Place-0135 直接退出
[GP] Total node move: 25704571.54, average node move: 172.23   ← 已进入布局迭代
```

同一份设计、同样的 14 个时钟、同样的 strategy/种子，只把时钟源从"第五颗 GPLL"
换成"现有 PLL 的闲置 clkout1"，就从内部错误变成正常布局。
⇒ **结论：不是时钟数量、不是器件占用、不是 BUFG 写法，而是"第 5 颗 GPLL 参与时钟规划"
这件事本身触发了 PDS 的 clock planning 求解失败。** dev_map 的 GPLL 用量也从 7 回到 **6**。

### 7.3 上板前的全量回归（对 **gpuclk3 同一份 RTL**）

比特流出自当前 RTL，所以上板前把全部单元/子系统闸门按**这一份源码**重跑一遍：

| 闸门 | 内容 | 结果 |
|---|---|---|
| `run_csr.sh` | CSR + 命令 FIFO（id/fill/fence/scissor/flip/unimpl/fifo-free） | **PASS** |
| `run_mem.sh` | 读写引擎（write16/read16/combine32/strb0-neg/unalign8B） | **PASS** |
| `run_tri_ab.sh` | tri_raster 7 个几何用例，逐点 | **7/7 PASS** |
| `run_2d.sh` | 2D 七个 case（单钟直连引擎） | **7/7 PASS** |
| `run_2d_trunc32.sh` | 同上 + 板级 32 B 突发截断模型 | **7/7 PASS** |
| `run_3d_ab.sh` | 3D 子系统（one/zoccl/span/comp） | **4/4 PASS** |
| `run_2d_cdc.sh` | **GPU 时钟域**：7 case × 2 个 gpu 时钟比 | **14/14 PASS** |
| ↳ 红臂 ① `DCFIFO_BAD_SYNC` | 拆掉 CDC 指针同步 | 如期 **FAIL** |
| ↳ 红臂 ② `DCFIFO_BAD_DATA` | FIFO 数据位取反 | 如期 **FAIL**（错误 2561） |

### 7.4 PnR 结果（tag `gpuclk3`，单种子 strategy 1，**All Constraints Met**）

| 时钟 | 请求 | est | 周期请求 | 周期 est | slack |
|---|---|---|---|---|---|
| soc_clk | 100.0000 | **106.6667** | 10.0000 | 9.3750 | **+0.625** |
| cpu_clk | 100.0000 | 104.2862 | 10.0000 | 9.5890 | +0.411 |
| npu_clk | 59.9988 | 62.0078 | 16.6670 | 16.1270 | +0.540 |
| **gpu_clk** | **101.2504** | **101.6829** | **9.8765** | 9.8345 | **+0.042** |
| core_clk | 125.0000 | 134.0123 | 8.0000 | 7.4620 | +0.538 |
| lcd_clk | 51.9238 | 104.6682 | 19.2590 | 9.5540 | +9.705 |

**两件事同时成立**：
1. GPU 有了自己的域（101.25 MHz，比原来的 100 MHz 还高 1.25%）；
2. **soc_clk 从 est 104.4496 → 106.6667 MHz**（+0.625 slack vs 原来的 +0.426）——
   这正是"GPU 在给整个 SoC 封顶"被解开后的直接收益。

比特流：`9,188,552 B` / sha256 `98c73e3e11b314dd16b17d75b3d8d465` / md5 `fcde9412528d5846835ae8f1bfe3a724`。

**gpu_clk 的最差路径已经换人**（不再是被 2D blend 主导）：

```
Startpoint : u_soc/u_gpu/u_gpu/u_3d/u_raster/cy[7]/opit_0_AQ_perm/CLK
Endpoint   : u_soc/u_gpu/u_gpu/u_3d/u_raster/wcolor[6]/opit_0/CE
Path Group : gpu_clk     slack +0.042 ns（9.8345 / 9.8765）
```

⇒ 下一步提 gpu_clk（RATIO1 9 → 112.5 MHz）之前，必须先打断 `tri_raster` 的逐像素组合链
（`cy` → 边函数 → `wcolor` 选通）；这也是现在唯一挡在提频前面的东西。

### 7.5 第二轮 PnR（tag `gpuclk4`，含 `cmd_start` 分派修复 + RAM 推断修复）与**余量真相**

| 时钟 | 请求 | est | slack |
|---|---|---|---|
| soc_clk | 100.0000 | 105.8425 | +0.552 |
| cpu_clk | 100.0000 | 105.0862 | +0.484 |
| npu_clk | 59.9988 | 61.3196 | +0.359 |
| **gpu_clk** | **101.2504** | **102.6431** | **+0.134** |
| core_clk | 125.0000 | 134.4086 | +0.560 |

比特流 9,188,552 B / md5 `7d39da796275039013f39c47b213af24`。

**⚠️ gpu_clk 的真实余量 ≈ 0，不是 "+0.1 ns"**：同一份 RTL、只多加两处只读探针的
`gpuclk5`，seed 0 的 gpu_clk 就是 **−0.061 ns（2 个失败端点）**，其余域全部 > +0.3。
把两轮并排看 ⇒ **gpu_clk 的 run-to-run 波动就有 ±0.1 ns**，所以 `+0.134` / `+0.042` /
`−0.061` 这三个数**同属"贴着 0 走"**，不能当成"收敛了"。

而且最差路径始终是**同一族**（`tri_raster` 的逐像素 Z/颜色链）：

```
Startpoint : u_3d/u_raster/cy[7]        Endpoint : u_3d/u_raster/wz[7]/CE (或 waddr/CE)
路径： cy → idx=(cy-yorg)*stride+(cx-xorg) → z_raddr[3]（fanout 257）→ 分布式 RAM DO
       → ztile_rdata 4 选 1 → zpass 比较 → wz 的 CE
gpuclk4: +0.134（MET）／gpuclk5 seed0: −0.061（VIOLATED，2 端点）
```

⇒ 结论（供选频用）：**101.25 MHz 这一档在这个结构下没有余量**。要么先把这条逐像素链打断
（寄存 `z_raddr`/`idx`，接受 1 拍延迟换余量），要么把 gpu_clk 退到整数分频的下一个可落点
（`RATIO1=12 → 84.375 MHz`，预计余量 > +1 ns）。这条要在上板定性之后再定。

<!-- 待回填（§8）：上板 gputest / gputest3d / gpu3ddemo -->

## 8. 上板验收

### 8.1 运行手册（待用户给板窗口后执行）

```bash
# 1) 烧写 + done bit + 启动 marker + ping/ssh
python scripts/flash_and_verify.py --tag gpuclk3

# 2) 2D 回归（五分区分区失配全 0 才算过）
python scripts/gpu_board_judge.py --test gpu

# 3) 3D 判据（CLEAR3D / DRAW_TRIS / Z 负对照 / COMPOSITE3D，逐像素对黄金）
python scripts/gpu_board_judge.py --test 3d

# 4) 交互演示（转动立方体，300 帧记 fps；触摸拖动改视角）
#    板上跑 /tmp/gpu3ddemo
```

板上二进制（与本轮源码同时间戳，可直接复用）：

| 程序 | 大小 | md5 |
|---|---|---|
| `y1/build/gputest`    | 205,356 | `6859c9cc1cea614340a3121d0b610ff1` |
| `y1/build/gputest3d`  | 205,484 | `6a8883af11c801debb89a34ed819ce2d` |
| `y1/build/gpu3ddemo`  | 304,380 | `dd40661cbbf48c7ac3f1a779e5023911` |

### 8.2 判据（缺一不可）

1. **启动 marker 8/8** + ping 通 + ssh 通（否则不是 GPU 的问题，先看板）；
2. `gputest` 的五分区失配全 0 —— 证明搬时钟域 + 3D 集成**没有回退 2D**；
3. `gputest3d` 的 CLEAR/DRAW/Z 负对照/COMPOSITE 全 ok —— **P2a 的硬件首验**；
4. `gpu3ddemo` 能出转动立方体、触摸能改视角，记 fps（这是"可互动 3D 场景"的交付形态）。

### 8.3 上板首轮结果（2026-11-01，gpuclk3）

| 步骤 | 结果 |
|---|---|
| 烧写 + 启动 marker 8/8 + ping/ssh | **PASS** |
| `gputest`（2D 回归） | **PASS**：`ID=0x59475055`、五分区失配 `board=0 round=0 blit=0 glyph=0 blit2=0`、`err=0 seq=2 => PASS` |
| `gputest3d`（3D） | ✗ **挂死**：CLEAR3D 完成后不再前进 |
| `gpu3ddemo` | 未执行（被 3D 挂死挡住） |

**⇒ 抓到一个真 bug（已修，见 §8.4）。**

### 8.4 抓到的 bug：`cmd_start` 没有按 op 分派（3D 命令把 2D 引擎带死）

**现象**：板上 CLEAR3D 正常完成（`last_op=0x10`），之后 FIFO 里正好压着 9 个字
（下一条 3D 命令）**永不启动**；`SEQ` 停在 1；三条并发实例互相堵死。

**定位手段**（都在真硬件上做的，不靠猜）：
1. `y1/tools/gpu3dprobe.c`：分步 `fflush` + 每条命令**带超时** + **逐字回读 FIFO 余量**
   ⇒ 证明 9 个字**一字不丢**地进了 FIFO（free 16→7 单调下降），但一个字都不被消费；
2. 把同一串命令（CLEAR3D → FENCE → DRAW_TRIS）喂进 **CDC 仿真装置**（走真 CSR 通路）
   ⇒ **复现**：`CDC TIMEOUT ... aw=64 ar=0`（64 笔写全是 CLEAR3D 的，**一次读都没有**）；
3. 在 TB 超时分支打印内部状态 ⇒ `cmd: state=3(S_DONE) cnt=0 lcnt=0`、
   `disp: is3d=0 n3=1`、`3d: st=0` —— 卡的是**那条 1 参数的 FENCE**，3D 引擎根本没启动。

**根因**：`gpu_top` 把 `cmd_start` **同时**喂给 `u_2d` 和 `u_3d`，而参数流是按 `is3d` 门控的
（`par_valid_2d = par_valid && !is3d`）。于是任何 3D 命令都会让 **2D 引擎**进入"等参数"状态
并且永远等不到 ⇒ 2D 引擎此后不再回 `cmd_done` ⇒ `gpu_cmd` 停在 `S_DONE`、后续命令全部排队不动。

**修法**（`rtl/gpu/gpu_top.v`）：

```verilog
wire cmd_is3d = (cmd_op == 8'h10) || (cmd_op == 8'h11) || (cmd_op == 8'h12);
wire start_2d = cmd_start && !cmd_is3d;      // u_2d 只吃非 3D 命令
...
gpu_2d u_2d ( .cmd_start(start_2d), ... );
```

`is3d` 锁存也改用同一个 `cmd_is3d`（单一来源）。

**补的闸门**：`sim/gpu/run_seq_ab.sh` —— CSR 通路重放 `CLEAR3D → FENCE → DRAW_TRIS`：

| 臂 | 判据 | 结果 |
|---|---|---|
| 正臂 | 跑完（`seq=2`）、3D 真发读（`ar=1`）、写回 1024 拍 | **PASS** |
| 红臂（把 `start_2d` 退回 `cmd_start`） | 必须 TIMEOUT | **如期 TIMEOUT** |

> **覆盖缺口说明**：既有闸门里 3D 是**直连** `start/p0..p7` 测的，`gpu_cmd → gpu_top 分发`
> 这条**真命令通路只有 2D 命令走过** —— 所以 2D 全绿、3D 单元也全绿，混排却挂死。
> 这个缺口现在被 `run_seq_ab.sh` 堵上。

**回归**（修后、同一份 RTL）：2D 7/7、2D-T32 7/7、3D 4/4、CDC 14/14 + 2 红臂、
CSR/MEM/RASTER 全 PASS。

### 8.5 一个已知的判据口径瑕疵（记下来，暂不改）

`gpu_cmd` 的 `S_DONE` 里，**非 FENCE 命令也会把 `seq_done` 加 1**：

```verilog
if (is_fence) seq_done <= fence_seq;   // FENCE：写成请求的 seq
else          seq_done <= seq_done + 16'd1;   // 其它命令：也 +1
```

后果：主机用 `fence(seq=N)` 等完成时，**可能被前一条命令的完成提前满足**。
目前无害（命令本来就是串行的，等的正是"上一条做完"），但语义不干净 ——
将来若引入并发/流水，这里会变成假完成的来源。本轮不动它（避免再多一轮 PnR），
只在此记录。

### 8.6 第二轮上板（gpuclk4）：3D 中途挂死 —— 现场证据与判定

| 步骤 | 结果 |
|---|---|
| 2D 回归 `gputest` | **PASS**（五分区失配全 0） |
| `gputest3d` 第 3 步（CLEAR+DRAW+逐像素比对） | **PASS**（`CLEAR3D bad=0`、`DRAW_TRIS bad=0`） |
| `gputest3d` 第 4 步（Z 负对照的 CLEAR+DRAW） | ✗ **挂死**：卡在 `[fence 3]` |

**现场取证**（挂死 30+ 分钟后仍然一模一样 ⇒ 真死锁，不是慢）：

```
STATUS=0x000000D1   busy=1, fifo_used=13         ；gpu_cmd 没被复位（复位会清 used）
SEQ_DONE=0x00000003                              ；第 4 步的 CLEAR3D 已算完（非 FENCE 也 +1）
DBG=0x07000006       last_op=0x07(FENCE), last_cycles=6
DBG2=0x93195E00      最后一笔**已发出**的 AR = 颜色/Z tile (ty=14,tx=12) 的 Z 第 31 行
DBG3=0x000708A5      wrs=0 wcnt=0（写引擎空）| rdlen=7 rdcnt=8（那笔 burst 8 拍收全）
DDR:  (400,470) color=0x0000 z=0xFFFF   ← **仍是 CLEAR 后的值：这块 tile 一个像素都没写**
DDR:  (0,460)   color=0x07E0 z=0x9C40   ← 别的 tile 正常（绿 + z=40000）
```

**判定链**：
1. `wrs/wcnt=0` + `DBG2` 冻结 ⇒ GPU **不再发任何读写**，不是被 DDR 饿着；
2. 被卡的 tile 在 DDR 里还是 CLEAR 值 ⇒ 死点在 **tile 内部**（不是命令收尾、不是 done 握手）；
   又因为它后面的 7 个 tile（tx=13..19）也没画，说明 DRAW 没走完；
3. 该 tile 的 32 行**颜色+Z 都读完了**（最后一笔 AR 就是它的 Z 第 31 行，8 拍收全）⇒
   死点落在 **`S_RA`/`S_RAW`（光栅）或写回**；而写引擎空 ⇒ 只剩光栅；
4. `tri_raster` 的循环边界全被 clip 到 tile 内（≤32×32），**逻辑上不可能无限循环**
   ⇒ 只剩"状态被打坏"这一条路 —— 而这正好对上 §7.5 的结论：**gpu_clk 域余量 ≈ 0**
   （gpuclk4 +0.134 / gpuclk5 seed0 −0.061）。

**处置过程**（commit `f5d7d39`，同一轮改动）：
1. `gpu_clk` 先退档 **101.25 → 84.375 MHz**（`RATIO1=12`；fdc 周期 11.85185 ns）；
2. `gpu_3d` / `tri_raster` 的 `default` 分支改成**走 S_DONE 收尾**（原来回 IDLE 却把 `busy` 挂着，
   一旦状态被打坏就永久堵死整条命令队列）；`gpu_3d.dbg_state[7]` 做非法状态的粘滞位；
3. `S_S1W/S_S2W` 的 `wr_valid` 保持到 `wr_ready`（原来只挂一拍，backpressure 时静默丢拍）。

### 8.7 ★ 归因翻案：挂死是**判据程序自己崩了**，不是时序

在 84.375 MHz 上重跑同一套判据，**同样的冻结点又出现了一次**（`STATUS=0xD1`、13 字排队、
`DBG2=0x93195E00`、`DBG3=0x000708A5` 与 gpuclk4 那次**逐位相同**）⇒ 与频率无关。顺藤摸瓜抓到
判据程序（`y1/tools/gputest3d.c`）的两个真缺陷：

| # | 缺陷 | 现象 |
|---|---|---|
| ① | `fence()` 只等 `SEQ_DONE`，而 `gpu_cmd` 对**非 FENCE 命令也把 seq +1**（§8.5 的 wart） | fence 在 DRAW 刚跑到第 33/300 个 tile 时就返回 ⇒ 后续比对/写入发生在**画到一半**的缓冲上 |
| ② | `mmap` 只映 0x280000（2.5 MB），而第 5 步的 `dstbuf=0x93280000` 正好在映射边界外 | 写哨兵即 **SIGSEGV**；进程死在 DRAW 途中，**留给 GPU 半条命令** ⇒ `gpu_cmd` 永远等参数、`busy=1` 不动 —— 这正是我们看到的"挂死" |

⇒ 之前"GPU 挂在 tile (14,12)"的现场（读写引擎全空、tile 一个像素没写、30 min 不动）
**完全由 ② 解释**：命令流被截断，GPU 在等永远不来的参数。**gpu_clk 的余量问题是真的（§7.5），
但它不是这次挂死的原因。**

**修好的判据**（commit 见下）：
- `fence()` 改成 `SEQ 到位 **且** STATUS.bit0==0`（真·空闲），不再被提前满足；
- `mmap` 0x280000 → 0x300000；
- 第 4 步 Z 负对照重做：把第二条记录的 z 拉到 60000（比远平面 40000 更远）+ zmode=OFF
  ⇒ LESS 应整块被拒、OFF 照写，`diff=87760` 证明判据有区分力（旧写法只改 zmode，
  近平面本来就过 LESS，diff 恒 0，等于没有负对照）；
- 第 5 步 dst 行宽 256 → 320：`dx=8 + w=256 > stride=256` 会让每行尾部 8 px 线性溢出到
  下一行行首（RTL 是按 stride 定位、按 w 连续写，不做行内裁剪）—— 那 1560 个失配是
  **判据几何错**，不是 RTL 错。

**修好后在 84.375 MHz 上的实测**：`gputest` 2D PASS；`gputest3d` 四步全 PASS
（CLEAR/DRAW 逐像素 bad=0、Z 负对照 diff=87760、COMPOSITE bad=0）；`gputest3d -r 10`
（整屏 CLEAR+双三角形 DRAW+逐像素比对连做 10 轮）**10/10 全对、无挂死**；
`gpu3ddemo 300` 帧 **8.91 fps**。

**⇒ 恢复 101.25 MHz**（`RATIO1=10`、fdc 9.8765 ns），重出一版 `gpuclk7` 并在板上用同一套
修好的判据复验（结果见 §8.8）。余量仍是全设计最薄的一档，要再往上提必须先打断
`tri_raster` 的逐像素链（§7.5 那条 `cy→idx→z_raddr→RAM→zpass→wz.CE`）。

### 8.8 选频 A/B（**同一份 RTL、同一套判据，只差 gpu_clk**）

| 档 | 比特流 | 2D | 3D 单次 | 3D `-r 10` 连做 10 轮整屏重绘 | demo |
|---|---|---|---|---|---|
| **84.375 MHz**（`gpuclk6`，RATIO1=12） | md5 `a5f83b49…` | PASS | **PASS** | **10/10 零失配** | 300 帧 **8.91 fps** |
| 101.25 MHz（`gpuclk7`，RATIO1=10） | md5 `1bdd5544…` | PASS | **PASS** | ✗ **第 7 轮起出错**（bad=233120，随后 170438×3） | — |

**101.25 MHz 的失败现场**（第二次复跑直接 fence 超时，读 CSR）：

```
STATUS=0x00000021      busy=1, fifo_used=2
DBG  =0x04200012       st3d=0x20 = S_C_RDW（COMPOSITE 读等待）
DBG2 =0x93131E80       最后一笔 AR = tile(ty=4,tx=14) 的行
DBG3 =0xD00708A5       **wrs=3 = WR_B，wcnt=8** ⇒ 写引擎在等一个永远不来的 B 响应
```

⇒ 不是"画错一点"，是**写事务的响应丢了**（`gpu_mem` 卡在 WR_B）。这正是"gpu_clk 域零余量
（+0.134 / +0.040 / −0.061 三次 PnR）"在真实硅上的表现：跑得动单次、跑不过长压测。

**结论（交付口径）**：
- **交付 84.375 MHz**（`gpuclk8` = 本档 + 当前 RTL，含 COMPOSITE 写口背压修复）；
- 84.375 的余量：请求 11.8519 / est 11.3748 ns ⇒ **+0.477 ns**；
- 要回到 101.25 MHz+，**必须先**打断 `tri_raster` 的逐像素链（§7.5）并重跑本节这套压测
  （`gputest3d -r 10` 是判据；单次 PASS 不算数）。

### 8.9 收口：3D 做成 yshell 桌面应用之后的显示链路

桌面应用化过程中把 GUI 帧存的口径彻底钉清了（**GUI bank1 = `0x9280_0000`**，字地址 bit21
= 8 MiB；文档里旧写的 `0x9220_0000` 是错的）。最终方案（RTL 零改动）：

- LCD 固定读 bank1（`GUI_CTRL[1]=1`、不 FLIP），LVGL 只画 bank0；
- 每帧 flush 末尾一次硬件 BLIT 把可见区 1024×600 镜像到 bank1；
- GPU 绘制单元**每个任务落地一次**（否则异步队列会晚于软件绘制执行，把图标整列盖掉）。

细节与全部踩坑见 **[gpu-desktop-app.md](gpu-desktop-app.md)**。

### 8.9 ★ 再翻案：所谓"COMPOSITE 丢 1.8% 写拍"是**判据没做缓存维护**

§8.8 把 101.25MHz 判死之前，先看这条更硬的证据链：

| 实验（同一目标区，192×196 复合） | 结果 |
|---|---|
| 第 1 次贴图后比对 | bad≈750–1050（`got=AAAA` 哨兵，即"没写进去"） |
| **紧接着再贴一次**（CPU 不动目标区）| **bad=0** |
| 改 `dx=0`（32 B 对齐、不需要 pad 拍）| 仍然 bad≈1050 |

第一遍"丢"、第二遍不丢 ⇒ 不是 RTL 丢拍。真因：**本核的 `/dev/mem` 是可缓存的**
（VexiiRiscv 的 PMA 不区分 UC），判据**没做 CBO 维护**：
- CPU 填哨兵 → 脏行留在 L1D；GPU 把正确像素写进 DDR 后，CPU 比对**命中自己的旧副本**
  ⇒ 报"哨兵还在"；第一次比对把 128 KB 扫一遍，把脏行挤回 DDR，所以第二遍就干净了。
- 写三角形记录同理：不 flush 的话 GPU 可能读到旧记录。

**判据修法**（`y1/tools/gputest3d.c`，`-march=rv32imac_zicbom`）：
- CPU 写完、GPU 要读 → `cbo.flush`；
- GPU 写完、CPU 要读 → `cbo.flush`（干净行=丢弃）。
  ⚠️ **不能用 `cbo.inval`**：本核只放行 CBCFE，CBIE=0 ⇒ `cbo.inval` 故意 SIGILL（P0 的负对照门）。

**修后板上（84.375MHz，`gpuclk9`）**：单次 5 项全 `bad=0`、`err=0`；
`gputest3d -r 10`（10 轮整屏 CLEAR+双三角形 DRAW+逐像素比对 + 复合两连）**14 项全 0、err=0**。

**仿真补漏**：既有 `comp` 用例源宽只有 64 ⇒ 复合只有 **1 个 64 px 块**，"多块推进"从未被测过；
新增 `comp4`（源 256 宽 ⇒ **4 块/行**）并入 `run_3d_ab.sh` 默认集，5/5 PASS。

⇒ **§8.8"101.25MHz 不可靠"的结论作废**：那两次失败分别来自 ①GUI 的 cube3d 抢占命令队列、
②判据的缓存一致性。101.25MHz 用修好的判据重测见 §8.10。

### 8.10 交付验收：84.375 MHz（`gpuclk9` = 当前 RTL + `STATUS[17]` 回读位）

判据全部在**同一块板、同一次上电**、**GUI 已停**（`yshell --cube3d` 会抢 GPU 命令队列）下取得：

| 判据 | 结果 |
|---|---|
| PnR（101.25 之前的门） | **All Constraints Met**，gpu_clk 84.375 / est 88.43 MHz ⇒ **+0.544 ns**（全设计最厚的一档）；sbit md5 `438c131b…` |
| `gputest`（2D 回归） | **PASS**：五分区失配全 0、`err=0 seq=2` |
| `gputest3d`（3D 四步） | **PASS**：`CLEAR3D bad=0`、`DRAW_TRIS bad=0`（640×480 双三角形逐像素）、Z 负对照 `diff=87760`、`COMPOSITE3D bad=0` |
| `gputest3d -r 10`（10 轮整屏重绘压测） | **14 项 `bad=0`、`err=0`** |
| `gpu3ddemo 300`（旋转立方体） | 300 帧全出，**17.37 fps**（GUI 停时；GUI 在时是 8.91 fps） |
| 新增 `STATUS[17]` 回读 | 板上 `devmem` 实测：两次 FLIP 后 `0x00000000 → 0x00020000 → 0x00020000 → 0x00000000` |

> 频点说明：101.25 MHz 的 `gpuclk10` 在**修好的判据**下尚未测完（PnR 布线时间长于 84.375 档）；
> 在它给出「All Met + 10 轮压测全绿」之前，**交付档按 84.375 MHz**。

### 8.11 101.25 MHz（`gpuclk10`）为什么没有交付

用**修好的判据**重开 101.25：`RATIO1=10`、fdc 9.8765 ns 的同一份 RTL，seed 0 布线
**78 分钟仍未出带**（84.375 档 seed 0 约 40 分钟就收敛）。结合历史三次余量
（+0.134 / +0.040 / −0.061 ns），判定该域**在 101.25 没有可用余量**。

⇒ **交付档 = 84.375 MHz**（`gpuclk9`，sbit md5 `438c131bda489175cbe3e9801c875156`），
源码时钟与之一致。板子已 reboot 回正常 GUI 状态（`yshell` 已恢复、GPU 空闲）。

要往上提频，下一步是**打断 `tri_raster` 的逐像素链**（把 `idx`/`z_raddr` 寄存一拍，
用 1 拍延迟换余量），再用本节的整套判据（含 `-r 10` 压测）重新选频。
