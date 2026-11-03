//////////////////////////////////////////////////////////////////////////////
//
// Copyright (c) 2019 PANGO MICROSYSTEMS, INC
// ALL RIGHTS REVERVED.
//
// THE SOURCE CODE CONTAINED HEREIN IS PROPRIETARY TO PANGO MICROSYSTEMS, INC.
// IT SHALL NOT BE REPRODUCED OR DISCLOSED IN WHOLE OR IN PART OR USED BY
// PARTIES WITHOUT WRITTEN AUTHORIZATION FROM THE OWNER.
//
//////////////////////////////////////////////////////////////////////////////
//
// Library:
// Filename:pll_gpu.v
//////////////////////////////////////////////////////////////////////////////
// ============================================================================
// ⛔ 2026-11-01 现状：**本文件暂不参与构建**（已从两份 PDS 源列表注释掉）。
//   第五颗 GPLL 的版本在 PnR 的 `pre clock plan` 阶段被 PDS 内部错误挡下：
//     E: Place-0135: clock planning: complete solution has invalids when solving clock target
//   （strategy 1/3 × 4 种子全一样；显式 BUFG / 自动插 BUFG 都一样；GPU 面积降 33k FF 后仍一样）。
//   当前构建改用 `board/pll_100m_125m.v` 的 **clkout1**（RATIO1=12 ⇒ 84.375MHz）。
//   本文件保留：等 PDS 侧对上 5 颗 GPLL 的场景能过 clock planning 后，这是首选路线（频率更自由）。
//
// 【GPU 独立时钟域（2026-11-01）】板级第五颗 GTP_GPLL：27MHz → clkout0 = **100.000 MHz（精确）**
//
//   动因（用户裁决）：「我希望后面GPU还是要有单独时钟，方便后续优化」。
//     gpu10 PnR 的 soc_clk 头号路径（9.574ns / est 104.4496MHz）就在 `u_soc/u_gpu/u_2d`
//     的 blend 通路上 —— GPU 正在**拖住整个 soc_clk**。搬进独立域后：
//       (a) GPU 与 SoC 主频解耦，后续可以只提 gpu_clk 而不动 SoC；
//       (b) 反过来说，SoC 侧的时钟也可以不再被 GPU 的 blend 路径封顶。
//     本档先取 **100.000 MHz（= soc_clk 同频）**：改时钟域本身要**零行为变化**，
//     提频是独立的下一次 PnR（届时只动下面的 RATIO0/DUTY0）。
//
//   频率账（口径与 pll_50m.v 逐字相同）：
//       PFD  = 27 / 1        = 27 MHz   ∈ [10,450]  ✓
//       VCO  = 27 × 1 × 25   = 675 MHz  ∈ [600,1200] ✓
//       clkout0 = 675 / 6.75 = **100.000000 MHz（精确）** ✓（6.75 = 6 + 6/8，落 1/8 格点）
//       合规：RATIO0=6.75 在 1/8 网格上；duty 6 ≤ 2×6.75−1 = 12.5；100 ≤ fout_max 800。
//   后续提频只改这两行（VCO 仍 675MHz，1/8 格点）：
//       RATIO0 = 6.0  → 112.5 MHz     RATIO0 = 5.625 → 120 MHz
//       RATIO0 = 5.4  → 125 MHz       RATIO0 = 5.0625 → 133.333 MHz
//     ⚠️ 提频前必须先看 GPU 自己的时序余量（本档 PnR 的 `.rtr` 里 `u_gpu` 路径），
//        并按 pll_50m.v 立下的"**板钟 ≤ PnR est**"认证关系取值。
//
//   ⚠️ 本文件是 `board/pll_50m.v` 的**逐字副本**，只改了：模块名、RATIO0/DUTY0、
//      以及本段说明。下面的历史段落（N2b/N5b/T-18c/L2a/2026-10-24 提频）是**那颗 NPU PLL
//      的沿革**，保留在这里作为来源与口径出处，**不描述本实例**。
// ============================================================================
// 板级第二颗 PLL：27MHz → clkout0 = **54.000 MHz（精确）**（L2a 认证档；见下方 L2a/L2a-OC 两段）
//   （T-18c～L2a 前为 56.250 MHz；N2b–t18b 期为 50.000 MHz，历史读数见各段）
//
// ---------------------------------------------------------------------------
// 【N2b（2026-10-11，Y1「NPU 独立时钟域」Task N2b）】本文件是**新增的兄弟 wrapper**
// ---------------------------------------------------------------------------
// 动因：N2（commit 3f5f791）为 `npu_clk` 走的回退是 `cpu_clk ÷ 2`（`create_generated_clock
//   -divide_by 2`）—— 频率精确但**与 CPU 相位耦合**，不是真独立域。用户裁决**弃用该回退**，
//   改为**再加一颗 GTP_GPLL** 独立产生 `npu_clk`。
// 方案出处：`board/pll_100m_125m.v` 文件头【N2 追加】段给出的"另加一颗 GTP_GPLL 专出 50MHz"
//   精确解（当时未取，因为不在 N2 任务书的三条路里）；
//   以及 N2 所写的 `constraints/yeshen_mini.fdc` N2 段里的"备选②"。
//
// 【N5b 追加（2026-10-11）】Task N5b 把 `NpuTop` 整块搬进 `npu_clk`（+ 三座异步桥的 npu 侧 +
//   `NpuResetSync` 的 npu 域）⇒ 本 PLL 的输出**有了真实功能负载**；N2/N2b 时期为防悬空清理
//   （`Public-4060 … dangling`）而挂的"活体"脚手架（`u_soc.npu_clk_alive_r` + 板级诊断那一字节）
//   **已删**。
//
// 【T-18c 追加（2026-10-16，Y1-Timing 轮"过约束→收敛→重发比特流"切片）】
//   动因：t18b 轮已把 `npu_clk` 约束收到 18.400 ns（= 54.3478 MHz 请求）并 `All Constraints Met`
//   （est **56.2683 MHz**、slack +0.628），但本 PLL 仍出 50 MHz ⇒ **板级真钟低于已闭合的约束档**
//   （刷 t18b 比特流得上 50 MHz 板钟）。用户指令"过约束、收敛、重发比特流" = 把板级钟抬到该
//   约束档位并重出比特流（本文件的参数改动 = 其中一件；PnR 重发比特流 = 另一件）。
//   改动：**只动 clkout0 的一处分频比** —— `STATIC_RATIO0` 13.5 → **12.0**（`STATIC_DUTY0` 13 → **12**）；
//   PFD/VCO/其余 clkout 参数**一字未动**（VCO 仍 675 MHz）。
//   频率账：PFD = 27/1 = 27 MHz（∈[10,450]）、VCO = 27×1×25 = **675 MHz**（∈[600,1200]）、
//     clkout0 = 675/12.0 = **56.250000 MHz（精确）**。合法性（逐条过 `ui.tcl:pllCheck_adv`）：
//     RATIO0 = 12.0 = 12 + 0/8（整数格点）、duty = 12 ≤ 2×12−1 = 23、clkout 56.25 ≤ fout_max 800。
//   为什么取 12.0（枚举 VCO=675 的 1/8 格点：12.375→54.5455 / 12.25→55.1020 / 12.125→55.6701 /
//     12.0→**56.25** / 11.875→56.8421 MHz）：**12.0 是"不超过 t18b 实测上限 56.2683 MHz"的最高格点**
//     （56.25 ≤ 56.2683，差 0.033%）⇒ 板级真钟 56.25 MHz 落在 **[约束请求 54.3478, t18b 实测 56.2683]**
//     区间内并贴住上沿；11.875（= 56.8421）越出该实测上限、不在任何已闭合证据的覆盖内（要它须再跑
//     一轮 PnR 取证），故不取。fps 口径（A+B1+DCI = 5,418,000 拍）：旧 50 MHz 板钟 = 9.2285 fps；
//     板钟 56.25 MHz = **10.3821 fps**（建模，非整帧实跑）。
//   对齐纪律：`constraints/yeshen_mini.fdc` 的 `npu_clk` 约束 18.400 ns **一字未改** —— 请求
//     （54.3478）与 t18b 实测（56.2683）都不变；本文件只负责让板级真钟落在两者之间。
//
// 【2026-10-24 提频追加（Y1 NPU 1 FPS 轮）】
//   动因：用户目标 NPU 1 FPS；上一步把 `tInPixW`（`tInHi*tInWi`）在 TILING 路径上寄存一拍后，
//   PnR 在 **16.667 ns（=60 MHz）过约束** 下 **All Constraints Met**（npu est **60.6024 MHz**、
//   period 16.667/16.501、slack **+0.166**；soc +0.760 / cpu +0.249；tag `npu60`）。
//   按本文件 T-18c 建立的认证关系"**板钟 ≤ est**"：est 60.6024 > 60.0 ⇒ 板钟可以取 60 MHz。
//   改动：**只动 clkout0 分频比** —— `STATIC_RATIO0` 12.5 → **11.25**、`STATIC_DUTY0` 12 → **11**；
//   PFD/VCO/其余 clkout 一字未动（VCO 仍 675 MHz）。
//   频率账：clkout0 = 675 / 11.25 = **60.000000 MHz（精确）**；11.25 = 11 + 2/8 落在 1/8 格点上；
//     duty 11 ≤ 2×11−1 = 21（50% 取整数部分，同 13.5→13 的旧口径）。
//   旧 54.000 MHz 档（RATIO0=12.5）保留为历史记录，回退只需把上面两个 localparam 改回 12.5 / 12。
//
// ---------------------------------------------------------------------------
//   公式（IP 内部，见 pll_100m_125m.v 文件头，及本机 `ipm2l_pll/ui.tcl` 的
//     `pllCheck_adv`：`fpfd = clkin/idiv`、`fvco = fpfd*mdiv*fbdiv`）：
//       PFD  = CLKIN_FREQ / STATIC_RATIOI
//       VCO  = PFD × STATIC_RATIOM × STATIC_RATIOF          （INTERNAL_FB = CLKOUTF）
//       CLKOUTn = VCO / STATIC_RATIOn                       （RATIO0/RATIOF 可带小数）
//   本实例取值（2026-10-24 现值 = 60 MHz；L2a 档 RATIO0=12.5 ⇒ 54 MHz；L2a-OC 实验档 RATIO0=12.0 ⇒ 56.25 MHz 已被证伪；更早 RATIO0=13.5 ⇒ 50 MHz）：
//       PFD  = 27 / 1                              = 27 MHz        ∈ [10,450]  ✓
//       VCO  = 27 × 1 × 25                         = 675 MHz       ∈ [600,1200] ✓
//       clkout0 = 675 / 11.25                      = **60.000000 MHz（精确）** ✓
//   · 三处都落在该 IP 的允许窗口内（窗口值逐字取自本机 PDS 的 `ipm2l_pll/ui.tcl`
//     `pllCheck_adv`：GPLL 的 `fpfd_min=10.0 / fpfd_max=450 / fvco_min=600 / fvco_max=1200`）。
//   · 小数分频落在 **1/8 网格**上（与 pll_100m_125m.v 的 10.125 = 10 + 1/8、18.75 = 18 + 6/8 同规）；
//     T-18c 取值 RATIO0 = 12.0（= 12 + 0/8）与 RATIOF = 25.0（= 25 + 0/8）**都取整数值**，
//     无小数误差（旧值 13.5 = 13 + 4/8 亦同规）。
//   · 为什么 RATIOM=1/RATIOF=25 而不是 RATIOM=2/RATIOF=12.5（VCO 同为 675MHz）：两者电气等效，
//     但**整数值的 RATIOF 免去反馈分频器的小数通路**（N2 文件头用的正是 1/25 这组）。
//   · ⚠️ 为什么**不能**复用 pll_100m_125m 的 clkout1 去做 50MHz：见 pll_100m_125m.v 文件头
//     【N2 追加】段的算术证明（单 VCO 下 clkout1 只能整数分频 ⇒ VCO 必须 ≥1350MHz，越出窗口；
//     穷举 0 组解）。⇒ 必须**另起一颗** GPLL（独立 VCO），本文件即是。
//
// 【L2a 追加（2026-10-18，Y1 面积/时序轮）】
//   动因：L_MAX=8→2 + CDC FIFO depth 8 + 写口几何寄存化之后，新 PnR（tag `c4a_l2d8u`）在
//   18.400 ns 约束下 **All Constraints Met**（npu est **54.6747 MHz / 18.290 ns / +0.110**）。
//   按本文件 T-18c 建立的认证关系"**板钟 ≤ est**"：原板钟 56.250 MHz > est 54.6747，
//   会超出已闭合证据 0.51 ns ⇒ 必须把板钟降到 est 以下。
//   改动：**只动 clkout0 分频比** —— `STATIC_RATIO0` 12.0 → **12.5** ⇒ **54.000 MHz（精确）**。
//   L2a-OC 实验（用户假设"收紧过约束可改善 NPU 时序"）：fdc 收到 17.5 ns + 本 PLL 56.25 MHz
//     跑了 2 个 seed，Setup(Slow) = −2.444 / −1.179 ns（线长 1.060M/0.955M），
//     而同网表在 18.4 ns 下 seed0 +0.006（最终 +0.110，线长 0.939M）⇒ **过约束反噬**，
//     故回退 18.4 ns 并采用本档 54 MHz（板钟 ≤ est 54.6747，1.2% 余量）。
//
// 【DUTY 编码】STATIC_DUTYx = int(RATIOx) ⇒ 50% 占空比（口径逐字照 pll_100m_125m.v：
//   RATIO0=10.125→DUTY0=10、RATIOF=18.75→DUTYF=18）。本实例 RATIO0=11.25→DUTY0=11、
//   RATIOF=25.0→DUTYF=25。未用的 clkout1..6/PHY 分频值照抄 pll_100m_125m.v 原值（那些输出本层不接）。
//
// 【端口与例化】骨架 = `board/pll_100m_125m.v`（本板已跑通的写法），只改分频参数 + 去掉 clkout1。
//   端口名 `clkout0 / clkin1 / lock` 与底层 `GTP_GPLL` 的 `CLKOUT0 / CLKIN1 / LOCK` 逐字一致。
// ============================================================================
`timescale 1ns/10fs

module pll_gpu (

    output wire clkout0,

    input wire clkin1,

    output wire lock
    );

    // Parameter

    localparam real    CLKIN_FREQ       = 27.0; //@IPC float 10.0,500.0

    localparam         LOCK_MODE        = 0; //@IPC enum 0,1

    localparam integer STATIC_RATIOI    = 1; //@IPC int 1,80  // PFD = 27/1 = 27MHz

    localparam integer STATIC_RATIOM    = 1; //@IPC int 1,128

    localparam real    STATIC_RATIO0    = 6.75; //@IPC int 1.0000,128.0000 // VCO 675 / 6.75 = 100.000000MHz（精确；本档 = soc_clk 同频，见文件头【GPU】）

    localparam integer STATIC_RATIO1    = 8; //@IPC int 1,128 // 未用（clkout1 本层不接；照 pll_100m_125m 原值）

    localparam integer STATIC_RATIO2    = 42; //@IPC int 1,128 // 未用（照 pll_100m_125m 原值）

    localparam integer STATIC_RATIO3    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO4    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO5    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO6    = 21; //@IPC int 1,128

    localparam real    STATIC_RATIOF    = 25.0; //@IPC int 1.0000,128.0000 // VCO = 27/1×1×25 = 675MHz（= 25 + 0/8）

    localparam integer STATIC_RATIOPHY  = 1; //@IPC int 1,128

    localparam integer STATIC_DUTY0     = 6; //@IPC int 2,255  (= int(RATIO0) ⇒ 50% 占空比；6.75 取整数部分 6)

    localparam integer STATIC_DUTY1     = 8; //@IPC int 2,255

    localparam integer STATIC_DUTY2     = 42; //@IPC int 2,255

    localparam integer STATIC_DUTY3     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY4     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY5     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY6     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTYF     = 25; //@IPC int 2,255  (= int(RATIOF))

    localparam integer STATIC_DUTYPHY   = 2; //@IPC int 2,255

    localparam integer STATIC_PHASE     = 0; //@IPC int 0,63

    localparam integer STATIC_PHASE0    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE1    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE2    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE3    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE4    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE5    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASE6    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASEF    = 0; //@IPC int 0,7

    localparam integer STATIC_PHASEPHY  = 0; //@IPC int 0,7

    localparam integer STATIC_CPHASE0   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE1   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE2   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE3   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE4   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE5   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASE6   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASEF   = 0; //@IPC int 0,127

    localparam integer STATIC_CPHASEPHY = 0; //@IPC int 0,127

    localparam         CLK_DPS0_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS1_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS2_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS3_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS4_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS5_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPS6_EN      = "FALSE"; //@IPC bool

    localparam         CLK_DPSF_EN      = "FALSE"; //@IPC bool

    localparam         CLK_CAS5_EN      = "FALSE"; //@IPC bool

    localparam         CLKOUT0_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT1_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT2_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT3_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT4_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT5_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUT6_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUTF_SYN_EN   = "FALSE"; //@IPC bool

    localparam         CLKOUTPHY_SYN_EN = "FALSE"; //@IPC bool

    localparam         SSC_MODE         = "DISABLE"; //@IPC enum DISABLE, DOWN_LOW, DOWN_HIGH, CENTER_LOW, CENTER_HIGH

    localparam real    SSC_FREQ         = 25; //@IPC int 25,250

    localparam         INTERNAL_FB      = "CLKOUTF"; //@IPC enum CLKOUT0,CLKOUT1,CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5,CLKOUT6,DISABLE

    localparam         EXTERNAL_FB      = "DISABLE"; //@IPC enum CLKOUT0,CLKOUT1,CLKOUT2,CLKOUT3,CLKOUT4,CLKOUT5,CLKOUT6,DISABLE

    localparam         BANDWIDTH        = "OPTIMIZED"; //@IPC enum OPTIMIZED,LOW,HIGH

    wire clkin2;
    assign clkin2 = 1'b0;

    wire clkfb;
    assign clkfb = 1'b0;

    wire clkin_sel;
    assign clkin_sel = 1'b0;

    wire dps_clk;
    wire dps_en;
    wire dps_dir;
    assign dps_clk = 1'b0;
    assign dps_en = 1'b0;
    assign dps_dir = 1'b0;

    wire clkout0_syn;
    assign clkout0_syn = 1'b0;

    wire clkout1_syn;
    assign clkout1_syn = 1'b0;

    wire clkout2_syn;
    assign clkout2_syn = 1'b0;

    wire clkout3_syn;
    assign clkout3_syn = 1'b0;

    wire clkout4_syn;
    assign clkout4_syn = 1'b0;

    wire clkout5_syn;
    assign clkout5_syn = 1'b0;

    wire clkout6_syn;
    assign clkout6_syn = 1'b0;

    wire clkoutf_syn;
    assign clkoutf_syn = 1'b0;

    wire pll_pwd;
    assign pll_pwd = 1'b0;

    wire rst;
    assign rst = 1'b0;

    wire apb_clk;
    wire apb_rst_n;
    wire [4:0] apb_addr;
    wire apb_sel;
    wire apb_en;
    wire apb_write;
    wire [15:0] apb_wdata;

    assign apb_clk = 1'd0;
    assign apb_rst_n = 1'd0;
    assign apb_addr [4:0] = 5'd0;
    assign apb_sel = 1'd0;
    assign apb_en = 1'd0;
    assign apb_write = 1'd0;
    assign apb_wdata [15:0] = 16'd0;

    GTP_GPLL #(

    .CLKIN_FREQ      (CLKIN_FREQ    ),
    .LOCK_MODE       (LOCK_MODE     ),
    .STATIC_RATIOI   (STATIC_RATIOI ),
    .STATIC_RATIOM   (STATIC_RATIOM ),

    .STATIC_RATIO0   (STATIC_RATIO0 ),
    .STATIC_RATIO1   (STATIC_RATIO1 ),
    .STATIC_RATIO2   (STATIC_RATIO2 ),
    .STATIC_RATIO3   (STATIC_RATIO3 ),
    .STATIC_RATIO4   (STATIC_RATIO4 ),

    .STATIC_RATIO5   (STATIC_RATIO5 ),
    .STATIC_RATIO6   (STATIC_RATIO6 ),

    .STATIC_RATIOF   (STATIC_RATIOF ),

    .STATIC_DUTY0    (STATIC_DUTY0  ),
    .STATIC_DUTY1    (STATIC_DUTY1  ),
    .STATIC_DUTY2    (STATIC_DUTY2  ),
    .STATIC_DUTY3    (STATIC_DUTY3  ),
    .STATIC_DUTY4    (STATIC_DUTY4  ),

    .STATIC_DUTY5    (STATIC_DUTY5  ),
    .STATIC_DUTY6    (STATIC_DUTY6  ),

    .STATIC_DUTYF    (STATIC_DUTYF  ),

    .STATIC_PHASE    (STATIC_PHASE  ),

    .STATIC_PHASE0   (STATIC_PHASE0 ),
    .STATIC_PHASE1   (STATIC_PHASE1 ),
    .STATIC_PHASE2   (STATIC_PHASE2 ),
    .STATIC_PHASE3   (STATIC_PHASE3 ),
    .STATIC_PHASE4   (STATIC_PHASE4 ),

    .STATIC_PHASE5   (STATIC_PHASE5 ),
    .STATIC_PHASE6   (STATIC_PHASE6 ),

    .STATIC_PHASEF   (STATIC_PHASEF ),

    .STATIC_CPHASE0  (STATIC_CPHASE0),
    .STATIC_CPHASE1  (STATIC_CPHASE1),
    .STATIC_CPHASE2  (STATIC_CPHASE2),
    .STATIC_CPHASE3  (STATIC_CPHASE3),
    .STATIC_CPHASE4  (STATIC_CPHASE4),

    .STATIC_CPHASE5  (STATIC_CPHASE5),
    .STATIC_CPHASE6  (STATIC_CPHASE6),

    .STATIC_CPHASEF  (STATIC_CPHASEF),

    .CLK_DPS0_EN     (CLK_DPS0_EN   ),
    .CLK_DPS1_EN     (CLK_DPS1_EN   ),
    .CLK_DPS2_EN     (CLK_DPS2_EN   ),
    .CLK_DPS3_EN     (CLK_DPS3_EN   ),
    .CLK_DPS4_EN     (CLK_DPS4_EN   ),
    .CLK_DPS5_EN     (CLK_DPS5_EN   ),
    .CLK_DPS6_EN     (CLK_DPS6_EN   ),
    .CLK_DPSF_EN     (CLK_DPSF_EN   ),
    .CLK_CAS5_EN     (CLK_CAS5_EN   ),

    .CLKOUT0_SYN_EN  (CLKOUT0_SYN_EN),
    .CLKOUT1_SYN_EN  (CLKOUT1_SYN_EN),
    .CLKOUT2_SYN_EN  (CLKOUT2_SYN_EN),
    .CLKOUT3_SYN_EN  (CLKOUT3_SYN_EN),
    .CLKOUT4_SYN_EN  (CLKOUT4_SYN_EN),

    .CLKOUT5_SYN_EN  (CLKOUT5_SYN_EN),
    .CLKOUT6_SYN_EN  (CLKOUT6_SYN_EN),

    .CLKOUTF_SYN_EN  (CLKOUTF_SYN_EN),

    .SSC_MODE       (SSC_MODE       ),
    .SSC_FREQ       (SSC_FREQ       ),

    .INTERNAL_FB    (INTERNAL_FB    ),
    .EXTERNAL_FB    (EXTERNAL_FB    ),
    .BANDWIDTH      (BANDWIDTH      )

    ) u_gpll (

    .CLKOUT0        (clkout0        ),

    .CLKOUT0N       (               ),

    .CLKOUT1        (               ),

    .CLKOUT1N       (               ),

    .CLKOUT2        (               ),

    .CLKOUT2N       (               ),

    .CLKOUT3        (               ),

    .CLKOUT3N       (               ),

    .CLKOUT4        (               ),

    .CLKOUT5        (               ),

    .CLKOUT6        (               ),

    .CLKOUTF        (               ),

    .CLKOUTFN       (               ),

    .LOCK           (lock           ),

    .DPS_DONE       (               ),

    .DPS_CLK        (dps_clk        ),
    .DPS_EN         (dps_en         ),
    .DPS_DIR        (dps_dir        ),

    .CLKIN1         (clkin1         ),

    .CLKIN2         (clkin2         ),

    .CLKFB          (clkfb          ),
    .CLKIN_SEL      (clkin_sel      ),
    .CLKOUT0_SYN    (clkout0_syn    ),
    .CLKOUT1_SYN    (clkout1_syn    ),
    .CLKOUT2_SYN    (clkout2_syn    ),
    .CLKOUT3_SYN    (clkout3_syn    ),
    .CLKOUT4_SYN    (clkout4_syn    ),

    .CLKOUT5_SYN    (clkout5_syn    ),
    .CLKOUT6_SYN    (clkout6_syn    ),

    .CLKOUTF_SYN    (clkoutf_syn    ),
    .PLL_PWD        (pll_pwd        ),
    .RST            (rst            ),

    .APB_RDATA      (               ),
    .APB_READY      (               ),

    .APB_CLK        (apb_clk        ),
    .APB_RST_N      (apb_rst_n      ),
    .APB_ADDR       (apb_addr[4:0]  ),
    .APB_SEL        (apb_sel        ),
    .APB_EN         (apb_en         ),
    .APB_WRITE      (apb_write      ),
    .APB_WDATA      (apb_wdata[15:0])
    );


endmodule
