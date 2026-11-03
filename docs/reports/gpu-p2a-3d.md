# GPU P2a（3D 光栅器）实施记录

> 对应 spec：`docs/superpowers/specs/2026-10-30-simple-gpu-design.md` §6 / §11；
> 计划：`docs/superpowers/plans/2026-11-01-gpu-p2a-3d.md`。
> 状态：**RTL 完成并仿真验证**；dev_map / PnR / 上板待做（需要板窗口 + 一轮 PDS）。

## 1. 交付件

| 文件 | 作用 |
|---|---|
| `rtl/gpu/tri_setup.v` | 三角形 setup：面积归一（area<0 ⇒ 三条边整体取反）+ 边函数系数 + 包围盒；单 24×24 乘法器串行 8 次乘 |
| `rtl/gpu/tri_raster.v` | 包围盒扫描光栅 + Z 测试（逐像素只做加法；48 位 Q16 累加器） |
| `rtl/gpu/gpu_3d.v` | 3D 命令引擎：CLEAR3D / DRAW_TRIS（32×32 tile 读改写）/ COMPOSITE3D |
| `rtl/gpu/gpu_top.v` | 加 `u_3d`；op `0x10/0x11/0x12` 参数流按 `is3d` 选通，`cmd_done` 与 mem 口 mux |
| `rtl/gpu/gpu_regs.vh` + `YeshenGui/platform/gpu_regs.h` | 两侧 op 定义（`check_gpu_regs.py` → `GPU-REGS-MIRROR OK 27 entries`） |
| `YeshenGui/platform/gpu.{h,c}` | 用户态封装 `gpu_clear3d/gpu_draw_tris/gpu_composite3d` |
| `sim/gpu/tri_ref.py` | 同口径 Python 黄金（`--selftest` 六条性质 PASS） |
| `sim/gpu/mk3d_case.py` / `tb_gpu_3d.v` / `run_3d_ab.sh` | 子系统闸门（记录读取 → setup → tile RMW → 逐像素比对） |
| `sim/gpu/tb_tri_raster.v` / `run_tri_ab.sh` | 光栅单元闸门（七例） |
| `y1/tools/gputest3d.c` | **板上 3D 判据**（C 黄金 + Z 负对照 + 复合校验） |
| `y1/tools/gpu3ddemo.c` | 可互动演示（旋转立方体 + 触摸拖拽） |

## 2. 命令与数据格式

```
CLEAR3D (0x10, 8 字)      : color, z, w, h, color_base, color_stride, z_base, z_stride
DRAW_TRIS (0x11, 8 字)    : tri_addr, count, w, h, color_base, color_stride, z_base, z_stride
COMPOSITE3D (0x12, 8 字)  : src_base, src_stride, dst_base, dst_stride, w, h, dst_x, dst_y
```

三角形记录 **48 B**（6 个 8 B 字）：
```
w0={v0y,v0x}  w1={v1y,v1x}  w2={v2y,v2x}
w3={dzdx[31:0], color[15:0], z0[15:0]}
w4={28'b0, zmode[1:0], dzdy[31:0]}   w5=pad
```
顶点 `{s32 x_q8_8, s32 y_q8_8, u16 z}`（8.8 定点，像素中心采样 `(px<<8)+128`）。

DDR 布局沿用 `gpu_regs.vh`：`COLOR3D 0x9300_0000`（640×480 RGB565）、`Z3D 0x9310_0000`、`ARENA 0x9320_0000`。

## 3. 与 spec 的偏差（均已定案并写明理由）

