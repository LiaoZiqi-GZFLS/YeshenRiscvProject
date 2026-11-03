# Y1-A1：DDR 静态上界判据（用户口位宽 × core_clk）

目标：**只从本仓源码出发**，判断 DDR 用户口的数据位宽与其时钟，算出静态带宽上界，
并回答"逐层特征图经 DDR 往返"这条架构能不能达到它需要的带宽。

- 工作负载：每次推理经 DDR 搬运 **30.5 MB** 中间激活 ⇒ @15fps = **458 MB/s**，@10fps = **305 MB/s**。
- 本任务**不上板**，只做仓内只读取证 + 算术。
- 判据：**若用户口 raw 上界 < 305 MB/s ⇒ 算术否决**；否则 ⇒ 继续实测。

---

## 1. 事实（逐条给出 file:line + 逐字原文）

### 1.1 DDR 用户口的数据位宽

| # | file:line | 逐字原文 |
|---|---|---|
| F1 | `board/yeshen_mini_board_top.v:378` | `    wire [255:0] ddr_axi_wdata;` |
| F2 | `board/yeshen_mini_board_top.v:379` | `    wire [31:0]  ddr_axi_wstrb;` |
| F3 | `board/yeshen_mini_board_top.v:385` | `    wire [255:0] ddr_axi_rdata;` |
| F4 | `board/yeshen_mini_board_top.v:484` | `        .MEM_DQ_WIDTH     (32),` |
| F5 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:20` | `   parameter MEM_DQ_WIDTH         =  32         ,` |
| F6 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:45` | `    input  [8*MEM_DQ_WIDTH-1:0]        axi_wdata                     ,` |
| F7 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:46` | `    input  [MEM_DQ_WIDTH-1:0]          axi_wstrb                     ,` |
| F8 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:58` | `    output [8*MEM_DQ_WIDTH-1:0]        axi_rdata                     ,` |
| F9 | `src/soc/DDR3Bridge.scala:113` | `    val ddrWData  = Output(UInt(256.W))` |
| F10 | `src/soc/DDR3Bridge.scala:114` | `    val ddrWStrb  = Output(UInt(32.W))` |
| F11 | `src/soc/DDR3Bridge.scala:122` | `    val ddrRData  = Input(UInt(256.W))` |
| F12 | `src/soc/DDR3Bridge.scala:130` | `  private val GRP_BYTES = 32                       // 一笔 DDR 事务 = 256bit = 32B（**不变**）` |

读法：IP 顶层 `ddr3_test` 的用户口 `axi_wdata` / `axi_rdata` 是 `8*MEM_DQ_WIDTH` 位，
本工程例化时 `MEM_DQ_WIDTH = 32` ⇒ **8 × 32 = 256 bit = 32 B/beat**。
`axi_wstrb` = `MEM_DQ_WIDTH` = 32 bit 逐字节掩码，与 32 B/beat 自洽。
板级 `ddr_axi_wdata[255:0]` / `ddr_axi_rdata[255:0]` 与桥的 `ddrWData/ddrRData = UInt(256.W)` 逐条对齐。

### 1.2 用户口的时钟

| # | file:line | 逐字原文 |
|---|---|---|
| F13 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:30` | `    output                             core_clk                      ,            ` |
| F14 | `third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:295` | `assign core_clk = ddrphy_sysclk;` |
| F15 | `constraints/yeshen_mini.fdc:88` | `create_clock -name {ref_clk} [get_ports {ref_clk_p}] -period {8.0} -waveform {0 4.0}` |
| F16 | `constraints/yeshen_mini.fdc:95` | `#     · core_clk = **DDR3 IP 自己的 core_clk 输出**（DDR PHY 由 ref_clk 派生、×16÷16 的 125MHz），` |
| F17 | `constraints/yeshen_mini.fdc:121` | `create_generated_clock -name {core_clk} -source [get_ports {ref_clk_p}] [get_pins {u_ddr3.u_ddrphy_top.ddrphy_gpll/clkout0}] -master_clock [get_clocks {ref_clk}] -multiply_by {16} -divide_by {16}` |
| F18 | `board/yeshen_mini_board_top.v:405` | `        .io_ddr_clk  (core_clk),             // ★ IP 输出的 125MHz（见文件头【1】）` |
| F19 | `board/yeshen_mini_board_top.v:9` | `//   ref_clk_p/n 125MHz ─► u_ddr3 ─► core_clk 125MHz ─► DDR3Bridge.io_ddr_clk` |
| F20 | `board/yeshen_mini_board_top.v:23` | `//   (a) **IP 的用户口（axi_awvalid/wdata/rvalid…）是 IP 内部 core_clk 域同步的**，我们这侧的` |
| F21 | `constraints/yeshen_mini.fdc:113` | `create_clock -name {cpu_clk} [get_pins {u_pll/u_gpll/CLKOUT0}] -period {10.000} -waveform {0 5.000}` |
| F22 | `constraints/yeshen_mini.fdc:93` | `#     · cpu_clk  = 板级 PLL u_pll/u_gpll/CLKOUT0 = **100.000MHz 精确**` |

