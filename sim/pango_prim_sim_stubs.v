// ============================================================================
// pango_prim_sim_stubs.v —— 紫光同创（Pango）原语的 **仿真替身**（只在 Verilator 里用）
//
// 为什么需要：`board/liteeth_wrap.v` 里为了 RGMII 用了厂家 `rgmii_interface.v`
// （`third_party/eth_stack_2_11/source/`），它内部例化了 6 个 Pango 原语
// （`GTP_ODDR_E1` / `GTP_IDDR_E1` / `GTP_IODELAY_E2` / `GTP_INBUF` / `GTP_OUTBUF` / `GTP_CLKBUFG`）。
// 这些原语 PDS 认，**Verilator 不认** ⇒ 不提供替身的话，跑了 eth 之后 `nax_mini_soc` 连
// 仿真门都进不去（`Cannot find file containing module 'GTP_...'`）。
//
// 替身是**纯组合直通**、不建模任何时序：板上那层 RGMII 的 IDELAY/DDR 行为**不在仿真判据里**
// （判据是"内核起不起得来"，RGMII 侧在 tb 里是恒空闲的常量输入）。
// ⚠️ 本文件**绝不能**加进 PDS 的 add_design 清单：那会和真实原语**重名冲突**。
// ============================================================================

module GTP_ODDR_E1 #(
    parameter GRS_EN    = "TRUE",
    parameter ODDR_MODE = "SAME_EDGE",
    parameter RS_TYPE   = "ASYNC_RESET"
) (
    output Q,
    input  CE,
    input  CLK,
    input  D0,
    input  D1,
    input  RS
);
    // 简化：取上升沿那一路（仿真里 RGMII 恒空闲，取值不影响判据）
    assign Q = D0;
endmodule

module GTP_IDDR_E1 #(
    parameter GRS_EN    = "TRUE",
    parameter IDDR_MODE = "SAME_PIPELINED",
    parameter RS_TYPE   = "SYNC_RESET"
) (
    output Q0,
    output Q1,
    input  CE,
    input  CLK,
    input  D,
    input  RS
);
    assign Q0 = D;
    assign Q1 = D;
endmodule

module GTP_IODELAY_E2 #(
    parameter DELAY_STEP_SEL   = "PARAMETER",
    parameter DELAY_STEP_VALUE = 0,
    parameter TDELAY_EN        = "FALSE"
) (
    input        DI,
    input        DELAY_SEL,
    input  [7:0] DELAY_STEP,
    output       DO,
    input        EN_N
);
    assign DO = DI;
endmodule

module GTP_INBUF #(
    parameter IOSTANDARD = "DEFAULT",
    parameter TERM_DDR   = "OFF"
) (
    output O,
    input  I
);
    assign O = I;
endmodule

module GTP_OUTBUF #(
    parameter IOSTANDARD    = "DEFAULT",
    parameter SLEW_RATE     = "SLOW",
    parameter DRIVE_STRENGTH = "4"
) (
    input  I,
    output O
);
    assign O = I;
endmodule

module GTP_CLKBUFG (
    input  CLKIN,
    output CLKOUT
);
    assign CLKOUT = CLKIN;
endmodule

// 无毛刺时钟 mux：语义对齐厂家 bsim 的 V_CLKBUFGMUX（TRIGGER_MODE="NEGEDGE"，
// LOGOS2 的 SWITCH=1）。每个输入钟在自己的**下降沿**把 SEL 打一拍；两拍一致才换源，
// 否则输出钳低。因此换源只可能发生在"被换上的那个钟正处于低电平"的时刻 ⇒ 不出窄脉冲。
module GTP_CLKBUFGMUX #(
    parameter TRIGGER_MODE = "NEGEDGE",
    parameter SIM_DEVICE   = "TITAN"
)(
    output CLKOUT,
    input  CLKIN0,
    input  CLKIN1,
    input  SEL
);
    // 逐行照厂家 bsim V_CLKBUFGMUX 的 SWITCH=1 路径（两段同步 + 双向确认）：
    //   第一段永远跟"当前被选中的那个钟"的下降沿走，第二段跟"目标钟"的下降沿走，
    //   两级一致才换源。因此**离开**旧钟发生在旧钟的下降沿（不截短高电平），
    //   **接入**新钟发生在新钟的下降沿（第一拍就是完整高电平）。
    reg n1 = 1'b0, n1d = 1'b0, n2 = 1'b0, n2d = 1'b0;
    always @(negedge CLKIN0) if (SEL)  begin n1 <= SEL; n1d <= n1; end
    always @(negedge CLKIN1) if (SEL)  begin n2 <= n1d; n2d <= n2; end
    always @(negedge CLKIN1) if (!SEL) begin n1 <= SEL; n1d <= n1; end
    always @(negedge CLKIN0) if (!SEL) begin n2 <= n1d; n2d <= n2; end

    reg o;
    always @(*) begin
        if (!n1d && !n2d)   o = CLKIN0;
        else if (n1d && n2d) o = CLKIN1;
        else                 o = 1'b0;
    end
    assign CLKOUT = o;
endmodule
