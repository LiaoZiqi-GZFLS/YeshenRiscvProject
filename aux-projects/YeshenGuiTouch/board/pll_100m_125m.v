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
// Filename:pll_100m_125m.v
//////////////////////////////////////////////////////////////////////////////
// ============================================================================
// 板级 PLL（27MHz → clkout0 = 100.000MHz（cpu_clk，精确）/ clkout1 = 126.5625MHz（备用，不接））
//
// 骨架 = `NaxYeshenSoC/board/pll_80m.v`（= 同名 `YeshenCore/verilog_soc/pll_80m.v` 的
// V0b 版），**只改分频参数**。IP 名（`pll` 之外的一层 wrapper 名）与端口名
// （`clkout0/clkout1/clkin1/lock`）逐字取自 PDS 2025.2 的 PLL IP 模板：
//   /c/Pango/PDS_2025.2-ads/ip/module_ip/ipm2l_flex_pll/ipm2l_flex_pll_eval/ipm2l_pll/
//       ipm2l_pll_wrapper_v1_2.v.xml   →  `output wire clkout0/clkout1/... , input wire clkin1,
//                                         output wire lock`（模板里 <iname/> = 模块名）
// 底层原语 `GTP_GPLL` 的端口名同样逐字照抄 pll_80m.v（已在本板跑通过的写法）。
//
// ---------------------------------------------------------------------------
// 【频率账】（IP 内部：VCO = CLKIN_FREQ / STATIC_RATIOI × STATIC_RATIOM × STATIC_RATIOF；
//   CLKOUTn = VCO / STATIC_RATIOn；STATIC_DUTYn = int(RATIO_n) 给 50% 占空比）
//   VCO = 27 / 1 × 2 × 18.75 = 1012.5 MHz
//     clkout0 = 1012.5 / 10.125 = **100.000 MHz（精确）**  ← cpu_clk（fdc: -period 10.000）
//     clkout1 = 1012.5 /  8     =  126.5625 MHz          ← 见下"125MHz 出不来"说明；**板上不接**
//     （fdc 里 cpu_clk 就是 clkout0；clkout1 没有 create_clock —— 它不被任何逻辑使用）
//
// 【★ 为什么 clkout1 不是 125MHz，以及为什么不能同时精确出 100MHz 与 125MHz】
//   本 IP 的分频器**只能落在 1/8 网格**上，且**各输出分频器的能力不同**（依据 = PDS 2025.2
//   的 PLL IP 生成算法与 wrapper 模板，都是本机实测读出来的）：
//     · `ipm2l_pll_wrapper_v1_2.v.xml`：`STATIC_RATIO0` / `STATIC_RATIOF` 是 `localparam real`，
//       而 `STATIC_RATIO1..6` 是 `localparam integer`（模板里 `<value param='STATIC_RATIO1'
//       type='int' min="1" max="128">`）⇒ **只有 clkout0 与反馈分频器能带小数**，clkout1..6
//       **必须是整数**分频。
//     · `createDivideParam.tcl`（同目录）：ODIV 与反馈分频值一律先 `int` 再取
//       `eighth_floor/eighth_ceil = floor/ceil(frac×8)`，按 1/8 仲裁 ⇒ **小数部分只能取 k/8**
//       （官方 4_10 的 `ipcore/pll/pll.v` 用的正是 19.25=19+2/8、114.75=114+6/8 这种值）。
//   ⇒ 设 RATIOF = n/8、RATIO0 = m/8（n,m 为整数）、RATIO1 为整数。要 clkout0 = 100MHz 与
//     clkout1 = 125MHz 同时成立，需要
//         VCO = 12.5·m（= 100·RATIO0）与 VCO = 125·RATIO1（RATIO1 整数）
//         ⇒ VCO ∈ {625, 750, 875, 1000, 1125}（[600,1200] 内 125 的整数倍），逐个验回推
//         VCO = 54·n/8 = 6.75n（RATIOI=1/RATIOM=2）⇒ n = VCO/6.75 必须为整数：
//            625→92.59 ✗  750→111.1 ✗  875→129.6 ✗  1000→148.1 ✗  1125→166.7 ✗
//         （一般地 6.75n = 500k ⇒ 27·n = 2000k ⇒ 27 | k ⇒ VCO 至少 13500MHz，超出该 IP 的
//          GPLL VCO 允许区间 600~1200MHz（`ui.tcl:pllCheck_adv`）。换 RATIOM 也一样解不出。）
//   ⇒ **算术上不可兼得**。本工程取"**主时钟精确、备用输出近似**"：
//       · cpu_clk **精确 100.000MHz**（它进 DTS 的 `timebase-frequency`、OpenSBI 的 16550
//         `clock-frequency`、fdc 的 10.000ns 周期 —— 三处都要求 100MHz，故它优先）；
//       · clkout1 = 126.5625MHz（最近的整数分频；**本版不接任何负载**——DDR 侧真正的 125MHz
//         是 `u_ddr3.core_clk`，由板上那颗 125MHz 差分晶振经 ref_clk 派生 ⇒ **板上唯一在用的
//         125MHz 是精确的**。理由见 board/nax_mini_board_top.v 文件头【1】）。
//   ⚠ 备选（若要 125MHz 那一路精确）：RATIOI=3/RATIOM=2/RATIOF=62.5/RATIO0=11.25/RATIO1=9
//     可**同时**精确出 100 与 125MHz，但 PFD = 27/3 = **9MHz**，低于该 IP 的 GPLL 允许下限
//     10MHz（`ui.tcl:pllCheck_adv` 的 `fpfd_min`）⇒ 有"锁不住"的风险，故不采用。
//   所有参数都落在该 IP 的允许窗口内：PFD = 27MHz、VCO = 1012.5MHz ∈ [600,1200]。
//   ⚠ 既有 `pll_80m.v` 用的 VCO=1350MHz（27×2×25）其实**越出** 600~1200 这条窗口，且那组参数
//     **只能**给 100MHz（1350/125 = 10.8，RATIO1 只能取整数 ⇒ 出不了 125MHz）。
//
// ---------------------------------------------------------------------------
// 【N2 追加（2026-10-11，Y1「NPU 独立时钟域」Task N2）】本文件**没有**被参数化去出 npu_clk
//   N2 的首选（spec §4.2）= "把未接线的 clkout1 重参数化为 npu_clk = 50.000MHz"。**算术上不可行**
//   （与上面 §"为什么 clkout1 不是 125MHz" 同一条账，换个数而已），故 N2 未改本文件：
//     · 约束 ①：cpu_clk 必须**仍精确 100.000MHz**（DTS `timebase-frequency` / OpenSBI 16550
//       `clock-frequency` / fdc 的 10.000ns 三处都依赖）⇒ RATIO0 = VCO/100 必需落在 1/8 网格上
//       ⇒ **VCO 是 12.5 的整数倍**；
//     · 约束 ②：clkout1 = 50.000MHz 且 **RATIO1 只能是整数**（见上面 ·1）⇒ **VCO 是 50 的整数倍**；
//     · ①② ⇒ VCO = 50·k 且 50·k = 27·RATIOM·n/(8·RATIOI) ⇒ 400·RATIOI·k = 27·RATIOM·n
//       ⇒（gcd(27,400)=1）27 | RATIOI·k；PFD = 27/RATIOI ≥ 10MHz ⇒ RATIOI ≤ 2 ⇒ **27 | k**
//       ⇒ VCO ≥ 50·27 = **1350MHz > 本 IP 的 VCO 窗口上限 1200MHz**（`ui.tcl:pllCheck_adv`）。
//     · 穷举核实（RATIOI 1..80 × RATIOM 1..128 × RATIOF = n/8 ∈ [1,128] × VCO∈[600,1200] ×
//       PFD∈[10,500]）：**0 组**解。最近的可达值 = RATIO1=20 ⇒ **50.625MHz**（+1.25%）；另一侧
//       RATIO1=21 ⇒ 48.214MHz。换 RATIOM/RATIOI 也一样解不出（上面 6.75n = 500k 那条同构）。
//     · 注：即使**另加一颗** GTP_GPLL 专出 50MHz，从这颗 27MHz 参考也做不出**精确** 50.000（同一条
//       27|k 的账）；只有让 50MHz 那路走 **clkout0 的小数分频器**才精确（例：VCO=675、
//       RATIOI=1/RATIOM=1/RATIOF=25、RATIO0=13.5 ⇒ 50.000MHz，PFD=27MHz）—— 那是"新增一路 PLL
//       输出"，不在 N2 任务书的三条路里，故未取。
//   ⇒ N2 走**文档化的回退**：`npu_clk = cpu_clk ÷ 2`（= 50.000MHz 精确），由板级分频器 + BUFG 生成，
//     在 `constraints/yeshen_mini.fdc` 里以 `create_generated_clock … -divide_by 2` 声明。
//     代价（诚实标注）：**NPU 频率耦合在 CPU 上（恒 CPU/2）**，不是真独立域。
//   ⇒ **本文件因此只有本段注释改动**：clkout1 仍 = 126.5625MHz、仍**不接任何逻辑**（fdc 不为它建钟）。
// ---------------------------------------------------------------------------
`timescale 1ns/10fs

module pll_100m_125m (

    output wire clkout0,

    output wire clkout1,

    input wire clkin1,

    output wire lock
    );

    // Parameter

    localparam real    CLKIN_FREQ       = 27.0; //@IPC float 10.0,500.0

    localparam         LOCK_MODE        = 0; //@IPC enum 0,1

    localparam integer STATIC_RATIOI    = 1; //@IPC int 1,80

    localparam integer STATIC_RATIOM    = 2; //@IPC int 1,128

    localparam real    STATIC_RATIO0    = 10.125; //@IPC int 1.0000,128.0000 // VCO 1012.5 / 10.125 = 100.000000MHz（cpu_clk，精确）

    localparam integer STATIC_RATIO1    = 8; //@IPC int 1,128 // VCO 1012.5 / 8 = 126.5625MHz（备用输出，本版不接）

    localparam integer STATIC_RATIO2    = 42; //@IPC int 1,128 // 未用（照 pll_80m 原值）

    localparam integer STATIC_RATIO3    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO4    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO5    = 21; //@IPC int 1,128

    localparam integer STATIC_RATIO6    = 21; //@IPC int 1,128

    localparam real    STATIC_RATIOF    = 18.75; //@IPC int 1.0000,128.0000 // VCO = 27/1×2×18.75 = 1012.5MHz（= 18 + 6/8）

    localparam integer STATIC_RATIOPHY  = 1; //@IPC int 1,128

    localparam integer STATIC_DUTY0     = 10; //@IPC int 2,255  (= int(RATIO0) ⇒ 50% 占空比)

    localparam integer STATIC_DUTY1     = 8; //@IPC int 2,255

    localparam integer STATIC_DUTY2     = 42; //@IPC int 2,255

    localparam integer STATIC_DUTY3     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY4     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY5     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTY6     = 21; //@IPC int 2,255

    localparam integer STATIC_DUTYF     = 18; //@IPC int 2,255

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

    .CLKOUT1        (clkout1        ),

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
