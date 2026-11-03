# CPU Zbb/Zbs + 130 MHz 定档 + GPU 101.25 MHz（2026-11-02）

> 本轮三件事：① GPU 逐像素链打拍后把 gpu_clk 从 84.375 提到 **101.25 MHz**；② CPU 加 **Zbb+Zbs**；
> ③ CPU 用**过约束**把布局拉起来，主频从 100 MHz 定到 **130.645 MHz**。
> 证据分级：**[A]** EDA 实测（dev_map / `.rtr`）、**[B]** RTL 仿真逐字节、**[C]** 模型估算。

---

## 1. GPU 打拍提频：84.375 → 101.25 MHz

### 1.1 改了什么

`rtl/gpu/tri_raster.v` 拆成**两拍流水**（commit `a0464d3`）：

- 扫描级（`S_PIX`）：`cx/cy → idx → z_raddr → z_rdata` 组合链；
- 写回级：`p_valid/p_addr/p_in/p_color/p_z` 寄存一拍，`zpass` 用**上一拍**的 `p_z` 与 RAM 读数据比较；
- 收尾多一拍 `S_DRAIN`（最后一像素要流出写回级），`default → S_DONE`（坏状态也响亮收尾）。

### 1.2 时序 [A]

| 版本 | 约束 | gpu_clk 实测 | est fmax | slack |
|---|---|---|---|---|
| 打拍前（gpuclk7） | 101.25 MHz | 9.8365 ns | 101.66 MHz | **+0.040** |
| 打拍后（gpuclk11，seed 1） | 101.25 MHz | 9.4805 ns | **105.48 MHz** | **+0.396** |

⇒ 同频余量 +0.040 → +0.396 ns，**打拍把这一档从"零余量"变成有 4% 余量**。

`gpuclk11` 判据：**Design Summary = All Constraints Met**（seed 1），
soc/cpu/npu/core/rgmii 全正（+0.558 / +0.427 / +0.385 / +0.686），
sbit 9,188,552 B / md5 **`b89dd790b53e840eca337f88328c1345`**，
资源 LUT **97,063（61%）**（与打拍前持平，LUT 97,071）。

**为什么停在 101.25**：GPU 的 PLL 分频是整数档（VCO 1012.5 / RATIO1），下一档是 112.5 MHz
（8.889 ns）。101.25 档实测 9.4805 ns，要到 112.5 还差 0.99 ns 余量——不够。
⇒ **交付档 = 101.25 MHz**。

---

## 2. CPU 指令集：Zbb + Zbs

### 2.1 生成 [A]

`scripts/gen_core.sh` 增加 `--with-rvZbb --with-rvZbs`（不开 zba/zbc）：
网表 `rtl/vexiiriscv/VexiiRiscv.v` md5 **`9b738e97e5e3d5f6d5f0e6c4a2e32ded`**（34,626 行），
两次重生成逐字节相同（生成器确定性已验证）。网表里 Zbb 七类插件（ByteReverse / Count / Extend /
Logic / MinMax / Or / Rotate）+ ZbsPlugin 全部在册。

### 2.2 IPC A/B（裸核 CoreMark，Verilator，MEM_LAT=1，i10）[B]

| 网表 | CoreMark 二进制 | crcfinal | ticks | CM/MHz |
|---|---|---|---|---|
| HEAD（无 Zbb，md5 `e5fb9c5c`） | `rv32imac` | 0xfcaf | 2,222,967 | 4.4985 |
| 新（Zbb+Zbs，`9b738e97`） | `rv32imac` | 0xfcaf | **2,222,967** | **4.4985** |
| 新（Zbb+Zbs，`9b738e97`） | `rv32imac_zbb_zbs` | 0xfcaf | 2,147,967 | **4.6556** |

- **Zbb 硬件对非 Zbb 代码零代价**（同一份 imac 二进制，tick 数逐位相同）；
- **Zbb 代码 +3.49%**（4.4985 → 4.6556），`crcfinal` 与基线逐字节相同 ⇒ 指令语义正确
  （反汇编确认 GCC 实际发射了 `min/max/zext.h`：9/4/258 条）。
- 二进制 `rv32imac_zbb_zbs` 比 `rv32imac` 小 2,400 B（60,360 → 57,960）。

> ⚠️ 口径备注：历史日志里 4.6426 那一版来自**工作树里一份未提交的网表**（md5 `54931ad7`，
> 非本次任何一版），不可复现，已作废；以本节两臂为准。

### 2.3 面积 [A]

dev_map（含 GPU 101.25）：LUT **98,529.5 / 159,800（62%）**、FF 129,618（41%）、DRM 316（77%）、APM 293（40%）。
相对打拍前的 97,063.5：**+1,466 LUT**（Zbb+Zbs 的真实代价；此前估计 ~971）。

### 2.4 软件面

