// =============================================================================
// BootSelTb.v -- 上电计划选择器（BootSel）单元闸门
//
// DUT：从 rtl/YeshenSocGlue.v 切出的 module BootSel（真网表）。
// 判据：
//   1) 提示串由**离线解码**核对（本装置把 io_txd 的每次跳变写进 bootsel_txd.log，
//      run_bootsel_ab.sh 用位周期 8680ns 解码，断言 4 次提示都 == 期望串）；
//   2) 发 'C' -> sel=1；发 'L' -> sel=0；发 'Z' -> 忽略、超时 sel=0；
//   3) 无字节 -> 超时 sel=0，且 elapsed >= TIMEOUT；
//   4) 负对照由闸门脚本做（io_sel 强制 0 的突变网表必须红）。
// io_timeout = 400_000 拍（4ms），大于提示串（28B x 10bit x 868 ~ 243k），远小于板级 100M（1s）。
// =============================================================================
`timescale 1ns/1ps
module BootSelTb;
  localparam integer BIT = 868;            // 115200 @100MHz
  localparam integer TIMEOUT = 400000;

  reg clock = 0;
  reg reset = 1;
  reg io_active = 0;
  reg io_rxd = 1;
  reg [31:0] io_timeout = TIMEOUT;
  wire io_sel, io_owner, io_txd, io_lineFree;

  BootSel dut (
    .clock(clock), .reset(reset),
    .io_active(io_active), .io_timeout(io_timeout), .io_rxd(io_rxd),
    .io_sel(io_sel), .io_owner(io_owner), .io_txd(io_txd), .io_lineFree(io_lineFree)
  );

  always #5 clock = ~clock;

  integer fails = 0;
  integer cyc = 0;
  always @(posedge clock) cyc = cyc + 1;

  // ---- TX 跳变记录（离线解码用）----
  integer txf;
  initial txf = $fopen("bootsel_txd.log", "w");
  always @(io_txd) if (txf) $fwrite(txf, "%0t %b\n", $time, io_txd);
  final begin if (txf) $fclose(txf); end

  // ---------------- 115200 8N1 发送（位周期 BIT 拍）----------------
  task automatic send_byte(input [7:0] b);
    integer i;
    begin
      io_rxd = 0;
      repeat (BIT) @(posedge clock);
      for (i = 0; i < 8; i = i + 1) begin
        io_rxd = b[i];
        repeat (BIT) @(posedge clock);
      end
      io_rxd = 1;
      repeat (BIT) @(posedge clock);
    end
  endtask

  integer t0, elapsed, sel_got, guard;
  task automatic start_case;
    begin
      reset = 1; io_active = 0; io_rxd = 1;
      repeat (5) @(posedge clock);
      reset = 0; io_active = 1;
      #1;
    end
  endtask

  task automatic run_case(input [7:0] sel_byte, input do_send,
                          output integer sel_out, output integer elapsed_out);
    begin
      start_case;
      t0 = cyc;
      if (io_owner !== 1) begin $display("TBFAIL: owner should be 1 during window"); fails = fails + 1; end
      if (do_send) send_byte(sel_byte);
      guard = 0;
      while (!io_lineFree) begin
        @(posedge clock);
        guard = guard + 1;
        if (guard > 2*TIMEOUT) begin
          $display("TBFAIL: lineFree never asserted"); fails = fails + 1; break;
        end
      end
      elapsed_out = cyc - t0;
      sel_out = io_sel;
      if (io_owner !== 0) begin $display("TBFAIL: owner still 1 after lineFree"); fails = fails + 1; end
    end
  endtask

  // ===================== 用例 =====================
  initial begin
    $display("=== BootSel unit gate (BIT=%0d, TIMEOUT=%0d) ===", BIT, TIMEOUT);

    // ---- case 1: 无输入 -> 超时默认 Linux ----
    run_case(8'h00, 0, sel_got, elapsed);
    if (sel_got !== 0) begin $display("TBFAIL: timeout sel=%0d (want 0)", sel_got); fails = fails + 1; end
    if (elapsed < TIMEOUT) begin $display("TBFAIL: timeout happened too early (%0d < %0d)", elapsed, TIMEOUT); fails = fails + 1; end
    $display("CASE timeout: sel=%0d elapsed=%0d", sel_got, elapsed);

    // ---- case 2: 发 'C' -> CoreMark ----
    run_case("C", 1, sel_got, elapsed);
    if (sel_got !== 1) begin $display("TBFAIL: 'C' sel=%0d (want 1)", sel_got); fails = fails + 1; end
    if (elapsed >= TIMEOUT) begin $display("TBFAIL: 'C' did not shorten the window (%0d)", elapsed); fails = fails + 1; end
    $display("CASE C: sel=%0d elapsed=%0d", sel_got, elapsed);

    // ---- case 3: 发 'L' -> Linux ----
    run_case("L", 1, sel_got, elapsed);
    if (sel_got !== 0) begin $display("TBFAIL: 'L' sel=%0d (want 0)", sel_got); fails = fails + 1; end
    $display("CASE L: sel=%0d elapsed=%0d", sel_got, elapsed);

    // ---- case 4: 发 'Z' -> 忽略、超时默认 ----
    run_case("Z", 1, sel_got, elapsed);
    if (sel_got !== 0) begin $display("TBFAIL: 'Z' sel=%0d (want 0)", sel_got); fails = fails + 1; end
    if (elapsed < TIMEOUT) begin $display("TBFAIL: 'Z' shortened the window (%0d)", elapsed); fails = fails + 1; end
    $display("CASE Z: sel=%0d elapsed=%0d", sel_got, elapsed);

    if (fails == 0) $display("RESULT: PASS");
    else            $display("RESULT: FAIL fails=%0d", fails);
    $finish;
  end
endmodule