1. **顶点 16 B（不是 8 B）**：spec 的 `int16 x_q8_8` 只能覆盖 ±128 px，装不下 640×480。改 s32 后 3 顶点仅 12 B 有效，为对齐取 16 B/顶点。
2. **Z 平面系数由 CPU 算**（`dzdx/dzdy` 随记录下发）：省掉一次 48/36 位有符号除法（约占几 K LUT）。与 spec「GPU 做 setup」的差别仅在这一次除法；边函数、光栅、Z 测试仍在 RTL。
3. **不做 tile 分桶表**：每三角形直接遍历其包围盒覆盖的 32×32 tile，逐 tile 读改写。演示场景（≤128 三角形、tile 覆盖少）够用；若将来三角形变大变多，再按 spec §6.3 加分桶表。
4. **COMPOSITE3D 的几何约束**：`w % 64 == 0`、`dst_x % 4 == 0`（每拍写满 8 B = 4 px，行首必须 8 B 对齐）。`dst_x=7` 会整体错位 —— 这是实测踩到的坑。

## 4. 闸门与证据

| 闸门 | 命令（WSL） | 结果 |
|---|---|---|
| 黄金自检 | `python3 sim/gpu/tri_ref.py --selftest` | `PASS`（覆盖数 / Z 双向 / LESS 负对照 / 退化 / 共边无洞） |
| 光栅单元 ×7 | `bash sim/gpu/run_tri_ab.sh` | 七例 `TRI PASS`（颜色 + Z 逐像素） |
| 3D 子系统 ×4 | `bash sim/gpu/run_3d_ab.sh` | `3D PASS`（one / zoccl / span / comp） |
| C↔Python 黄金同语义 | `gcc -DSELFTEST` + 脚本比对 | 两侧 `painted=153211 hash=9db11435326f76a6` **完全一致** |
| 2D 回归（集成后） | `run_2d.sh` / `run_2d_trunc32.sh` / `run_mem.sh` / `run_csr.sh` / `run_gpu_unit.sh` | 全绿（7 / 7 / MEM / CSR / GPU-GLUE） |
| 2D/3D 混排 + 红臂 | `bash sim/gpu/run_seq_ab.sh` | 正臂 `seq=2 ar=1` PASS；红臂（退回 `cmd_start`）如期 TIMEOUT |
| 3D **整屏 640×480**（CDC 双时钟、真 CSR） | `bash sim/gpu/run_3d_big.sh` | `CDC PASS`：`aw=48000 ar=38402 seq=2`，153600 字零失配 |
| gpu_mem 32 B 对齐读（丢前导拍） | `bash sim/gpu/run_mem_unalign.sh` | `MEM_UNALIGN PASS`（pad=0/1/3 三正例 + 一负对照） |

外科负对照：把 `in_tri` 的 `>=0` 改成 `>0`，`two_z` 立刻翻红（边界 2 像素），复原后 md5 与改前一致。

实现过程中抓到的真 bug（都已修）：
1. tile 写回只写了每行前 4 px（应按 8 拍 × 4 px = 32 px）；
2. 第 8 拍 off-by-one（`beat<7` 漏最后一拍）→ 改 `sw_last` 标志；
3. `tri_setup` 的 bbox 夹紧误用 `xmax[15:0]`（8.8 原值 → 扫到 30720，超时）；
4. 空包围盒不退出（加 `bx1<bx0 || by1<by0` 直接收工）；
5. `gpu_mem` 写口是 64-bit 字，4 B/拍会丢高半 → 一拍写满 8 B。

## 5. 待做（收口清单）

- [x] dev_map 记账（`gpuclk2`：3D 修完 tile 阵列后相对 2D-only 基线 **LUT +4.2 K / FF +3.4 K / APM +23 / DRM +3**）
- [x] PnR（`gpuclk3`，单种子 strategy 1，**All Constraints Met**；`gpu_clk` 101.25 MHz、soc est 106.67 MHz）
- [ ] 上板 `gputest3d` —— **首轮抓到真 bug，已修，等 `gpuclk4` 重验**（见 §6）
- [ ] 上板 `gpu3ddemo`（旋转立方体 + 触摸），记录 fps
- [ ] 报告回填实测数字（fps）

### 5.1 上板命令（一次窗口）

