# 双目相机切换（CAM0/CAM1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 J10 双目模组的第二颗镜头（CAM1）可用，并能用 KEY2 按键或 `VIDEO` 窗寄存器在 CAM0/CAM1 之间切换；切换在整帧边界重启、事件驱动黑屏、DDR 不落撕裂帧；不按键时行为与现交付逐位一致。

**Architecture:** 两套 vendor `camera.v` 常开（各自 SCCB/复位）；新模块 `cam_switch.v` 负责"sel 跨域同步 + 无毛刺像素时钟 mux + 数据/href/vsync mux + `sw_rst` + 掐写 + 黑屏状态机"；`video_regs` 加 `0x00C CAM_CTRL` 作为唯一真源；KEY2 经 `key_toggle.v` 消抖后翻转同一位。

**Tech Stack:** Verilog-2001/2012（iverilog `-g2012` 仿真）、Pango PDS（dev_map / PnR）、Python 3（host 脚本）、板内 Linux 用户态（`devmem` / y1cam）。

**Spec:** `docs/superpowers/specs/2026-10-27-camera-switch-design.md`

---

## 文件结构（先锁边界，再谈任务）

| 文件 | 职责 | 新建/修改 |
|---|---|---|
| `board/cam/cam_switch.v` | 双目切换的全部时序与 mux（4 个时钟域：clk0/clk1/soc_clk/pix_clk/ddr_clk/lcd_clk） | 新建 |
| `board/cam/key_toggle.v` | KEY 消抖 + 单次脉冲（soc_clk） | 新建 |
| `board/cam/video_passthrough.v` | 接线：第二份 `camera.v`、`cam_switch` 实例、写侧门、输出级黑屏 | 修改 |
| `board/cam/video_regs.v` | `0x00C CAM_CTRL`（RW sel / RO ready / RO busy） | 修改 |
| `board/yeshen_mini_board_top.v` | 新端口（cam1 七组 + key2）+ 连线 | 修改 |
| `constraints/yeshen_mini.fdc` | cam1 14 球 + key2 + clk1 时钟 | 修改 |
| `sim/video/tb_cam_switch.v` | `cam_switch` 独立 TB（切换/毛刺/掐写/黑屏） | 新建 |
| `sim/video/tb_key_toggle.v` | `key_toggle` 独立 TB | 新建 |
| `sim/video/tb_video_regs.v` | 加 `CAM_CTRL` 读写用例 | 修改 |
| `sim/video/tb_video_path.v` | 补 cam1 端口 tie-off（不改判据） | 修改 |
| `sim/video/run_video_gates.sh` | 加 U5/U6 两档 + 负对照 | 修改 |

**判据约定（与仓里既有 `run_*_ab.sh` 一致）：** 每档必须打印 `RESULT: PASS`；负对照必须**发火**；退出码 0/1/2/3 = 通过/被测红/闸门自身不可信/前置缺失。

---

### Task 1: `cam_switch.v` 的时钟/数据 mux（先红后绿）

**Files:**
- Create: `board/cam/cam_switch.v`
- Test: `sim/video/tb_cam_switch.v`
- Modify: `sim/video/run_video_gates.sh`（新增 U5 档）

- [ ] **Step 1: 写会失败的 TB（mux + 毛刺判据）**

创建 `sim/video/tb_cam_switch.v`：