读法：
- `ref_clk` 约束周期 8.0 ns ⇒ **125 MHz**（F15）。
- `core_clk` 是 `ref_clk` 派生的 generated clock，`-multiply_by 16 -divide_by 16`（F17）
  ⇒ **125 MHz**（F16 的注释也写明"×16÷16 的 125MHz"）。
- IP 顶层 `assign core_clk = ddrphy_sysclk;`（F14）—— 用户口就活在这个域里（F20），
  板级把桥的 `io_ddr_clk` 接到 IP 的 `core_clk` 输出（F18）。

### 1.3 位宽转换（读数的歧义来源，必须显式说明）

| # | file:line | 逐字原文 |
|---|---|---|
| F23 | `board/yeshen_mini_board_top.v:11` | `//   DDR3Bridge.io_ddr*（256bit 简化 AXI 主）─► u_ddr3 的 axi_* 用户口` |
| F24 | `board/yeshen_mini_board_top.v:10` | `//   yeshen_mini_soc.mem_*（64bit AXI4 主）─► DDR3Bridge.io_axi_*（64bit 从）` |
| F25 | `src/soc/DDR3Bridge.scala:9` | `// CPU 侧 (axi_clk 域, 80MHz): 完整 AXI4 slave (**64bit 数据**, 字节地址)` |
| F26 | `src/soc/DDR3Bridge.scala:10` | `// DDR 侧 (ddr_clk 域, 125MHz): 紫光同创 DDR3 IP 简化 AXI (256bit 数据, word地址)` |
| F27 | `src/soc/DDR3Bridge.scala:131` | `  private val GRP_BEATS = GRP_BYTES / AXI_BYTES    // 每 32B 组的 AXI 拍数 = **4**（32bit 时代是 8）` |
| F28 | `src/YeshenSocGlue.scala:8` | `//   mBus_* : AXI4 主（**64bit data**/32bit addr，awid=arid=bid=rid=2bit，**有 awallStrb、没有 prot**）` |
| F29 | `src/YeshenSocGlue.scala:20` | `//    DDR3Bridge 内部的 32B 聚合（它的 DDR 侧协议一字未改，见该文件头）。` |
| F30 | `board/yeshen_mini_soc.v:86` | `    // ---- 内存主口：AXI4 master，**64bit data**/32bit addr、id 4bit（= YeshenSocGlue.io_mem）----` |

**歧义说明**：桥 `DDR3Bridge` 是一次**真实的宽度转换**——AXI 从口 **64 bit**（SoC 内存主口，`mem_*`），
DDR 侧 **256 bit**（IP 用户口）。两端口位宽不同 ⇒ 若把"我们的 fabric 看到的那个口"
理解成"挂在 SoC 内存总线上的 AXI 主口"，读数就是 64 bit。两种读数都列在下面，不静默择一。

---

## 2. 读数 W（字节/拍）与 f（Hz）

### 读数 A（主读数，本任务标题与 commit message 的口径："用户口位宽 × core_clk"）

- **W = 32 B/beat**（256 bit，F1–F11）。
- **f = 125 MHz = 1.25e8 Hz**（F15/F16/F17）。
- 时钟域：**`core_clk`** = DDR3 IP 自己的 `core_clk` 输出（= `ddrphy_sysclk`），由 `ref_clk`(125MHz) 经
  内部 GPLL ×16÷16 派生；IP 用户口即此域（F20）。桥的 DDR 侧、板级 `ddr_axi_*` 线、IP 的 `axi_*` 用户口同域。

### 读数 B（次读数：桥的 AXI 从口 / SoC 内存主口）

- **W = 8 B/beat**（64 bit，F24/F25/F28/F30）。
- **f = 100 MHz = 1.0e8 Hz**（F21/F22，`cpu_clk`）。
- 时钟域：**`cpu_clk`**（板级 PLL `u_pll/u_gpll/CLKOUT0`，10.000 ns 周期）。
  `YeshenSocGlue.io_mem` / `board/yeshen_mini_soc.v` 的 `mem_*` / `DDR3Bridge.io_axi_*` 同域。
- ⚠️ `src/soc/DDR3Bridge.scala:9` 的注释写"axi_clk 域, **80MHz**"，与 `constraints/yeshen_mini.fdc:113`
  的 `cpu_clk` = 10.000 ns (**100 MHz**) 不一致 —— 这条注释是**过期的**（板级接线
  `board/yeshen_mini_board_top.v:403` `.clock (cpu_clk)`）。本报告按 fdc 的 100 MHz。

> 本报告**以读数 A 作为静态上界的主判据**（口径见任务标题），读数 B 作为"若加速器挂在 SoC 内存总线上"
> 的上界一并给出。

---

## 3. 脚本与运行结果

脚本：`y1/partA/ddr_ceiling.py`（内容按任务书给定，逐字一致）。

### 3.1 主读数 A：`W=32 B/beat @ 125 MHz`