```bash
# ① 烧比特流（判据：启动 marker 8/8）
python -u scripts/flash_and_verify.py --tag gpuclk4
# ② 板上 3D 自检（判据：gputest3d 打印各段 bad=0 且结尾 => PASS）
python scripts/board_ssh.py "/tmp/gputest3d"
# ③ 交互演示：300 帧（触摸设备按板上实际 eventX）
python scripts/board_ssh.py "chmod 755 /tmp/gpu3ddemo; /tmp/gpu3ddemo 300 /dev/input/event1"
```

失败分诊：`gputest3d` 的 `CLEAR3D bad!=0` ⇒ 先看 CLEAR 的 base/stride 是否与 `gpu_regs.vh` 一致；
`DRAW_TRIS bad!=0` 且集中在某几列/行 ⇒ 先怀疑 tile 边界（32 px）与 COMPOSITE 的 `dst_x%4`；
`Z 负对照 diff==0` ⇒ 判据失效，别继续往下判。

## 6. 上板首轮（2026-11-01，`gpuclk3`）：抓到一个真 bug 并修掉

**现象**：`gputest`（2D）PASS，五分区失配全 0；`gputest3d` 卡死——CLEAR3D 之后不再前进。

**定位**（硬件探针 + 仿真复现，两条独立证据）：
1. `y1/tools/gpu3dprobe.c`（分步 `fflush` + 每条命令带超时 + **逐字回读 FIFO 余量**）
   ⇒ 9 个命令字**一字不丢**地进了 FIFO（free 16→7 单调下降），但**一个都不被消费**；
2. `sim/gpu/run_seq_ab.sh` 的装置（CDC 仿真、走真 CSR）重放同一串命令 ⇒ **复现**
   `CDC TIMEOUT ... aw=64 ar=0`（64 笔写全是 CLEAR3D 的，**一次读都没有**）；
3. 仿真超时分支打印内部状态 ⇒ `cmd: state=S_DONE cnt=0 lcnt=0`、`disp: is3d=0 n3=1`、
   `3d: st=0` —— 卡的是那条 1 参数的 **FENCE**，3D 引擎根本没被启动。

**根因**：`gpu_top` 把 `cmd_start` **同时**喂给 `u_2d` 与 `u_3d`，而参数流按 `is3d` 门控
（`par_valid_2d = par_valid && !is3d`）。任何 3D 命令都会让 **2D 引擎**进入"等参数"状态并
永远等不到 ⇒ 2D 引擎此后不再回 `cmd_done` ⇒ `gpu_cmd` 停在 `S_DONE`，后续命令全部排队不动。

**修法**（`rtl/gpu/gpu_top.v`，3 行）：

```verilog
wire cmd_is3d = (cmd_op == 8'h10) || (cmd_op == 8'h11) || (cmd_op == 8'h12);
wire start_2d = cmd_start && !cmd_is3d;      // u_2d 只吃非 3D 命令
```

**覆盖缺口（这才是它能溜过所有闸门的原因）**：既有的 3D 闸门是**直连** `start/p0..p7` 测引擎，
2D 闸门走的是 `gpu_cmd → 分发` 的真通路但只有 2D 命令 ⇒ **混排从未被测过**。
新增 `sim/gpu/run_seq_ab.sh`（正臂 + 红臂，红臂=退回旧接法必须 TIMEOUT）堵上这个缺口。

**回归**：修后 2D 7/7、2D-T32 7/7、3D 4/4、CDC 14/14 + 2 红臂、CSR/MEM/RASTER 全 PASS。

## 7. 上板第二轮（2026-11-01，`gpuclk4`，101.25MHz）：3D 中途"挂死" → **判据程序崩了**

`gputest3d` 第 3 步（CLEAR+DRAW+逐像素对黄金）**PASS**，之后表现为"第 4 步 DRAW 挂死、
30 min 不动"。硬件取证链（4 个寄存器探针 + DDR 里被卡 tile 的实际内容）见
[gpu-clock-domain.md](gpu-clock-domain.md) §8.6。

