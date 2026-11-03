// tri_raster.v —— 包围盒扫描光栅 + Z 测试（逐像素只做加法）。
//
// 与 sim/gpu/tri_ref.py 同口径：
//   · 采样点 = 像素中心：(px<<8)+128, (py<<8)+128
//   · 内部：E0,E1,E2 全 >= 0（边界算内部）
//   · Z：zacc = z0<<16 + dzdx*(sx-sx_v0) + dzdy*(sy-sy_v0)，逐像素 zacc += dzdx / 逐行 += dzdy，
//         z = zacc >>> 16（算术右移=向下取整，与黄金的 Python >> 一致），clamp 到 [0,65535]
//   · zmode: 0=LESS(z<old) 1=LEQUAL(z<=old) 2=OFF(总是写)
//
// ★ 2026-11-02：**两拍流水**（提频用；语义逐像素不变）
//   原实现一拍里做完 `cy → idx=(cy-yorg)*stride+(cx-xorg) → z_raddr（fanout 257）
//   → 分布式 RAM → ztile_rdata 4 选 1 → zpass → wz/waddr 的 CE`，这条链在 84.375MHz
//   只剩 +0.544ns、在 101.25MHz 直接布不出来。
//   拆法：
//     · A 级（扫描）：只算 idx 与 in_tri/zval，**寄存成 p_***；
//     · B 级（写回）：用 p_addr 读 Z 阵列、比 zpass、写 we/waddr/wcolor/wz。
//   代价：每个 tile 多 1 拍收尾（S_DRAIN），写回整体晚 1 拍 —— tile 是整块光栅完才
//   写回 DDR，晚一拍对外不产生任何差异（golden 逐字节不变）。
//
// 端口：Z 缓冲是"组合读 + 写"的单口 RAM（TB/上层给），地址 = y*stride + x。
module tri_raster (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  signed [23:0] a0, b0, a1, b1, a2, b2,
    input  signed [47:0] c0, c1, c2,
    input  wire [15:0] bx0, by0, bx1, by1,
    input  wire [15:0] stride,
    input  wire [15:0] xorg, yorg,          // 本块（tile）左上角在屏幕上的坐标（单元闸门填 0）
    input  wire [15:0] color,
    input  wire [15:0] z0v,
    input  signed [23:0] dzdx, dzdy,
    input  wire [23:0] vx0, vy0,          // v0 的 8.8 坐标（Z 平面原点）
    input  wire [1:0]  zmode,
    output reg         busy,
    output reg         done,

    // Z 缓冲读口（组合；**B 级地址**）
    output wire [17:0] z_raddr,
    input  wire [15:0] z_rdata,
    // 写回（颜色 + Z）
    output reg         we,
    output reg  [17:0] waddr,
    output reg  [15:0] wcolor,
    output reg  [15:0] wz
);

  localparam S_IDLE = 3'd0, S_INIT = 3'd1, S_PIX = 3'd3, S_DRAIN = 3'd5, S_DONE = 3'd4;

  reg [2:0] st;
  reg [15:0] cx, cy;

  reg signed [47:0] e0, e1, e2;         // 当前行起点
  reg signed [47:0] r0, r1, r2;         // 本行 e 初值
  reg signed [47:0] s0, s1, s2;         // 扫描中的 e
  reg signed [63:0] zacc;               // Q16 累加器
  reg signed [63:0] zrow;
  reg signed [47:0] dxstep0, dxstep1, dxstep2;   // A<<8
  reg signed [47:0] dystep0, dystep1, dystep2;   // B<<8

  // ---------------- A 级（扫描，组合只到这里）----------------
  wire [17:0] idx = (cy - yorg) * stride + (cx - xorg);
  wire signed [63:0] zsh = zacc >>> 16;
  wire [15:0] zval_c = (zsh < 0) ? 16'd0 : (zsh > 64'sd65535) ? 16'd65535 : zsh[15:0];
  wire in_tri = (s0 >= 0) && (s1 >= 0) && (s2 >= 0);

  // ---------------- A 级 → B 级 的流水寄存器 ----------------
  reg              p_valid;
  reg  [17:0]      p_addr;
  reg              p_in;
  reg  [15:0]      p_color, p_z;

  assign z_raddr = p_addr;

  // ---------------- B 级（写回）----------------
  wire zpass_b = (zmode == 2'd2) ? 1'b1 :
                 (zmode == 2'd1) ? (p_z <= z_rdata) : (p_z < z_rdata);

  always @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; we <= 1'b0;
      cx <= 16'd0; cy <= 16'd0; waddr <= 18'd0; wcolor <= 16'd0; wz <= 16'd0;
      zacc <= 64'sd0; zrow <= 64'sd0; s0 <= 48'sd0; s1 <= 48'sd0; s2 <= 48'sd0;
      p_valid <= 1'b0; p_addr <= 18'd0; p_in <= 1'b0; p_color <= 16'd0; p_z <= 16'd0;
    end else begin
      done <= 1'b0;
      we   <= 1'b0;

      // ---- B 级：把上一拍压进来的像素写掉（读 p_addr 的 Z 已在组合口上）----
      if (p_valid && p_in && zpass_b) begin
        we     <= 1'b1;
        waddr  <= p_addr;
        wcolor <= p_color;
        wz     <= p_z;
      end

      // ---- A 级：每拍把当前像素压进 B 级（离开 S_PIX 后自动失效）----
      p_valid <= (st == S_PIX);
      p_addr  <= idx;
      p_in    <= in_tri;
      p_color <= color;
      p_z     <= zval_c;

      case (st)
        S_IDLE: if (start) begin
          busy <= 1'b1;
          cx <= bx0; cy <= by0;
          // 符号扩展后再左移 8（{a,8'd0} 是无符号拼接，负数会丢符号）
          dxstep0 <= {{16{a0[23]}}, a0, 8'd0};
          dxstep1 <= {{16{a1[23]}}, a1, 8'd0};
          dxstep2 <= {{16{a2[23]}}, a2, 8'd0};
          dystep0 <= {{16{b0[23]}}, b0, 8'd0};
          dystep1 <= {{16{b1[23]}}, b1, 8'd0};
          dystep2 <= {{16{b2[23]}}, b2, 8'd0};
          // 行/像素初值：E_i = (A_i*bx0 + B_i*by0)*256 + 128*(A_i+B_i) + C_i
          e0 <= a0 * $signed({8'd0, bx0}) * 256 + b0 * $signed({8'd0, by0}) * 256
                + 128 * (a0 + b0) + c0;
          e1 <= a1 * $signed({8'd0, bx0}) * 256 + b1 * $signed({8'd0, by0}) * 256
                + 128 * (a1 + b1) + c1;
          e2 <= a2 * $signed({8'd0, bx0}) * 256 + b2 * $signed({8'd0, by0}) * 256
                + 128 * (a2 + b2) + c2;
          // Z 初值：z0<<16 + dzdx*(sx0-vx0) + dzdy*(sy0-vy0)
          zacc <= ({48'd0, z0v} << 16)
                + dzdx * (($signed({8'd0, bx0}) << 8 | 24'sd128) - $signed({1'b0, vx0}))
                + dzdy * (($signed({8'd0, by0}) << 8 | 24'sd128) - $signed({1'b0, vy0}));
          st <= S_INIT;
        end
        S_INIT: begin
          r0 <= e0; r1 <= e1; r2 <= e2;
          s0 <= e0; s1 <= e1; s2 <= e2;
          zrow <= zacc;
          // 空包围盒（bx1<bx0 或 by1<by0）直接收工，否则行/列计数永远等不到相等
          if ((bx1 < bx0) || (by1 < by0)) st <= S_DONE;
          else st <= S_PIX;
        end
        S_PIX: begin
          if (cx == bx1) begin
            if (cy == by1) st <= S_DRAIN;      // 最后像素已压入 B 级
            else begin
              cy <= cy + 16'd1;
              cx <= bx0;
              r0 <= r0 + dystep0; r1 <= r1 + dystep1; r2 <= r2 + dystep2;
              s0 <= r0 + dystep0; s1 <= r1 + dystep1; s2 <= r2 + dystep2;
              zrow <= zrow + dzdy;
              zacc <= zrow + dzdy;
            end
          end else begin
            cx <= cx + 16'd1;
            s0 <= s0 + dxstep0; s1 <= s1 + dxstep1; s2 <= s2 + dxstep2;
            zacc <= zacc + dzdx;
          end
        end
        // 收尾一拍：让 B 级把最后一个像素写掉（p_valid 在本拍仍为 1）
        S_DRAIN: st <= S_DONE;
        S_DONE: begin
          busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
        end
        // ★ 2026-11-01 上板险情：默认分支原来是 `st <= S_IDLE`，但 **busy 还挂着 1** ⇒
        //   一旦 st 被打到非法值，本模块永远不回 done，上层 gpu_3d 就死在 S_RAW，
        //   整个 GPU 队列永久堵死（板上实测：30 min 不动、被卡的 tile 一个像素都没写）。
        //   改成"走正常收尾"：清 busy、给一拍 done，让上层继续 —— 坏只有这一块 tile，
        //   而且 golden 比对会响亮报错，不再需要重启板子。
        default: st <= S_DONE;
      endcase
    end
  end

endmodule