```
=== 主读数 A: DDR3 IP 用户口 256bit @ core_clk 125MHz ===
user port = 32 B/beat @ 125 MHz -> raw ceiling 4000.0 MB/s
  eff=0.5 ->  2000.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
  eff=0.6 ->  2400.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
  eff=0.7 ->  2800.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
  eff=0.8 ->  3200.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
需要: @15fps 458 MB/s ; @10fps 305 MB/s
```

**raw 上界 = 4000.0 MB/s**（= 32 B/beat × 125 MHz）。

### 3.2 次读数 B：`W=8 B/beat @ 100 MHz`

```
=== 次读数 B: 桥 AXI 从口 / SoC 内存主口 64bit @ cpu_clk 100MHz ===
user port = 8 B/beat @ 100 MHz -> raw ceiling 800.0 MB/s
  eff=0.5 ->   400.0 MB/s | @15fps(458 MB/s): NO | @10fps(305 MB/s): OK
  eff=0.6 ->   480.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
  eff=0.7 ->   560.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
  eff=0.8 ->   640.0 MB/s | @15fps(458 MB/s): OK | @10fps(305 MB/s): OK
需要: @15fps 458 MB/s ; @10fps 305 MB/s
```

**raw 上界 = 800.0 MB/s**（= 8 B/beat × 100 MHz）。

---

## 4. 判定

`## 判定`

**RESULT: 继续实测**

### 数字

- 主读数 A（DDR3 IP 用户口）：**raw 上界 = 4000 MB/s ≫ 305 MB/s（10fps）、≫ 458 MB/s（15fps）**。
- 次读数 B（桥 AXI 从口 / SoC 内存主口）：**raw 上界 = 800 MB/s ≥ 305 MB/s（10fps）、≥ 458 MB/s（15fps）**。

两种读数下 raw 上界**都高于** 305 MB/s 这条否决线，也高于 458 MB/s ⇒ **算术上不否决**。
`raw ceiling` 不是约束条件：**真正的约束是"可达值"（achievable），必须上板实测**（后续任务 Y1-A2）。
特别地，桥 `DDR3Bridge` 是**单 outstanding**、每笔 DDR 事务**只发 1 个 256bit beat**、
每个 beat 都要过一次**四相 CDC 握手**（`src/soc/DDR3Bridge.scala` 文件头约束 1 / 约束 4、
`io.ddrAwLen := 0.U` / `io.ddrArLen := 0.U`）⇒ 用户口**不可能**每拍都打满 32 B，
raw 4000 MB/s 与可达值之间会有一个由协议开销决定的折减，这正是 A2 要测的量。

### 命中 458 MB/s 所需的效率系数（存档）

- 主读数 A（raw = 4000 MB/s）：需要 eff = 458/4000 = **0.115**（≈ 11.5%）。
- 次读数 B（raw = 800 MB/s）：需要 eff = 458/800 = **0.573**（≈ 57.3%）。
  （次读数 B 在 eff=0.5 时只有 400 MB/s < 458 MB/s ⇒ 若按 SoC 内存主口口径，15fps 需要 ≥57% 的效率才成立。）

### 对下游的含义

- 逐层-DDR 架构**未被算术否决**；真正的风险落在"可达值"而非"上界"。
- Part-B 的切片工作（int8 MAC 阵列 / 分组卷积 / 行缓冲等）是**与架构无关**的，无论 DDR 结论如何都成立，
  照原计划推进。
- DDR 往返方案的**可行/不可行结论以 Y1-A2 的实测为准**；若实测可达值 < 305 MB/s，
  该架构届时才需改（例如片上多块激活缓存以少走 DDR）。

---

## 5. 存疑

1. **口径歧义（已显式两读）**：桥两侧位宽不同（64 bit ↔ 256 bit）。本任务标题与 commit message 的
   口径是"用户口位宽 × core_clk"= 读数 A；但若加速器作为 AXI 主口挂在 SoC 内存总线上，
   它"看到"的端口是 64 bit @ 100 MHz = 读数 B。本报告两者都给了上界，未静默择一。
2. **`DDR3Bridge.scala:9` 的 "80MHz" 注释与 fdc 的 100 MHz 冲突**：以 `constraints/yeshen_mini.fdc:113`
   （`cpu_clk` = 10.000 ns）为准；这条注释过期，不影响 A 读数（A 只用到 `core_clk` 125 MHz）。
3. **A 的 raw 4000 MB/s 是"每拍都打满 32 B"的理论上界**。桥的协议（单 outstanding + 每 beat 一次
   四相 CDC 握手 + 单 beat 突发）会使真实可达值显著低于此数 ⇒ 上界通过**不等于**可达值通过，
   这正是 Y1-A2 存在的理由。

---

# Y1-A2：板端 DDR 有效带宽实测（位宽扫描判别 + 缓存负对照）

## A2 板端实测

### 0. 结论速览

