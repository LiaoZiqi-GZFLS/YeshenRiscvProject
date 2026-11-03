// gpu_3d.v —— P2a 3D 命令引擎（CLEAR3D / DRAW_TRIS）。
//
// 与 gpu_2d 并列挂在 gpu_top 里，**共用 gpu_mem**：本模块只在 busy 时用读/写口，
// 且读、写不同时在飞（读完整行 → 光栅 → 写回），上层保证命令串行。
//
// ---- CLEAR3D (0x10) ----
//   p0=color, p1=z, p2=w, p3=h, p4=color_base, p5=color_stride(px), p6=z_base, p7=z_stride(px)
//   颜色、Z 各按行写满；每拍 8 B = 4 px（gpu_mem 写口是 64-bit 字）。
//
// ---- DRAW_TRIS (0x11) ----
//   p0=tri_addr, p1=count, p2=buf_w, p3=buf_h, p4=color_base, p5=color_stride,
//   p6=z_base, p7=z_stride
//   三角形记录 48 B（6 个 8 B 字）：
//     w0={v0y,v0x} w1={v1y,v1x} w2={v2y,v2x}
//     w3={dzdx[31:0], color[15:0], z0[15:0]}  w4={28'b0, zmode[1:0], dzdy[31:0]}  w5=pad
//   buf_w/buf_h 必须是 32 的倍数（640×480）⇒ 每个 tile 都是完整 32×32。
//   每个三角形：读记录 → tri_setup → 对其包围盒覆盖的每个 32×32 tile：
//     读颜色 tile（32 行 × 8 拍）→ 读 Z tile → tri_raster（写 tile BRAM）→ 写回颜色 + Z。
//   每个 tile 行在 DDR 里不连续 ⇒ 每行单独一次 burst（flush）。
module gpu_3d (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  op,
    input  wire [31:0] p0, p1, p2, p3, p4, p5, p6, p7,
    output reg         busy,
    output reg         done,

    // gpu_mem 读口
    output reg         rd_req,
    output reg  [31:0] rd_addr,
    output reg  [7:0]  rd_beats,
    input  wire        rd_busy,
    input  wire [63:0] rd_data,
    input  wire        rd_valid,
    input  wire        rd_last,

    // gpu_mem 写口
    output reg         wr_valid,
    output reg  [31:0] wr_addr,
    output reg  [63:0] wr_data,
    output reg  [7:0]  wr_strb,
    input  wire        wr_ready,
    output reg         wr_flush,
    input  wire        wr_idle,

    output wire [7:0]  dbg_state
);

  localparam OP_CLEAR3D = 8'h10;
  localparam OP_DRAW3D  = 8'h11;
  localparam OP_COMP3D  = 8'h12;

  // ------------------------------------------------------------ CLEAR3D
  reg [15:0] cw, ch, cy, cx;
  reg [31:0] cbase, zbase, cur_base;
  reg [15:0] cstride, zstride, cur_stride;
  reg [15:0] color, zval;
  reg        phase;

  // ------------------------------------------------------------ DRAW
  reg [31:0] tri_addr, tri_cnt, tri_idx;
  reg [15:0] bw, bh, st_stride, st_stride_z;
  reg [31:0] base_c, base_z;

  reg [63:0] rec [0:5];
  reg [2:0]  rec_i;

  reg signed [31:0] rec_dzdx, rec_dzdy;
  reg [15:0] rec_z0, rec_color;
  reg [1:0]  rec_zmode;
  reg [31:0] rec_v0x, rec_v0y;

  reg  [31:0] v0x, v0y, v1x, v1y, v2x, v2y;
  reg         st_start;
  wire        st_done;
  wire signed [23:0] a0, b0, a1, b1, a2, b2;
  wire signed [47:0] c0w, c1w, c2w;
  wire [15:0] bx0, by0, bx1, by1;
  wire signed [47:0] area;
  wire        degen;

  tri_setup u_setup (
      .clk(clk), .rst(rst), .start(st_start),
      .v0x(v0x), .v0y(v0y), .v1x(v1x), .v1y(v1y), .v2x(v2x), .v2y(v2y),
      .wmax(bw), .hmax(bh),
      .busy(), .done(st_done),
      .a0(a0), .b0(b0), .a1(a1), .b1(b1), .a2(a2), .b2(b2),
      .c0(c0w), .c1(c1w), .c2(c2w),
      .bx0(bx0), .by0(by0), .bx1(bx1), .by1(by1),
      .area(area), .degen(degen)
  );

  // ---- tile 存储（32×32 像素 = 1024 项，按**像素下标 mod 4 交错**拆成 4 个小阵列）----
  //   ★ 2026-11-01：原来是一整块 `reg [15:0] ctile [0:1023]`，而**装载一拍要写 4 个连续项**
  //     ⇒ 综合报 `Sdm-2010: Not support multi-write simultaneously for RAM ctile/ztile`，
  //     两块 16 kbit 的阵列落成触发器 + 巨大读 mux（dev_map 实测 FF +36 k / LUT +18.8 k 的主项）。
  //   ★ 拆法：像素下标 i 存进 `ct{i[1:0]} [i[9:2]]`。于是
  //       · 装载一拍 4 个连续像素（i 是 4 的倍数，见 `bidx`/`rowbase`）⇒ **每个小阵列各写 1 项**
  //         ⇒ 每个阵列只有一个写口（光栅写与装载写本来就互斥，同在一个 always 里 if/else）；
  //       · 写回一拍读 4 个连续像素 ⇒ 每个小阵列各读 1 项；
  //       · 光栅的任意单点读/写 ⇒ 按 [1:0] 选阵列、[9:2] 取下标。
  //     读仍是**组合读**（光栅时序一格未变），可推断成分布式 RAM，不再吃 32 k 触发器。
  reg [15:0] ct0 [0:255], ct1 [0:255], ct2 [0:255], ct3 [0:255];
  reg [15:0] zt0 [0:255], zt1 [0:255], zt2 [0:255], zt3 [0:255];

  reg  [15:0] zr_idx;
  wire [15:0] ztile_rdata = (zr_idx[1:0] == 2'd0) ? zt0[zr_idx[9:2]] :
                            (zr_idx[1:0] == 2'd1) ? zt1[zr_idx[9:2]] :
                            (zr_idx[1:0] == 2'd2) ? zt2[zr_idx[9:2]] : zt3[zr_idx[9:2]];

  reg         ra_start;
  wire        ra_done;
  wire [17:0] z_raddr;
  wire        ra_we;
  wire [17:0] ra_waddr;
  wire [15:0] ra_wcolor, ra_wz;

  reg  [15:0] torg_x, torg_y;
  reg  [15:0] cx0_clip, cy0_clip, cx1_clip, cy1_clip;

  tri_raster u_raster (
      .clk(clk), .rst(rst), .start(ra_start),
      .a0(a0), .b0(b0), .a1(a1), .b1(b1), .a2(a2), .b2(b2),
      .c0(c0w), .c1(c1w), .c2(c2w),
      .bx0(cx0_clip), .by0(cy0_clip), .bx1(cx1_clip), .by1(cy1_clip),
      .stride(16'd32), .xorg(torg_x), .yorg(torg_y),
      .color(rec_color), .z0v(rec_z0),
      .dzdx(rec_dzdx[23:0]), .dzdy(rec_dzdy[23:0]),
      .vx0(rec_v0x[23:0]), .vy0(rec_v0y[23:0]),
      .zmode(rec_zmode),
      .busy(), .done(ra_done),
      .z_raddr(z_raddr), .z_rdata(ztile_rdata),
      .we(ra_we), .waddr(ra_waddr), .wcolor(ra_wcolor), .wz(ra_wz)
  );

  assign zr_idx = z_raddr[15:0];


  // ---- COMPOSITE3D ----
  reg [31:0] cp_src, cp_dst;
  reg [15:0] cp_ss, cp_ds, cp_w, cp_h, cp_dx, cp_dy;
  reg [15:0] crow, cchunk, cchunks;
  reg [3:0]  cbi;
  reg [63:0] cbuf [0:15];

  reg [15:0] tx, ty, tx_end, ty_end;
  reg [5:0]  trow;
  reg [2:0]  beat;
  reg        sw_last;      // 本行 8 拍已发完（beat==7 之后）

  // ------------------------------------------------------------ FSM
  localparam S_IDLE = 8'd0,
             S_CW   = 8'd1,  S_CWAIT = 8'd2,  S_FLUSH = 8'd3, S_DONE = 8'd4,
             S_DF   = 8'd10, S_DFW   = 8'd11,
             S_DL   = 8'd12, S_DS    = 8'd13,
             S_DT   = 8'd14,
             S_L1   = 8'd15, S_L1W   = 8'd16, S_L1E = 8'd17,
             S_L2   = 8'd18, S_L2W   = 8'd19, S_L2E = 8'd20,
             S_RA   = 8'd21, S_RAW   = 8'd22,
             S_S1   = 8'd23, S_S1W   = 8'd24, S_S1F = 8'd25,
             S_S2   = 8'd26, S_S2W   = 8'd27, S_S2F = 8'd28,
             S_C_ROW = 8'd30, S_C_RD = 8'd31, S_C_RDW = 8'd32,
             S_C_WR  = 8'd33, S_C_WRF = 8'd34, S_C_WRF2 = 8'd35;

  reg [7:0] st;
  reg       st_bad;        // 曾经落到 case 的 default（非法状态）—— 粘滞，只在复位时清
  // bit7 = 非法状态粘滞位（st 的合法值 ≤ 35，bit7 空着，不用额外端口）
  assign dbg_state = {st_bad, st[6:0]};

  wire [31:0] tri_off = tri_idx * 32'd48;
  wire [15:0] tx0px   = tx << 5;
  wire [15:0] ty0px   = ty << 5;
  wire [15:0] rowbase = {trow[4:0], 5'b0};
  // 交错阵列的下标：第 beat 拍的 4 个连续像素都在 `sidx` 这一项上（像素下标 >>2）
  wire [7:0]  sidx    = rowbase[9:2] + {5'd0, beat[2:0]};

  always @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; busy <= 1'b0; done <= 1'b0; phase <= 1'b0; st_bad <= 1'b0;
      rd_req <= 1'b0; rd_addr <= 32'd0; rd_beats <= 8'd0;
      wr_valid <= 1'b0; wr_addr <= 32'd0; wr_data <= 64'd0; wr_strb <= 8'd0; wr_flush <= 1'b0;
      cw <= 16'd0; ch <= 16'd0; cy <= 16'd0; cx <= 16'd0;
      cbase <= 32'd0; zbase <= 32'd0; cur_base <= 32'd0;
      cstride <= 16'd0; zstride <= 16'd0; cur_stride <= 16'd0;
      color <= 16'd0; zval <= 16'd0;
      tri_idx <= 32'd0; rec_i <= 3'd0; st_start <= 1'b0;
      tx <= 16'd0; ty <= 16'd0; tx_end <= 16'd0; ty_end <= 16'd0;
      trow <= 6'd0; beat <= 3'd0; sw_last <= 1'b0; ra_start <= 1'b0;
    end else begin
      done <= 1'b0;
      st_start <= 1'b0;
      case (st)
        // ======================= CLEAR3D =======================
        S_IDLE: if (start && op == OP_CLEAR3D) begin
          busy       <= 1'b1;
          color      <= p0[15:0];
          zval       <= p1[15:0];
          cw         <= p2[15:0];
          ch         <= p3[15:0];
          cbase      <= p4;
          cstride    <= p5[15:0];
          zbase      <= p6;
          zstride    <= p7[15:0];
          cur_base   <= p4;
          cur_stride <= p5[15:0];
          phase      <= 1'b0;
          cy         <= 16'd0;
          cx         <= 16'd0;
          st         <= S_CW;
        end else if (start && op == OP_DRAW3D) begin
          busy     <= 1'b1;
          tri_addr <= p0;
          tri_cnt  <= p1;
          bw       <= p2[15:0];
          bh       <= p3[15:0];
          base_c   <= p4;  st_stride   <= p5[15:0];
          base_z   <= p6;  st_stride_z <= p7[15:0];
          tri_idx  <= 32'd0;
          st       <= S_DF;
        end else if (start && op == OP_COMP3D) begin
          busy    <= 1'b1;
          cp_src  <= p0;  cp_ss <= p1[15:0];
          cp_dst  <= p2;  cp_ds <= p3[15:0];
          cp_w    <= p4[15:0];
          cp_h    <= p5[15:0];
          cp_dx   <= p6[15:0];
          cp_dy   <= p7[15:0];
          crow    <= 16'd0;
          cchunk  <= 16'd0;
          cchunks <= p4[15:6];        // w/64 个 16 字块（w 必须是 64 的倍数）
          st      <= S_C_ROW;
        end
        S_CW: if (cx < cw) begin
          wr_valid <= 1'b1;
          wr_addr  <= cur_base + (cy * cur_stride + cx) * 2;
          wr_data  <= {(phase ? zval : color), (phase ? zval : color),
                       (phase ? zval : color), (phase ? zval : color)};
          wr_strb  <= 8'hFF;
          st       <= S_CWAIT;
        end else if (cy + 16'd1 >= ch) begin
          wr_flush <= 1'b1;
          st       <= S_FLUSH;
        end else begin
          cy <= cy + 16'd1;
          cx <= 16'd0;
        end
        S_CWAIT: if (wr_ready) begin
          wr_valid <= 1'b0;
          cx <= cx + 16'd4;
          st <= S_CW;
        end
        S_FLUSH: if (wr_idle) begin
          wr_flush <= 1'b0;
          cy <= 16'd0;
          cx <= 16'd0;
          if (!phase) begin
            phase      <= 1'b1;
            cur_base   <= zbase;
            cur_stride <= zstride;
            st         <= S_CW;
          end else begin
            st <= S_DONE;
          end
        end
        S_DONE: begin
          busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
        end

        // ======================= DRAW_TRIS =======================
        S_DF: begin
          if (tri_idx >= tri_cnt) st <= S_DONE;
          else begin
            rd_req   <= 1'b1;
            rd_addr  <= tri_addr + tri_off;
            rd_beats <= 8'd5;
            rec_i    <= 3'd0;
            st       <= S_DFW;
          end
        end
        S_DFW: begin
          rd_req <= 1'b0;
          if (rd_valid) begin
            rec[rec_i] <= rd_data;
            rec_i <= rec_i + 3'd1;
            if (rd_last) st <= S_DL;
          end
        end
        S_DL: begin
          rec_v0x  <= rec[0][31:0];
          rec_v0y  <= rec[0][63:32];
          v0x <= rec[0][31:0]; v0y <= rec[0][63:32];
          v1x <= rec[1][31:0]; v1y <= rec[1][63:32];
          v2x <= rec[2][31:0]; v2y <= rec[2][63:32];
          rec_z0    <= rec[3][15:0];
          rec_color <= rec[3][31:16];
          rec_dzdx  <= rec[3][63:32];
          rec_dzdy  <= rec[4][31:0];
          rec_zmode <= rec[4][33:32];
          st_start  <= 1'b1;
          st        <= S_DS;
        end
        S_DS: if (st_done) st <= S_DT;
        S_DT: begin
          if (degen || (bx1 < bx0) || (by1 < by0)) begin
            tri_idx <= tri_idx + 32'd1;
            st <= S_DF;
          end else begin
            tx     <= {11'd0, bx0[15:5]};
            ty     <= {11'd0, by0[15:5]};
            tx_end <= {11'd0, bx1[15:5]};
            ty_end <= {11'd0, by1[15:5]};
            trow   <= 6'd0;
            beat   <= 3'd0;
            st     <= S_L1;
          end
        end
        // ---- 读颜色 tile 一行（8 拍 = 32 px）----
        S_L1: begin
          rd_req   <= 1'b1;
          rd_addr  <= base_c + ((ty0px + trow) * st_stride + tx0px) * 2;
          rd_beats <= 8'd7;
          beat     <= 3'd0;
          st       <= S_L1W;
        end
        S_L1W: begin
          rd_req <= 1'b0;
          if (rd_valid) begin
            beat <= beat + 3'd1;
            if (rd_last) st <= S_L1E;
          end
        end
        S_L1E: if (trow == 6'd31) begin trow <= 6'd0; beat <= 3'd0; st <= S_L2; end
               else begin trow <= trow + 6'd1; st <= S_L1; end
        // ---- 读 Z tile 一行 ----
        S_L2: begin
          rd_req   <= 1'b1;
          rd_addr  <= base_z + ((ty0px + trow) * st_stride_z + tx0px) * 2;
          rd_beats <= 8'd7;
          beat     <= 3'd0;
          st       <= S_L2W;
        end
        S_L2W: begin
          rd_req <= 1'b0;
          if (rd_valid) begin
            beat <= beat + 3'd1;
            if (rd_last) st <= S_L2E;
          end
        end
        S_L2E: if (trow == 6'd31) begin trow <= 6'd0; st <= S_RA; end
               else begin trow <= trow + 6'd1; st <= S_L2; end
        // ---- 光栅（写 tile BRAM）----
        S_RA: begin
          torg_x   <= tx0px;
          torg_y   <= ty0px;
          cx0_clip <= (bx0 < tx0px) ? tx0px : bx0;
          cy0_clip <= (by0 < ty0px) ? ty0px : by0;
          cx1_clip <= (bx1 > (tx0px + 16'd31)) ? (tx0px + 16'd31) : bx1;
          cy1_clip <= (by1 > (ty0px + 16'd31)) ? (ty0px + 16'd31) : by1;
          ra_start <= 1'b1;
          st       <= S_RAW;
        end
        S_RAW: begin
          ra_start <= 1'b0;
          if (ra_done) begin trow <= 6'd0; st <= S_S1; end
        end
        // ---- 写回颜色 tile 一行（8 拍 × 4 px = 32 px）----
        S_S1: if (!sw_last) begin
          wr_valid <= 1'b1;
          wr_addr  <= base_c + ((ty0px + trow) * st_stride + tx0px) * 2
                      + {26'd0, beat, 3'b000};
          wr_data  <= {ct3[sidx], ct2[sidx], ct1[sidx], ct0[sidx]};
          wr_strb  <= 8'hFF;
          st       <= S_S1W;
        end else begin
          wr_flush <= 1'b1;
          st       <= S_S1F;
        end
        // ★ 2026-11-01：`wr_valid` 必须**保持到 wr_ready**。原来只在 S_S1W 挂一拍就撤，
        //   若那一拍 wr_ready=0（写引擎正忙），这一拍数据就被静默丢掉 ⇒ 整行错位。
        //   gpu_mem 的 wr_ready 正常为高，所以板上只是偶发；但只要发生就是画错。
        S_S1W: if (wr_ready) begin
          wr_valid <= 1'b0;
          beat     <= beat + 3'd1;
          if (beat == 3'd7) sw_last <= 1'b1;
          st       <= S_S1;
        end
        S_S1F: if (wr_idle) begin
          wr_flush <= 1'b0;
          beat     <= 3'd0;
          sw_last  <= 1'b0;
          if (trow == 6'd31) begin trow <= 6'd0; st <= S_S2; end
          else begin trow <= trow + 6'd1; st <= S_S1; end
        end
        // ---- 写回 Z tile 一行 ----
        S_S2: if (!sw_last) begin
          wr_valid <= 1'b1;
          wr_addr  <= base_z + ((ty0px + trow) * st_stride_z + tx0px) * 2
                      + {26'd0, beat, 3'b000};
          wr_data  <= {zt3[sidx], zt2[sidx], zt1[sidx], zt0[sidx]};
          wr_strb  <= 8'hFF;
          st       <= S_S2W;
        end else begin
          wr_flush <= 1'b1;
          st       <= S_S2F;
        end
        S_S2W: if (wr_ready) begin
          wr_valid <= 1'b0;
          beat     <= beat + 3'd1;
          if (beat == 3'd7) sw_last <= 1'b1;
          st       <= S_S2;
        end
        S_S2F: if (wr_idle) begin
          wr_flush <= 1'b0;
          beat     <= 3'd0;
          sw_last  <= 1'b0;
          if (trow != 6'd31) begin
            trow <= trow + 6'd1;
            st   <= S_S2;
          end else begin
            trow <= 6'd0;
            if ((tx == tx_end) && (ty == ty_end)) begin
              tri_idx <= tri_idx + 32'd1;
              st <= S_DF;
            end else if (tx == tx_end) begin
              tx <= {11'd0, bx0[15:5]};
              ty <= ty + 16'd1;
              st <= S_L1;
            end else begin
              tx <= tx + 16'd1;
              st <= S_L1;
            end
          end
        end
        // ======================= COMPOSITE3D =======================
        // 每块 64 px = 128 B = 16 字：读满 16 拍 → 写回 16 字 → flush
        S_C_ROW: begin
          if (crow >= cp_h) st <= S_DONE;
          else begin
            cchunk <= 16'd0;
            cbi    <= 4'd0;
            st     <= S_C_RD;
          end
        end
        S_C_RD: begin
          rd_req   <= 1'b1;
          rd_addr  <= cp_src + ((crow * cp_ss) + (cchunk << 6)) * 2;
          rd_beats <= 8'd15;
          cbi      <= 4'd0;
          st       <= S_C_RDW;
        end
        S_C_RDW: begin
          rd_req <= 1'b0;
          if (rd_valid) begin
            cbuf[cbi] <= rd_data;
            cbi <= cbi + 4'd1;
            if (rd_last) begin cbi <= 4'd0; st <= S_C_WR; end
          end
        end
        S_C_WR: begin
          wr_valid <= 1'b1;
          wr_addr  <= cp_dst + (((cp_dy + crow) * cp_ds) + cp_dx + (cchunk << 6)) * 2
                      + {27'd0, cbi, 3'b000};
          wr_data  <= cbuf[cbi];
          wr_strb  <= 8'hFF;
          st       <= S_C_WRF;
        end
        // ★ 2026-11-01：同 S_S1W —— `wr_valid` 必须保持到 `wr_ready`。原来这里无条件撤，
        //   而 cbi 只有 wr_ready 为高才前进 ⇒ backpressure 时那一拍**静默丢失**，
        //   复合目标上就留下哨兵值（背压闸门实测抓到的就是这个）。
        S_C_WRF: if (wr_ready) begin
          wr_valid <= 1'b0;
          cbi <= cbi + 4'd1;
          if (cbi == 4'd15) begin
            wr_flush <= 1'b1;
            cbi      <= 4'd0;
            st       <= S_C_WRF2;
          end else st <= S_C_WR;
        end
        S_C_WRF2: if (wr_idle) begin
          wr_flush <= 1'b0;
          if (cchunk + 16'd1 >= cchunks) begin
            crow <= crow + 16'd1;
            st   <= S_C_ROW;
          end else begin
            cchunk <= cchunk + 16'd1;
            st     <= S_C_RD;
          end
        end
        default: begin st_bad <= 1'b1; st <= S_DONE; end   // 同 tri_raster：非法状态也要把命令收尾
      endcase

      // ---- tile 阵列的唯一写口 ----
      //   光栅写（ra_we，任意单点）与 tile 装载写（S_L1W/S_L2W 收数，一拍 4 连续项）**必须在
      //   同一个 always 块**：分成两个 clocked 块会被综合判 DRC-1021 多驱动（gpu3d0 compile 就是这么挂的）。
      //   两者在状态上互斥（装载时不在光栅），所以这里按 if/else 串起来安全。
      //   ★ 交错拆阵列后：装载一拍 = 4 个小阵列各 1 项 ⇒ 每个阵列只有**一个写口**（可推断 RAM）。
      if (ra_we) begin
        case (ra_waddr[1:0])
          2'd0: begin ct0[ra_waddr[9:2]] <= ra_wcolor; zt0[ra_waddr[9:2]] <= ra_wz; end
          2'd1: begin ct1[ra_waddr[9:2]] <= ra_wcolor; zt1[ra_waddr[9:2]] <= ra_wz; end
          2'd2: begin ct2[ra_waddr[9:2]] <= ra_wcolor; zt2[ra_waddr[9:2]] <= ra_wz; end
          default: begin ct3[ra_waddr[9:2]] <= ra_wcolor; zt3[ra_waddr[9:2]] <= ra_wz; end
        endcase
      end else if (st == S_L1W && rd_valid) begin
        ct0[sidx] <= rd_data[15:0];
        ct1[sidx] <= rd_data[31:16];
        ct2[sidx] <= rd_data[47:32];
        ct3[sidx] <= rd_data[63:48];
      end else if (st == S_L2W && rd_valid) begin
        zt0[sidx] <= rd_data[15:0];
        zt1[sidx] <= rd_data[31:16];
        zt2[sidx] <= rd_data[47:32];
        zt3[sidx] <= rd_data[63:48];
      end
    end
  end

endmodule