```verilog
//=============================================================================
// tb_cam_switch: cam_switch 的独立闸门（U5）
//   ① 切源瞬间 cam_clk 不出现窄脉冲（最小脉宽 >= 9 ns；clk0 半周期 10 ns）
//   ② cam_d/href/vs 跟随 sel（两路给不同图案）
//   ③ sw_rst 宽度 = SW_RST_CYC 个 soc 拍
//   ④ 掐写：sel 变化后 wr_ok 立即为 0，直到 ready & 首个 frame_sof
//   ⑤ 黑屏：sel 变化后 black=1，直到 ready & frames_ok & settle 到
//=============================================================================
`timescale 1ns/1ps
module tb_cam_switch;
    localparam integer SW_RST_CYC  = 20;   // 仿真缩放（真实 100000）
    localparam integer SETTLE_CYC  = 200;  // 仿真缩放（真实 40000000）
    localparam integer FRAMES_NEED = 2;

    reg clk0 = 0, clk1 = 0, soc_clk = 0, ddr_clk = 0, lcd_clk = 0;
    always #10.0   clk0    = ~clk0;     // 50 MHz
    always #13.33  clk1    = ~clk1;     // 37.5 MHz（与 clk0 非整数比）
    always #5.0    soc_clk = ~soc_clk;  // 100 MHz
    always #4.0    ddr_clk = ~ddr_clk;  // 125 MHz
    always #9.63   lcd_clk = ~lcd_clk;  // 51.9 MHz

    reg soc_rstn = 0, lcd_rstn = 0, ddr_rstn = 0;

    reg [7:0] d0 = 8'hA5, d1 = 8'h5A;
    reg href0 = 0, vs0 = 0, href1 = 0, vs1 = 0;
    reg init_done_0 = 0, init_done_1 = 0;
    reg sel = 0;

    wire        cam_clk, cam_href, cam_vs, cam_rstn;
    wire [7:0]  cam_d;
    wire        ready, switch_busy, wr_ok, black;

    // 像素钟 = cam_clk/2（与 cmos_8_16bit 内部一致）
    reg pix_clk = 0;
    always @(posedge cam_clk) pix_clk <= ~pix_clk;

    reg pix_rstn = 0;
    reg frame_sof = 0, frame_start = 0;

    cam_switch #(
        .SW_RST_CYC(SW_RST_CYC), .SETTLE_CYC(SETTLE_CYC), .FRAMES_NEED(FRAMES_NEED)
    ) dut (
        .clk0(clk0), .raw_d0(d0), .raw_href0(href0), .raw_vs0(vs0), .init_done_0(init_done_0),
        .clk1(clk1), .raw_d1(d1), .raw_href1(href1), .raw_vs1(vs1), .init_done_1(init_done_1),
        .soc_clk(soc_clk), .soc_rstn(soc_rstn), .sel(sel),
        .ready(ready), .switch_busy(switch_busy),
        .cam_clk(cam_clk), .cam_d(cam_d), .cam_href(cam_href), .cam_vs(cam_vs), .cam_rstn(cam_rstn),
        .pix_clk(pix_clk), .pix_rstn(pix_rstn), .frame_sof(frame_sof), .wr_ok(wr_ok),
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn), .frame_start(frame_start),
        .lcd_clk(lcd_clk), .lcd_rstn(lcd_rstn), .black(black)
    );

    // ---- 毛刺监控：cam_clk 的高/低脉宽最小值 ----
    realtime t_rise = 0, t_fall = 0;
    realtime min_hi = 1.0e9, min_lo = 1.0e9;
    always @(posedge cam_clk) begin t_rise = $realtime; if (t_fall > 0) begin
        if (($realtime - t_fall) < min_lo) min_lo = $realtime - t_fall; end end
    always @(negedge cam_clk) begin t_fall = $realtime; if (t_rise > 0) begin
        if (($realtime - t_rise) < min_hi) min_hi = $realtime - t_rise; end end

    integer errs = 0;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin $display("TBFAIL %0s", msg); errs = errs + 1; end end
    endtask

    integer i;
    initial begin
        // 上电
        repeat (4) @(posedge soc_clk);
        soc_rstn = 1; lcd_rstn = 1; ddr_rstn = 1;
        init_done_0 = 1;
        repeat (4) @(posedge soc_clk);
        pix_rstn = 1;

        // 制造若干帧，让黑屏能放行
        for (i = 0; i < 6; i = i + 1) begin
            @(posedge pix_clk); frame_sof = 1; @(posedge pix_clk); frame_sof = 0;
            repeat (3) @(posedge ddr_clk); frame_start = 1;
            @(posedge ddr_clk); frame_start = 0;
            repeat (5) @(posedge lcd_clk);
        end
        repeat (SETTLE_CYC + 40) @(posedge soc_clk);
        chk(black === 1'b0, "power-up: black 未在 ready+frames+settle 后放行");

        // ---- 切到 cam1（未 init_done）----
        @(posedge soc_clk); sel = 1;
        repeat (4) @(posedge soc_clk);
        chk(black === 1'b1, "切换后 black 未立即拉高");
        chk(cam_rstn === 1'b0, "cam1 未 init_done 时 cam_rstn 应为 0");
        repeat (SW_RST_CYC + 8) @(posedge soc_clk);
        chk(wr_ok === 1'b0, "切换期 wr_ok 应为 0（掐写）");

        // cam1 初始化完成 -> 数据应跟着 sel 走
        init_done_1 = 1;
        repeat (SW_RST_CYC + 8) @(posedge soc_clk);
        chk(cam_rstn === 1'b1, "cam1 init_done 且 sw_rst 结束后 cam_rstn 应为 1");
        repeat (4) @(posedge clk1);
        chk(cam_d === d1, "切到 cam1 后 cam_d 未跟随");

        // 给足帧 + settle -> 放行
        for (i = 0; i < 6; i = i + 1) begin
            @(posedge pix_clk); frame_sof = 1; @(posedge pix_clk); frame_sof = 0;
            repeat (3) @(posedge ddr_clk); frame_start = 1;
            @(posedge ddr_clk); frame_start = 0;
            repeat (5) @(posedge lcd_clk);
        end
        repeat (SETTLE_CYC + 40) @(posedge soc_clk);
        chk(black === 1'b0, "切到 cam1 后 black 未放行");
        chk(wr_ok === 1'b1, "切到 cam1 后 wr_ok 未恢复");

        // 切回 cam0
        @(posedge soc_clk); sel = 0;
        repeat (SW_RST_CYC + 8) @(posedge soc_clk);
        repeat (4) @(posedge clk0);
        chk(cam_d === d0, "切回 cam0 后 cam_d 未跟随");

        // 毛刺判据（最后查，覆盖整段运行）
        chk(min_hi > 9.0, "cam_clk 出现窄高脉冲（毛刺）");
        chk(min_lo > 9.0, "cam_clk 出现窄低脉冲（毛刺）");

        if (errs == 0) $display("RESULT: PASS");
        else begin $display("RESULT: FAIL errs=%0d", errs); end
        $finish;
    end

    initial begin
        #2000000;
        $display("TBFAIL 超时");
        $display("RESULT: FAIL");
        $finish;
    end
endmodule
```

- [ ] **Step 2: 跑一次确认是红的（模块还不存在）**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u5.vvp tb_cam_switch.v ../..//board/cam/cam_switch.v
```

Expected: `error: Unknown module type: cam_switch`（红灯，证明 TB 真的在要这个模块）

- [ ] **Step 3: 写 `cam_switch.v`（完整实现）**

创建 `board/cam/cam_switch.v`：

```verilog
//=============================================================================
// cam_switch: 双目相机切换的全部时序（mux + 复位 + 掐写 + 黑屏）
//
// 时钟域（一次切换要穿过它们，全部列清楚）：
//   clk0 / clk1 : 各相机的 PCLK（板外振荡器，频率可不同、互不相关）
//   soc_clk     : 100 MHz，控制域（sel / 定时器 / switch_busy）
//   pix_clk     : cam_clk ÷ 2（cmos_8_16bit 的输出像素钟）→ wr_ok
//   ddr_clk     : 125 MHz，数"切换后写了几个完整帧" → frames_ok
//   lcd_clk     : 51.9 MHz，输出级黑屏
//
// 三条承重规则（别"顺手改"）：
//   ① sel 在各自 PCLK 域 2FF 后，**只在下降沿**更新门控 ⇒ cam_clk 换源时不产生窄脉冲：
//        cam_clk = (clk0 & en0) | (clk1 & en1)
//   ② cam_rstn = 所选 init_done & ~sw_rst ⇒ SCCB 没配完不让采集级出数据；
//      释放后由 cmos_8_16bit 自己等新相机第一个 VS 再起（整帧边界）。
//   ③ 切换期把 wr_ok 拉 0（上层用它同时门控 wr_en 与 wr_fsync）：
//      没有 fsync 就不会有 bank 翻转 ⇒ DDR 里不会出现"被当成完整帧"的半帧。
//=============================================================================
module cam_switch #(
    parameter integer SW_RST_CYC  = 100000,      // 1 ms @100 MHz
    parameter integer SETTLE_CYC  = 40000000,    // 400 ms @100 MHz
    parameter integer FRAMES_NEED = 2
)(
    // ---- 相机 0（PCLK 域）----
    input  wire        clk0,
    input  wire [7:0]  raw_d0,
    input  wire        raw_href0,
    input  wire        raw_vs0,
    input  wire        init_done_0,
    // ---- 相机 1（PCLK 域）----
    input  wire        clk1,
    input  wire [7:0]  raw_d1,
    input  wire        raw_href1,
    input  wire        raw_vs1,
    input  wire        init_done_1,
    // ---- 控制（soc_clk）----
    input  wire        soc_clk,
    input  wire        soc_rstn,
    input  wire        sel,           // 0 = cam0
    output wire        ready,         // 所选相机的 init_done
    output wire        switch_busy,   // 黑屏或 sw_rst 期间为 1
    // ---- 输出给 cmos_8_16bit ----
    output wire        cam_clk,
    output wire [7:0]  cam_d,
    output wire        cam_href,
    output wire        cam_vs,
    output wire        cam_rstn,
    output wire        sw_rst,
    // ---- 像素域 ----
    input  wire        pix_clk,
    input  wire        pix_rstn,      // = cam_rstn（异步、低有效）
    input  wire        frame_sof,     // 裁列后包络的帧起脉冲（pix_clk 域）
    output wire        wr_ok,         // 0 = 掐写
    // ---- DDR 帧事件 ----
    input  wire        ddr_clk,
    input  wire        ddr_rstn,
    input  wire        frame_start,   // 每帧一次（ddr_clk 域）
    // ---- 显示 ----
    input  wire        lcd_clk,
    input  wire        lcd_rstn,
    output wire        black         // 1 = 黑屏
);

    //-------------------------------------------------------------------------
    // ① sel 同步 + 下降沿门控（无毛刺时钟 mux）
    //-------------------------------------------------------------------------
    reg s0a = 1'b0, s0b = 1'b0;
    always @(posedge clk0) begin s0a <= sel; s0b <= s0a; end
    reg s1a = 1'b0, s1b = 1'b0;
    always @(posedge clk1) begin s1a <= sel; s1b <= s1a; end

    reg en0 = 1'b0, en1 = 1'b0;
    always @(negedge clk0) en0 <= ~s0b;
    always @(negedge clk1) en1 <=  s1b;

    assign cam_clk = (clk0 & en0) | (clk1 & en1);

    //-------------------------------------------------------------------------
    // 数据：各自 PCLK 负边沿采样（传感器在上升沿发数据，下降沿采在眼图中间）
    //   不复位：只在 cam_rstn=1 的帧里才有意义
    //-------------------------------------------------------------------------
    reg [7:0] d0q; reg h0q, v0q;
    always @(negedge clk0) begin d0q <= raw_d0; h0q <= raw_href0; v0q <= raw_vs0; end
    reg [7:0] d1q; reg h1q, v1q;
    always @(negedge clk1) begin d1q <= raw_d1; h1q <= raw_href1; v1q <= raw_vs1; end

    assign cam_d    = s0b ? d1q : d0q;
    assign cam_href = s0b ? h1q : h0q;
    assign cam_vs   = s0b ? v1q : v0q;

    //-------------------------------------------------------------------------
    // ② soc 域：init_done 2FF / sel 边沿 / sw_rst
    //-------------------------------------------------------------------------
    reg id0a, id0b, id1a, id1b;
    always @(posedge soc_clk) begin
        id0a <= init_done_0; id0b <= id0a;
        id1a <= init_done_1; id1b <= id1a;
    end
    assign ready = sel ? id1b : id0b;

    reg        sel_d = 1'b0;
    reg [31:0] sw_cnt = 32'd0;
    reg        sw_rst_r = 1'b0;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin
            sel_d <= 1'b0; sw_cnt <= 32'd0; sw_rst_r <= 1'b0;
        end else begin
            sel_d <= sel;
            if (sel != sel_d) begin
                sw_cnt <= SW_RST_CYC;
                sw_rst_r <= 1'b1;
            end else if (sw_cnt != 32'd0) begin
                sw_cnt <= sw_cnt - 32'd1;
                sw_rst_r <= 1'b1;
            end else begin
                sw_rst_r <= 1'b0;
            end
        end
    end
    assign sw_rst  = sw_rst_r;
    assign cam_rstn = ready & ~sw_rst_r;

    //-------------------------------------------------------------------------
    // ③ pix 域：wr_ok —— ready&~sw_rst 之后、再过第一个 frame_sof 才放行
    //-------------------------------------------------------------------------
    reg g0, g1, wr_ok_r;
    always @(posedge pix_clk or negedge pix_rstn) begin
        if (!pix_rstn) begin
            g0 <= 1'b0; g1 <= 1'b0; wr_ok_r <= 1'b0;
        end else begin
            g0 <= ready & ~sw_rst_r;
            g1 <= g0;
            if (!g1)            wr_ok_r <= 1'b0;
            else if (frame_sof) wr_ok_r <= 1'b1;
        end
    end
    assign wr_ok = wr_ok_r;

    //-------------------------------------------------------------------------
    // ddr 域：切换后已写满多少个完整帧
    //-------------------------------------------------------------------------
    reg sd0, sd1;
    always @(posedge ddr_clk) begin sd0 <= sel; sd1 <= sd0; end

    reg [7:0] fcnt;
    always @(posedge ddr_clk or negedge ddr_rstn) begin
        if (!ddr_rstn)          fcnt <= 8'd0;
        else if (sd0 != sd1)    fcnt <= 8'd0;
        else if (frame_start && fcnt != 8'hFF) fcnt <= fcnt + 8'd1;
    end
    wire frames_ok = (fcnt >= FRAMES_NEED);

    //-------------------------------------------------------------------------
    // 黑屏 FSM（soc 域）+ 跨到 lcd
    //   置黑：sel 变化（立即）/ 复位
    //   放行：ready ∧ frames_ok ∧ SETTLE_CYC 到
    //-------------------------------------------------------------------------
    reg fo0, fo1;
    reg [31:0] settle_cnt;
    reg        black_r;
    always @(posedge soc_clk or negedge soc_rstn) begin
        if (!soc_rstn) begin
            fo0 <= 1'b0; fo1 <= 1'b0; settle_cnt <= SETTLE_CYC; black_r <= 1'b1;
        end else begin
            fo0 <= frames_ok; fo1 <= fo0;
            if (sel != sel_d) begin
                black_r    <= 1'b1;
                settle_cnt <= SETTLE_CYC;
            end else if (black_r) begin
                if (settle_cnt != 32'd0)      settle_cnt <= settle_cnt - 32'd1;
                else if (ready && fo1)        black_r    <= 1'b0;
            end
        end
    end
    assign switch_busy = black_r | sw_rst_r;

    reg b0, b1;
    always @(posedge lcd_clk or negedge lcd_rstn) begin
        if (!lcd_rstn) begin b0 <= 1'b1; b1 <= 1'b1; end
        else begin b0 <= black_r; b1 <= b0; end
    end
    assign black = b1;

endmodule
```

- [ ] **Step 4: 跑 TB 确认绿**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u5.vvp tb_cam_switch.v ../../board/cam/cam_switch.v && vvp /tmp/u5.vvp
```

Expected: `RESULT: PASS`

- [ ] **Step 5: 负对照（裸 mux 必须被毛刺判据打红）**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
cp ../../board/cam/cam_switch.v /tmp/cam_switch_bad.v
sed -i 's@assign cam_clk = (clk0 & en0) | (clk1 & en1);@assign cam_clk = s0b ? clk1 : clk0;@' /tmp/cam_switch_bad.v
if cmp -s ../../board/cam/cam_switch.v /tmp/cam_switch_bad.v; then
    echo "FATAL: 突变没落盘（锚点没命中）"; exit 3; fi
grep -n "assign cam_clk" /tmp/cam_switch_bad.v      # 必须看到裸 mux 那一行
iverilog -g2012 -o /tmp/u5bad.vvp tb_cam_switch.v /tmp/cam_switch_bad.v && vvp /tmp/u5bad.vvp
```

Expected: `RESULT: FAIL` 且至少一条 `cam_clk 出现窄高脉冲` 或 `窄低脉冲`。
若没有变红 ⇒ **闸门不可信**，先修判据再继续（不许跳过）。

- [ ] **Step 6: 接进闸门套件**

在 `sim/video/run_video_gates.sh` 的 U4 之后插入：

```bash
#---- U5: 双目切换的 mux/毛刺/掐写/黑屏 -------------------------------------
iverilog -g2012 -o "$LOG/u5.vvp" tb_cam_switch.v "$V/cam_switch.v"
vvp "$LOG/u5.vvp" > "$LOG/u5.log"
check "U5 CAM_SWITCH: PASS" "$LOG/u5.log" "RESULT: PASS"
```

并在 U2 之前加一行自检（负对照必须红）：

```bash
#---- U5 负对照：裸 mux 必须打红 -------------------------------------------
cp "$V/cam_switch.v" "$LOG/cam_switch_bad.v"
sed -i 's@assign cam_clk = (clk0 & en0) | (clk1 & en1);@assign cam_clk = s0b ? clk1 : clk0;@' \
    "$LOG/cam_switch_bad.v"
if cmp -s "$V/cam_switch.v" "$LOG/cam_switch_bad.v"; then
    echo "VIDEO_GATES: FAIL at U5 负对照（突变没落盘）"; exit 1; fi
iverilog -g2012 -o "$LOG/u5neg.vvp" tb_cam_switch.v "$LOG/cam_switch_bad.v"
vvp "$LOG/u5neg.vvp" > "$LOG/u5neg.log"
if grep -q "RESULT: PASS" "$LOG/u5neg.log"; then
    echo "VIDEO_GATES: FAIL at U5 负对照（裸 mux 没有打红）"; exit 1
fi
echo "U5 CAM_SWITCH: PASS（负对照必红）"
```

- [ ] **Step 7: 提交**

```bash
git add board/cam/cam_switch.v sim/video/tb_cam_switch.v sim/video/run_video_gates.sh
git commit -m "feat(video): cam_switch 前端（无毛刺时钟 mux + 掐写 + 事件驱动黑屏）+ U5 闸门"
```

---

### Task 2: `key_toggle.v` 消抖 + 单次脉冲

**Files:**
- Create: `board/cam/key_toggle.v`
- Test: `sim/video/tb_key_toggle.v`
- Modify: `sim/video/run_video_gates.sh`（U6 档）

- [ ] **Step 1: 写 TB（先红）**

创建 `sim/video/tb_key_toggle.v`：

```verilog
//=============================================================================
// tb_key_toggle: KEY 电平消抖 + 单次脉冲（U6）
//   ① 抖动 100 拍不触发；② 稳定按满 CNT_MAX 拍恰好 1 个脉冲；
//   ③ 一直按住不再发第二个；④ 松开再按可再触发
//=============================================================================
`timescale 1ns/1ps
module tb_key_toggle;
    localparam integer CNT_MAX = 20;

    reg clk = 0, rstn = 0, key_n = 1;
    wire pulse;
    always #5.0 clk = ~clk;

    key_toggle #(.CNT_MAX(CNT_MAX)) dut (
        .clk(clk), .rstn(rstn), .key_n(key_n), .pulse(pulse)
    );

    integer errs = 0, npulse = 0;
    always @(posedge clk) if (pulse) npulse = npulse + 1;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin $display("TBFAIL %0s", msg); errs = errs + 1; end end
    endtask

    integer i;
    initial begin
        repeat (3) @(posedge clk); rstn = 1;
        // ① 抖动：反复按 1~2 拍
        for (i = 0; i < 6; i = i + 1) begin
            key_n = 0; repeat (2) @(posedge clk);
            key_n = 1; repeat (2) @(posedge clk);
        end
        chk(npulse == 0, "抖动期间不应触发");

        // ② 稳定按住
        key_n = 0;
        repeat (CNT_MAX + 5) @(posedge clk);
        chk(npulse == 1, "按住满阈值后应恰好 1 个脉冲");

        // ③ 继续按住
        repeat (CNT_MAX * 3) @(posedge clk);
        chk(npulse == 1, "一直按住不应重复触发");

        // ④ 松开再按
        key_n = 1; repeat (5) @(posedge clk);
        key_n = 0; repeat (CNT_MAX + 5) @(posedge clk);
        chk(npulse == 2, "松开再按应再触发一次");

        if (errs == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL errs=%0d", errs);
        $finish;
    end
endmodule
```

- [ ] **Step 2: 跑一次确认红**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u6.vvp tb_key_toggle.v ../../board/cam/key_toggle.v
```

Expected: `Unknown module type: key_toggle`

- [ ] **Step 3: 写 `key_toggle.v`**

```verilog
//=============================================================================
// key_toggle: 按键电平消抖 + 单次脉冲（soc_clk 域）
//
// ★ 必须按**电平持续计数**，不能只在"刚变低"那一拍计数：
//   早期版本用 `k2_sync == 2'b10` 触发计数，下一拍电平变 2'b00 就清零，
//   计数器永远到不了阈值 ⇒ 按键完全无效（cam2lcd_200mini 踩过）。
//=============================================================================
module key_toggle #(
    parameter integer CNT_W   = 21,
    parameter [CNT_W-1:0] CNT_MAX = 21'd1_900_000   // 19 ms @100 MHz
)(
    input  wire clk,
    input  wire rstn,
    input  wire key_n,     // 低有效
    output reg  pulse      // 单拍脉冲
);
    reg k1, k2;
    reg [CNT_W-1:0] cnt;
    reg fired;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            k1 <= 1'b1; k2 <= 1'b1; cnt <= {CNT_W{1'b0}}; fired <= 1'b0; pulse <= 1'b0;
        end else begin
            k1 <= key_n;
            k2 <= k1;
            pulse <= 1'b0;
            if (!k2) begin
                if (!fired) begin
                    if (cnt == CNT_MAX) begin
                        pulse <= 1'b1;
                        fired <= 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            end else begin
                cnt   <= {CNT_W{1'b0}};
                fired <= 1'b0;
            end
        end
    end
endmodule
```

- [ ] **Step 4: 跑绿 + 负对照**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u6.vvp tb_key_toggle.v ../../board/cam/key_toggle.v && vvp /tmp/u6.vvp
# 负对照：把"数到阈值才发"改成"第一拍就发"（= 没有消抖，抖动期必误触发）
cp ../../board/cam/key_toggle.v /tmp/key_toggle_bad.v
sed -i 's@if (cnt == CNT_MAX) begin@if (cnt >= {CNT_W{1'"'"'b0}}) begin@' /tmp/key_toggle_bad.v
if cmp -s ../../board/cam/key_toggle.v /tmp/key_toggle_bad.v; then
    echo "FATAL: 突变没落盘（锚点没命中）"; exit 3; fi
grep -n "cnt >= {CNT_W{1'b0}}" /tmp/key_toggle_bad.v
iverilog -g2012 -o /tmp/u6bad.vvp tb_key_toggle.v /tmp/key_toggle_bad.v && vvp /tmp/u6bad.vvp
```

Expected: 第一档 `RESULT: PASS`；第二档 `RESULT: FAIL`（`抖动期间不应触发` 会报）。

- [ ] **Step 5: 接进闸门套件（同 Task 1 Step 6 的写法）**

```bash
#---- U6: KEY 消抖 --------------------------------------------------------
iverilog -g2012 -o "$LOG/u6.vvp" tb_key_toggle.v "$V/key_toggle.v"
vvp "$LOG/u6.vvp" > "$LOG/u6.log"
check "U6 KEY_TOGGLE: PASS" "$LOG/u6.log" "RESULT: PASS"
```

- [ ] **Step 6: 提交**

```bash
git add board/cam/key_toggle.v sim/video/tb_key_toggle.v sim/video/run_video_gates.sh
git commit -m "feat(video): key_toggle 消抖（电平持续计数）+ U6 闸门"
```

---

### Task 3: `video_regs` 增加 `CAM_CTRL`

**Files:**
- Modify: `board/cam/video_regs.v`（端口 + 地址 + 读写）
- Test: `sim/video/tb_video_regs.v`

- [ ] **Step 1: 先在 TB 里加用例（红）**

`sim/video/tb_video_regs.v` 已有的 helper 是 **`axi_wr(a,d)` / `axi_rd(a,d)` / `fail(msg)`**（见该文件 `:80/:92/:106`）。
(a) DUT 实例（`:56` 那一组）追加端口：

```verilog
        .cam_sel_toggle(cam_tgl), .cam_rdy(cam_rdy), .cam_busy(cam_busy), .cam_sel(cam_sel_o),
```

(b) 声明测试用寄存器（`reg [31:0] d;` 附近）：

```verilog
    reg cam_tgl = 0, cam_rdy = 0, cam_busy = 0;
    wire cam_sel_o;
```

(c) 在 `initial` 的末尾（打印 `VIDEO_REGS: PASS` 之前）加用例：

```verilog
        // ---- 5) CAM_CTRL (0x00C)：RW[0] sel / RO[1] ready / RO[2] busy ----
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b0) fail("CAM_CTRL 复位 sel 应为 0");
        axi_wr(12'h00C, 32'h0000_0001);
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b1) fail("CAM_CTRL 写 1 后 sel 应为 1");

        cam_rdy = 1'b1; cam_busy = 1'b1;
        repeat (4) @(posedge clk);
        axi_rd(12'h00C, d);
        if (d[1] !== 1'b1) fail("CAM_CTRL.ready 未跟随 cam_rdy");
        if (d[2] !== 1'b1) fail("CAM_CTRL.busy 未跟随 cam_busy");
        cam_rdy = 1'b0; cam_busy = 1'b0;

        // 按键翻转（单拍脉冲）
        @(posedge clk); cam_tgl = 1'b1; @(posedge clk); cam_tgl = 1'b0;
        repeat (4) @(posedge clk);
        axi_rd(12'h00C, d);
        if (d[0] !== 1'b0) fail("按键翻转后 sel 应为 0");
```

- [ ] **Step 2: 跑一次确认红**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u4.vvp tb_video_regs.v ../../board/cam/video_regs.v && vvp /tmp/u4.vvp
```

Expected: 编译错（`cam_rdy` 等端口不存在）或读回不符。

- [ ] **Step 3: 改 `video_regs.v`**

(a) 端口表加三进一出（放在 `init_done` 那一组旁边）：

```verilog
    input  wire        cam_sel_toggle, // soc_clk：按键翻转（单拍）
    input  wire        cam_rdy,        // 所选相机 init_done
    input  wire        cam_busy,       // 切换/黑屏进行中
    output wire        cam_sel,        // 当前相机（0=cam0）
```

(b) localparam 加一行（`A_VER` 旁边）：

```verilog
    localparam [11:0] A_CAMCTRL = 12'h00C;
```

(c) 存储与翻转（`ovl_count` 声明旁）：

```verilog
    reg  cam_sel_r;
    assign cam_sel = cam_sel_r;
```

(d) 复位分支里加：

```verilog
            cam_sel_r <= 1'b0;
```

(e) 写通道（`if (wr_go) begin ... end` 的 `if/else if` 链里，加在 `A_CTRL` 分支之后）：

```verilog
                end else if (awaddr_q == A_CAMCTRL) begin
                    // CAM_CTRL[0]：0=cam0 1=cam1（与按键同源，软件优先）
                    cam_sel_r <= wdata_q[0];
```

并在 `if (wr_go) begin` **这一行之前**加按键翻转（同一 always 块里后写覆盖先写 ⇒ 软件写天然优先）：

```verilog
            // ---- 按键翻转（软件写优先：同一拍两者都发生时，下面 wr_go 分支的赋值覆盖这里）----
            if (cam_sel_toggle) cam_sel_r <= ~cam_sel_r;
```

(f) 读通道 `case (araddr_q)` 里加：

```verilog
                        A_CAMCTRL: s_rdata <= {29'd0, cam_busy, cam_rdy, cam_sel_r};
```

- [ ] **Step 4: 跑绿**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -o /tmp/u4.vvp tb_video_regs.v ../../board/cam/video_regs.v && vvp /tmp/u4.vvp
```

Expected: `VIDEO_REGS: PASS`

- [ ] **Step 5: 提交**

```bash
git add board/cam/video_regs.v sim/video/tb_video_regs.v
git commit -m "feat(video): VIDEO 0x00C CAM_CTRL（RW sel / RO ready / RO busy）"
```

---

### Task 4: `video_passthrough` 接入（第二份 camera + cam_switch + 写门 + 黑屏）

**Files:**
- Modify: `board/cam/video_passthrough.v`
- Modify: `sim/video/tb_video_path.v`（补 cam1 端口 tie-off）

- [ ] **Step 1: 先改 TB 让编译失败（暴露端口缺口）**

在 `sim/video/tb_video_path.v` 的 `video_passthrough u_dut (` 实例里追加：

```verilog
        .camera_clk_1   (1'b0),
        .camera_data_1  (8'h00),
        .camera_href_1  (1'b0),
        .camera_vsync_1 (1'b0),
        .SCL_1          (),
        .SDA_1          (),
        .cam_rst_1      (),
        .soc_clk        (1'b0),
        .soc_rstn       (1'b0),
        .cam_sel        (1'b0),
        .cam_ready      (),
        .switch_busy    (),
```

- [ ] **Step 2: 跑一次确认红**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -DROW_OFFSET=60 -o /tmp/u2.vvp tb_video_path.v ddr_model.v stub_rd_fram_buf.v \
  ../../board/cam/video_passthrough.v ../../board/cam/overlay.v \
  ../../board/cam/vendor/camera/camera.v ../../board/cam/vendor/camera/camera_data.v \
  ../../board/cam/vendor/tutorial/cmos_8_16bit.v ../../board/cam/vendor/tutorial/fram_buf.v \
  ../../board/cam/vendor/tutorial/wr_buf.v ../../board/cam/vendor/tutorial/rd_buf.v \
  ../../board/cam/vendor/tutorial/wr_ctrl.v ../../board/cam/vendor/tutorial/rd_ctrl.v \
  ../../board/cam/vendor/tutorial/wr_cmd_trans.v ../../board/cam/vendor/tutorial/wr_rd_ctrl_top.v \
  ../../board/cam/vendor/sync_vg.v ../../board/cam/vendor/stub_rambuf_sync.v
```

Expected: `port ... does not exist` （红灯）

- [ ] **Step 3: 改 `video_passthrough.v`**

(a) 端口表（`camera_clk_0` 一组之后、`vin_clk` 之前）加：

```verilog
    input  wire        camera_clk_1,
    input  wire [7:0]  camera_data_1,
    input  wire        camera_href_1,
    input  wire        camera_vsync_1,
    output wire        SCL_1,
    output wire        SDA_1,
    output wire        cam_rst_1,
```

(b) 控制面的端口（`cam_init_done` 那组之后）加（**`soc_clk`/`soc_rstn` 是 `cam_switch` 的控制域，必须新增**）：

```verilog
    input  wire        soc_clk,        // 100 MHz：切换控制域
    input  wire        soc_rstn,       // 低有效
    input  wire        cam_sel,        // 0=cam0
    output wire        cam_ready,      // 所选相机 init_done
    output wire        switch_busy,    // 切换/黑屏进行中
```

(c) 在 `generate` **之前**声明**新增的**共享 wire（**不要**重复声明 `cam_pixel_clk_i`/`cam_de16`/`cam_data16_i`/`frame_sof`——
它们已经在 `g_camera` 里声明过了，重复声明会编译失败）：

```verilog
    wire        cam_wr_ok;      // pix 域：1 = 允许写
    wire        cam_black;      // lcd 域：1 = 黑屏
    wire        cam_sw_busy;    // soc 域
    wire        cam_rdy_w;      // soc 域
    wire [7:0]  cap_d;          // 进 cmos 的 8 bit
    wire        cap_href, cap_vs, cap_clk, cam_cmos_rstn;
```

⚠️ 同时把 `:374-394` 的**"帧状态（ddr_clk 域）"整段**（`cam_fs_d1/d2/d3` + `frame_start_ddr` + `frame_cnt/frame_tog` + 两条
`assign frame_toggle/wr_bank`）**原样上移到 `generate` 之前**：`cam_switch` 实例要读 `frame_start_ddr`，
留在后面会变成隐式悬空 wire（1 bit、无驱动）。纯搬运，逻辑一字不改。

(d) 旁路分支（`if (SIM_BYPASS_CAMERA) begin : g_bypass`）补齐：

```verilog
    assign cap_clk        = vin_clk;
    assign cap_d          = vin_pix[7:0];      // 旁路时 8 bit 无意义，cmos 不走
    assign cap_href       = vin_de;
    assign cap_vs         = vin_vsync;
    assign cam_cmos_rstn  = cam_rstn;
    assign cam_wr_ok      = 1'b1;
    assign cam_black      = 1'b0;
    assign cam_sw_busy    = 1'b0;
    assign cam_rdy_w      = cam_rstn;
    assign SCL_1          = 1'b1;
    assign SDA_1          = 1'b1;
    assign cam_rst_1      = 1'b1;
```

(e) 相机分支（`end else begin : g_camera`）里：
- **删除**原来的 `cam_d_d0/cam_href_d0/cam_vsync_d0` 采样块和 `cmos_8_16bit u_cmos16` 的直接接线，换成：

```verilog
    cam_switch #(
        .SW_RST_CYC  (100000),
        .SETTLE_CYC  (40000000),
        .FRAMES_NEED (2)
    ) u_camsw (
        .clk0(camera_clk_0), .raw_d0(camera_data_0), .raw_href0(camera_href_0), .raw_vs0(camera_vsync_0),
        .init_done_0(cam_init_done_0),
        .clk1(camera_clk_1), .raw_d1(camera_data_1), .raw_href1(camera_href_1), .raw_vs1(camera_vsync_1),
        .init_done_1(cam_init_done_1),
        .soc_clk(soc_clk), .soc_rstn(soc_rstn), .sel(cam_sel),
        .ready(cam_rdy_w), .switch_busy(cam_sw_busy),
        .cam_clk(cap_clk), .cam_d(cap_d), .cam_href(cap_href), .cam_vs(cap_vs),
        .cam_rstn(cam_cmos_rstn), .sw_rst(),
        .pix_clk(cam_pixel_clk_i), .pix_rstn(cam_cmos_rstn),
        .frame_sof(frame_sof), .wr_ok(cam_wr_ok),
        .ddr_clk(ddr_clk), .ddr_rstn(ddr_rstn), .frame_start(frame_start_ddr),
        .lcd_clk(lcd_clk), .lcd_rstn(lcd_rstn), .black(cam_black)
    );

    cmos_8_16bit u_cmos16 (
        .pclk    (cap_clk),
        .rst_n   (cam_cmos_rstn),
        .pdata_i (cap_d),
        .de_i    (cap_href),
        .vs_i    (cap_vs),
        .pixel_clk (cam_pixel_clk_i),
        .de_o    (cam_de16),
        .pdata_o (cam_data16_i)
    );
```

- 第二份 camera 实例（照 `camera_inst0` 逐行复制，换 `_1` 后缀）：

```verilog
    wire cam_init_done_1;
    wire cam_vsync_n_1;
    camera camera_inst1(
        .clk(sys_clk), .rst_n(cam_rstn),
        .SCL(SCL_1), .SDA(SDA_1),
        .camera_clk(camera_clk_1), .camera_data(camera_data_1),
        .camera_herf(camera_href_1), .camera_vsync(camera_vsync_1),
        .ddr_init(ddr_init_done),
        .camera_rstn(cam_rst_1), .camera_pwnd(),
        .init_done(cam_init_done_1),
        .wf_wr_data(), .wf_wr_en(), .vs(cam_vsync_n_1), .hs(), .sop(), .eop()
    );
```

⚠️ `cam_switch` 的两个输入 `soc_clk/soc_rstn` 与 `frame_start_ddr` 在 `video_passthrough` 里当前**不存在**：
- 需新增端口 `input wire soc_clk, input wire soc_rstn`；
- `frame_start_ddr` 已在 `:380` 定义，但位置在 `g_camera` 之后 ⇒ **把 `frame_start_ddr` 的产生块整段上移到 `generate` 之前**（纯搬运，不改逻辑），否则前向引用在 Verilog 里是隐式 wire（会静默悬空）。

(f) 写侧门（`fram_buf` 实例，`:297-299`）——**`wr_fsync` 与 `wr_en` 必须同门控**：

```verilog
        .wr_fsync      (cam_fsync   & cam_wr_ok),
        .wr_en         (cam_de_crop & cam_wr_ok),
```

（`cam_de_crop` 是 `:111` 已存在的 wire；`cam_fsync` 在 `g_camera` 内已 `assign` 为 `frame_sof`，不动。）

(g) 输出级黑屏（`lcd` 域，`:425-439` 那块）：

```verilog
            de_r <= de_o & ~cam_black;
            r_r  <= cam_black ? 8'd0 : {pix_ovl[15:11], 3'd0};
            g_r  <= cam_black ? 8'd0 : {pix_ovl[10:5],  2'd0};
            b_r  <= cam_black ? 8'd0 : {pix_ovl[4:0],   3'd0};
```

(h) 输出赋值：

```verilog
    assign cam_ready   = cam_rdy_w;
    assign switch_busy = cam_sw_busy;
```

- [ ] **Step 4: 跑 U2 确认没坏（旁路档）**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video && bash run_video_gates.sh
```

Expected: `VIDEO_GATES: ALL PASS`（U1/U1b/U3/U4/U5/U6/U2 全绿）
若 U2 红：先看是不是 `frame_sof` 搬运位置错（`g_camera` 作用域）。

- [ ] **Step 5: 提交**

```bash
git add board/cam/video_passthrough.v sim/video/tb_video_path.v
git commit -m "feat(video): video_passthrough 接入第二路相机 + cam_switch（掐写/黑屏）"
```

---

### Task 5: 板级顶层 + 约束

**Files:**
- Modify: `board/yeshen_mini_board_top.v`
- Modify: `constraints/yeshen_mini.fdc`

- [ ] **Step 1: 顶层端口**

在 `input wire camera_vsync_0,` 之后加：

```verilog
    input  wire        camera_clk_1,    // M21
    input  wire [7:0]  camera_data_1,   // M22/R23/T23/AB24/P26/M26/AA24/AB25  D7..D0
    input  wire        camera_href_1,   // U26
    input  wire        camera_vsync_1,  // U25
    output wire        SCL_1,           // AC24
    output wire        SDA_1,           // Y25
    output wire        cam_rst_1,       // AC26
```

在 `input wire key1,` 之后加：

```verilog
    input  wire        key2,            // KEY2（B22），双目切换（低有效）
```

- [ ] **Step 2: 连线**

在 `u_video` 实例里追加：

```verilog
        .camera_clk_1   (camera_clk_1),
        .camera_data_1  (camera_data_1),
        .camera_href_1  (camera_href_1),
        .camera_vsync_1 (camera_vsync_1),
        .SCL_1          (SCL_1),
        .SDA_1          (SDA_1),
        .cam_rst_1      (cam_rst_1),
        .soc_clk        (soc_clk),
        .soc_rstn       (soc_resetn),
        .cam_sel        (cam_sel_w),
        .cam_ready      (cam_ready_w),
        .switch_busy    (cam_busy_w),
```

在 `video_regs u_video_regs (` 实例里追加：

```verilog
        .cam_sel_toggle (key2_toggle),
        .cam_rdy        (cam_ready_w),
        .cam_busy       (cam_busy_w),
        .cam_sel        (cam_sel_w),
```

在 `u_video` / `u_video_regs` 之前声明：

```verilog
    wire        cam_sel_w, cam_ready_w, cam_busy_w;
    wire        key2_toggle;

    key_toggle u_key2 (
        .clk   (soc_clk),
        .rstn  (soc_resetn),
        .key_n (key2),
        .pulse (key2_toggle)
    );
```

- [ ] **Step 3: FDC 加引脚**

在相机段（`p:camera_clk_0` 那组后面）加：

```tcl
# ===== V1b（2026-10-27）：双目第二路 CAM1（J10 同一连接器；参考工程实测引脚）=====
define_attribute {p:camera_clk_1} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_clk_1} {PAP_IO_LOC} {M21}
define_attribute {p:camera_clk_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_clk_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_clk_1} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[0]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[0]} {PAP_IO_LOC} {M22}
define_attribute {p:camera_data_1[0]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[0]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[1]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[1]} {PAP_IO_LOC} {R23}
define_attribute {p:camera_data_1[1]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[1]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[1]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[2]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[2]} {PAP_IO_LOC} {T23}
define_attribute {p:camera_data_1[2]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[2]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[2]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[3]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[3]} {PAP_IO_LOC} {AB24}
define_attribute {p:camera_data_1[3]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[3]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[3]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[4]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[4]} {PAP_IO_LOC} {P26}
define_attribute {p:camera_data_1[4]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[4]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[4]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[5]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[5]} {PAP_IO_LOC} {M26}
define_attribute {p:camera_data_1[5]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[5]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[5]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[6]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[6]} {PAP_IO_LOC} {AA24}
define_attribute {p:camera_data_1[6]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[6]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[6]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_data_1[7]} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_data_1[7]} {PAP_IO_LOC} {AB25}
define_attribute {p:camera_data_1[7]} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_data_1[7]} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_data_1[7]} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_href_1} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_href_1} {PAP_IO_LOC} {U26}
define_attribute {p:camera_href_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_href_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_href_1} {PAP_IO_NONE} {TRUE}

define_attribute {p:camera_vsync_1} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_vsync_1} {PAP_IO_LOC} {U25}
define_attribute {p:camera_vsync_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_vsync_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:camera_vsync_1} {PAP_IO_NONE} {TRUE}

define_attribute {p:SCL_1} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:SCL_1} {PAP_IO_LOC} {AC24}
define_attribute {p:SCL_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:SCL_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:SCL_1} {PAP_IO_DRIVE} {8}
define_attribute {p:SCL_1} {PAP_IO_NONE} {TRUE}
define_attribute {p:SCL_1} {PAP_IO_SLEW} {SLOW}

define_attribute {p:SDA_1} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:SDA_1} {PAP_IO_LOC} {Y25}
define_attribute {p:SDA_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:SDA_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:SDA_1} {PAP_IO_DRIVE} {8}
define_attribute {p:SDA_1} {PAP_IO_NONE} {TRUE}
define_attribute {p:SDA_1} {PAP_IO_SLEW} {SLOW}

define_attribute {p:cam_rst_1} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:cam_rst_1} {PAP_IO_LOC} {AC26}
define_attribute {p:cam_rst_1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:cam_rst_1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:cam_rst_1} {PAP_IO_DRIVE} {8}
define_attribute {p:cam_rst_1} {PAP_IO_NONE} {TRUE}
define_attribute {p:cam_rst_1} {PAP_IO_SLEW} {SLOW}

# ===== KEY2（B22）：双目切换输入 =====
define_attribute {p:key2} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:key2} {PAP_IO_LOC} {B22}
define_attribute {p:key2} {PAP_IO_VCCIO} {3.3}
define_attribute {p:key2} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:key2} {PAP_IO_NONE} {TRUE}
```

时钟段（`cam_pixel_clk` 那两行之后、`:219-222` 附近）加：

```tcl
create_clock -name {camera_clk_1} [get_ports {camera_clk_1}] -period {10.000}
create_generated_clock -name {cam_pixel_clk_1} -source [get_ports {camera_clk_1}] \
  [get_pins {u_video/g_camera.u_cmos16/pixel_clk}] -master_clock [get_clocks {camera_clk_1}] \
  -multiply_by {1} -divide_by {2} -add
```

异步组（**必须排在所有 `create_clock` 之后**——本文件顺序执行，引用在定义前 = 静默丢弃；
照既有 `:286-302` 的写法逐条加）：

```tcl
set_clock_groups -name camera_clk_1 -asynchronous -group [get_clocks {camera_clk_1}]
set_clock_groups -name cam_pixel_clk_1 -asynchronous -group [get_clocks {cam_pixel_clk_1}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_0}] -group [get_clocks {camera_clk_1}]
set_clock_groups -asynchronous -group [get_clocks {cam_pixel_clk}]  -group [get_clocks {camera_clk_1}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {cam_pixel_clk_1}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {lcd_clk}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {soc_clk}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {core_clk}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {clk_in}]
set_clock_groups -asynchronous -group [get_clocks {camera_clk_1}]   -group [get_clocks {ref_clk}]
set_clock_groups -asynchronous -group [get_clocks {cam_pixel_clk_1}] -group [get_clocks {soc_clk}]
set_clock_groups -asynchronous -group [get_clocks {cam_pixel_clk_1}] -group [get_clocks {lcd_clk}]
```

> `sel` 在 clk0/clk1 之间是**故意的 2FF 异步穿越** ⇒ 这两座钟必须互为异步组，不能当同步域分析。

- [ ] **Step 4: 检查引脚唯一性（防重复占用）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
for p in M21 M22 R23 T23 AB24 P26 M26 AA24 AB25 U26 U25 AC24 AC26 Y25 B22; do
  n=$(grep -c "{p:.*} {PAP_IO_LOC} {$p}" constraints/yeshen_mini.fdc); echo "$p: $n"; done
```

Expected: 每行恰好 `1`（之前都是 0，加完是 1；出现 2 就是撞脚）。

- [ ] **Step 5: 提交**

```bash
git add board/yeshen_mini_board_top.v constraints/yeshen_mini.fdc
git commit -m "board(video): CAM1 端口/引脚 + KEY2(B22) + camera_clk_1 约束"
```

---

### Task 6: Lint + dev_map + 面积记账

**Files:**
- Modify: `pds/run_devmap_yeshen.tcl`、`pds/run_pnr_yeshen.tcl`（**两个新 RTL 必须进 PDS 源清单**）

- [ ] **Step 0: 把新 RTL 加进 PDS 源清单（2026-10-27 首跑踩到，必须做）**

`run_devmap_yeshen.tcl` 与 `run_pnr_yeshen.tcl` 的 `board/cam` 源段各追加两行（两份清单必须一致）：

```tcl
add_design "$root/board/cam/cam_switch.v"
add_design "$root/board/cam/key_toggle.v"
```

不做这一步，Compile 会报 `'key_toggle' is referenced to undefined module`（实测）。

- [ ] **Step 1: Verilator lint（WSL）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
wsl bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && verilator --lint-only -Wno-fatal \
  -Iboard/cam/vendor/tutorial -Iboard/cam/vendor/camera \
  board/cam/cam_switch.v board/cam/key_toggle.v board/cam/video_regs.v 2>&1 | tail -20'
```

Expected: 无 `%Error`。

- [ ] **Step 2: dev_map**

```bash
cd /d/code/PDS/VexiiYeshenLinux
YESHENMINI_DEVMAP_TAG=camsw /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe \
  -file pds/run_devmap_yeshen.tcl 2>&1 | tee sim/reglogs/m_camsw_devmap.log
python scripts/check_devmap.py sim/reglogs/m_camsw_devmap.log; echo "rc=$?"
```

- [ ] **Step 3: 面积记账（与基线比）**

把 `sim/reglogs/m_camsw_devmap.log` 的 `Total LUTs / Total Registers / Total DRMs` 与
**上一次板级 devmap**（`sim/reglogs/` 里最近一份 `m_yeshen_devmap*.log`）逐项对比，把增量写进报告。
判据：**DRM 增量必须 = 0**（本版不新增 BRAM）；LUT 增量记账即可，但若 **> 5000** 要停下来
先看第二份 `camera.v` 的 SCCB ROM 是不是被推成了分布式 RAM（那是面积失控的信号，不是"差不多"）。

- [ ] **Step 4: 提交日志摘要**

```bash
git add sim/reglogs/m_camsw_devmap.log docs/reports/camera-switch.md   # 报告在 Task 8 写
git commit -m "build(video): CAM1 + cam_switch dev_map（LUT/FF/DRM 记账）"
```

---

### Task 7: PnR + 比特流

- [ ] **Step 1: PnR**

```bash
cd /d/code/PDS/VexiiYeshenLinux
/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file pds/run_pnr_yeshen.tcl \
  2>&1 | tee sim/reglogs/p_camsw.log
```

- [ ] **Step 2: 判据**

```bash
grep -E "All Constraints Met|WNS|TNS|THS" sim/reglogs/p_camsw.log | head -10
grep -c "SDC-2025" sim/reglogs/p_camsw.log     # 允许（良性提示），但要在报告里记数
ls -l deliver/sbits/*.sbit | tail -3
md5sum deliver/sbits/<本轮的 sbit>
```

Expected: `All Constraints Met`；sbit 与 md5 记进报告。

- [ ] **Step 3: 提交**

```bash
git add sim/reglogs/p_camsw.log
git commit -m "build(video): CAM1 切换 PnR（All Met）+ 比特流指纹"
```

---

### Task 8: 上板验收 + 报告

> 上板时机由用户给窗口；动板前先按 `feedback-board-occupancy` 检查没有别的会话占板。

- [ ] **Step 1: 不按键基线（最重要的一条）**

烧写新比特流 → 上电 → 屏幕画面与 Cam known-good 逐项对照（颜色/位置/撕裂）。
判据：**与旧版视觉一致**；`led[3]` 1 Hz 心跳正常。

- [ ] **Step 2: KEY2 切换**

按 KEY2（>19 ms）→ 观察：黑屏约 0.5 s → 出现 cam1 画面；再按一次 → 回 cam0。
判据：两次都能切；黑屏不超 1.5 s；不出现花屏/死黑。

- [ ] **Step 3: 寄存器读回**

```bash
# 板内（ssh）
devmem 0xF000740C          # 期望 bit0 与当前画面一致；切换后立即反映 bus 位置 1
```

- [ ] **Step 4: 负对照（CAM1 不插）**

拔掉/遮住 cam1（或用 `CAM_CTRL` 切到 cam1 而 cam1 未接）：
判据：停在黑屏且 `CAM_CTRL[2]=1`；**再按一次能回 cam0 出画面**（不锁死）。

- [ ] **Step 5: 回归**

- `y1run` 12/12 CRC（若本次只改视频前端，NPU 路径不变，仍要跑）
- 整帧 G7（若时间允许）

- [ ] **Step 6: 写报告**

创建 `docs/reports/camera-switch.md`，至少包含：设计要点、dev_map 增量表、PnR 关键行、sbit md5、
四条上板判据的实测结果、已知限制（0.5 s 黑屏；无角标；cam1 缺失可恢复）。

- [ ] **Step 7: 提交**

```bash
git add docs/reports/camera-switch.md
git commit -m "docs(video): 双目切换上板验收报告"
```

---

## 自查（写完计划后逐条核对 spec）

| spec 要求 | 对应任务 |
|---|---|
| CAM1 14 引脚接入 + 独立 SCCB/复位 | Task 4（第二份 camera）+ Task 5（引脚） |
| 按键 + 寄存器同源 | Task 2（消抖）+ Task 3（CAM_CTRL） |
| 整帧边界重启 | Task 1（`cam_rstn` = 所选 init_done & ~sw_rst）+ Task 4（cmos 等首 VS） |
| 事件驱动黑屏 | Task 1（`black` FSM：ready ∧ frames_ok ∧ settle） |
| 掐写侧、DDR 无撕裂帧 | Task 1（`wr_ok`）+ Task 4（`wr_en/wr_fsync` 同门控） |
| 上电默认 CAM0、不按键逐位不变 | Task 3（复位值 0）+ Task 8 Step 1 |
| 不占硬件 LED | 全部任务均未改 `led[]` |
| 约束（camera_clk_1 + cam_pixel_clk_1 -add） | Task 5 Step 3 |
| 验证 V1–V5 | Task 1/2（仿真+负对照）、Task 6（lint/dev_map）、Task 7（PnR）、Task 8（上板） |

**已知的口径细节（实现时必须照做）：**
1. `frame_start_ddr` 的产生块要从 `:374-380` **上移**到 `generate` 之前（Task 4 Step 3 末），否则 `cam_switch` 实例取到的是隐式悬空 wire。
2. `cam_fsync`/`cam_de_crop` 门控用 `& cam_wr_ok`，**两者必须同门控**——只掐 `wr_en` 会让 `fram_buf` 收到"有 fsync 无数据"的空帧并翻 bank。
3. 仿真参数（`SW_RST_CYC/SETTLE_CYC/FRAMES_NEED`）在 TB 里缩小，产品里用默认值；**不要把 TB 的小值带进 `video_passthrough` 的实例**。
