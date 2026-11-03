// cpu_domain_cdc —— CPU 独立时钟域的复位/时基/中断跨域件。
//
// 复位：soc_rst（= glue_reset | cpu_reset，soc 域高有效）→ cpu 域异步置位/2FF 同步释放。
// 时基：CLINT mtime 是 soc 域的 64bit 二进制计数器（每 soc_clk +1）。这里在 soc 域转 Gray，
//       2FF 进 cpu 域，再 Gray→binary。Gray 每步只变 1 位 ⇒ 采样结果只会是相邻值，单调安全。
// 中断：mtip/msip/meip/seip 是 soc 域电平，各 2FF 进 cpu 域。
// 桥复位：bridge_rst_s 直接回 soc_rst，供桥目的侧 FIFO 与源侧（cpu_rst）一起清，避免半笔事务。
module cpu_domain_cdc (
    input  wire        soc_clk,
    input  wire        soc_rst,

    input  wire        cpu_clk,
    input  wire [63:0] rdtime_soc,
    input  wire        int_m_timer_soc,
    input  wire        int_m_soft_soc,
    input  wire        int_m_ext_soc,
    input  wire        int_s_ext_soc,

    output wire        cpu_rst,
    output reg  [63:0] rdtime_cpu,
    output wire        int_m_timer_cpu,
    output wire        int_m_soft_cpu,
    output wire        int_m_ext_cpu,
    output wire        int_s_ext_cpu,
    output wire        bridge_rst_s
);
    // ---------------- reset: async assert / sync release ----------------
    reg [1:0] rst_sync;
    always @(posedge cpu_clk or posedge soc_rst) begin
        if (soc_rst) rst_sync <= 2'b11;
        else         rst_sync <= {rst_sync[0], 1'b0};
    end
    assign cpu_rst      = rst_sync[1];
    assign bridge_rst_s = soc_rst;

    // ---------------- rdtime: Gray CDC ----------------
    // 先在 soc 域把 Gray 码**打一拍**再跨域：组合 Gray 编码在二进制多位同时翻转时会有毛刺，
    // 直接送 2FF 可能采到非法码；寄存器输出保证跨域信号每步只变 1 位。
    reg  [63:0] rdtime_gray_r;
    always @(posedge soc_clk) begin
        if (soc_rst) rdtime_gray_r <= 64'd0;
        else         rdtime_gray_r <= rdtime_soc ^ (rdtime_soc >> 1);
    end

    reg  [63:0] g1, g2;
    always @(posedge cpu_clk) begin
        if (cpu_rst) begin
            g1 <= 64'd0;
            g2 <= 64'd0;
        end else begin
            g1 <= rdtime_gray_r;
            g2 <= g1;
        end
    end

    integer i;
    always @(*) begin
        for (i = 0; i < 64; i = i + 1)
            rdtime_cpu[i] = ^(g2 >> i);      // Gray→binary：bin[i] = XOR(gray[63:i])
    end

    // ---------------- interrupts: 2FF level sync ----------------
    reg [1:0] mt, ms, me, se;
    always @(posedge cpu_clk) begin
        if (cpu_rst) begin
            mt <= 2'b00; ms <= 2'b00; me <= 2'b00; se <= 2'b00;
        end else begin
            mt <= {mt[0], int_m_timer_soc};
            ms <= {ms[0], int_m_soft_soc};
            me <= {me[0], int_m_ext_soc};
            se <= {se[0], int_s_ext_soc};
        end
    end
    assign int_m_timer_cpu = mt[1];
    assign int_m_soft_cpu  = ms[1];
    assign int_m_ext_cpu   = me[1];
    assign int_s_ext_cpu   = se[1];
endmodule