| 项 | 值 |
|---|---|
| 被测路径 | **CPU 驱动**（用户态 RV32 用户程序，直读/直写 64 MiB 缓冲） |
| 大缓冲（64 MiB）最大可达 | u32 write **47.2 MB/s**、u32 read **38.4 MB/s** |
| 位宽扫描 | read ×2.67、write ×1.41、rmw ×4.36（r32/r8）⇒ **不是平坦** |
| 缓存负对照 | **4 KiB 成立**（write ×5.04、read ×1.86）；**32 KiB 不成立**（×1.00）—— 因为板上 L1D 只有 **8 KiB** |
| 与 305/458 比 | 实测 47.2 MB/s = 305 的 **15%**、458 的 **10%**（30.5 MB/帧 ⇒ **1.55 fps**） |
| **RESULT** | **`RESULT: 指令受限，本次测不出 DDR 上限（须升级到 A3 的 AXI 主口微基准）`** |

### 1. 程序与口径

程序：`y1/partA/ddr_bw_test.c`；构建脚本：`y1/partA/build_ddr_bw_test.sh`。

判据（**写在程序文件头**，判决由程序自己给出，同时把所有原始数字打出来供人工复核）：

- **方法学陷阱**：本核是 RV32，最宽单次访问只有 32 bit，一次搬运是 `load`+`store` = 2 条指令/元素
  ⇒ CPU 驱动路径的上界 ≈ `4 B/(元素指令数)/周期`，100 MHz 下量级 ~200 MB/s，**本身就低于 305 MB/s**。
  所以测到低值只能说"CPU 驱不动"，**不能**说"DDR 慢"。
- **位宽扫描判据**：同一足迹下用 `volatile uint8_t/uint16_t/uint32_t` 访问。
  吞吐**随位宽放大**（≈1:2:4）⇒ **指令/CPU 受限**，绝对数**与 DDR 无关**；
  吞吐**跨位宽平坦** ⇒ **内存受限**，数字才有意义。
  阈值写死：**平坦** = read/write/rmw 三者 `r32/r8 ≤ 1.40`；**有放大证据** = 任一 mode `r32/r8 ≥ 1.80`。
- **缓存负对照的合格线**：小缓冲速率必须**明显高于**大缓冲（判据取 **32 位那一行**的 `small/big ≥ 1.50`，三个 mode 都要成立）。
  不成立 ⇒ 大缓冲那个数**不是** DRAM 在限速 ⇒ 无效。
  但"无效"只在**同时**满足"负对照不成立"且"位宽扫描毫无放大证据"时才判（否则"CPU 受限"已经能解释小缓冲不变快）。
- **判定优先级**：P1 无效 → P2 平坦（比 305/458）→ P3 其余（指令受限）。
- 口径：MB = 1e6 B（与 305/458 同口径）；read/write/rmw 分开测分开报；RMW 按**足迹**计字节
  （它**实际产生的 DDR 流量是它的 2×**）；预热 1 遍丢弃；取 N 遍里最好（时间最短）的一次；N 默认 3。
- 输出**纯 ASCII**（控制台 GBK 味，仓内被非 ASCII 打印坑过）：中文结论由
  `RESULT:` 的 ASCII 码唯一映射写在报告里。

### 2. 构建 / 传输 / 运行的确切命令

```
# 构建（在 WSL 里）
wsl -e bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && bash y1/partA/build_ddr_bw_test.sh'
#   CC = /home/lazybones/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc
#   flags = -O3 -fno-common -funroll-loops ... -march=rv32imac_zicsr_zifencei -mabi=ilp32
#           -mcmodel=medany -Wall -static      （与 sw/coremark-linux/build_linux.sh 同一套）
#   strip 后二进制 = **83288 B**，md5 = **763c38dac66a85cbe80a02fac5d29e8c**

# 传输（dropbear 没有 sftp-server ⇒ **必须 -O 走老 scp 协议**）
scp -O -o KexAlgorithms=curve25519-sha256 -o HostKeyAlgorithms=ssh-ed25519 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    y1/partA/ddr_bw_test root@192.168.1.110:/tmp/ddr_bw_test      # → 远端 83288 B（与本地一致）

# 运行（板上后台跑，结果落板上文件）
nohup /tmp/ddr_bw_test 67108864 3 4096  16777216 > /tmp/a2_full_s4k.txt  2>&1 &
nohup /tmp/ddr_bw_test 67108864 3 32768 16777216 > /tmp/a2_full_s32k.txt 2>&1 &
nohup /tmp/ddr_bw_test 4194304  1 <small> 4194304 > /tmp/a2_p<small>.txt 2>&1   # 缓存尺寸阶梯 <small>∈{4096,8192,16384,32768,65536}
```

⚠️ **传输通道的实测坑（与任务书"strip 后 ~50 KB 一次传完"的既有结论有关，但这条更严重）**：

- 这块板子的 **ssh 输出方向超过约 1 KB 就会卡死**（客户端 exit 124），但**远端命令其实已经执行完**——
  所以**不能按退出码判成败**。`stat` 板内也没有（busybox）。
