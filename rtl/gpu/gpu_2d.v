// gpu_2d.v —— 2D 像素流发生器。
//
// 写路径：FILL / ROUND_FILL / SET_SCISSOR / FENCE——按行攒成 8 B 对齐字（半字选通），行尾 flush。
// 读改写：BLIT（RGB565，可选混合）/ GLYPH（A8+fg）——按 **≤64 像素一块**：
//   drain 写侧 → 读源块（≤16 拍）→（混合时）读目标块 → 逐像素合并进 obuf → 整块写回。
//   每块 2~3 次 burst，且满足 gpu_mem “读/写不同时在飞” 的契约（读前必先 drain 写侧）。
//
// 混合口径与 sim/gpu/gpu2d_ref.c（LVGL 9.2）逐位一致：
//   a<2 不写；a>=253 直接拷贝；否则每通道 x = bg*255 + (fg-bg)*a，out = (x*0x8081)>>23
//   （0x8081 乘法用移位加法：(x<<15)+(x<<7)+x 后 >>23）
module gpu_2d (
    input  wire        clk,
    input  wire        rst,

    input  wire        cmd_start,
    input  wire [7:0]  cmd_op,
    input  wire [7:0]  cmd_nwords,
    input  wire [15:0] cmd_flags,
    input  wire [31:0] par_data,
    input  wire        par_valid,
    output wire        par_ready,
    output reg         cmd_done,

    output reg         wr_valid,
    output reg  [31:0] wr_addr,
    output reg  [63:0] wr_data,
    output reg  [7:0]  wr_strb,
    input  wire        wr_ready,
    output reg         wr_flush,
    input  wire        wr_idle,

    output reg         rd_req,
    output reg  [31:0] rd_addr,
    output reg  [7:0]  rd_beats,
    input  wire        rd_busy,
    input  wire [63:0] rd_data,
    input  wire        rd_valid,
    input  wire        rd_last,

    output wire [4:0]  dbg_state,
    output wire [31:0] dbg_px,
    output wire [31:0] dbg_npx,
    output wire [31:0] dbg_nflush,
    output wire [15:0] dbg_brow, dbg_bcx, dbg_bcxe,
    output wire [6:0]  dbg_cpx
);

  localparam OP_NOP         = 8'h01;
  localparam OP_FILL        = 8'h02;
  localparam OP_BLIT        = 8'h03;
  localparam OP_GLYPH       = 8'h04;
  localparam OP_ROUND_FILL  = 8'h05;
  localparam OP_SET_SCISSOR = 8'h06;
  localparam OP_FENCE       = 8'h07;

  localparam [4:0] S_IDLE     = 5'd0;
  localparam [4:0] S_COLLECT  = 5'd1;
  localparam [4:0] S_DEC      = 5'd2;
  localparam [4:0] S_PREP     = 5'd3;
  localparam [4:0] S_SEARCH   = 5'd4;
  localparam [4:0] S_ROWSTART = 5'd5;
  localparam [4:0] S_ROW      = 5'd6;
  localparam [4:0] S_FLUSH    = 5'd7;
  localparam [4:0] S_ROWEND   = 5'd8;
  localparam [4:0] S_WAITIDLE = 5'd9;
  localparam [4:0] S_DONE     = 5'd10;
  localparam [4:0] S_B_ROW    = 5'd11;
  localparam [4:0] S_B_CHUNK  = 5'd12;
  localparam [4:0] S_B_DRAIN  = 5'd13;
  localparam [4:0] S_B_SRC    = 5'd14;
  localparam [4:0] S_B_SRCW   = 5'd15;
  localparam [4:0] S_B_DST    = 5'd16;
  localparam [4:0] S_B_DSTW   = 5'd17;
  localparam [4:0] S_B_PMRG   = 5'd18;
  localparam [4:0] S_B_MERGE  = 5'd19;
  localparam [4:0] S_B_WR     = 5'd20;
  localparam [4:0] S_B_NEXT   = 5'd21;
  localparam [4:0] S_B_MIX    = 5'd22;   // 混合像素的第 2 拍（拆乘法链，见 S_B_MERGE）
  localparam [4:0] S_B_COV    = 5'd23;   // 字形覆盖率（cov*alpha → udiv255）单独一拍

  reg [4:0]  state;
  reg [7:0]  op;
  reg [15:0] flags;
  reg [7:0]  nwords;
  reg [7:0]  pcnt;
  reg [31:0] p [0:15];

  reg [15:0] scx0, scy0, scx1, scy1;

  // FILL / ROUND
  reg [31:0] dst, stride_b;
  reg [15:0] px, py, pw, ph;
  reg [15:0] cur_y, cur_x, x_end, y_end;
  reg [31:0] px_addr, row_base;
  reg [15:0] color;
  reg [15:0] rad, inset, sdy, si;
  reg        acc_has;
  reg [31:0] acc_word;
  reg [63:0] acc_data;
  reg [7:0]  acc_strb;
  reg        flush_req;
  reg        flushing;

  // BLIT / GLYPH
  reg [15:0] g_x0, g_y0, g_w, g_h;
  reg [31:0] s_base, s_stride_b, d_base, d_stride_b;
  reg [15:0] s_sx, s_sy;
  reg [15:0] g_alpha, g_fg;
  reg        g_blend, g_glyph;
  reg [1:0]  g_bpp;
  reg [15:0] b_row, b_cx, b_cxe;
  reg [31:0] s_row_addr, d_row_addr;
  reg [31:0] s_cbase, d_cbase;
  reg [4:0]  s_lead, d_lead;
  reg [6:0]  c_px;
  reg [6:0]  m_idx;
  // 混合像素的第 1 拍寄存（第 2 拍再算 mix565）— 把 3 乘法串联拆成两个乘法级
  reg [7:0]  mix_a;
  reg [15:0] mix_fg, mix_bg;
  reg [3:0]  mix_wi;
  reg [1:0]  mix_lane;
  reg [7:0]  mix_cov;      // 字形：本像素的覆盖字节（S_B_MERGE 锁存 → S_B_COV 算 alpha）
  reg        mix_direct;   // S_B_MIX 直接写 mix_fg（eff_a>=253 时与旧版逐字节一致）
  reg [5:0]  c_nw;
  reg [4:0]  rdcnt;
  reg [4:0]  w_idx;
  // ⚠️ 必须显式钉成寄存器。PDS 会把这 4 个 16 深数组推断成 RAM
  //    （dev_map 日志 `Found Ram sbuf/dbuf, depth=16, width=64`），推断后的行为
  //    与仿真不一致：上板实测 BLIT 的源指针会按"目标地址 bit[4:3]"整字偏移
  //    （gputest 的 blit 区 3072/3072 全错、而只写不读的 FILL 131072/131072 全对）。
  //    仿真里它们是普通寄存器数组，所以这条缺陷在仿真闸门下不可见。
  (* syn_ramstyle = "registers" *) reg [63:0] sbuf [0:15];
  (* syn_ramstyle = "registers" *) reg [63:0] dbuf [0:15];
  (* syn_ramstyle = "registers" *) reg [63:0] obuf [0:15];
  (* syn_ramstyle = "registers" *) reg [7:0]  ostb [0:15];

  reg [31:0] npx, nflush;
  integer    i;

  assign par_ready  = (state == S_COLLECT);
  assign dbg_state  = state;
  assign dbg_px     = {cur_y, cur_x};
  assign dbg_npx    = npx;
  assign dbg_nflush = nflush;
  assign dbg_brow = b_row; assign dbg_bcx = b_cx; assign dbg_bcxe = b_cxe; assign dbg_cpx = c_px;

  wire [31:0] pword_next = {px_addr[31:3], 3'b000};
  wire [1:0]  plane_next = px_addr[2:1];

  wire signed [31:0] sA = 2 * $signed({16'd0, si}) + 1 - 2 * $signed({16'd0, rad});
  wire signed [31:0] sB = 2 * $signed({16'd0, sdy}) + 1 - 2 * $signed({16'd0, rad});
  wire signed [31:0] sR = 4 * $signed({16'd0, rad}) * $signed({16'd0, rad});
  wire corner_ok = (sA * sA + sB * sB) <= sR;

  wire [15:0] xs_c = (px + inset < scx0) ? scx0 : (px + inset);
  wire [15:0] xe_c = (px + pw - inset > scx1) ? scx1 : (px + pw - inset);

  // ---------------- 混合（逐位等价 LVGL） ----------------
  function [7:0] udiv255(input [31:0] x);
    udiv255 = (x + (x << 7) + (x << 15)) >> 23;
  endfunction

  function [5:0] mix_chan(input [5:0] fg, input [5:0] bg, input [7:0] a);
    reg signed [17:0] d;
    reg signed [17:0] t;
    begin
      // x = 255*bg + (fg-bg)*a ∈ [0, 16065]（14 位）⇒ **16 位就够**；原来按 32 位算，
      // 乘法器又宽又慢（PnR 实测单个 APM ~2–3 ns）。18 位有符号中间量保证 fg<bg 不绕。
      d = $signed({12'd0, fg}) - $signed({12'd0, bg});
      t = $signed({12'd0, bg}) * 18'sd255 + d * $signed({10'd0, a});
      mix_chan = udiv255({18'd0, t[15:0]});
    end
  endfunction

  function [15:0] mix565(input [15:0] fg, input [15:0] bg, input [7:0] a);
    reg [5:0] cr, cg, cb;
    begin
      // RGB565 是 5/6/5；三者都取 6 位拼会变 18 位、截断后整色错位
      cr = mix_chan(fg[15:11], bg[15:11], a);
      cg = mix_chan(fg[10:5],  bg[10:5],  a);
      cb = mix_chan(fg[4:0],   bg[4:0],   a);
      mix565 = {cr[4:0], cg[5:0], cb[4:0]};
    end
  endfunction

  wire [7:0]  s_boff = {3'd0, s_lead} + m_idx * g_bpp;
  wire [7:0]  d_boff = {3'd0, d_lead} + m_idx * 8'd2;
  wire [3:0]  s_wi   = s_boff[6:3];
  wire [2:0]  s_bi   = s_boff[2:0];
  wire [3:0]  d_wi   = d_boff[6:3];
  wire [1:0]  d_lane = d_boff[2:1];
  wire [15:0] s_px   = sbuf[s_wi][s_bi[2:1] * 16 +: 16];
  wire [7:0]  s_cov  = sbuf[s_wi][s_bi * 8 +: 8];
  wire [15:0] d_px   = dbuf[d_wi][d_lane * 16 +: 16];
  wire [7:0]  eff_a  = g_alpha[7:0];          // 只给非字形混合用；字形在 S_B_COV 算
  wire [15:0] fg_px  = s_px;
  // 不透明 BLIT 直接拷源；混合才走 mix（否则 eff_a=0 会写成目标底色）。
  // 字形覆盖率（cov*alpha 的乘法 + udiv255）**不在这条链上**：
  //   S_B_MERGE 只锁存 s_cov → S_B_COV 单独一拍算 eff_a → S_B_MIX 再算 mix565。
  // 原来这一拍是 mux → 乘法 → udiv → 比较 → obuf/CE，PnR 实测 soc_clk −0.846（布线占 59%）。
  wire        do_write = g_blend ? (eff_a >= 8'd2) : 1'b1;

  always @(*) begin
    c_nw = (({2'd0, d_lead} + {1'd0, c_px} * 5'd2 + 5'd7) >> 3);
  end

  // ---- 分块几何（模块级组合逻辑）----
  // 这些量原来写成 S_B_CHUNK 里的块内局部变量（blocking 赋值）：仿真正确，但 PDS 把它们
  // 当成 clocked 块里的寄存器，dev_map 日志实测
  //   W: Sdm-2020: Unused register calc.d_byte was removed.
  //   W: Sdm-2020: Unused register calc.s_byte was removed.
  // ⇒ 上板 BLIT/GLYPH 的源指针按**目标**地址的 8B 字索引整字偏移（gputest blit 区
  //    3072/3072 全错、而只写不读的 FILL 131072/131072 全对）。改成模块级 always @(*)。
  reg [31:0] d_byte_c, s_byte_c;
  reg [6:0]  c_px_c;
  always @(*) begin
    d_byte_c = d_row_addr + {17'd0, b_cx, 1'b0};
    // 源地址 = 基址 + sy 行 + (sx + 本行内偏移) * bpp —— s_sx 别漏
    s_byte_c = s_row_addr + ({15'd0, s_sx} + {15'd0, b_cx} - {15'd0, g_x0}) * g_bpp;
    c_px_c = ((b_cxe - b_cx) > 16'd64) ? 7'd64 : (b_cxe[6:0] - b_cx[6:0]);
    // 一个 8B 对齐的分块最多到 128B 边界（7'd128 会溢出成 0）
    if (c_px_c > ((8'd128 - {5'd0, d_byte_c[2:0]}) >> 1))
      c_px_c = ((8'd128 - {5'd0, d_byte_c[2:0]}) >> 1);
    // 源读窗口同样必须留在 16 拍（128 B）以内：s_lead 是本行首个源字节在 8 B 字内的偏移。
    // 只按目标对齐夹紧时，s_lead=7 + 64 px 会算出 17 拍，sbuf（16 深）会回绕。
    if (g_bpp == 2'd2) begin
      if (c_px_c > ((8'd128 - {5'd0, s_byte_c[2:0]}) >> 1))
        c_px_c = ((8'd128 - {5'd0, s_byte_c[2:0]}) >> 1);
    end else begin
      if (c_px_c > (8'd128 - {5'd0, s_byte_c[2:0]}))
        c_px_c = (8'd128 - {5'd0, s_byte_c[2:0]});
    end
  end

  // 混合写回：把像素写进 64 位字的第 lane 个半字（lane 由地址算）
  function [63:0] set_px;
    input [63:0] w;
    input [1:0]  lane;
    input [15:0] px;
    begin
      set_px = (w & ~(64'h0000_FFFF << (lane * 16))) | ({48'd0, px} << (lane * 16));
    end
  endfunction
  function [7:0] set_stb;
    input [7:0] s;
    input [1:0] lane;
    begin
      set_stb = s | (8'h03 << (lane * 2));
    end
  endfunction

  // 字形覆盖率（cov*alpha → udiv255）：同样从块内局部变量改成模块级 wire
  wire [7:0] cov_a = udiv255({8'd0, mix_cov} * g_alpha[7:0]);

  always @(posedge clk) begin
    if (rst) begin
      state     <= S_IDLE;
      cmd_done  <= 1'b0;
      wr_valid  <= 1'b0;
      wr_flush  <= 1'b0;
      flush_req <= 1'b0;
      flushing  <= 1'b0;
      acc_has   <= 1'b0;
      rd_req    <= 1'b0;
      scx0 <= 16'd0; scy0 <= 16'd0; scx1 <= 16'd1024; scy1 <= 16'd600;
      pcnt  <= 8'd0;
      cur_y <= 16'd0; cur_x <= 16'd0; x_end <= 16'd0; y_end <= 16'd0;
      npx   <= 32'd0; nflush <= 32'd0;
      b_row <= 16'd0; b_cx <= 16'd0; b_cxe <= 16'd0; m_idx <= 7'd0;
      mix_cov <= 8'd0; mix_direct <= 1'b0;
    end else begin
      cmd_done <= 1'b0;

      case (state)
        S_IDLE: if (cmd_start) begin
          op     <= cmd_op;
          flags  <= cmd_flags;
          nwords <= cmd_nwords;
          pcnt   <= 8'd0;
          state  <= (cmd_nwords == 8'd0) ? S_DEC : S_COLLECT;
        end

        S_COLLECT: if (par_valid) begin
          p[pcnt] <= par_data;
          pcnt <= pcnt + 8'd1;
          if (pcnt + 8'd1 == nwords) state <= S_DEC;
        end

        S_DEC: begin
          if (op == OP_SET_SCISSOR) begin
            scx0 <= p[0][15:0]; scy0 <= p[1][15:0];
            scx1 <= p[2][15:0]; scy1 <= p[3][15:0];
            flush_req <= 1'b1; state <= S_WAITIDLE;
          end else if (op == OP_BLIT || op == OP_GLYPH) begin
            s_base  <= p[0];
            g_glyph <= (op == OP_GLYPH);
            if (op == OP_BLIT) begin
              s_stride_b <= p[1] << 1;
              g_bpp      <= 2'd2;
              s_sx <= p[3][15:0]; s_sy <= p[4][15:0];
              g_w  <= p[5][15:0]; g_h  <= p[6][15:0];
              d_base <= p[7]; d_stride_b <= p[8] << 1;
              g_x0 <= p[9][15:0]; g_y0 <= p[10][15:0];
              g_blend <= p[11][0]; g_alpha <= p[12][15:0]; g_fg <= 16'd0;
              b_row <= p[10][15:0];
            end else begin
              s_stride_b <= p[1];
              g_bpp      <= 2'd1;
              s_sx <= p[2][15:0]; s_sy <= p[3][15:0];
              g_w  <= p[4][15:0]; g_h  <= p[5][15:0];
              d_base <= p[6]; d_stride_b <= p[7] << 1;
              g_x0 <= p[8][15:0]; g_y0 <= p[9][15:0];
              g_blend <= 1'b1; g_alpha <= p[11][15:0]; g_fg <= p[10][15:0];
              b_row <= p[9][15:0];
            end
            state <= S_B_ROW;
          end else if (op == OP_FILL || op == OP_ROUND_FILL) begin
            dst      <= p[0];
            stride_b <= p[1] << 1;
            px       <= p[2][15:0];
            py       <= p[3][15:0];
            pw       <= p[4][15:0];
            ph       <= p[5][15:0];
            if (op == OP_ROUND_FILL) begin
              if (p[6][15:0] > (p[4][15:0] >> 1))       rad <= p[4][15:0] >> 1;
              else if (p[6][15:0] > (p[5][15:0] >> 1))  rad <= p[5][15:0] >> 1;
              else                                      rad <= p[6][15:0];
              color <= p[7][15:0];
            end else begin
              color <= p[6][15:0];
              rad   <= 16'd0;
            end
            cur_y    <= p[3][15:0];
            y_end    <= p[3][15:0] + p[5][15:0];
            row_base <= p[0] + p[3][15:0] * (p[1] << 1);
            state    <= S_PREP;
          end else begin
            flush_req <= 1'b1; state <= S_WAITIDLE;
          end
        end

        // ---------------- FILL / ROUND ----------------
        S_PREP: begin
          if (cur_y >= y_end || cur_y >= scy1) begin
            flush_req <= 1'b1; state <= S_WAITIDLE;
          end else if (cur_y < scy0) begin
            cur_y    <= cur_y + 16'd1;
            row_base <= row_base + stride_b;
          end else if (op == OP_ROUND_FILL &&
                       ((cur_y < py + rad) || (cur_y + rad >= py + ph))) begin
            sdy <= (cur_y < py + rad) ? (cur_y - py) : (py + ph - 16'd1 - cur_y);
            si  <= 16'd0;
            state <= S_SEARCH;
          end else begin
            inset <= 16'd0;
            state <= S_ROWSTART;
          end
        end

        S_SEARCH: begin
          if (corner_ok)              begin inset <= si;  state <= S_ROWSTART; end
          else if (si + 16'd1 >= rad) begin inset <= rad; state <= S_ROWSTART; end
          else                        begin si <= si + 16'd1; end
        end

        S_ROWSTART: begin
          cur_x   <= xs_c;
          x_end   <= xe_c;
          px_addr <= row_base + {19'd0, xs_c, 1'b0};
          state   <= S_ROW;
        end

        S_ROW: begin
          if (cur_x >= x_end) begin
            state <= S_ROWEND;
          end else if (acc_has && (acc_word != pword_next)) begin
            state <= S_FLUSH;
          end else begin
            begin : merge
              reg [63:0] nd;
              reg [7:0]  ns;
              nd = (!acc_has || acc_word != pword_next) ? 64'd0 : acc_data;
              ns = (!acc_has || acc_word != pword_next) ? 8'd0  : acc_strb;
              nd[plane_next * 16 +: 16] = color;
              ns[plane_next * 2 +: 2]   = 2'b11;
              acc_data <= nd;
              acc_strb <= ns;
            end
            acc_word <= pword_next;
            acc_has  <= 1'b1;
            npx      <= npx + 32'd1;
            px_addr  <= px_addr + 32'd2;
            cur_x    <= cur_x + 16'd1;
          end
        end

        S_FLUSH: begin
          if (!wr_valid) begin
            wr_valid <= 1'b1;
            wr_addr  <= acc_word;
            wr_data  <= acc_data;
            wr_strb  <= acc_strb;
            nflush   <= nflush + 32'd1;
          end else if (wr_ready) begin
            wr_valid <= 1'b0;
            acc_has  <= 1'b0;
            state    <= S_ROW;
          end
        end

        S_ROWEND: begin
          if (acc_has) state <= S_FLUSH;
          else begin flush_req <= 1'b1; state <= S_WAITIDLE; end
        end

        S_WAITIDLE: begin
          if (!flushing) begin
            if (wr_idle) begin
              flush_req <= 1'b0;
              if ((op == OP_FILL || op == OP_ROUND_FILL) && (cur_y + 16'd1 < y_end)) begin
                cur_y    <= cur_y + 16'd1;
                row_base <= row_base + stride_b;
                state    <= S_PREP;
              end else state <= S_DONE;
            end else begin wr_flush <= 1'b1; flushing <= 1'b1; end
          end else if (wr_idle) begin
            wr_flush  <= 1'b0;
            flushing  <= 1'b0;
            flush_req <= 1'b0;
            if ((op == OP_FILL || op == OP_ROUND_FILL) && (cur_y + 16'd1 < y_end)) begin
              cur_y    <= cur_y + 16'd1;
              row_base <= row_base + stride_b;
              state    <= S_PREP;
            end else state <= S_DONE;
          end
        end

        S_DONE: begin
          cmd_done <= 1'b1;
          state    <= S_IDLE;
        end

        // ---------------- BLIT / GLYPH ----------------
        S_B_ROW: begin
          if (b_row >= g_y0 + g_h || b_row >= scy1) begin
            flush_req <= 1'b1; state <= S_WAITIDLE;
          end else if (b_row < scy0) begin
            b_row <= b_row + 16'd1;
          end else begin
            d_row_addr <= d_base + b_row * d_stride_b;
            s_row_addr <= s_base + (s_sy + (b_row - g_y0)) * s_stride_b;
            b_cx  <= (g_x0 < scx0) ? scx0 : g_x0;
            b_cxe <= (g_x0 + g_w > scx1) ? scx1 : (g_x0 + g_w);
            state <= S_B_CHUNK;
          end
        end

        S_B_CHUNK: begin
          d_cbase <= {d_byte_c[31:3], 3'b000};
          d_lead  <= {2'b00, d_byte_c[2:0]};
          s_cbase <= {s_byte_c[31:3], 3'b000};
          s_lead  <= {2'b00, s_byte_c[2:0]};
          c_px    <= c_px_c;
          flush_req <= 1'b1;
          state     <= S_B_DRAIN;
        end

        S_B_DRAIN: begin
          if (!flushing) begin
            if (wr_idle) begin
              if (b_cx >= b_cxe) begin
                b_row <= b_row + 16'd1;
                state <= S_B_ROW;
              end else begin
                rd_req   <= 1'b1;
                rd_addr  <= s_cbase;
                rd_beats <= (({3'd0, s_lead} + {1'd0, c_px} * g_bpp + 7) >> 3) - 1;
                rdcnt    <= 5'd0;
                flush_req <= 1'b0;
                state    <= S_B_SRC;
              end
            end else begin wr_flush <= 1'b1; flushing <= 1'b1; end
          end else begin
            wr_flush <= 1'b0;
            flushing <= 1'b0;
          end
        end

        S_B_SRC: begin
          rd_req <= 1'b0;
          if (rd_busy) state <= S_B_SRCW;
        end

        S_B_SRCW: if (rd_valid) begin
          sbuf[rdcnt[3:0]] <= rd_data;
          rdcnt <= rdcnt + 5'd1;
          if (rd_last) begin
            if (g_blend) begin
              rd_req   <= 1'b1;
              rd_addr  <= d_cbase;
              rd_beats <= (({3'd0, d_lead} + {1'd0, c_px} * 8'd2 + 7) >> 3) - 1;
              rdcnt    <= 5'd0;
              state    <= S_B_DST;
            end else begin
              m_idx <= 7'd0;
              state <= S_B_PMRG;
            end
          end
        end

        S_B_DST: begin
          rd_req <= 1'b0;
          if (rd_busy) state <= S_B_DSTW;
        end

        S_B_DSTW: if (rd_valid) begin
          dbuf[rdcnt[3:0]] <= rd_data;
          rdcnt <= rdcnt + 5'd1;
          if (rd_last) begin
            m_idx <= 7'd0;
            state <= S_B_PMRG;
          end
        end

        S_B_PMRG: begin
          for (i = 0; i < 16; i = i + 1) begin
            obuf[i] <= g_blend ? dbuf[i] : 64'd0;
            ostb[i] <= 8'd0;
          end
          m_idx <= 7'd0;
          state <= S_B_MERGE;
        end

        // 混合像素分两拍：本拍只算 alpha（glyph 的 cov*alpha 是乘法）并寄存，
        // 下一拍（S_B_MIX）再算 mix565。原来一拍的链路是
        //   m_idx → s_cov → APM(cov*alpha) → APM((fg-bg)*a) → obuf
        // 三个乘法串联 ⇒ PnR 实测 16.8 ns（soc_clk 要求 10 ns）。拆分后每拍 ≤1 级乘法。
        // 字形（g_glyph）再多拆一拍：本拍只锁存覆盖字节 → S_B_COV 算 eff_a → S_B_MIX 写。
        S_B_MERGE: begin
          if (m_idx >= c_px) begin
            w_idx <= 5'd0;
            state <= S_B_WR;
          end else if (g_glyph) begin
            mix_cov  <= s_cov;
            mix_fg   <= g_fg;
            mix_bg   <= d_px;
            mix_wi   <= d_wi;
            mix_lane <= d_lane;
            m_idx    <= m_idx + 7'd1;
            state    <= S_B_COV;
          end else if (!do_write) begin
            m_idx <= m_idx + 7'd1;
          end else if (g_blend && (eff_a < 8'd253)) begin
            mix_a    <= eff_a;
            mix_direct <= 1'b0;
            mix_fg   <= fg_px;
            mix_bg   <= d_px;
            mix_wi   <= d_wi;
            mix_lane <= d_lane;
            m_idx    <= m_idx + 7'd1;
            state    <= S_B_MIX;
          end else begin
            obuf[d_wi] <= set_px(obuf[d_wi], d_lane, g_blend ? fg_px : s_px);
            ostb[d_wi] <= set_stb(ostb[d_wi], d_lane);
            npx   <= npx + 32'd1;
            m_idx <= m_idx + 7'd1;
          end
        end

        S_B_COV: begin
          if (cov_a >= 8'd2) begin
            mix_a      <= cov_a;
            // eff_a>=253 旧版是"直写 fg"（不走 mix565），这里用 mix_direct 保逐字节一致
            mix_direct <= (cov_a >= 8'd253);
            state      <= S_B_MIX;
          end else begin
            state      <= S_B_MERGE;   // 覆盖率近 0：不写、不计数（与旧版一致）
          end
        end

        S_B_MIX: begin
          obuf[mix_wi] <= set_px(obuf[mix_wi], mix_lane,
                                 mix_direct ? mix_fg : mix565(mix_fg, mix_bg, mix_a));
          ostb[mix_wi] <= set_stb(ostb[mix_wi], mix_lane);
          npx   <= npx + 32'd1;
          state <= S_B_MERGE;
        end

        S_B_WR: begin
          if (w_idx >= c_nw[4:0]) begin
            flush_req <= 1'b1;
            state     <= S_B_NEXT;
          end else if (ostb[w_idx[3:0]] == 8'd0) begin
            w_idx <= w_idx + 5'd1;
          end else if (!wr_valid) begin
            wr_valid <= 1'b1;
            wr_addr  <= d_cbase + {27'd0, w_idx[3:0], 3'b000};
            wr_data  <= obuf[w_idx[3:0]];
            wr_strb  <= ostb[w_idx[3:0]];
            nflush   <= nflush + 32'd1;
          end else if (wr_ready) begin
            wr_valid <= 1'b0;
            w_idx    <= w_idx + 5'd1;
          end
        end

        S_B_NEXT: begin
          if (!flushing) begin
            if (wr_idle) begin
              flush_req <= 1'b0;
              if (b_cx + {9'd0, c_px} >= b_cxe) begin
                b_row <= b_row + 16'd1;
                state <= S_B_ROW;
              end else begin
                b_cx  <= b_cx + {9'd0, c_px};
                state <= S_B_CHUNK;
              end
            end else begin wr_flush <= 1'b1; flushing <= 1'b1; end
          end else if (wr_idle) begin
            wr_flush <= 1'b0;
            flushing <= 1'b0;
            flush_req <= 1'b0;
            if (b_cx + {9'd0, c_px} >= b_cxe) begin
              b_row <= b_row + 16'd1;
              state <= S_B_ROW;
            end else begin
              b_cx  <= b_cx + {9'd0, c_px};
              state <= S_B_CHUNK;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
