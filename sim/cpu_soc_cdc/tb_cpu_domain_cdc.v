// tb_cpu_domain_cdc —— CPU 域复位/Gray rdtime/中断 2FF 的单元闸门。
// sclk=100MHz, dclk=108MHz；rdtime 每 soc 拍 +1。
`timescale 1ns/1ps
module tb_cpu_domain_cdc;
    reg soc_clk = 0, cpu_clk = 0;
    always #5.000 soc_clk = ~soc_clk;
    always #4.630 cpu_clk = ~cpu_clk;

    reg soc_rst = 1;
    reg [63:0] rdtime = 0;
    reg mtip = 0, msip = 0, meip = 0, seip = 0;

    wire cpu_rst;
    wire [63:0] rdtime_cpu;
    wire mtip_c, msip_c, meip_c, seip_c;
    wire bridge_rst_s;

    cpu_domain_cdc dut (
        .soc_clk(soc_clk), .soc_rst(soc_rst), .cpu_clk(cpu_clk),
        .rdtime_soc(rdtime),
        .int_m_timer_soc(mtip), .int_m_soft_soc(msip),
        .int_m_ext_soc(meip), .int_s_ext_soc(seip),
        .cpu_rst(cpu_rst), .rdtime_cpu(rdtime_cpu),
        .int_m_timer_cpu(mtip_c), .int_m_soft_cpu(msip_c),
        .int_m_ext_cpu(meip_c), .int_s_ext_cpu(seip_c),
        .bridge_rst_s(bridge_rst_s)
    );

    always @(posedge soc_clk) if (!soc_rst) rdtime <= rdtime + 1;

    integer errors = 0;
    integer i;
    reg [63:0] prev;

    initial begin
        #50 soc_rst = 0;
        // 等 cpu_rst 释放 + 时基稳定
        wait (!cpu_rst);
        repeat (8) @(posedge cpu_clk);

        prev = 0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge cpu_clk);
            if (!cpu_rst) begin
                if (rdtime_cpu < prev) begin
                    $display("FAIL rdtime not monotonic at i=%0d prev=%0d now=%0d", i, prev, rdtime_cpu);
                    errors = errors + 1;
                end
                prev = rdtime_cpu;
            end
        end
        if (rdtime - rdtime_cpu > 32) begin
            $display("FAIL rdtime lag too big: soc=%0d cpu=%0d", rdtime, rdtime_cpu);
            errors = errors + 1;
        end

        // 中断电平 2FF：置 1 后 4 拍内必须看到 1；撤 1 后 4 拍内必须看到 0
        mtip = 1; msip = 1; meip = 1; seip = 1;
        repeat (4) @(posedge cpu_clk);
        if (!(mtip_c && msip_c && meip_c && seip_c)) begin
            $display("FAIL irq sync high mtip=%b msip=%b meip=%b seip=%b", mtip_c, msip_c, meip_c, seip_c);
            errors = errors + 1;
        end
        mtip = 0; msip = 0; meip = 0; seip = 0;
        repeat (4) @(posedge cpu_clk);
        if (mtip_c || msip_c || meip_c || seip_c) begin
            $display("FAIL irq sync low mtip=%b msip=%b meip=%b seip=%b", mtip_c, msip_c, meip_c, seip_c);
            errors = errors + 1;
        end

        // 复位再断言：cpu_rst 必须拉高；bridge_rst_s 跟随 soc_rst
        soc_rst = 1;
        repeat (3) @(posedge cpu_clk);
        if (!cpu_rst || !bridge_rst_s) begin
            $display("FAIL reset assert cpu_rst=%b bridge_rst_s=%b", cpu_rst, bridge_rst_s);
            errors = errors + 1;
        end
        soc_rst = 0;
        repeat (4) @(posedge cpu_clk);
        if (cpu_rst || bridge_rst_s) begin
            $display("FAIL reset release cpu_rst=%b bridge_rst_s=%b", cpu_rst, bridge_rst_s);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS tb_cpu_domain_cdc");
        else             $display("FAIL tb_cpu_domain_cdc errors=%0d", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL tb_cpu_domain_cdc timeout");
        $finish;
    end
endmodule