- **≤1024 B 的输出重试几次可以稳收**；>1536 B 十次也没成功过一次。
- `scp -O` 反向（host→board）83 KB 是通的，但本次 549 B 的 runner 脚本反而 5 次全失败 ⇒ scp 也会抖。
- **最终可用的取回通道是串口控制台**：`python -u scripts/guest_cmd.py COM7 115200 "cat <file>"`
  （2621 B 一次读完，稳）。本报告所有原始行都是这样取回的。
- 板子**没有被别的会话占用**（本会话唯一），失败是这条 ssh 通道本身的脾气，不是抢板。

### 3. 原始结果行（逐字，只删掉每个单元开始前的 `PROG ...` 进度行）

#### 3.1 主测量：大缓冲 64 MiB，N=3，小缓冲 4 KiB

```
CFG size_req=67108864 n=3 small_req=4096 minwork=16777216
ALLOC which=big want=67108864 got=67108864
ALLOC which=small want=4096 got=4096
BW width=8 mode=read MBs=14.4 size=67108864 n=3
BW width=8 mode=write MBs=33.5 size=67108864 n=3
BW width=8 mode=rmw MBs=5.2 size=67108864 n=3
BW width=16 mode=read MBs=24.9 size=67108864 n=3
BW width=16 mode=write MBs=46.6 size=67108864 n=3
BW width=16 mode=rmw MBs=7.6 size=67108864 n=3
BW width=32 mode=read MBs=38.4 size=67108864 n=3
BW width=32 mode=write MBs=47.2 size=67108864 n=3
BW width=32 mode=rmw MBs=22.8 size=67108864 n=3
BW width=8 mode=read MBs=17.9 size=4096 n=3
BW width=8 mode=write MBs=60.8 size=4096 n=3
BW width=8 mode=rmw MBs=5.7 size=4096 n=3
BW width=16 mode=read MBs=35.8 size=4096 n=3
BW width=16 mode=write MBs=120.8 size=4096 n=3
BW width=16 mode=rmw MBs=8.7 size=4096 n=3
BW width=32 mode=read MBs=71.4 size=4096 n=3
BW width=32 mode=write MBs=237.9 size=4096 n=3
BW width=32 mode=rmw MBs=33.3 size=4096 n=3
SCALING mode=read r8=14.4 r16=24.9 r32=38.4 r32_over_r8=2.68 r16_over_r8=1.73
SCALING mode=write r8=33.5 r16=46.6 r32=47.2 r32_over_r8=1.41 r16_over_r8=1.39
SCALING mode=rmw r8=5.2 r16=7.6 r32=22.8 r32_over_r8=4.36 r16_over_r8=1.45
CACHECTRL width=8 mode=read big=14.4 small=17.9 ratio=1.25 ok=0
CACHECTRL width=8 mode=write big=33.5 small=60.8 ratio=1.82 ok=1
CACHECTRL width=8 mode=rmw big=5.2 small=5.7 ratio=1.09 ok=0
CACHECTRL width=16 mode=read big=24.9 small=35.8 ratio=1.44 ok=0
CACHECTRL width=16 mode=write big=46.6 small=120.8 ratio=2.59 ok=1
CACHECTRL width=16 mode=rmw big=7.6 small=8.7 ratio=1.15 ok=0
CACHECTRL width=32 mode=read big=38.4 small=71.4 ratio=1.86 ok=1
CACHECTRL width=32 mode=write big=47.2 small=237.9 ratio=5.04 ok=1
CACHECTRL width=32 mode=rmw big=22.8 small=33.3 ratio=1.46 ok=0
CACHECTRL_RESULT ok=0 threshold=1.50 scope=width32
VERDICT cache_ok=0 scaling_modes=2 all_flat=0 ref_mbs=47.2 need_10fps=305.0 need_15fps=458.0 meets305=0 meets458=0
SINK v=0
RESULT: INSN_BOUND_DDR_CEILING_UNKNOWN
```

#### 3.2 主测量：大缓冲 64 MiB，N=3，小缓冲 32 KiB（任务书建议的那个尺寸）

