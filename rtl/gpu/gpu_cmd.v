// gpu_cmd.v —— 16 项命令 FIFO + 命令字解包（spec §4）。
//
// 命令字 = {op[7:0], nwords[7:0], flags[15:0]}；nwords 不含头。
// 软件：普通字写 CMD_DATA；一条命令的最后一个字写 CMD_PUSH。
//
// 关键语义：**执行从完整命令到达后才开始**。两条 FIFO：
//   · 字 FIFO（16 x 32）：所有命令字按序存放；
//   · 长度 FIFO（16 x 5）：某条命令的最后一个字写进字 FIFO 时，记下它的总字数（1+nwords）。
// 读侧只从长度 FIFO 取命令；取一条 = 弹头字（发 cmd_start）+ 流 (len-1) 个参数。
//
// 指针纪律：pop 用**组合**信号（pop_now），同拍推进 rptr —— 否则头字会在 S_PAR 里
// 再被当一次参数（2026-10-31 实测踩过）。
//
// 执行侧协议：cmd_start（一拍，带 op/flags/nwords）→ 参数流（par_valid/par_ready）→ 等 cmd_done。
// FENCE 特例：唯一参数是 seq，参数消费完把 seq 写进 SEQ_DONE。
module gpu_cmd (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] wr_word,
    input  wire        wr_en,
    input  wire        wr_push,

    output wire [4:0]  used,
    output wire        busy,

    output reg         cmd_start,
    output reg  [7:0]  cmd_op,
    output reg  [7:0]  cmd_nwords,
    output reg  [15:0] cmd_flags,
    output wire [31:0] par_data,
    output reg         par_valid,
    input  wire        par_ready,
    input  wire        cmd_done,

    output reg  [15:0] seq_done,
    output reg  [7:0]  last_op,
    output reg  [15:0] last_cycles,

    output wire [2:0]  dbg_state,
    output wire [7:0]  dbg_left
);

  localparam DEPTH = 16;
  localparam S_IDLE = 3'd0, S_START = 3'd1, S_PAR = 3'd2, S_DONE = 3'd3;

  reg [31:0] mem  [0:DEPTH-1];
  reg [4:0]  lmem [0:DEPTH-1];

  reg [3:0]  wptr, rptr, lwptr, lrptr;
  reg [4:0]  cnt, lcnt;
  reg [31:0] cyc;

  reg [2:0]  state;
  reg [7:0]  left;         // 剩余参数
  reg [15:0] t0;
  reg        is_fence;
  reg [15:0] fence_seq;

  // ---------------- 写侧组包 ----------------
  reg       assembling;
  reg [7:0] left_w;
  reg [4:0] len_w;

  wire [7:0] hdr_nw   = wr_word[23:16];
  wire       wr_ok    = wr_en && (cnt != DEPTH[4:0]);
  wire       done_now = wr_ok && (assembling ? (left_w == 8'd1) : (hdr_nw == 8'd0));
  wire [4:0] len_next = len_w + 5'd1;   // len_w 只数**已收到**的字（头=1）

  // ---------------- 读侧 pop（组合） ----------------
  wire [31:0] head     = mem[rptr];
  assign par_data = head;   // 组合：握手那拍必须给出当前 head（寄存器会晚一拍）
  wire [4:0]  next_len = lmem[lrptr];

  wire pop_idle = (state == S_IDLE) && (lcnt != 5'd0);
  // 必须同时有 par_valid：S_PAR 的第一拍 par_valid 还是 0（寄存器），此时若消费者
  // 已经给 ready（如单元 TB 恒 1），只按 ready 弹栈会**吞掉第一个参数**。
  wire pop_par  = (state == S_PAR) && (left != 8'd0) && par_valid && par_ready;
  wire pop_now  = pop_idle || pop_par;

  assign used = cnt;
  assign dbg_state = state;
  assign dbg_left = left;
  assign busy = (cnt != 5'd0) || (lcnt != 5'd0) || (state != S_IDLE);

  always @(posedge clk) begin
    if (rst) begin
      wptr <= 4'd0; rptr <= 4'd0; lwptr <= 4'd0; lrptr <= 4'd0;
      cnt  <= 5'd0; lcnt <= 5'd0; cyc <= 32'd0;
      assembling <= 1'b0; left_w <= 8'd0; len_w <= 5'd0;
    end else begin
      cyc <= cyc + 32'd1;

      // ---- 字 FIFO ----
      if (wr_ok) begin
        mem[wptr] <= wr_word;
        wptr      <= wptr + 4'd1;
        if (done_now) begin
          lmem[lwptr] <= len_next;
          lwptr       <= lwptr + 4'd1;
          assembling  <= 1'b0;
          left_w      <= 8'd0;
          len_w       <= 5'd0;
        end else if (!assembling) begin
          assembling <= 1'b1;
          left_w     <= hdr_nw;
          len_w      <= 5'd1;
        end else begin
          left_w <= left_w - 8'd1;
          len_w  <= len_next;
        end
      end
      if (pop_now) rptr <= rptr + 4'd1;

      case ({wr_ok, pop_now})
        2'b10:   cnt <= cnt + 5'd1;
        2'b01:   cnt <= cnt - 5'd1;
        default: ;
      endcase

      // ---- 长度 FIFO ----
      if (pop_idle) lrptr <= lrptr + 4'd1;
      case ({done_now, pop_idle})
        2'b10:   lcnt <= lcnt + 5'd1;
        2'b01:   lcnt <= lcnt - 5'd1;
        default: ;
      endcase
    end
  end

  // ---------------- 读侧解包 FSM ----------------
  always @(posedge clk) begin
    if (rst) begin
      state     <= S_IDLE;
      cmd_start <= 1'b0;
      par_valid <= 1'b0;
      left      <= 8'd0;
      seq_done  <= 16'd0;
      last_op   <= 8'd0;
      last_cycles <= 16'd0;
    end else begin
      cmd_start <= 1'b0;
      par_valid <= 1'b0;

      case (state)
        S_IDLE: if (pop_idle) begin
          cmd_op     <= head[31:24];
          cmd_nwords <= head[23:16];
          cmd_flags  <= head[15:0];
          is_fence   <= (head[31:24] == 8'h07);
          left       <= next_len - 5'd1;
          t0         <= cyc[15:0];
          cmd_start  <= 1'b1;
          state      <= (next_len == 5'd1) ? S_DONE : S_PAR;
        end

        S_PAR: if (left != 8'd0) begin
          par_valid <= 1'b1;
          if (par_valid && par_ready) begin
            left <= left - 8'd1;
            if (is_fence) fence_seq <= head[15:0];
            if (left == 8'd1) begin
              // 最后一个参数握手后立刻撤 valid：否则 S_DONE 第一拍还挂着 valid，
              // 消费者看到 valid&ready 会多收一个（单元 TB 实测 6 个参数）
              par_valid <= 1'b0;
              state     <= S_DONE;
            end
          end
        end

        S_DONE: begin
          // ★ FENCE 的 seq_done 必须等 cmd_done（引擎把写回也排空）才发布：
          //   原来无条件 `if (is_fence) seq_done <= fence_seq;` ⇒ 引擎还在画就报完成，
          //   软件读到半成品（板上 gputest 首行只有前 8 px 落地即此因）。
          if (cmd_done) begin
            last_op     <= cmd_op;
            last_cycles <= cyc[15:0] - t0;
            if (is_fence) seq_done <= fence_seq;
            else          seq_done <= seq_done + 16'd1;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