- DTS 的 `riscv,isa-extensions` 增加 `"zbb","zbs"`（供 6.18 内核给用户态置 HWCAP）；
- 用户态要用上 Zbb，需按 `-march=rv32imac_zbb_zbs` 重编镜像（等新内核镜像到位一起做）。

---

## 3. CPU 主频：100 → 130.645 MHz

### 3.1 关键发现：**布局是 FDC 的函数** [A]

同一份网表、同一 seed、strategy 1，只改 `cpu_clk` 约束：

| 约束 | 布完 WNS(place) | 布线后最差路径 | est fmax | slack |
|---|---|---|---|---|
| 10.000 ns | — | 9.573 ns | 104.46 MHz | +0.427 |
| 7.900 ns | −0.727 ns | （未跑完，布局已劣化） | — | — |
| **7.000 ns** | **−1.177 ns** | **7.413 ns** | **134.90 MHz** | −0.413 |

⇒ 10 ns 约束只会布到 9.57 ns；**7.0 ns 过约束能布到 7.413 ns**（差 2.16 ns = 23%）。
"能跑多快"不是网表的固有属性，而是**约束驱动布局**的结果。

### 3.2 定档 [A]

PLL：`board/pll_cpu.v` **RATIO0 = 7.75 / DUTY0 = 7** ⇒ VCO 1012.5 / 7.75 = **130.645 MHz**（7.6543 ns）。
（`DUTY0 ≤ int(RATIO0)`，否则 GTP_GPLL 静态参数违例——8.0/7.875 档曾因此作废。）

FDC：`cpu_clk` 写 **7.000 ns 过约束**（布局旋钮），交付频点 7.6543 ns 对实测 7.413 ns
有 **+0.241 ns（3.1%）** 余量。

### 3.3 不变量

mtime/UART 都在 **soc_clk 域**（glue 跑 soc_clk 100 MHz），所以主频变化**不需要**改
DTS `timebase-frequency` / `serial clock-frequency` / OpenSBI `NAX_CONSOLE_FREQ`。
CPU 与 soc 之间是三座 AXI 异步桥（`axi4_cdc_*`），跨速比不改变正确性。

### 3.4 操作注记：过约束跑法要**单种子收尾**

`run_pnr_yeshen.tcl` 的 `pnr -gplace_times 4 -pick_first_timing_convergence_seed true`
在没有 seed 收敛时会**把 4 个种子全跑完**。本档 7.0 ns 本来就不可能收敛（目标就是过约束），
seed 0 布到 7.413（想要的布局）、seed 1 更差、seed 2 病态（单轮 84 s、3 万条未布）。
处置：用 `pds/run_pnr_seed0.tcl`（**`-gplace_times 1 -saved_outcome 1`**）复用同一工程重跑——
实测 **place checksum 与 4 种子版的 seed 0 逐位相同**（`8327F34858DA070F`），
即"单种子"不改变 seed 0 的布局，只是不再去试注定失败的后续种子，跑完即出带。

> 直接对被杀工程跑 `gen_bit_stream` 会报 `Flow-0011: Place & Route adf file is not found`
> （工程状态不完整）——必须整轮 PnR 走完再出带。

---

## 4. 交付清单

| 件 | 值 |
|---|---|
| 核网表 | `9b738e97e5e3d5f6d5f0e6c4a2e32ded`（Zbb+Zbs） |
| GPU RTL | `tri_raster` 两拍流水（commit `a0464d3`） |
| PLL | cpu 130.645 MHz（RATIO0 7.75 / DUTY0 7）；gpu 101.25 MHz（RATIO1 10） |
| FDC | cpu 7.000 ns 过约束；gpu 9.8765 ns |
| 资源 | LUT 98,529.5（62%）/ FF 129,618 / DRM 316 / APM 293 |
| 比特流 | `pds_cpu130_20261102.sbit` / md5 **`89f4e1f09ae1c2337605e7ef9e967164`** / 9,188,552 B |
| 判据 | `pnr_verdict.sh cpu130 7.000`：Design Summary = **Some Constraints Violated**（**只有 cpu_clk 一项**，−0.413 @ 7.000 的过约束；其余 soc +0.464 / npu +0.493 / gpu +0.401 / core +0.460 / rgmii 全正）。按交付频点 7.6543 ns 计，cpu_clk 实际余量 **+0.241 ns** |

## 5. 待办

1. 上板验收（等用户窗口）：启动/UART、`gputest` 2D/3D、`-r 10` 压测、CoreMark（合法分需 ITERS≥6700）。
2. 新内核镜像到位后：用户态按 `-march=rv32imac_zbb_zbs` 重编 + DTB 带 zbb/zbs。
3. NPU 16-co（16×8 单阵列 + W16）集成：源码在 `D:\code\PDS_npu_ws`，按该仓
   `docs/specs/2026-11-01-wide-npu-mainline-integration.md` 执行。