```
CFG size_req=67108864 n=3 small_req=32768 minwork=16777216
ALLOC which=big want=67108864 got=67108864
ALLOC which=small want=32768 got=32768
BW width=8 mode=read MBs=14.4 size=67108864 n=3
BW width=8 mode=write MBs=33.5 size=67108864 n=3
BW width=8 mode=rmw MBs=5.2 size=67108864 n=3
BW width=16 mode=read MBs=24.9 size=67108864 n=3
BW width=16 mode=write MBs=46.6 size=67108864 n=3
BW width=16 mode=rmw MBs=7.6 size=67108864 n=3
BW width=32 mode=read MBs=38.4 size=67108864 n=3
BW width=32 mode=write MBs=47.2 size=67108864 n=3
BW width=32 mode=rmw MBs=22.8 size=67108864 n=3
BW width=8 mode=read MBs=14.4 size=32768 n=3
BW width=8 mode=write MBs=33.6 size=32768 n=3
BW width=8 mode=rmw MBs=5.5 size=32768 n=3
BW width=16 mode=read MBs=24.9 size=32768 n=3
BW width=16 mode=write MBs=46.8 size=32768 n=3
BW width=16 mode=rmw MBs=8.2 size=32768 n=3
BW width=32 mode=read MBs=38.6 size=32768 n=3
BW width=32 mode=write MBs=47.1 size=32768 n=3
BW width=32 mode=rmw MBs=26.6 size=32768 n=3
SCALING mode=read r8=14.4 r16=24.9 r32=38.4 r32_over_r8=2.67 r16_over_r8=1.73
SCALING mode=write r8=33.5 r16=46.6 r32=47.2 r32_over_r8=1.41 r16_over_r8=1.39
SCALING mode=rmw r8=5.2 r16=7.6 r32=22.8 r32_over_r8=4.36 r16_over_r8=1.45
CACHECTRL width=8 mode=read big=14.4 small=14.4 ratio=1.00 ok=0
CACHECTRL width=8 mode=write big=33.5 small=33.6 ratio=1.00 ok=0
CACHECTRL width=8 mode=rmw big=5.2 small=5.5 ratio=1.05 ok=0
CACHECTRL width=16 mode=read big=24.9 small=24.9 ratio=1.00 ok=0
CACHECTRL width=16 mode=write big=46.6 small=46.8 ratio=1.00 ok=0
CACHECTRL width=16 mode=rmw big=7.6 small=8.2 ratio=1.08 ok=0
CACHECTRL width=32 mode=read big=38.4 small=38.6 ratio=1.00 ok=0
CACHECTRL width=32 mode=write big=47.2 small=47.1 ratio=1.00 ok=0
CACHECTRL width=32 mode=rmw big=22.8 small=26.6 ratio=1.17 ok=0
CACHECTRL_RESULT ok=0 threshold=1.50 scope=width32
VERDICT cache_ok=0 scaling_modes=2 all_flat=0 ref_mbs=47.2 need_10fps=305.0 need_15fps=458.0 meets305=0 meets458=0
SINK v=0
RESULT: INSN_BOUND_DDR_CEILING_UNKNOWN
```

#### 3.3 缓存尺寸阶梯（大缓冲 4 MiB，N=1）—— 为回答"32 KiB 负对照为什么不成立"

只列 `CACHECTRL` 的 32 位那一行（其余行见 §4 的 4 KiB / 8 KiB 全表）：

```
small=4096  : CACHECTRL width=32 mode=read  ratio=2.85 ok=1 | write ratio=4.96 ok=1 | rmw ratio=1.46 ok=0
small=8192  : CACHECTRL width=32 mode=read  ratio=1.78 ok=1 | write ratio=4.59 ok=1 | rmw ratio=1.41 ok=0
small=16384 : CACHECTRL width=32 mode=read  ratio=1.01 ok=0 | write ratio=1.00 ok=0 | rmw ratio=1.16 ok=0
small=32768 : CACHECTRL width=32 mode=read  ratio=1.00 ok=0 | write ratio=1.00 ok=0 | rmw ratio=1.17 ok=0
small=65536 : CACHECTRL width=32 mode=read  ratio=1.01 ok=0 | write ratio=0.99 ok=0 | rmw ratio=1.16 ok=0
```

（缓存阶梯 4 KiB 那一轮的大缓冲 u32 read 曾跑到 25.1 MB/s，是**唯一**的离群点；其余 6 轮 + 两次 N=3 主测量
全部落在 38.2~38.6 MB/s。N=1 的离群点在 N=3 主测量里没有复现。）

### 4. 缓存负对照：结论与**交叉验证**

**结论：任务书建议的 32 KiB 小缓冲在本板上不是"装得进 cache 的"缓冲 —— 它比 L1D 还大，
所以负对照在 32 KiB 上必然不成立；换成真正装得进 cache 的 4 KiB，负对照就成立了。**

- 交叉验证（仓内源码，先验、独立于本测量）：`scripts/gen_core.sh` 生成核时用的是
  `--with-lsu-l1 --lsu-l1-sets 64 --lsu-l1-ways 2 --with-lsu-bypass --lsu-l1-mem-data-width-min 64`
  ⇒ L1D = 64 sets × 2 ways × 64 B/line = **8192 B = 8 KiB**。
- 实测阶梯与 8 KiB 完全吻合：**4 KiB 装得进（明显变快）、8 KiB 勉强、16 KiB 及以上全部无差别**。

| 小缓冲 | u32 read 比 | u32 write 比 | u32 rmw 比 | 判定 |
|---|---|---|---|---|
| 4 KiB | **1.86** | **5.04** | 1.46 | read/write **成立**；rmw 不成立 |
| 8 KiB | 1.78 | 4.59 | 1.41 | read/write 成立；rmw 不成立 |
| 16 KiB | 1.01 | 1.00 | 1.16 | 全部不成立（超出 8 KiB L1D） |
| 32 KiB | 1.00 | 1.00 | 1.17 | 全部不成立（同左） |
| 64 KiB | 1.01 | 0.99 | 1.16 | 全部不成立（同左） |