**归因翻案（§8.7 详述）**：先按"gpu_clk 零余量"处置（退到 84.375MHz），结果在 84.375MHz 上
**同样的冻结状态逐位复现** ⇒ 与频率无关。真因是**判据程序自己崩了**：

1. `fence()` 只等 `SEQ_DONE`，而 gpu_cmd 对非 FENCE 命令也 +1（已知 wart）⇒ fence 在 DRAW
   只画到 33/300 个 tile 时就返回，后续比对/写入落在半成品缓冲上；
2. `mmap` 只映 2.5MB，第 5 步 `dstbuf=0x93280000` 正在映射边界外 ⇒ 写哨兵即 **SIGSEGV**；
   进程死在 DRAW 途中 ⇒ **留给 GPU 半条命令**，`gpu_cmd` 永远等参数 = 我们看到的"挂死"。

**判据修好后（84.375MHz 实测）**：2D PASS；3D 四步全 PASS（DRAW 逐像素 bad=0、
Z 负对照 diff=87760、COMPOSITE bad=0）；`-r 10` 连做 10 轮整屏重绘 **10/10 零失配**；
`gpu3ddemo 300` 帧 **8.91 fps**。随后把 `gpu_clk` **恢复 101.25MHz** 重出 `gpuclk7` 复验。


## 8. 写口背压：`S_C_WRF` 漏改（2026-11-01 补）

`f5d7d39` 把 `S_S1W/S_S2W` 的 `wr_valid` 改成保持到 `wr_ready`，但 **COMPOSITE3D 的
`S_C_WRF` 漏了**：`wr_valid` 无条件拉低、`cbi` 只在 `wr_ready` 为高时前进 ⇒
backpressure 那一拍**静默丢失**，复合目标上留哨兵值。

既有闸门全都覆盖不到，因为 `gpu_mem` 的 `wr_ready` 平时恒高。补的闸门：

| 臂 | 做法 | 结果 |
|---|---|---|
| 正臂 | `gpu_mem` 加 `-DWSTALL`（4 拍给 3 拍 ready，收发两侧同一个 ready） | `one`/`comp` 全 **PASS** |
| 旧 RTL | `S_C_WRF` 未修（`4020125`） | **931 处失配**（静默丢拍确实存在） |
| 自证 | 统计 `wr_valid && !wr_ready` 拍数 | 1182 / 3310 拍，背压**真的**挡住了 |

> ⚠️ 踩坑：一开始只在 TB 侧把 `wr_ready` 挡给生产者，`gpu_mem` 内部仍按自己的 ready 收数，
> 于是"保持到 ready"的生产者会把同一拍**重复交付** ⇒ 造出假红。注入点必须收发共享。

修法（`rtl/gpu/gpu_3d.v`）：

```verilog
S_C_WRF: if (wr_ready) begin          // 原来：begin wr_valid<=0; if (wr_ready) ...
  wr_valid <= 1'b0;
  cbi <= cbi + 4'd1;
  ...
```

回归（修后）：`run_3d_ab` 4/4、`run_3d_stall` 2/2、`run_seq_ab` 正+红、`run_3d_big`
640×480 逐字节 PASS、`run_mem_unalign` PASS。

## 9. 3D 已做成 yshell 桌面窗口应用（2026-11-01）

交付形态、显示链路口径（**GUI bank1 = 0x9280_0000，字址 bit21 = 8 MiB**）、以及这一轮
在桌面上踩到的 9 类坑（Z 饱和 / 5 个几何 bug / scissor 持久状态 / tile 过载 /
bank 地址账 / 单缓冲 / 整屏失效放大 30 倍 / 图像越界跳过 / GPU 异步盖图标）
全部记录在 **[gpu-desktop-app.md](gpu-desktop-app.md)**。

回归闸门：`gpu3ddemo --selftest` 六向逐像素（每向 bbox 384×384、147456 像素、单色、单深度）。
