// tri_setup.v —— 三角形 setup：3 个屏幕空间顶点 -> 边函数系数 + 包围盒。
//
// 口径（与 sim/gpu/tri_ref.py 逐条一致，改一处必须两边一起改）：
//   · 顶点 x/y 是 8.8 定点（256 = 1 px），s32；z 是 u16（0=近）
//   · area = (x1-x0)*(y2-y0) - (y1-y0)*(x2-x0)（有符号面积的 2 倍）
//   · 归一：area < 0 时把**三条边函数整体取反**（E'=-E）。这等价于交换 v1/v2：
//     边界线不变，只是"内部"从 E>=0 换成 E<=0 ⇒ 取反后又回到 E>=0，
//     而且不用重算乘积（比交换顶点省一半乘法）。
//   · 边函数（Q16）E_i(p) = A_i*x + B_i*y + C_i，p 为 8.8 坐标：
//       E0: A0 = -(y2-y1), B0 = (x2-x1), C0 = -(A0*x1 + B0*y1)
//       E1: A1 = -(y0-y2), B1 = (x0-x2), C1 = -(A1*x2 + B1*y2)
//       E2: A2 = -(y1-y0), B2 = (x1-x0), C2 = -(A2*x0 + B2*y0)
//     内部判据：E0,E1,E2 全 >= 0（边界算内部）。C_i 由 E_i(v_i)=0 直接得出。
//   · 包围盒：min/max 顶点坐标 >> 8 后 clamp 到 [0, wmax-1] / [0, hmax-1]（含端点）
//
// 实现：一个 24x24 有符号乘法器串行做 8 次乘（area 2 次 + C 6 次），约 11 拍/三角形。
module tri_setup (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [31:0] v0x, v0y, v1x, v1y, v2x, v2y,   // s32 8.8
    input  wire [15:0] wmax, hmax,                      // 屏幕宽高（px，开区间）
    output reg         busy,
    output reg         done,

    output reg  signed [23:0] a0, b0, a1, b1, a2, b2,   // 边函数一次项（Q8/px）
    output reg  signed [47:0] c0, c1, c2,               // 常数项（Q16）
    output reg  [15:0] bx0, by0, bx1, by1,              // 包围盒（含）
    output reg  signed [47:0] area,                     // >0；0 = 退化
    output reg         degen
);

  localparam S_IDLE = 4'd0, S_MUL = 4'd1, S_FIN = 4'd2, S_DONE = 4'd3;

  reg [3:0]  st;
  reg [3:0]  mi;                          // 第几次乘（0..7）
  reg signed [23:0] ma, mb;
  wire signed [47:0] prod = ma * mb;

  reg signed [23:0] x0, y0, x1, y1, x2, y2;
  reg signed [47:0] p [0:7];

  // 组合出第 mi 次的乘数（x/y 已在 S_IDLE 锁存）
  always @(*) begin
    case (mi)
      4'd0: begin ma = x1 - x0; mb = y2 - y0; end        // (x1-x0)*(y2-y0)
      4'd1: begin ma = y1 - y0; mb = x2 - x0; end        // (y1-y0)*(x2-x0)
      4'd2: begin ma = -(y2 - y1); mb = x1; end          // A0*x1
      4'd3: begin ma =  (x2 - x1); mb = y1; end          // B0*y1
      4'd4: begin ma = -(y0 - y2); mb = x2; end          // A1*x2
      4'd5: begin ma =  (x0 - x2); mb = y2; end          // B1*y2
      4'd6: begin ma = -(y1 - y0); mb = x0; end          // A2*x0
      default: begin ma = (x1 - x0); mb = y0; end        // B2*y0
    endcase
  end

  integer k;
  always @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; degen <= 1'b0;
      mi <= 4'd0; area <= 48'sd0;
      a0 <= 24'sd0; b0 <= 24'sd0; a1 <= 24'sd0; b1 <= 24'sd0; a2 <= 24'sd0; b2 <= 24'sd0;
      c0 <= 48'sd0; c1 <= 48'sd0; c2 <= 48'sd0;
      bx0 <= 16'd0; by0 <= 16'd0; bx1 <= 16'd0; by1 <= 16'd0;
    end else begin
      done <= 1'b0;
      case (st)
        S_IDLE: if (start) begin
          busy <= 1'b1;
          x0 <= v0x[23:0]; y0 <= v0y[23:0];
          x1 <= v1x[23:0]; y1 <= v1y[23:0];
          x2 <= v2x[23:0]; y2 <= v2y[23:0];
          mi <= 4'd0;
          st <= S_MUL;
        end
        S_MUL: begin
          p[mi] <= prod;
          if (mi == 4'd7) st <= S_FIN;
          else mi <= mi + 4'd1;
        end
        S_FIN: begin
          // area = p0 - p1
          area   <= p[0] - p[1];
          degen  <= ((p[0] - p[1]) == 48'sd0);
          a0 <= -(y2 - y1); b0 <= (x2 - x1); c0 <= -(p[2] + p[3]);
          a1 <= -(y0 - y2); b1 <= (x0 - x2); c1 <= -(p[4] + p[5]);
          a2 <= -(y1 - y0); b2 <= (x1 - x0); c2 <= -(p[6] + p[7]);
          // 归一：area<0 时三条边整体取反
          if ((p[0] - p[1]) < 0) begin
            a0 <= (y2 - y1); b0 <= -(x2 - x1); c0 <= (p[2] + p[3]);
            a1 <= (y0 - y2); b1 <= -(x0 - x2); c1 <= (p[4] + p[5]);
            a2 <= (y1 - y0); b2 <= -(x1 - x0); c2 <= (p[6] + p[7]);
          end
          // 包围盒（>>8 = 算术右移，负数向下取整，与黄金一致）
          begin
            reg signed [23:0] xmin, xmax, ymin, ymax;
            xmin = x0; if (x1 < xmin) xmin = x1; if (x2 < xmin) xmin = x2;
            xmax = x0; if (x1 > xmax) xmax = x1; if (x2 > xmax) xmax = x2;
            ymin = y0; if (y1 < ymin) ymin = y1; if (y2 < ymin) ymin = y2;
            ymax = y0; if (y1 > ymax) ymax = y1; if (y2 > ymax) ymax = y2;
            if ((xmin >>> 8) < 0) bx0 <= 16'd0; else bx0 <= xmin[23:8];
            if ((ymin >>> 8) < 0) by0 <= 16'd0; else by0 <= ymin[23:8];
            // ⚠️ 右移 8 后才是像素坐标；直接取 [15:0] 会拿到 8.8 的原始值（bbox 变成 30720）
            if ((xmax >>> 8) >= wmax) bx1 <= wmax - 16'd1; else bx1 <= xmax[23:8];
            if ((ymax >>> 8) >= hmax) by1 <= hmax - 16'd1; else by1 <= ymax[23:8];
          end
          st <= S_DONE;
        end
        S_DONE: begin
          busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