**因此**：

- 大缓冲的 **read / write** 两个数**不是**在 cache 里跑出来的 —— 它们确实走的是"L1 未命中 → DDR 通路"，
  **读数有效**（这是负对照要证明的那件事）。
- **rmw** 那一档的负对照比只有 1.46（< 1.50 门限）⇒ 按预登记判据 **rmw 的绝对值没有被认证**，
  下面**不引用** rmw 的绝对数（只引用它的**比值**做位宽扫描，因为位宽扫描只需要三个位宽之间可比）。
- 按程序自己的 P1 判据，"无效"要求"负对照不成立 **且** 位宽扫描毫无放大证据"。本测**有**放大证据
  （read ×2.67、rmw ×4.36），所以 P1 未触发 ⇒ 不是 `测法无效`，而是落到 P3 `指令受限`。

### 5. CPU 受限 vs 内存受限：判定的数字

#### 5.1 按预登记规则（位宽扫描）

| mode | r8 | r16 | r32 | r32/r8 | r16/r8 |
|---|---|---|---|---|---|
| read | 14.4 | 24.9 | 38.4 | **2.67** | 1.73 |
| write | 33.5 | 46.6 | 47.2 | **1.41** | 1.39 |
| rmw | 5.2 | 7.6 | 22.8 | **4.36** | 1.45 |

- 预登记判据：**平坦 = 三个 mode 全部 ≤ 1.40**。read 2.67、rmw 4.36 远超 ⇒ **`all_flat = 0`**。
  （write 1.41 是贴线，但即使把门限放宽到 1.45，read/rmw 仍让它不成立 ⇒ 结论不靠这条贴线值。）
- **纯指令受限**应当看到每一步都 ≈ ×2（每条访存指令搬的字节翻倍）；
  **纯字节带宽受限**应当看到 ≈ ×1（比值全 1）。实测 read ×2.67、write ×1.41、rmw ×4.36 —— **两头都不像，是混的**。
- 把同样的数据换成"**每秒访问次数**"看（这是判别指令受限最直接的量）：

| mode | 12→8 位 | 16 位 | 32 位 | 8→32 倍的"访问次数"变化 | 读数含义 |
|---|---|---|---|---|---|
| read | 14.4 M ops/s | 12.5 M | 9.6 M | 跌 1.50× | 指令受限应为 1.0×，纯字节受限应为 4.0× ⇒ **各占一半** |
| write | 33.5 M ops/s | 23.3 M | 11.8 M | 跌 2.84× | 接近 4.0×（字节受限）⇒ **偏内存受限** |
| rmw | 5.2 M ops/s | 3.8 M | 5.7 M | 基本平（0.91×） | **每元素成本恒定 ⇒ 偏指令受限** |

- 再看"**每字节的周期数**"（按 cpu_clk = 100 MHz 折算）：

| mode | 8 位 | 16 位 | 32 位 | 读法 |
|---|---|---|---|---|
| write | 2.99 cyc/B | 2.15 | 2.12 | **近似恒定 ⇒ 字节速率上限 ~0.47 B/cycle ≈ 47 MB/s**（16→32 位只 +1.5% ⇒ 已饱和） |
| read | 6.94 cyc/B | 4.02 | 2.61 | 不恒定；拟合 `cyc/访问 ≈ 5.6 + 位宽/0.83` ⇒ **5.6 周期/次的固定开价 + ~83 MB/s 的字节速率** |

**判定的诚实写法**：这次位宽扫描**没有**给出"随位宽放大"的干净签名（read 是混合的、write 是饱和的、
rmw 才是接近纯指令的），也**没有**给出"跨位宽平坦"的干净签名。因此：

- **预登记判据下的大缓冲数不能当作 DDR 带宽**（平坦是引用它的前提，前提不成立）⇒ 判决走 P3 `指令受限`。
- 但要讲清楚：**它也不是"CPU 发指令发不过来"**——write 的每字节周期数恒定、u32 只跑到 CPU 发射上界的
  1/4~1/3，这两条都说明**写方向是字节速率（存储侧）在限速**，而 read 的残余放大来自每次访问的固定开价
  （load-use 停顿一类，属 CPU 侧）。**是"混杂"，不是任何单一受限。**

#### 5.2 与 305 MB/s（10fps）/ 458 MB/s（15fps）的比较

- 本次 CPU 驱动路径的最优数：u32 write **47.2 MB/s**、u32 read **38.4 MB/s**。
- 47.2 MB/s ÷ 305 MB/s = **15.5%**；47.2 ÷ 458 = **10.3%**。
- 换算成帧率：30.5 MB/帧 ÷ 47.2 MB/s = **0.646 s/帧 ⇒ 1.55 fps**（连 10 fps 档都远远不到）。
- ⚠️ **但这个数不能直接拿去否决 DDR**：它测的是 **CPU 驱动**这条路径，而任务是"CPU 驱不动 DDR"这个陷阱
  的原型场景。按预登记规则，本次**没有**拿到可以引用 DDR 的签名 ⇒ 只能给上界性质的一句话：
  **"CPU 驱动路径最多 47.2 MB/s"**，而不是 **"DDR 最多 47.2 MB/s"**。

