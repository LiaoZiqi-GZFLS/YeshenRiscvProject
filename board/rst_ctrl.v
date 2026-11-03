//=============================================================================
// rst_ctrl: 软件可请求的整片 SoC 复位（`reboot` 的硬件落点）
//
// 为什么需要它：板上没有可编程的复位触发源（KEY0 是硬复位键，按下去等价于断电重启，
//   软件碰不到）。Linux 里敲 `reboot` 原先只会走到 `machine_restart` 的死等。
//   本模块给出一条**软件可触发、时长确定、不自锁**的 SoC 复位路径。
//
// 复位范围：
//   · 输出 `sys_rstn` 与板级既有复位链**相与**（`soc_resetn = rst_sync2 & sys_rstn`）
//     ⇒ 复位整个 SoC/fabric/外设。含胶合块的 SD 装载器 ⇒ 复位后走与冷启动**同一条**
//     装载路径（SD 读表 → 装内核 → 放 CPU），不是"热重启"。
//   · **一并复位 DDR3 IP**（`sys_rstn` 也清 POR 计数器并直接压 `ddr_rstn`，见板级顶层）：
//     reboot 那一刻视频通路几乎必然有一笔 DDR 读在飞，而 DDR3 IP 不在 SoC 复位链上 ⇒
//     那笔 R 数据无人取 ⇒ R 通道堵死 ⇒ 重启后装载器读回残数。所以 reboot 语义定为
//     "除两颗板级 PLL 外等同冷启动"（代价：多一次 PHY 校准，几百 ms）。
//   · **不复位**：两颗板级 PLL（`pll_lock_100m` / `pll_lock_cpu` 全程保持，无需重配）。
//
// ★ 承重：请求绝不能自锁（否则就是无限重启环）
//   `rst_req` 是 soc_clk 域的电平，来源 `video_regs` 的 RST_CTRL[0]；那个寄存器的复位端
//   就是 `soc_resetn` ⇒ 本次复位**必然**把请求清掉。本模块再补两道保险：
//     ① `req_ack`：一个请求只兑现一次 —— 请求若因任何原因挂住不放，**不会**再次触发；
//     ② `req_ack` 只在看到 `rst_req` 回低时才清（重新武装）。
//   两道保险同时失效（请求永久为高且从未回落）的结果是"以后再也不复位"，
//   而不是"每 20 ms 复位一次"。这个方向是刻意选的：宁可失效，不可自激。
//
// 时长：HOLD_CYC 个 clk_in 拍（20 ms @27 MHz = 540000）。
//   下限只需"够把所有同步/异步复位端压住"，20 ms 远大于任何内部复位链；
//   上限受 `syscon-reboot` 里那 50 ms `mdelay` 约束 —— 超过它软件会先打印
//   "Reboot failed" 再被本复位打断（只是日志难看，不影响结果）。
//=============================================================================
`timescale 1ns/1ps

module rst_ctrl #(
    parameter integer HOLD_CYC = 540000      // 20 ms @ 27 MHz
)(
    input  wire clk,        // clk_in = 板载 27 MHz 晶振，永远在跑
    input  wire rst_req,    // soc_clk 域，电平请求（被本模块产生的复位清掉）
    output wire sys_rstn    // 1 = 运行（与 soc_resetn 的同步器输出相与）
);

    localparam integer CW = (HOLD_CYC > 1) ? $clog2(HOLD_CYC) : 1;

    reg          req_s1  = 1'b0;
    reg          req_s2  = 1'b0;
    reg          req_ack = 1'b0;   // 1 = 这一轮请求已兑现（禁止重复触发）
    reg          hold    = 1'b0;
    reg [CW-1:0] cnt     = {CW{1'b0}};

    always @(posedge clk) begin
        req_s1 <= rst_req;
        req_s2 <= req_s1;

        if (!req_s2) req_ack <= 1'b0;      // 请求回低 ⇒ 重新武装

        if (!hold) begin
            if (req_s2 && !req_ack) begin
                hold <= 1'b1;
                cnt  <= {CW{1'b0}};
            end
        end else if (cnt != HOLD_CYC - 1) begin
            cnt <= cnt + 1'b1;
        end else begin
            hold    <= 1'b0;
            req_ack <= 1'b1;               // 同一请求不得再次触发
        end
    end

    assign sys_rstn = ~hold;

endmodule
