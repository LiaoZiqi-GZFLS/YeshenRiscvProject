//=============================================================================
// ddr_model: 行为级 256-bit 简化 DDR（U1~U4 共用）
//   - 单端口命令（AW/W/AR 各一条），无 B 通道
//   - 地址口径 = 厂家链路的 32-bit 字地址（重要）：
//       每拍 256-bit = 8 个 4 字节字，故每 beat 地址 +8；
//       16-beat burst 跨 128 字（512B）。wr_ctrl/rd_ctrl 的地址推进
//       （+{len,3'd0}+8）就是按这个口径写的。存储按 256-bit 拍索引 addr[22:3]。
//   - 写：wusero_last 与每笔 burst 的**最后一拍 W 同拍**置 1。厂家 wr_ctrl 的
//     `cmd_cnt` 只在 `axi_wlast && axi_wvalid && axi_wready` 同拍递减，而
//     `axi_wvalid = axi_wready` ⇒ 若把 last 做成"后一拍"，厂家记账会漏减。
//     wstrb 忽略（视频链路全 32B 有效）
//   - 读：aruser_id -> rid，读延迟 LAT 拍，rlast 在最后一拍
//   - mem 1<<20 个 256-bit 拍 = 32 MiB；帧存基址 0x0400_0000 落在 0x80000，
//     双 bank 的第 2^22 字偏移在此窗口内与 bank0 别名（TB 两帧同图案，无碍）
//=============================================================================
`timescale 1ns/1ps
module ddr_model #(parameter AW=28, parameter LAT=8, parameter ARDEPTH=1)(
    input clk, input rstn,
    input [AW-1:0] awaddr, input [3:0] awlen, input awvalid, output reg awready,
    input [255:0] wdata, input [31:0] wstrb, input wvalid, output reg wready,
    output wire wusero_last,
    input [AW-1:0] araddr, input [3:0] arlen, input [3:0] aruser_id,
    input arvalid, output reg arready,
    output reg [255:0] rdata, output reg [3:0] rid, output reg rlast,
    output reg rvalid, input rready
);
    reg [255:0] mem [0:(1<<20)-1];   // 32 MiB 窗口足够 TB
    // 写
    reg [3:0] wleft; reg [AW-1:0] waddr;
    // 与最后一拍 W 同拍（厂家 wr_ctrl 的 cmd_cnt 递减依赖这个同拍关系）
    assign wusero_last = wvalid && wready && (wleft == 4'd0);
    always @(posedge clk) begin
        if (!rstn) begin awready<=1; wready<=0; wleft<=0; end
        else begin
            if (awvalid && awready) begin
                awready<=0; waddr<=awaddr; wleft<=awlen; wready<=1;
            end
            if (wvalid && wready) begin
                mem[waddr[22:3]] <= wdata;
                waddr <= waddr + 8;
                if (wleft==0) begin wready<=0; awready<=1; end
                else wleft <= wleft - 1;
            end
        end
    end
    // 读（burst 内背靠背 1 拍/beat；rd_ctrl 的 done 计数器按 rvalid 拍数计数，
    //      有空洞会把 rd_cmd_done 展宽成 2 拍 -> rd_buf 行指针一次 +2 行）
    // ★ ARDEPTH：AR 命令队列（多未完成）。默认 1 = **逐字保持旧行为**
    //   （只在上一笔 burst 的 rlast 交出后才收下一笔 AR）。ARDEPTH>1 时按序回 R，
    //   队列里的命令逐笔服务（命令间留 LAT 拍延迟），rid 带各自的 aruser_id。
    reg [4:0] rdelay; reg [3:0] rleft; reg [AW-1:0] raddr; reg [3:0] r_id;
    reg       rbusy;
    reg [AW-1:0] q_addr [0:ARDEPTH-1];
    reg [3:0]    q_len  [0:ARDEPTH-1];
    reg [3:0]    q_id   [0:ARDEPTH-1];
    reg [4:0]    q_cnt;              // 0..ARDEPTH
    reg [3:0]    q_wr, q_rd;         // 指针（模 ARDEPTH）

    // ARDEPTH=1 时要求空闲（与旧行为逐字相同）；>1 时只要队列有位就收
    always @(*) begin
        arready = (q_cnt < ARDEPTH) && ((ARDEPTH > 1) || !rbusy);
    end

    always @(posedge clk) begin
        if (!rstn) begin
            rvalid<=0; rlast<=0; rdelay<=0; rbusy<=0;
            q_cnt<=0; q_wr<=0; q_rd<=0; r_id<=0;
        end else begin
            if (rvalid && rready) rvalid <= 1'b0;      // 先消费
            // ---- AR 入队 ----
            if (arvalid && arready) begin
                q_addr[q_wr] <= araddr;
                q_len[q_wr]  <= arlen;
                q_id[q_wr]   <= aruser_id;
                q_wr  <= ((q_wr + 4'd1) == ARDEPTH) ? 4'd0 : (q_wr + 4'd1);
                q_cnt <= q_cnt + 5'd1;
            end
            // ---- 读引擎 ----
            if (rbusy) begin
                if (rdelay>0) rdelay <= rdelay-1;
                else begin                             // 后发拍（同拍覆盖上面的清零）
                    rvalid <= 1'b1;
                    rdata  <= mem[raddr[22:3]];
                    rid    <= r_id;
                    rlast  <= (rleft==0);
                    raddr  <= raddr + 8;
                    if (rleft==0) begin rbusy<=0; r_id<=0; end
                    else rleft <= rleft - 1;
                end
            end else if (q_cnt != 0) begin
                raddr  <= q_addr[q_rd];
                rleft  <= q_len[q_rd];
                r_id   <= q_id[q_rd];
                rdelay <= LAT;
                rbusy  <= 1;
                q_rd   <= ((q_rd + 4'd1) == ARDEPTH) ? 4'd0 : (q_rd + 4'd1);
                q_cnt  <= q_cnt - 5'd1;
            end
        end
    end
endmodule