### 6. 判定

`## 判定`

RESULT: 指令受限，本次测不出 DDR 上限（须升级到 A3 的 AXI 主口微基准）

对应程序输出：`RESULT: INSN_BOUND_DDR_CEILING_UNKNOWN`（两个主测量run与 5 个阶梯 run 全部一致）。

一次讲清四件事：

1. **缓存负对照**：任务书建议的 **32 KiB 不成立**（比数 ×1.00）——原因是本板 **L1D 只有 8 KiB**
   （`scripts/gen_core.sh` 的 `--lsu-l1-sets 64 --lsu-l1-ways 2`，实测阶梯独立吻合）。
   换成装得进 cache 的 **4 KiB 就成立**（u32 write ×5.04、u32 read ×1.86）⇒
   大缓冲的 **read/write** 确实是"L1 未命中 → DDR 通路"的数，**读数有效**；**rmw 未被认证**（×1.46 < 1.50）。
2. **位宽扫描**：read ×2.67、write ×1.41、rmw ×4.36 ⇒ **不满足"平坦"**（预登记门限：三者全 ≤1.40）。
   同时它**也不满足"等比放大"**（纯指令受限应 ≈×4、每一步 ≈×2；write 的 16→32 位只 +1.5% 是饱和）。
   ⇒ 是**混杂**：写方向偏字节速率受限（~47 MB/s），读方向"固定开价 + 字节速率"各占一半，rmw 才偏每元素成本。
3. **因此不能引用绝对数作为 DDR 带宽**。本次能说的上限是 **"CPU 驱动路径 ≤ 47.2 MB/s"**
   （u32 write）——相对 305 MB/s 只有 15.5%，相对 458 MB/s 只有 10.3%，折合 1.55 fps。
   但**"CPU 驱不动"与"DDR 慢"这两件事本次没有分开**，所以**不据此否决**逐层-DDR 架构。
4. **必须升级到 A3**：用 fabric **AXI 主口**（流式、多 outstanding）去发，绕开 CPU 的指令速率与
   L1 未命中的固定开价。这条由本板桥的结构决定：`DDR3Bridge` **单 outstanding**、每笔 DDR 事务
   **只发 1 个 256 bit beat**、每 beat 过一次**四相 CDC 握手**（`GRP_BYTES = 32`、`io.ddrAwLen := 0`）,
   ⇒ **CPU 驱动的"一次访问一次事务"访问形态与流式主口差别很大**，A2 测到的东西对 A3 只有参考意义。

### 7. 存疑（务必与结论一起读）

1. **"指令受限"是预登记判据的输出，不是"CPU 发射能力"的证明**。数据里**同时**有内存（写饱和）与
   CPU（rmw 每元素成本恒定、读的固定开价）两种签名。取 P3 是因为**"平坦"这个引用 DDR 数前提不成立**；
   若只按"u32 写方向已饱和"读，也可以说**写方向是内存受限**。两种读法都把结论指向同一个动作：**做 A3**。
2. **rmw 的绝对数未被认证**（负对照比 1.46 < 1.50），报告中不使用 `22.8 MB/s` 这个绝对值；
   它出现是作为位宽扫描的比值证据。
3. **只跑了 100 MHz 的 cpu_clk 口径**。板级 `cpu_clk = 100.000 MHz`（`constraints/yeshen_mini.fdc:113`），
   `core_clk = 125 MHz`（A1 报告 §1.2）。本程序在 Linux 用户态，跑的是 cpu_clk 域；
   "cyc/B" 换算依赖"cpu_clk = 100 MHz 且无 DVFS"这一条。
4. **4 MiB 那一轮 u32 read 的 25.1 MB/s 离群点**未解释（N=1；同批另外 4 轮与两次 N=3 全在 38.2~38.6）。
   主数取 N=3 的 38.4 MB/s。
5. **"2× 流量"只对 rmw 成立**：rmw 的 MB/s 按足迹（size×reps）算，其真实 DDR 流量是它的 2×。
   read/write 的数是纯单向足迹。
6. **板子空闲性**：本会话唯一占板，测量期间无其他负载；取回数据走的是串口控制台（不是 ssh），
   最后一次 ssh 尝试早于主测量启动。
7. **测量程序本身的一次 bug 已修**：`alloc_buf` 最初把地板写成 1 MiB，导致 32 KiB 小缓冲直接
   `FATAL` 秒退、整个测量一行没跑（只留下 3 行 ALLOC 头）。修复为 4 KiB 地板后重跑，即本报告数据。
8. **传输通道的坑**：板子 ssh **输出方向 >~1 KB 就卡死**（远端命令其实已执行），
   所以 `cat` 结果文件必须走串口控制台；`scripts/guest_cmd.py` 需要控制台处于已登录 shell。
   这条已写进 §2，后续任务别再踩。
