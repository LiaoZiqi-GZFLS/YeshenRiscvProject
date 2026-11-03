# Camera Passthrough + FPGA Box Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CAM0 1280×720 实时 1:1 裁切直通到 1024×600 LCD；中央 640×640 走 CPU+Y1 NPU 做 YuNet 人脸检测；FPGA 在扫描路径上叠加检测框。

**Architecture:** 复用厂家 `cam2lcd_200mini` 已验证的采集/帧存/扫描链（复制进本仓，参考仓库零改动），新增一个 DDR IP 256-bit 用户口的 2:1 仲裁器让视频与 `DDR3Bridge` 共享 DDR；新增 1 KiB VIDEO 寄存器窗（胶合块解码）与双 bank 叠加引擎；板内 Linux C 程序负责快照、同口径预处理、NPU 调度、YuNet 后处理与写框。

**Tech Stack:** Verilog-2001 / SpinalHDL 胶合（scala-cli + java -jar）/ PDS 2025.2（紫光 PG2L200H）/ iverilog（Git Bash）/ Verilator（WSL）/ Linux 5.10.1 rv32 / Y1 NPU（Mailbox + DDR Master）。

**Spec:** `docs/superpowers/specs/2026-10-19-video-camera-lcd-overlay-design.md`

---

## File Structure（先锁定边界）

| 文件 | 职责 |
|---|---|
| `board/cam/vendor/**` | 厂家 RTL/IP 复制件（唯一改动：`rd_buf.v` 增加 `ROW_OFFSET`） |
| `board/cam/video_passthrough.v` | 相机→裁列→帧存→扫描→叠加→LCD 的组装层；对外只暴露 DDR 简化 AXI、LCD/相机引脚、帧状态 |
| `board/cam/overlay.v` | 16 框、2 px 绿色边框、双 bank box BRAM、vsync 切换 |
| `board/cam/video_regs.v` | VIDEO 窗 AxiLite 从口（STATUS/CTRL/BOX）+ 帧计数跨域 + overlay 写口 |
| `board/cam/ddr_arbiter_2to1.v` | 桥 vs 视频 的 256-bit 简化口 2:1 仲裁（同通道二选一、RID 分流） |
| `board/pll_lcd.v` | 27 MHz → 51.923 MHz 像素时钟（VCO 1350 / 26） |
| `board/yeshen_mini_soc.v` | 暴露胶合块新增的 `videoAxi` 主口 |
| `board/yeshen_mini_board_top.v` | 例化视频链/仲裁器/寄存器；把 `u_ddr3` 用户口改接到仲裁器输出 |
| `constraints/yeshen_mini.fdc` | 相机/LCD 引脚与三组新时钟、异步组 |
| `src/YeshenSocGlue.scala` → `rtl/YeshenSocGlue.v` | 新增 `VIDEO_BASE=0xF0007400` 窗（1 KiB，掩码 `0xFFFF_FC00`） |
| `scripts/check_addr_map.py` | 台账新增 VIDEO 窗五项 |
| `pds/run_devmap_yeshen.tcl` / `pds/run_pnr_yeshen.tcl` | 新增视频源文件 |
| `sim/video/**` | U1~U4 单元闸门 + 共享 DDR 模型 |
| `y1/tools/y1_common.h` | 从 `y1run.c` 抽出的 payload 结构/CRC/mmap 公共件（y1run 与 y1cam 共用） |
| `y1/tools/y1_deq.h` + `gen_deq_header.py` | 12 路输出的反量化 scale/zp 静态常量（生成物） |
| `y1/tools/y1cam.c` + `build_y1cam.sh` | 板内检测循环程序 |
| `sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/y1/y1cam` | rootfs 内的二进制（由构建脚本放入） |

---

## Task 1: 复制厂家视频资产（参考仓库零改动）

**Files:**
- Create: `board/cam/vendor/**`（复制件）
- Create: `board/cam/vendor/PROVENANCE.md`
- Verify: `D:/code/PDS/cam2lcd_200mini` 的 sha256 前后一致

- [ ] **Step 1: 记录参考仓库指纹（复制前）**

```bash
cd /d/code/PDS
find cam2lcd_200mini/rtl cam2lcd_200mini/ip cam2lcd_200mini/constraints -type f -exec sha256sum {} \; | sort > /tmp/cam_ref_before.sha
wc -l /tmp/cam_ref_before.sha
```

Expected: 行数 > 30，无报错。

- [ ] **Step 2: 复制到本仓（保留目录结构）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
mkdir -p board/cam/vendor/tutorial board/cam/vendor/camera board/cam/vendor/ip
cp -a /d/code/PDS/cam2lcd_200mini/rtl/camera/. board/cam/vendor/camera/
cp -a /d/code/PDS/cam2lcd_200mini/rtl/tutorial/. board/cam/vendor/tutorial/
cp -a /d/code/PDS/cam2lcd_200mini/rtl/sync_vg.v board/cam/vendor/
cp -a /d/code/PDS/cam2lcd_200mini/rtl/pll_80m.v board/cam/vendor/
cp -a /d/code/PDS/cam2lcd_200mini/ip/wr_fram_buf board/cam/vendor/ip/
cp -a /d/code/PDS/cam2lcd_200mini/ip/rd_fram_buf board/cam/vendor/ip/
cp -a /d/code/PDS/cam2lcd_200mini/scripts/stub_rambuf.v board/cam/vendor/
cp -a /d/code/PDS/cam2lcd_200mini/scripts/stub_rambuf_sync.v board/cam/vendor/
```

- [ ] **Step 3: 写 PROVENANCE.md（来源 + 改动白名单 + 指纹）**

```markdown
# 厂家视频资产（只读复制件）

来源：`D:/code/PDS/cam2lcd_200mini`（cam2lcd2 交付，2026-10-04，板级验收通过）。
复制日期：2026-10-19。参考仓库保持零改动（复制前后 sha256 全量对比一致）。

允许的本地改动（且仅此一处）：
- `vendor/tutorial/rd_buf.v`：新增 `ROW_OFFSET` 参数（显示窗口起始行 60）。

其余文件逐字节与来源一致。11 条历史根因（整流级/负边沿采样/短行回滚/消隐判帧尾/
DUTYx==RATIOx/双 bank 反相读等）见来源 `DELIVERY_REPORT.md` §4，**不得"顺手清理"**。
```

- [ ] **Step 4: 记录复制件指纹并核对来源未变**

```bash
cd /d/code/PDS/VexiiYeshenLinux
find board/cam/vendor -type f -exec sha256sum {} \; | sort > board/cam/vendor/SHA256SUMS
cd /d/code/PDS
find cam2lcd_200mini/rtl cam2lcd_200mini/ip cam2lcd_200mini/constraints -type f -exec sha256sum {} \; | sort > /tmp/cam_ref_after.sha
diff -q /tmp/cam_ref_before.sha /tmp/cam_ref_after.sha && echo "REF-UNCHANGED"
```

Expected: `REF-UNCHANGED`。

- [ ] **Step 5: Commit**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git add board/cam/vendor
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "video: vendor camera/LCD assets copied verbatim (reference untouched)"
```

---

## Task 2: 视频组装层 + 行偏移 + LCD PLL（RTL）

**Files:**
- Modify: `board/cam/vendor/tutorial/rd_buf.v`
- Create: `board/pll_lcd.v`
- Create: `board/cam/video_passthrough.v`
- Test: `sim/video/tb_video_path.v`, `sim/video/ddr_model.v`

- [ ] **Step 1: `rd_buf.v` 增加 `ROW_OFFSET`（唯一允许的厂家文件改动）**

在 `rd_buf` 参数表加：

```verilog
    parameter                     ROW_OFFSET      = 12'd0,   // 显示窗口起始行（相机行号）
```

把帧复位分支里的行计数器初值改成：

```verilog
        if(wr_rst)
            wr_cnt <= ROW_OFFSET * DDR_ADDR_OFFSET;
        else if(ddr_rdone)
            wr_cnt <= wr_cnt + DDR_ADDR_OFFSET;
```

（`DDR_ADDR_OFFSET` 是既有 localparam = 一行 512 个 32-bit 字。）

- [ ] **Step 2: 新建 `board/pll_lcd.v`（VCO 1350 / RATIO0=26）**

复制 `board/pll_cpu.v` 为 `board/pll_lcd.v`，改模块名与四个参数（其余保持同一 GTP_GPLL 例化）：

```verilog
module pll_lcd (
    output wire clkout0,
    input  wire clkin1,
    output wire lock
);
    localparam real    CLKIN_FREQ    = 27.0;
    localparam integer STATIC_RATIOI = 1;
    localparam integer STATIC_RATIOM = 2;     // PFD=27MHz
    localparam real    STATIC_RATIO0 = 26.0;  // 1350/26 = 51.9230769 MHz
    localparam integer STATIC_DUTY0  = 26;    // DUTYx==RATIOx
    localparam real    STATIC_RATIOF = 25.0;  // VCO = 27*2*25 = 1350 MHz
    localparam integer STATIC_DUTYF  = 25;
    // 其余 RATIO1..6/PHY 保持 pll_cpu.v 原值（未用）
```

- [ ] **Step 3: 新建 `board/cam/video_passthrough.v`（从厂家 top 复制 + 定点改）**

从 `board/cam/vendor/../cam2lcd_200mini/rtl/cam2lcd2_top.v`（即来源工程同名文件）**逐块复制**以下段落到新文件，并按编号改：
1. `camera camera_inst0` 例化（来源 100–118 行）——**原样**；
2. `cmos_8_16bit u_cmos16`（来源 186–260 行）——**原样**（`rst_n(cam_init_done_0)`）；
3. `fram_buf` 例化（来源 516–560 行）：参数改为
   `.MEM_ROW_WIDTH(15) .MEM_COLUMN_WIDTH(10) .MEM_BANK_WIDTH(3) .MEM_DQ_WIDTH(32)
    .H_NUM(12'd1024) .V_NUM(12'd720) .PIX_WIDTH(16) .ADDR_OFFSET(32'h0400_0000)
    .ROW_OFFSET(12'd60)`；
4. `rd_buf` 的行偏移通过 `fram_buf` 透传：在复制件 `fram_buf.v` 中新增 `ROW_OFFSET` 参数并
   接到 `rd_buf #(.ROW_OFFSET(ROW_OFFSET))`；`video_passthrough` 例化 `fram_buf` 时传
   `.ROW_OFFSET(12'd60)`；
5. `sync_vg`（来源 309–330 行）——**原样**，参数为
   `.X_BITS(12) .Y_BITS(12) .V_TOTAL(635) .V_FP(12) .V_BP(20) .V_SYNC(3) .V_ACT(600)
    .H_TOTAL(1344) .H_FP(160) .H_BP(140) .H_SYNC(20) .H_ACT(1024)`；
6. LCD 输出级 `r_r/g_r/b_r` 三拍寄存器（来源 625–644 行）——**原样**；
7. 删除厂家 DDR IP、TMDS/HDMI、UART 调试、LED、`video_rect_read_data` 不需要的部分。

写侧裁列（在 `cmos_8_16bit` 与 `fram_buf` 之间）：

```verilog
    // 相机列 128..1151 → 存 1024 列（居中；全 720 行）
    reg [11:0] col_cnt;
    always @(posedge cam_pixel_clk or negedge cam_rstn) begin
        if (!cam_rstn)          col_cnt <= 12'd0;
        else if (!cam_de)       col_cnt <= 12'd0;
        else if (col_cnt < 12'd1280) col_cnt <= col_cnt + 12'd1;
    end
    wire cam_de_crop = cam_de && (col_cnt >= 12'd128) && (col_cnt < 12'd1152);
```

对外端口（完整列表）：

```verilog
module video_passthrough #(
    parameter SIM_BYPASS_CAMERA = 0,
    parameter [27:0] FB_ADDR_WORD = 28'h0400_0000,
    parameter integer ROW_OFFSET  = 60
)(
    input  wire        sys_clk,          // 27 MHz（camera SCCB 初始化）
    input  wire        cam_rstn,         // 低有效，来自板级复位
    input  wire        ddr_clk,          // 125 MHz core_clk
    input  wire        ddr_rstn,         // ddr_init_done（高有效）
    input  wire        lcd_clk,          // 51.923 MHz
    input  wire        lcd_rstn,
    input  wire        ddr_init_done,

    // 相机引脚
    input  wire        camera_clk_0,
    input  wire [7:0]  camera_data_0,
    input  wire        camera_href_0,
    input  wire        camera_vsync_0,
    output wire        SCL_0,
    output wire        SDA_0,
    output wire        cam_rst_0,

    // 仿真旁路（SIM_BYPASS_CAMERA=1 时用）
    input  wire        vin_clk,
    input  wire        vin_de,
    input  wire        vin_vsync,
    input  wire [15:0] vin_pix,

    // DDR 简化口（接仲裁器视频侧）
    output wire [27:0] ddr_awaddr,
    output wire [3:0]  ddr_awlen,
    output wire        ddr_awvalid,
    input  wire        ddr_awready,
    output wire [255:0] ddr_wdata,
    output wire [31:0] ddr_wstrb,
    output wire        ddr_wvalid,
    input  wire        ddr_wready,
    input  wire        ddr_wusero_last,
    output wire [27:0] ddr_araddr,
    output wire [3:0]  ddr_arlen,
    output wire        ddr_arvalid,
    input  wire        ddr_arready,
    input  wire [255:0] ddr_rdata,
    input  wire [3:0]  ddr_rid,
    input  wire        ddr_rlast,
    input  wire        ddr_rvalid,
    output wire        ddr_rready,

    // LCD 引脚
    output wire        lcd_pclk,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_pwm,
    output wire [7:0]  lcd_r,
    output wire [7:0]  lcd_g,
    output wire [7:0]  lcd_b,

    // 帧状态（ddr_clk 域）
    output wire        frame_toggle,   // 每帧起点翻转
    output wire        wr_bank,        // 当前写 bank
    output wire        cam_init_done,

    // overlay 写口（soc_clk 域，来自 video_regs）
    input  wire        ovl_wr_clk,
    input  wire        ovl_wr_rstn,
    input  wire        ovl_wr_en,
    input  wire [4:0]  ovl_wr_addr,
    input  wire [31:0] ovl_wr_data,
    input  wire        ovl_commit,
    input  wire        ovl_en,
    input  wire [7:0]  ovl_count,
    output wire        ovl_active_bank
);
```

帧状态：`wr_bank` 取 `fram_buf` 的 `frame_wcnt[0]`；`frame_toggle` 在 `ddr_clk` 下检测
`frame_wcnt` 变化并翻转（每帧一次）。

- [ ] **Step 4: 写 `sim/video/ddr_model.v`（256-bit 简化 DDR 模型）**

```verilog
`timescale 1ns/1ps
module ddr_model #(parameter AW=28, parameter LAT=8)(
    input clk, input rstn,
    input [AW-1:0] awaddr, input [3:0] awlen, input awvalid, output reg awready,
    input [255:0] wdata, input [31:0] wstrb, input wvalid, output reg wready,
    output reg wusero_last,
    input [AW-1:0] araddr, input [3:0] arlen, input [3:0] aruser_id,
    input arvalid, output reg arready,
    output reg [255:0] rdata, output reg [3:0] rid, output reg rlast,
    output reg rvalid, input rready
);
    reg [255:0] mem [0:(1<<20)-1];   // 32 MiB 窗口足够 TB
    // 写
    reg [3:0] wleft; reg [AW-1:0] waddr;
    always @(posedge clk) begin
        if (!rstn) begin awready<=1; wready<=0; wusero_last<=0; wleft<=0; end
        else begin
            wusero_last <= 0;
            if (awvalid && awready) begin
                awready<=0; waddr<=awaddr; wleft<=awlen; wready<=1;
            end
            if (wvalid && wready) begin
                mem[waddr[19:0]] <= wdata;
                waddr <= waddr + 1;
                if (wleft==0) begin wready<=0; awready<=1; wusero_last<=1; end
                else wleft <= wleft - 1;
            end
        end
    end
    // 读
    reg [4:0] rdelay; reg [3:0] rleft; reg [AW-1:0] raddr; reg [3:0] r_id;
    always @(posedge clk) begin
        if (!rstn) begin arready<=1; rvalid<=0; rlast<=0; rdelay<=0; end
        else begin
            if (arvalid && arready) begin
                arready<=0; raddr<=araddr; rleft<=arlen; r_id<=aruser_id; rdelay<=LAT;
            end
            if (rdelay>0) rdelay <= rdelay-1;
            else if (!rvalid && arready==0) begin
                rdata<=mem[raddr[19:0]]; rid<=r_id; rvalid<=1;
                rlast<=(rleft==0);
                if (rleft==0) begin arready<=1; r_id<=0; end
                else rleft<=rleft-1;
                raddr<=raddr+1;
            end
            if (rvalid && rready) rvalid<=0;
        end
    end
endmodule
```

- [ ] **Step 5: 写 `sim/video/tb_video_path.v`（先红：先不传 ROW_OFFSET）**

TB 用 `SIM_BYPASS_CAMERA=1` 直接驱动 16-bit 像素：

```verilog
`timescale 1ns/1ps
`define CHECK(cond,msg) if (!(cond)) begin $display("VIDEO_PATH: FAIL %s (t=%0t x=%0d y=%0d got=%04x exp=%04x)", msg, $time, cx, cy, got, exp); $fatal; end
module tb_video_path;
    reg vin_clk=0, ddr_clk=0, lcd_clk=0, rstn=0;
    always #5 vin_clk=~vin_clk;      // 100 MHz
    always #4 ddr_clk=~ddr_clk;      // 125 MHz
    always #9.6295 lcd_clk=~lcd_clk; // 51.923 MHz

    reg vin_de=0, vin_vsync=0; reg [15:0] vin_pix=0;
    wire [27:0] awaddr; wire [3:0] awlen; wire awvalid, awready;
    wire [255:0] wdata; wire [31:0] wstrb; wire wvalid, wready, wusero_last;
    wire [27:0] araddr; wire [3:0] arlen, aruser_id; wire arvalid, arready;
    wire [255:0] rdata; wire [3:0] rid; wire rlast, rvalid, rready;
    wire lcd_pclk, lcd_de, lcd_hs, lcd_vs, lcd_pwm;
    wire [7:0] lcd_r, lcd_g, lcd_b;
    wire frame_toggle, wr_bank, cam_init_done, ovl_bank;

    video_passthrough #(.SIM_BYPASS_CAMERA(1), .ROW_OFFSET(`ROW_OFFSET)) dut (
        .sys_clk(vin_clk), .cam_rstn(rstn), .ddr_clk(ddr_clk), .ddr_rstn(rstn),
        .lcd_clk(lcd_clk), .lcd_rstn(rstn), .ddr_init_done(rstn),
        .camera_clk_0(1'b0), .camera_data_0(8'd0), .camera_href_0(1'b0),
        .camera_vsync_0(1'b0), .SCL_0(), .SDA_0(), .cam_rst_0(),
        .vin_clk(vin_clk), .vin_de(vin_de), .vin_vsync(vin_vsync), .vin_pix(vin_pix),
        .ddr_awaddr(awaddr), .ddr_awlen(awlen), .ddr_awvalid(awvalid), .ddr_awready(awready),
        .ddr_wdata(wdata), .ddr_wstrb(wstrb), .ddr_wvalid(wvalid), .ddr_wready(wready),
        .ddr_wusero_last(wusero_last),
        .ddr_araddr(araddr), .ddr_arlen(arlen), .ddr_arvalid(arvalid), .ddr_arready(arready),
        .ddr_rdata(rdata), .ddr_rid(rid), .ddr_rlast(rlast), .ddr_rvalid(rvalid), .ddr_rready(rready),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_pwm(lcd_pwm),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .frame_toggle(frame_toggle), .wr_bank(wr_bank), .cam_init_done(cam_init_done),
        .ovl_wr_clk(vin_clk), .ovl_wr_rstn(rstn), .ovl_wr_en(1'b0), .ovl_wr_addr(5'd0),
        .ovl_wr_data(32'd0), .ovl_commit(1'b0), .ovl_en(1'b0), .ovl_count(8'd0),
        .ovl_active_bank(ovl_bank)
    );

    ddr_model ddr (.clk(ddr_clk), .rstn(rstn),
        .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .wusero_last(wusero_last),
        .araddr(araddr), .arlen(arlen), .aruser_id(aruser_id), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rid(rid), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    // 1920×1080 的简单图案（只用到 1280×720）：
    //   一行 = 1280 像素；vsync 低有效脉冲 4 拍；de=1 持续 1280 拍
    task drive_frame(input integer n);
        integer x, y;
        begin
            vin_vsync=0; @(posedge vin_clk); vin_vsync=1; repeat(4) @(posedge vin_clk);
            for (y=0; y<720; y=y+1) begin
                for (x=0; x<1280; x=x+1) begin
                    vin_pix = {x[7:0], y[7:0]};
                    vin_de = 1;
                    @(posedge vin_clk);
                end
                vin_de=0;
                repeat(40) @(posedge vin_clk);
            end
        end
    endtask

    integer cx, cy, errs=0; reg [15:0] got, exp;
    // 显示侧捕获：VS 脉冲（低有效）清行列；DE 有效期间逐像素比对
    always @(posedge lcd_pclk) begin
        if (lcd_vs == 1'b0) begin
            cx <= 0; cy <= 0;
        end else if (lcd_de) begin
            got = {lcd_r[7:5], lcd_g[7:4], lcd_b[7:3]};   // 888 -> 565 还原
            exp = {(cx+128) & 8'hFF, (cy+`ROW_OFFSET) & 8'hFF};
            if (got !== exp) errs = errs + 1;
            if (cx==1023) begin cx <= 0; cy <= cy + 1; end else cx <= cx + 1;
        end
    end

    initial begin
        repeat(10) @(posedge vin_clk); rstn=1;
        drive_frame(0);   // 第 1 帧写 bank0
        drive_frame(1);   // 第 2 帧写 bank1
        repeat(4_000_000) @(posedge lcd_clk);
        if (errs==0) $display("VIDEO_PATH: PASS");
        else begin $display("VIDEO_PATH: FAIL mismatches=%0d", errs); $fatal; end
        $finish;
    end
endmodule
```

- [ ] **Step 6: 先红——行偏移故意设 0 跑一次**

```bash
cd /d/code/PDS/VexiiYeshenLinux/sim/video
iverilog -g2012 -DROW_OFFSET=0 -o tb_video_path_red.vvp tb_video_path.v ddr_model.v \
  ../../board/cam/video_passthrough.v \
  ../../board/cam/vendor/camera/camera.v ../../board/cam/vendor/camera/camera_data.v \
  ../../board/cam/vendor/tutorial/cmos_8_16bit.v \
  ../../board/cam/vendor/tutorial/fram_buf.v ../../board/cam/vendor/tutorial/wr_buf.v \
  ../../board/cam/vendor/tutorial/rd_buf.v ../../board/cam/vendor/tutorial/wr_ctrl.v \
  ../../board/cam/vendor/tutorial/rd_ctrl.v ../../board/cam/vendor/tutorial/wr_cmd_trans.v \
  ../../board/cam/vendor/tutorial/wr_rd_ctrl_top.v ../../board/cam/vendor/sync_vg.v \
  ../../board/cam/vendor/ip/wr_fram_buf/wr_fram_buf.v ../../board/cam/vendor/ip/rd_fram_buf/rd_fram_buf.v \
  ../../board/cam/vendor/stub_rambuf.v ../../board/cam/vendor/stub_rambuf_sync.v 2>&1 | head -20
vvp tb_video_path_red.vvp | tail -5
```

Expected: `VIDEO_PATH: FAIL mismatches=...`（**必红**；若通过说明行偏移/裁列没生效）。

- [ ] **Step 7: 绿——ROW_OFFSET=60 重跑**

同上命令把 `-DROW_OFFSET=0` 换成 `-DROW_OFFSET=60`、输出 `tb_video_path_green.vvp`。

Expected: `VIDEO_PATH: PASS`。

- [ ] **Step 8: Commit**

```bash
git add board/cam board/pll_lcd.v sim/video/tb_video_path.v sim/video/ddr_model.v
git commit -m "video: passthrough wrapper with centered column crop and row-offset 60 (U2 red/green)"
```

---

## Task 3: 叠加引擎 + U3 闸门

**Files:**
- Create: `board/cam/overlay.v`
- Test: `sim/video/tb_overlay.v`

- [ ] **Step 1: 写 `board/cam/overlay.v`（16 框、2 px、双 bank、vsync 切换）**

```verilog
module overlay #(parameter MAXBOX=16)(
    input  wire        lcd_clk,
    input  wire        lcd_rstn,
    input  wire [10:0] pix_x,
    input  wire [9:0]  pix_y,
    input  wire        pix_de,
    input  wire [15:0] pix_in,
    output wire [15:0] pix_out,
    input  wire        vsync,        // 帧同步（任意极性，用上升沿）
    input  wire        hs,           // 行同步（用上升沿触发 box 预取；消隐期足够）
    // 写口（soc_clk 域）
    input  wire        wr_clk,
    input  wire        wr_rstn,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,      // {box[3:0], word}
    input  wire [31:0] wr_data,
    input  wire        commit,
    input  wire        ovl_en,
    input  wire [7:0]  ovl_count,
    output reg         active_bank
);
    // 双 bank：每 bank 16 box × 2 word = 32 word
    reg [31:0] box_mem [0:63];
    // 写 bank = ~active_bank（跨到 wr_clk 用 2FF；切换滞后一帧无影响）
    reg ab_w1, ab_w2;
    always @(posedge wr_clk) begin ab_w1<=active_bank; ab_w2<=ab_w1; end
    wire wr_bank = ~ab_w2;
    always @(posedge wr_clk) if (wr_en) box_mem[{wr_bank, wr_addr}] <= wr_data;

    // commit：wr_clk 脉冲 -> lcd 域，vsync 时切换
    reg pend_w; always @(posedge wr_clk) if (!wr_rstn) pend_w<=0; else if (commit) pend_w<=1;
    reg pw1,pw2; always @(posedge lcd_clk) begin pw1<=pend_w; pw2<=pw1; end
    reg vs_d; always @(posedge lcd_clk) vs_d<=vsync;
    wire vs_rise = vsync & ~vs_d;
    always @(posedge lcd_clk) begin
        if (!lcd_rstn) active_bank<=0;
        else if (vs_rise && pw2) active_bank<=~active_bank;
    end
    // 行首把 32 个 word 预取到寄存器（每行 32 拍，消隐区足够）
    reg [31:0] bq [0:31];   // 每框 2 word，16 框 = 32 word（行首预取）
    reg [5:0]  ld_idx; reg ld_run, hs_d;
    always @(posedge lcd_clk) begin
        if (!lcd_rstn) begin ld_run<=0; ld_idx<=0; end
        else begin
            if (hs && !hs_d) begin ld_run<=1; ld_idx<=0; end
            else if (ld_run) begin
                bq[ld_idx] <= box_mem[{active_bank, ld_idx[4:0]}];
                if (ld_idx==31) ld_run<=0; else ld_idx<=ld_idx+6'd1;
            end
        end
        hs_d <= hs;
    end
    // 每像素：16 框边框比较（2 px）
    integer k; reg hit;
    always @(*) begin
        hit = 0;
        for (k=0;k<MAXBOX;k=k+1) begin
            if (k < ovl_count) begin
                // bq[{k,0}] = {x1[15:0], y1[15:0]}；bq[{k,1}] = {x2[15:0], y2[15:0]}
                if (pix_x>=bq[{k[3:0],1'b0}][31:16] && pix_x<=bq[{k[3:0],1'b1}][31:16] &&
                    pix_y>=bq[{k[3:0],1'b0}][15:0]  && pix_y<=bq[{k[3:0],1'b1}][15:0]) begin
                    if (pix_x < bq[{k[3:0],1'b0}][31:16] + 2 ||
                        pix_x + 2 > bq[{k[3:0],1'b1}][31:16] ||
                        pix_y < bq[{k[3:0],1'b0}][15:0] + 2 ||
                        pix_y + 2 > bq[{k[3:0],1'b1}][15:0]) hit = 1;
                end
            end
        end
    end
    assign pix_out = (ovl_en && pix_de && hit) ? 16'h07E0 : pix_in;
endmodule
```

（若综合器不接受 `bq[{k,1'b0}]` 这种变量位选，改成 16 组显式寄存器或把 bq 拆成
`bq_x1[k]` 等四个数组；行为不变。）

- [ ] **Step 2: 写 `sim/video/tb_overlay.v`**

```verilog
`timescale 1ns/1ps
module tb_overlay;
    reg clk=0, rstn=0; always #9.6295 clk=~clk;
    reg [10:0] x=0; reg [9:0] y=0; reg de=1; reg [15:0] pin=16'h1234;
    wire [15:0] pout; reg vsync=0; reg hs=0;
    reg wr_en=0; reg [4:0] wa=0; reg [31:0] wd=0; reg commit=0; reg en=1; reg [7:0] cnt=1;
    wire ab;
    overlay dut(.lcd_clk(clk),.lcd_rstn(rstn),.pix_x(x),.pix_y(y),.pix_de(de),
        .pix_in(pin),.pix_out(pout),.vsync(vsync),.hs(hs),
        .wr_clk(clk),.wr_rstn(rstn),.wr_en(wr_en),.wr_addr(wa),.wr_data(wd),
        .commit(commit),.ovl_en(en),.ovl_count(cnt),.active_bank(ab));
    task wr(input [4:0] a, input [31:0] d); begin
        @(posedge clk); wr_en=1; wa=a; wd=d; @(posedge clk); wr_en=0;
    end endtask
    task sw(input [10:0] xx, input [9:0] yy, output [15:0] o); begin
        x=xx; y=yy; de=1; #1 o=pout;
    end endtask
    reg [15:0] o; reg ok=1;
    initial begin
        repeat(5) @(posedge clk); rstn=1;
        // box0: (100,100)-(199,199)
        wr(5'd0, {16'd100,16'd100}); wr(5'd1, {16'd199,16'd199});
        @(posedge clk); commit=1; @(posedge clk); commit=0;
        // vsync 切换 + 行首 hs 上升沿触发 32 拍预取
        vsync=1; @(posedge clk); vsync=0;
        hs=1; @(posedge clk); hs=0;
        for (int i=0;i<40;i=i+1) begin x=0; @(posedge clk); end
        // 命中边框
        sw(100,150,o); if (o!==16'h07E0) ok=0;
        sw(199,150,o); if (o!==16'h07E0) ok=0;
        sw(150,100,o); if (o!==16'h07E0) ok=0;
        sw(150,199,o); if (o!==16'h07E0) ok=0;
        // 框内非边框：不命中
        sw(150,150,o); if (o!==16'h1234) ok=0;
        // 框外：不命中
        sw(99,150,o);  if (o!==16'h1234) ok=0;
        // 旁路
        en=0; sw(100,150,o); if (o!==16'h1234) ok=0; en=1;
        if (ok) $display("OVERLAY: PASS"); else begin $display("OVERLAY: FAIL"); $fatal; end
        $finish;
    end
endmodule
```

- [ ] **Step 3: 先红（把 2 px 改成 1 px 或坐标 +1）→ 绿**

Run: `iverilog -g2012 -o tb_overlay.vvp tb_overlay.v ../../board/cam/overlay.v && vvp tb_overlay.vvp`
Expected: `OVERLAY: PASS`。再做一次变异（把 `pix_x+2` 改成 `+3`）确认 `OVERLAY: FAIL` 后还原。

- [ ] **Step 4: Commit**

```bash
git add board/cam/overlay.v sim/video/tb_overlay.v
git commit -m "video: 16-box 2px overlay engine with double-banked box table (U3)"
```

---

## Task 4: VIDEO 寄存器窗（CSR）+ U4 闸门

**Files:**
- Create: `board/cam/video_regs.v`
- Test: `sim/video/tb_video_regs.v`

- [ ] **Step 1: 写 `board/cam/video_regs.v`**

寄存器映射（窗内偏移）：

| 偏移 | 名称 | 说明 |
|---:|---|---|
| 0x000 | STATUS | RO：[0] init_done；[1] 写 bank；[31:8] 24-bit 帧序号 |
| 0x004 | DBG | RO：[15:0] 视频读请求等待计数（core_clk 打拍到 soc_clk） |
| 0x008 | OVERLAY_CTRL | RW：[0] 使能；[1] commit（写 1）；[15:8] 框数 |
| 0x010..0x08F | BOX[16] | RW：每框 8 B（x1,y1,x2,y2，u16 小端） |
| 0x090 | VERSION | RO：0x0001_0001 |

```verilog
module video_regs (
    input  wire        clk,        // soc_clk
    input  wire        rstn,       // 同步低有效
    // AxiLite4 从口（窗内偏移）
    input  wire [11:0] s_awaddr, input wire s_awvalid, output reg s_awready,
    input  wire [31:0] s_wdata,  input wire [3:0] s_wstrb, input wire s_wvalid,
    output reg         s_wready, output reg s_bvalid, input wire s_bready,
    output wire [1:0]  s_bresp,
    input  wire [11:0] s_araddr, input wire s_arvalid, output reg s_arready,
    output reg  [31:0] s_rdata,  output reg s_rvalid, input wire s_rready,
    output wire [1:0]  s_rresp,
    // 异步帧状态（core_clk 域）
    input  wire        frame_toggle,
    input  wire        wr_bank,
    input  wire        init_done,
    input  wire [15:0] vid_stall,
    // overlay 写口
    output reg         ovl_wr_en,
    output reg  [4:0]  ovl_wr_addr,
    output reg  [31:0] ovl_wr_data,
    output reg         ovl_commit,
    output reg         ovl_en,
    output reg  [7:0]  ovl_count,
    input  wire        ovl_active_bank
);
    assign s_bresp = 2'b00;
    assign s_rresp = 2'b00;

    // --- 帧事件跨域：toggle 边沿 -> 帧序号 + bank 快照 ---
    reg ft1, ft2, ft3; reg [23:0] seq; reg bank_r; reg id_r;
    reg wb1, wb2, id1, id2; reg [15:0] st1, st2;
    always @(posedge clk) begin
        ft1<=frame_toggle; ft2<=ft1; ft3<=ft2;
        wb1<=wr_bank; wb2<=wb1; id1<=init_done; id2<=id1;
        st1<=vid_stall; st2<=st1;
    end
    wire ft_edge = ft2 ^ ft3;
    always @(posedge clk) begin
        if (!rstn) begin seq<=0; bank_r<=0; id_r<=0; end
        else begin
            if (ft_edge) begin seq<=seq+1; bank_r<=wb2; end
            id_r<=id2;
        end
    end

    // --- 寄存器写 ---
    reg [31:0] reg_ctrl; reg [31:0] box_shadow [0:31];   // 写镜像（读回用）
    integer i;
    always @(posedge clk) begin
        if (!rstn) begin
            s_awready<=0; s_wready<=0; s_bvalid<=0; s_arready<=0; s_rvalid<=0; s_rdata<=0;
            reg_ctrl<=0; ovl_wr_en<=0; ovl_commit<=0; ovl_wr_addr<=0; ovl_wr_data<=0;
            ovl_en<=0; ovl_count<=0;
        end else begin
            // 写地址握手
            if (s_awvalid && !s_awready) s_awready<=1;
            if (s_wvalid && !s_wready)   s_wready<=1;
            if (s_awready && s_awvalid)  s_awready<=0;
            if (s_wready && s_wvalid)    s_wready<=0;
            if ((s_awready && s_awvalid) && (s_wready && s_wvalid)) s_bvalid<=1;
            if (s_bvalid && s_bready) s_bvalid<=0;

            ovl_wr_en<=0; ovl_commit<=0;
            if (s_wready && s_wvalid && s_awready) begin
                if (s_awaddr[11:4]==8'h00) begin
                    case (s_awaddr[3:0])
                        4'h8: begin
                            reg_ctrl <= s_wdata;
                            ovl_en    <= s_wdata[0];
                            ovl_count <= s_wdata[15:8];
                            if (s_wdata[1]) ovl_commit <= 1;
                        end
                        default: ;
                    endcase
                end else if (s_awaddr>=12'h010 && s_awaddr<12'h090) begin
                    // BOX k 在 0x010 + 8*k：box = addr[6:3]-2，word = addr[2]
                    ovl_wr_en   <= 1;
                    ovl_wr_addr <= {s_awaddr[6:3]-4'd2, s_awaddr[2]};
                    ovl_wr_data <= s_wdata;
                    box_shadow[{s_awaddr[6:3]-4'd2, s_awaddr[2]}] <= s_wdata;
                end
            end

            // 读
            if (s_arvalid && !s_arready) s_arready<=1;
            if (s_arready && s_arvalid)  s_arready<=0;
            if (s_arready && s_arvalid) begin
                s_rvalid<=1;
                case (s_araddr[7:0])
                    8'h00: s_rdata <= {seq, 6'd0, bank_r, id_r};
                    8'h04: s_rdata <= {16'd0, st2};
                    8'h08: s_rdata <= {16'd0, ovl_count, 7'd0, ovl_en};
                    8'h90: s_rdata <= 32'h0001_0001;
                    default: begin
                        if (s_araddr>=12'h010 && s_araddr<12'h090)
                            s_rdata <= box_shadow[{s_araddr[6:3]-4'd2, s_araddr[2]}];
                        else s_rdata <= 32'd0;
                    end
                endcase
            end
            if (s_rvalid && s_rready) s_rvalid<=0;
        end
    end
endmodule
```

> 注：BOX 读回不在硬件里做镜像（软件自己缓存）；V2 的 gate 用 `OVERLAY_CTRL` 读回 +
> 屏幕目视判据。若需要硬件读回，在 `box_lo/hi` 加写镜像并在读分支返回。

- [ ] **Step 2: 写 `sim/video/tb_video_regs.v`（AxiLite 任务 + 帧 toggle + commit）**

```verilog
`timescale 1ns/1ps
module tb_video_regs;
    reg clk=0, rstn=0; always #5 clk=~clk;
    reg [11:0] awaddr=0, araddr=0; reg awvalid=0, wvalid=0, arvalid=0, bready=1, rready=1;
    reg [31:0] wdata=0; wire awready, wready, bvalid, arready, rvalid; wire [31:0] rdata;
    reg ftoggle=0, wb=0, idone=1; reg [15:0] stall=0;
    wire wr_en, commit, oen, ab; wire [4:0] wa; wire [31:0] wd; wire [7:0] cnt;
    video_regs dut(.clk(clk),.rstn(rstn),
      .s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),
      .s_wdata(wdata),.s_wstrb(4'hF),.s_wvalid(wvalid),.s_wready(wready),
      .s_bvalid(bvalid),.s_bready(bready),.s_bresp(),
      .s_araddr(araddr),.s_arvalid(arvalid),.s_arready(arready),
      .s_rdata(rdata),.s_rvalid(rvalid),.s_rready(rready),.s_rresp(),
      .frame_toggle(ftoggle),.wr_bank(wb),.init_done(idone),.vid_stall(stall),
      .ovl_wr_en(wr_en),.ovl_wr_addr(wa),.ovl_wr_data(wd),.ovl_commit(commit),
      .ovl_en(oen),.ovl_count(cnt),.ovl_active_bank(ab));
    task wr(input [11:0] a, input [31:0] d); begin
        @(posedge clk); awaddr=a; wdata=d; awvalid=1; wvalid=1;
        @(posedge clk); awvalid=0; wvalid=0; @(posedge clk);
    end endtask
    task rd(input [11:0] a, output [31:0] d); begin
        @(posedge clk); araddr=a; arvalid=1; @(posedge clk); arvalid=0;
        while (!rvalid) @(posedge clk); d=rdata; @(posedge clk);
    end endtask
    reg [31:0] d; integer ok=1;
    initial begin
        repeat(5) @(posedge clk); rstn=1;
        wr(12'h008, 32'h0000_2101);      // en + count=0x21 + commit
        @(posedge clk); if (!commit) ok=0; @(posedge clk);
        rd(12'h008, d); if (d[0]!==1 || d[15:8]!==8'h21) ok=0;
        rd(12'h090, d); if (d!==32'h0001_0001) ok=0;
        // 帧事件 3 次
        repeat(3) begin ftoggle=~ftoggle; repeat(4) @(posedge clk); end
        rd(12'h000, d); if (d[31:8]!==24'd3) ok=0;
        // BOX 写：box2 word0 = (10,20)
        wr(12'h010 + 12'h10 + 12'h0, {16'd10,16'd20});
        @(posedge clk); if (!wr_en) ok=0;
        if (!(wa==5'd4)) ok=0;
        if (ok) $display("VIDEO_REGS: PASS"); else begin $display("VIDEO_REGS: FAIL"); $fatal; end
        $finish;
    end
endmodule
```

- [ ] **Step 3: 跑 U4**

Run: `cd sim/video && iverilog -g2012 -o tb_video_regs.vvp tb_video_regs.v ../../board/cam/video_regs.v && vvp tb_video_regs.vvp`
Expected: `VIDEO_REGS: PASS`。

- [ ] **Step 4: Commit**

```bash
git add board/cam/video_regs.v sim/video/tb_video_regs.v
git commit -m "video: 1KiB CSR window regs (status/ctrl/boxes) with frame-event CDC (U4)"
```

---

## Task 5: DDR 2:1 仲裁器 + U1 闸门

**Files:**
- Create: `board/cam/ddr_arbiter_2to1.v`
- Test: `sim/video/tb_ddr_arbiter.v`

- [ ] **Step 1: 写 `board/cam/ddr_arbiter_2to1.v`**

```verilog
module ddr_arbiter_2to1 #(parameter AW=28)(
    input  wire clk, rstn,
    // ---- 桥侧（ID=0） ----
    input  wire [AW-1:0] b_awaddr, input wire [3:0] b_awlen,
    input  wire b_awvalid, output wire b_awready,
    input  wire [255:0] b_wdata, input wire [31:0] b_wstrb,
    input  wire b_wvalid, output wire b_wready,
    input  wire [AW-1:0] b_araddr, input wire [3:0] b_arlen,
    input  wire b_arvalid, output wire b_arready,
    output wire [255:0] b_rdata, output wire [3:0] b_rid,
    output wire b_rlast, output wire b_rvalid, input wire b_rready,
    // ---- 视频侧（ID=1） ----
    input  wire [AW-1:0] v_awaddr, input wire [3:0] v_awlen,
    input  wire v_awvalid, output wire v_awready,
    input  wire [255:0] v_wdata, input wire [31:0] v_wstrb,
    input  wire v_wvalid, output wire v_wready,
    input  wire [AW-1:0] v_araddr, input wire [3:0] v_arlen,
    input  wire v_arvalid, output wire v_arready,
    output wire [255:0] v_rdata, output wire [3:0] v_rid,
    output wire v_rlast, output wire v_rvalid, input wire v_rready
    // ---- DDR IP 简化口 ----
    output reg  [AW-1:0] m_awaddr, output reg [3:0] m_awlen,
    output reg  m_awvalid, input wire m_awready,
    output reg  [255:0] m_wdata, output reg [31:0] m_wstrb,
    output reg  m_wvalid, input wire m_wready,
    input  wire m_wusero_last,
    output reg  [AW-1:0] m_araddr, output reg [3:0] m_arlen,
    output reg  [3:0] m_aruser_id,
    output reg  m_arvalid, input wire m_arready,
    input  wire [255:0] m_rdata, input wire [3:0] m_rid,
    input  wire m_rlast, input wire m_rvalid, output wire m_rready,
    output wire b_wlast,                        // 桥不需要，留作观测
    output wire v_wlast,                        // 视频写完成（接 fram_buf.axi_wlast）
    output reg  [31:0] dbg_v_ar_wait           // 视频读请求等待拍数
);
    // ---------------- 写通道：AW+W 成对，一次一笔 ----------------
    localparam W_IDLE=0, W_AW=1, W_DATA=2;
    reg [1:0] wst; reg wsel; reg [3:0] wleft;
    always @(posedge clk) begin
        if (!rstn) begin wst<=W_IDLE; wsel<=0; wleft<=0; m_awvalid<=0; m_wvalid<=0; end
        else case (wst)
        W_IDLE: begin
            // 视频优先；桥侧只有 awvalid&&wvalid 才授予
            if (v_awvalid && v_wvalid) begin
                wsel<=1; m_awaddr<=v_awaddr; m_awlen<=v_awlen; m_awvalid<=1; wst<=W_AW;
            end else if (b_awvalid && b_wvalid) begin
                wsel<=0; m_awaddr<=b_awaddr; m_awlen<=b_awlen; m_awvalid<=1; wst<=W_AW;
            end
        end
        W_AW: if (m_awready) begin
            m_awvalid<=0; m_wdata<=wsel? v_wdata : b_wdata;
            m_wstrb<=wsel? v_wstrb : b_wstrb;
            m_wvalid<=1; wleft<=wsel? v_awlen : b_awlen; wst<=W_DATA;
        end
        W_DATA: if (m_wready) begin
            if (m_wusero_last || wleft==0) begin
                m_wvalid<=0; wst<=W_IDLE;
            end else begin
                wleft<=wleft-1'b1;
                m_wdata<=wsel? v_wdata : b_wdata;
                m_wstrb<=wsel? v_wstrb : b_wstrb;
            end
        end
        endcase
    end
    assign b_wready = (wst==W_DATA && wsel==0) ? m_wready : 1'b0;
    assign v_wready = (wst==W_DATA && wsel==1) ? m_wready : 1'b0;
    assign b_awready = (wst==W_AW && wsel==0 && m_awready) ? 1'b1 : 1'b0;
    assign v_awready = (wst==W_AW && wsel==1 && m_awready) ? 1'b1 : 1'b0;
    assign b_wlast = m_wusero_last && (wsel==0);
    assign v_wlast = m_wusero_last && (wsel==1);

    // ---------------- 读通道 ----------------
    localparam R_IDLE=0, R_WAIT=1;
    reg rst_rd; reg rsel; reg [4:0] rbeats;
    always @(posedge clk) begin
        if (!rstn) begin rst_rd<=R_IDLE; rsel<=0; m_arvalid<=0; rbeats<=0; dbg_v_ar_wait<=0; end
        else begin
            if (v_arvalid && !v_arready) dbg_v_ar_wait <= dbg_v_ar_wait + 1;
            case (rst_rd)
            R_IDLE: begin
                // 轮转：桥优先一次后让视频一次（简化：v 优先，但桥等待计数强让）
                if (v_arvalid) begin
                    rsel<=1; m_araddr<=v_araddr; m_arlen<=v_arlen; m_aruser_id<=4'h1;
                    m_arvalid<=1; rst_rd<=R_WAIT;
                end else if (b_arvalid) begin
                    rsel<=0; m_araddr<=b_araddr; m_arlen<=b_arlen; m_aruser_id<=4'h0;
                    m_arvalid<=1; rst_rd<=R_WAIT;
                end
            end
            R_WAIT: if (m_arready) begin
                m_arvalid<=0;
                if (m_rvalid && m_rlast) rst_rd<=R_IDLE;
            end else if (m_rvalid && m_rlast) rst_rd<=R_IDLE;
            endcase
        end
    end
    assign b_arready = (rst_rd==R_WAIT && rsel==0 && m_arready) ? 1'b1 : 1'b0;
    assign v_arready = (rst_rd==R_WAIT && rsel==1 && m_arready) ? 1'b1 : 1'b0;
    assign m_rready = (m_rid==4'h1) ? v_rready : b_rready;
    assign b_rvalid = m_rvalid && (m_rid!=4'h1);
    assign v_rvalid = m_rvalid && (m_rid==4'h1);
    assign b_rdata = m_rdata; assign v_rdata = m_rdata;
    assign b_rid = m_rid;     assign v_rid = m_rid;
    assign b_rlast = m_rlast; assign v_rlast = m_rlast;
endmodule
```

- [ ] **Step 2: 写 `sim/video/tb_ddr_arbiter.v`（并发写 + RID 分流 + 负对照）**

```verilog
`timescale 1ns/1ps
module tb_ddr_arbiter;
    reg clk=0, rstn=0; always #4 clk=~clk;
    // 桥侧
    reg [27:0] baw=0, bar=0; reg [3:0] bal=0, brl=0; reg bav=0, barv=0, bwv=0;
    reg [255:0] bwd=0; reg [31:0] bws=32'hFFFF_FFFF;
    wire b_awready,b_wready,b_arready,b_rvalid,b_rlast; wire [255:0] b_rdata; wire [3:0] b_rid;
    reg b_rready=1;
    // 视频侧
    reg [27:0] vaw=0, var_=0; reg [3:0] val=0, vrl=0; reg vav=0, varv=0, vwv=0;
    reg [255:0] vwd=0; reg [31:0] vws=32'hFFFF_FFFF;
    wire v_awready,v_wready,v_arready,v_rvalid,v_rlast; wire [255:0] v_rdata; wire [3:0] v_rid;
    reg v_rready=1;
    // IP 侧
    wire [27:0] maw, mar; wire [3:0] mal, mrl, mrid, marid; wire mav, mwv, marv, m_awready, m_wready, m_arready, m_rvalid, m_rlast, m_wlast;
    wire [255:0] mwd, mrd; wire [31:0] mws;
    wire m_rready_w;
    ddr_model ddr(.clk(clk),.rstn(rstn),
      .awaddr(maw),.awlen(mal),.awvalid(mav),.awready(m_awready),
      .wdata(mwd),.wstrb(mws),.wvalid(mwv),.wready(m_wready),.wusero_last(m_wlast),
      .araddr(mar),.arlen(mrl),.aruser_id(marid),.arvalid(marv),.arready(m_arready),
      .rdata(mrd),.rid(mrid),.rlast(m_rlast),.rvalid(m_rvalid),.rready(m_rready_w));
    ddr_arbiter_2to1 dut(.clk(clk),.rstn(rstn),
      .b_awaddr(baw),.b_awlen(bal),.b_awvalid(bav),.b_awready(b_awready),
      .b_wdata(bwd),.b_wstrb(bws),.b_wvalid(bwv),.b_wready(b_wready),
      .b_araddr(bar),.b_arlen(brl),.b_arvalid(barv),.b_arready(b_arready),
      .b_rdata(b_rdata),.b_rid(b_rid),.b_rlast(b_rlast),.b_rvalid(b_rvalid),.b_rready(b_rready),
      .v_awaddr(vaw),.v_awlen(val),.v_awvalid(vav),.v_awready(v_awready),
      .v_wdata(vwd),.v_wstrb(vws),.v_wvalid(vwv),.v_wready(v_wready),
      .v_araddr(var_),.v_arlen(vrl),.v_arvalid(varv),.v_arready(v_arready),
      .v_rdata(v_rdata),.v_rid(v_rid),.v_rlast(v_rlast),.v_rvalid(v_rvalid),.v_rready(v_rready),
      .m_awaddr(maw),.m_awlen(mal),.m_awvalid(mav),.m_awready(m_awready),
      .m_wdata(mwd),.m_wstrb(mws),.m_wvalid(mwv),.m_wready(m_wready),
      .m_wusero_last(m_wlast),.m_araddr(mar),.m_arlen(mrl),.m_aruser_id(marid),
      .m_arvalid(marv),.m_arready(m_arready),.m_rdata(mrd),.m_rid(mrid),
      .m_rlast(m_rlast),.m_rvalid(m_rvalid),.m_rready(m_rready_w),
      .b_wlast(),.v_wlast(),.dbg_v_ar_wait());
    integer ok=1;
    task bwrite(input [27:0] a, input [255:0] d); begin
        @(posedge clk); baw=a; bwd=d; bav=1; bwv=1;
        while (!(bav && b_awready)) @(posedge clk);
        bav=0;
        while (!(bwv && b_wready)) @(posedge clk);
        bwv=0;
    end endtask
    task vwrite_burst(input [27:0] a, input [3:0] len, input [255:0] d0); begin
        @(posedge clk); vaw=a; val=len; vwd=d0; vav=1; vwv=1;
        while (!(vav && v_awready)) @(posedge clk);
        vav=0;
        for (int i=0; i<=len; i=i+1) begin
            vwd = d0 + i;
            while (!(vwv && v_wready)) @(posedge clk);
            @(posedge clk);
        end
        vwv=0;
    end endtask
    task bread(input [27:0] a, output [255:0] d); begin
        @(posedge clk); bar=a; barv=1;
        while (!(barv && b_arready)) @(posedge clk);
        barv=0;
        while (!b_rvalid) @(posedge clk); d=b_rdata; @(posedge clk);
    end endtask
    task vread(input [27:0] a, output [255:0] d); begin
        @(posedge clk); var_=a; vrl=0; varv=1;
        while (!(varv && v_arready)) @(posedge clk);
        varv=0;
        while (!v_rvalid) @(posedge clk); d=v_rdata; @(posedge clk);
    end endtask
    reg [255:0] got;
    initial begin
        repeat(5) @(posedge clk); rstn=1;
        // 1) 桥写 0x100，视频写 0x200
        bwrite(28'h100, 256'h1111);
        vwrite_burst(28'h200, 4'd0, 256'h2222);
        repeat(50) @(posedge clk);
        // 2) 读回分流：桥地址 0x100 -> 1111；视频地址 0x200 -> 2222
        bread(28'h100, got); if (got!==256'h1111) ok=0;
        vread(28'h200, got); if (got!==256'h2222) ok=0;
        // 3) 视频多拍 burst（len=3）写 0x300..0x303
        vwrite_burst(28'h300, 4'd3, 256'h3333);
        repeat(20) @(posedge clk);
        if (ok) $display("DDR_ARB: PASS"); else begin $display("DDR_ARB: FAIL"); $fatal; end
        $finish;
    end
endmodule
```

- [ ] **Step 3: 红/绿**

Run: `cd sim/video && iverilog -g2012 -o tb_ddr_arbiter.vvp tb_ddr_arbiter.v ddr_model.v ../../board/cam/ddr_arbiter_2to1.v && vvp tb_ddr_arbiter.vvp`
Expected: `DDR_ARB: PASS`。
负对照：把 `assign v_rvalid = m_rvalid && (m_rid==4'h1)` 临时改成 `m_rvalid`（或把
`m_rready` 恒接 `b_rready`），重跑必红；还原后 PASS。

- [ ] **Step 4: 汇总闸门脚本 `sim/video/run_video_gates.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
V=../../board/cam
iverilog -g2012 -o /tmp/u1.vvp tb_ddr_arbiter.v ddr_model.v $V/ddr_arbiter_2to1.v
vvp /tmp/u1.vvp | grep -q "DDR_ARB: PASS"
iverilog -g2012 -o /tmp/u3.vvp tb_overlay.v $V/overlay.v
vvp /tmp/u3.vvp | grep -q "OVERLAY: PASS"
iverilog -g2012 -o /tmp/u4.vvp tb_video_regs.v $V/video_regs.v
vvp /tmp/u4.vvp | grep -q "VIDEO_REGS: PASS"
iverilog -g2012 -DROW_OFFSET=60 -o /tmp/u2g.vvp tb_video_path.v ddr_model.v $V/video_passthrough.v \
  $V/vendor/camera/camera.v $V/vendor/camera/camera_data.v $V/vendor/tutorial/cmos_8_16bit.v \
  $V/vendor/tutorial/fram_buf.v $V/vendor/tutorial/wr_buf.v $V/vendor/tutorial/rd_buf.v \
  $V/vendor/tutorial/wr_ctrl.v $V/vendor/tutorial/rd_ctrl.v $V/vendor/tutorial/wr_cmd_trans.v \
  $V/vendor/tutorial/wr_rd_ctrl_top.v $V/vendor/sync_vg.v \
  $V/vendor/ip/wr_fram_buf/wr_fram_buf.v $V/vendor/ip/rd_fram_buf/rd_fram_buf.v \
  $V/vendor/stub_rambuf.v $V/vendor/stub_rambuf_sync.v
vvp /tmp/u2g.vvp | grep -q "VIDEO_PATH: PASS"
echo "VIDEO_GATES: ALL PASS"
```

Run: `bash sim/video/run_video_gates.sh` → `VIDEO_GATES: ALL PASS`。

- [ ] **Step 5: Commit**

```bash
git add board/cam/ddr_arbiter_2to1.v sim/video/tb_ddr_arbiter.v sim/video/run_video_gates.sh
git commit -m "video: 2:1 DDR simplified-AXI arbiter with RID split (U1 + firing negative)"
```

---

## Task 6: 胶合块 VIDEO 窗 + 台账 + 重生成

**Files:**
- Modify: `src/YeshenSocGlue.scala`（常量/端口/解码/接线）
- Modify: `scripts/check_addr_map.py`（NEW checks）
- Modify: `sim/glue_pbus/gen_glue.sh` + `tb_pbus.cpp`（窗探针）
- Regenerate: `rtl/YeshenSocGlue.v`

- [ ] **Step 1: Scala 常量（放在 DMA 常量之后）**

```scala
  // ---- VIDEO（摄像头/叠加寄存器窗；2026-10-19）----
  // 0xF000_5000–0x7FFF 空闲，但 0x5000/0x7000 是既有"未译码洞"探针（tb_pbus/tb_npu_pbus）
  // ⇒ 取 0x7400，1 KiB（掩码 0xFFFF_FC00），两端都避开探针。
  val VIDEO_BASE = 0xF0007400L
  val VIDEO_MASK = 0xFFFF_FC00L
```

- [ ] **Step 2: Bundle 端口（DMA 端口之后）**

```scala
  // ---- VIDEO 寄存器窗从口（形态与 npuAxi/dmaAxi 逐字同款；本模块是主方）----
  val videoAxi = new VexiiAxiLite32
```

- [ ] **Step 3: 解码与接线（DMA 段之后）**

```scala
  private val isVideoR = (pR & YeshenMap.VIDEO_MASK.U) === YeshenMap.VIDEO_BASE.U
  private val isVideoW = (pW & YeshenMap.VIDEO_MASK.U) === YeshenMap.VIDEO_BASE.U

  io.videoAxi.awaddr  := pW(9, 0)
  io.videoAxi.awprot  := pBus.awprot
  io.videoAxi.awvalid := pBus.awvalid && isVideoW
  io.videoAxi.wdata   := pBus.wdata
  io.videoAxi.wstrb   := pBus.wstrb
  io.videoAxi.wvalid  := pBus.wvalid && isVideoW
  io.videoAxi.bready  := pBus.bready
  io.videoAxi.araddr  := pR(9, 0)
  io.videoAxi.arprot  := pBus.arprot
  io.videoAxi.arvalid := pBus.arvalid && isVideoR
  io.videoAxi.rready  := pBus.rready
```

- [ ] **Step 4: 台账五处**

在 `scripts/check_addr_map.py` 的 `EXPECT` 加 `"VIDEO_BASE": 0xF000_7400`，并加：

```python
check("glue VIDEO_BASE", "src/YeshenSocGlue.scala",
      r"VIDEO_BASE\s*=\s*(0x[0-9A-Fa-f]+)L", EXPECT["VIDEO_BASE"],
      "YeshenSocGlue 的 VIDEO 寄存器窗解码（1 KiB；0x7400 避开 0x5000/0x7000 探针）")
```

同时在 `docs/开发板功能清单-2026-10-08.md` 的外设表加一行 VIDEO 窗。

- [ ] **Step 5: 胶合单测加窗探针**

在 `sim/glue_pbus/tb_pbus.cpp` 加：

```cpp
    // VIDEO 窗（0xF0007400）：test top 里给 videoAxi 接一个"始终 ready、读回 0xA5A50001"
    // 的一寄存器从口；写入后读回必须等于该常量（沿用 harness 现有 K_OK 分类）。
    { 0xF0007400u, K_OK, "VIDEO 窗基址（期望读回 0xA5A50001）" },
```

并保留现有 `{0xF0005000u, K_UNDEC}`、`{0xF0007000u, K_UNDEC}`。

- [ ] **Step 6: 重生成胶合网表**

```bash
cd /d/code/PDS/VexiiYeshenLinux
SC=/c/Users/Ziqi/AppData/Local/Coursier/data/bin/scala-cli.bat
"$SC" --power package src --assembly -o YeshenSocGlue.jar --main-class YeshenSocGlueMain -f
java -jar YeshenSocGlue.jar
grep -q "^module YeshenSocGlue" rtl/YeshenSocGlue.v && echo "GLUE-REGEN-OK"
grep -c "videoAxi" rtl/YeshenSocGlue.v
```

Expected: `GLUE-REGEN-OK`；端口计数 > 0。

- [ ] **Step 7: 跑胶合回归**

```bash
cd sim/glue_pbus
bash gen_glue.sh          # 若 top 需新端口
bash run_unit.sh && bash run_npu_unit.sh && bash run_dma_pbus_unit.sh && bash run_memmerge_unit.sh
python ../../scripts/check_addr_map.py
```

Expected: 全 PASS / `ALL LEDGER CHECKS PASS`。

- [ ] **Step 8: Commit**

```bash
git add src/YeshenSocGlue.scala rtl/YeshenSocGlue.v scripts/check_addr_map.py sim/glue_pbus docs/开发板功能清单-2026-10-08.md
git commit -m "glue: VIDEO CSR window at 0xF0007400 (1KiB) + ledger and glue gates"
```

---

## Task 7: 板级集成（SoC 端口 / board top / FDC / PDS 源）

**Files:**
- Modify: `board/yeshen_mini_soc.v`
- Modify: `board/yeshen_mini_board_top.v`
- Modify: `constraints/yeshen_mini.fdc`
- Modify: `pds/run_devmap_yeshen.tcl`, `pds/run_pnr_yeshen.tcl`

- [ ] **Step 1: `yeshen_mini_soc.v` 暴露 glue 的 videoAxi 主口**

在模块端口加（输出组，逐字对应 glue 端口名 `io_videoAxi_*`）：

```verilog
    // VIDEO 寄存器窗（glue 主口 → 板级 video_regs 从口）
    output wire        video_awvalid,
    output wire [9:0]  video_awaddr,
    output wire [2:0]  video_awprot,
    output wire        video_wvalid,
    output wire [31:0] video_wdata,
    output wire [3:0]  video_wstrb,
    input  wire        video_bvalid,
    output wire        video_bready,
    input  wire [1:0]  video_bresp,
    output wire        video_arvalid,
    output wire [9:0]  video_araddr,
    output wire [2:0]  video_arprot,
    input  wire        video_rvalid,
    output wire        video_rready,
    input  wire [31:0] video_rdata,
    input  wire [1:0]  video_rresp,
```

例化 glue 时接：

```verilog
        .io_videoAxi_awvalid (video_awvalid),
        .io_videoAxi_awaddr  (video_awaddr),
        .io_videoAxi_awprot  (video_awprot),
        .io_videoAxi_wvalid  (video_wvalid),
        .io_videoAxi_wdata   (video_wdata),
        .io_videoAxi_wstrb   (video_wstrb),
        .io_videoAxi_bvalid  (video_bvalid),
        .io_videoAxi_bready  (video_bready),
        .io_videoAxi_bresp   (video_bresp),
        .io_videoAxi_arvalid (video_arvalid),
        .io_videoAxi_araddr  (video_araddr),
        .io_videoAxi_arprot  (video_arprot),
        .io_videoAxi_rvalid  (video_rvalid),
        .io_videoAxi_rready  (video_rready),
        .io_videoAxi_rdata   (video_rdata),
        .io_videoAxi_rresp   (video_rresp),
```

- [ ] **Step 2: board top 例化 PLL / 视频 / 寄存器 / 仲裁器**

```verilog
    // LCD 像素时钟 51.923 MHz
    wire lcd_pclk_raw, lcd_pclk, pll_lock_lcd;
    pll_lcd u_pll_lcd (.clkout0(lcd_pclk_raw), .clkin1(clk_in), .lock(pll_lock_lcd));
    GTP_CLKBUFG u_lcdclk_bufg (.CLKIN(lcd_pclk_raw), .CLKOUT(lcd_pclk));

    // DDR 仲裁器：桥 + 视频 → u_ddr3
    wire [27:0] vid_awaddr, vid_araddr;
    wire [3:0]  vid_awlen, vid_arlen, vid_rid, ddr_rid;   // ddr_rid 来自 IP
    wire        vid_awvalid, vid_awready, vid_wvalid, vid_wready, vid_wlast;
    wire [255:0] vid_wdata, vid_rdata;
    wire [31:0] vid_wstrb;
    wire        vid_arvalid, vid_arready, vid_rvalid, vid_rlast, vid_rready;
    wire [27:0] m_awaddr, m_araddr;
    wire [3:0]  m_awlen, m_arlen;
    wire        m_awvalid, m_awready, m_wvalid, m_wready, m_arvalid, m_arready;
    wire [255:0] m_wdata, m_rdata;
    wire [31:0] m_wstrb;
    wire [3:0]  m_aruser_id;
    wire        m_rvalid, m_rlast;
    wire        m_wusero_last;
    wire [31:0] dbg_vid_ar_wait;

    ddr_arbiter_2to1 u_ddr_arb (
        .clk(core_clk), .rstn(ddr_rstn),
        .b_awaddr(ddr_axi_awaddr), .b_awlen(ddr_axi_awlen),
        .b_awvalid(ddr_axi_awvalid), .b_awready(ddr_axi_awready),
        .b_wdata(ddr_axi_wdata), .b_wstrb(ddr_axi_wstrb),
        .b_wvalid(ddr_axi_wvalid), .b_wready(ddr_axi_wready),
        .b_araddr(ddr_axi_araddr), .b_arlen(ddr_axi_arlen),
        .b_arvalid(ddr_axi_arvalid), .b_arready(ddr_axi_arready),
        .b_rdata(ddr_axi_rdata), .b_rid(ddr_axi_rid),
        .b_rlast(ddr_axi_rlast), .b_rvalid(ddr_axi_rvalid), .b_rready(ddr_axi_rready),
        .v_awaddr(vid_awaddr), .v_awlen(vid_awlen), .v_awvalid(vid_awvalid),
        .v_awready(vid_awready), .v_wdata(vid_wdata), .v_wstrb(vid_wstrb),
        .v_wvalid(vid_wvalid), .v_wready(vid_wready),
        .v_araddr(vid_araddr), .v_arlen(vid_arlen), .v_arvalid(vid_arvalid),
        .v_arready(vid_arready), .v_rdata(vid_rdata), .v_rid(vid_rid),
        .v_rlast(vid_rlast), .v_rvalid(vid_rvalid), .v_rready(vid_rready),
        .v_wlast(vid_wlast),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awvalid(m_awvalid),
        .m_awready(m_awready), .m_wdata(m_wdata), .m_wstrb(m_wstrb),
        .m_wvalid(m_wvalid), .m_wready(m_wready), .m_wusero_last(m_wusero_last),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_aruser_id(m_aruser_id),
        .m_arvalid(m_arvalid), .m_arready(m_arready), .m_rdata(m_rdata),
        .m_rid(ddr_rid), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .b_wlast(), .dbg_v_ar_wait(dbg_vid_ar_wait));
```

把 `u_ddr3` 的 `axi_awaddr/awlen/awvalid/awready/wdata/wstrb/wvalid/wready/araddr/arlen/
arvalid/arready/rdata/rid/rlast/rvalid` 从 `ddr_axi_*` 改接 `m_*`/`ddr_rid`；`axi_awuser_id`
接 `4'h0`，`axi_aruser_id` 接 `m_aruser_id`；`axi_wusero_last` 接 `m_wusero_last`。

- [ ] **Step 3: board top 例化视频链 + video_regs**

```verilog
    wire [27:0] vid_awaddr_w, vid_araddr_w; // 直接复用上面的 vid_* 线
    wire        vid_aruser_unused;
    video_passthrough u_video (
        .sys_clk(clk_in), .cam_rstn(cam_rstn), .ddr_clk(core_clk), .ddr_rstn(ddr_init_done),
        .lcd_clk(lcd_pclk), .lcd_rstn(soc_resetn), .ddr_init_done(ddr_init_done),
        .camera_clk_0(camera_clk_0), .camera_data_0(camera_data_0),
        .camera_href_0(camera_href_0), .camera_vsync_0(camera_vsync_0),
        .SCL_0(SCL_0), .SDA_0(SDA_0), .cam_rst_0(cam_rst_0),
        .vin_clk(1'b0), .vin_de(1'b0), .vin_vsync(1'b0), .vin_pix(16'd0),
        .ddr_awaddr(vid_awaddr), .ddr_awlen(vid_awlen), .ddr_awvalid(vid_awvalid),
        .ddr_awready(vid_awready), .ddr_wdata(vid_wdata), .ddr_wstrb(vid_wstrb),
        .ddr_wvalid(vid_wvalid), .ddr_wready(vid_wready), .ddr_wusero_last(vid_wlast),
        .ddr_araddr(vid_araddr), .ddr_arlen(vid_arlen), .ddr_arvalid(vid_arvalid),
        .ddr_arready(vid_arready), .ddr_rdata(vid_rdata), .ddr_rid(vid_rid),
        .ddr_rlast(vid_rlast), .ddr_rvalid(vid_rvalid), .ddr_rready(vid_rready),
        .lcd_pclk(lcd_pclk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_pwm(lcd_pwm), .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .frame_toggle(vid_frame_toggle), .wr_bank(vid_wr_bank),
        .cam_init_done(vid_cam_init_done),
        .ovl_wr_clk(soc_clk), .ovl_wr_rstn(soc_resetn), .ovl_wr_en(ovl_wr_en),
        .ovl_wr_addr(ovl_wr_addr), .ovl_wr_data(ovl_wr_data),
        .ovl_commit(ovl_commit), .ovl_en(ovl_en), .ovl_count(ovl_count),
        .ovl_active_bank(ovl_active_bank));

    video_regs u_video_regs (
        .clk(soc_clk), .rstn(soc_resetn),
        .s_awaddr({2'b00, u_soc_video_awaddr}), .s_awvalid(u_soc_video_awvalid),
        .s_awready(u_soc_video_awready), .s_wdata(u_soc_video_wdata),
        .s_wstrb(u_soc_video_wstrb), .s_wvalid(u_soc_video_wvalid),
        .s_wready(u_soc_video_wready), .s_bvalid(u_soc_video_bvalid),
        .s_bready(u_soc_video_bready), .s_bresp(u_soc_video_bresp),
        .s_araddr({2'b00, u_soc_video_araddr}), .s_arvalid(u_soc_video_arvalid),
        .s_arready(u_soc_video_arready), .s_rdata(u_soc_video_rdata),
        .s_rvalid(u_soc_video_rvalid), .s_rready(u_soc_video_rready),
        .s_rresp(u_soc_video_rresp),
        .frame_toggle(vid_frame_toggle), .wr_bank(vid_wr_bank),
        .init_done(vid_cam_init_done), .vid_stall(dbg_vid_ar_wait[15:0]),
        .ovl_wr_en(ovl_wr_en), .ovl_wr_addr(ovl_wr_addr), .ovl_wr_data(ovl_wr_data),
        .ovl_commit(ovl_commit), .ovl_en(ovl_en), .ovl_count(ovl_count),
        .ovl_active_bank(ovl_active_bank));
```

（`u_soc_video_*` 即 Step 1 的 `video_*` 端口，例化 `u_soc` 时一一接上。）

- [ ] **Step 4: FDC 引脚与时钟**

相机（全部来自官方 fdc）：

```tcl
define_attribute {p:camera_clk_0} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:camera_clk_0} {PAP_IO_LOC} {L22}
define_attribute {p:camera_clk_0} {PAP_IO_VCCIO} {3.3}
define_attribute {p:camera_clk_0} {PAP_IO_STANDARD} {LVCMOS33}
# camera_data_0[7:0]: M24 R22 K26 K25 M25 N19 T24 R21
# camera_href_0 T25 / camera_vsync_0 L23 / SCL_0 P19 / SDA_0 R20 / cam_rst_0 T22
# （按同名逐条写 LOC，方向 INPUT/OUTPUT）
```

LCD（J26）：`lcd_r[7:0]` AF23 AE23 AF25 AF24 AE26 AE25 W15 W14；`lcd_g[7:0]`
AC16 AB16 AD17 AC17 AB20 AA20 AF17 AE17；`lcd_b[7:0]` AF18 AE18 AE20 AD20 AF20 AF19
AD24 AD23；`lcd_de` AC23、`lcd_hs` AD26、`lcd_vs` AD25、`lcd_pclk` AC19、`lcd_pwm` AC22。

时钟：

```tcl
create_clock -name {camera_clk_0} [get_ports {camera_clk_0}] -period {10.000}
create_generated_clock -name {cam_pixel_clk} -source [get_ports {camera_clk_0}] \
  [get_pins {u_video/u_cmos16/pixel_clk}] -master_clock [get_clocks {camera_clk_0}] \
  -multiply_by {1} -divide_by {2}
create_clock -name {lcd_pclk} [get_pins {u_pll_lcd/u_gpll/CLKOUT0}] -period {19.259} -waveform {0 9.6295}
set_clock_groups -asynchronous -group [get_clocks {camera_clk_0}]
set_clock_groups -asynchronous -group [get_clocks {cam_pixel_clk}]
set_clock_groups -asynchronous -group [get_clocks {lcd_pclk}]
# 再各与 soc_clk/cpu_clk/npu_clk/core_clk/ref_clk/clk_in 互列异步组
```

- [ ] **Step 5: PDS 源列表**

两个 tcl 的 `add_design` 段加：

```tcl
foreach f [glob -nocomplain "$root/board/cam/*.v"] { add_design $f }
foreach f [glob -nocomplain "$root/board/cam/vendor/*.v"] { add_design $f }
foreach f [glob -nocomplain "$root/board/cam/vendor/tutorial/*.v"] { add_design $f }
foreach f [glob -nocomplain "$root/board/cam/vendor/camera/*.v"] { add_design $f }
add_design "$root/board/cam/vendor/ip/wr_fram_buf/wr_fram_buf.v"
add_design "$root/board/cam/vendor/ip/rd_fram_buf/rd_fram_buf.v"
add_design "$root/board/pll_lcd.v"
```

（`stub_rambuf*.v` **不能**进 PDS 源；只给仿真。）

- [ ] **Step 6: Lint（WSL Verilator）**

```bash
cd /mnt/d/code/PDS/VexiiYeshenLinux
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  board/cam/ddr_arbiter_2to1.v board/cam/overlay.v board/cam/video_regs.v 2>&1 | tail -20
```

Expected: 无 `%Error`。

- [ ] **Step 7: Commit**

```bash
git add board/yeshen_mini_soc.v board/yeshen_mini_board_top.v constraints/yeshen_mini.fdc pds/run_devmap_yeshen.tcl pds/run_pnr_yeshen.tcl
git commit -m "board: camera/LCD pinout, lcd PLL, video chain, DDR arbiter and CSR wiring"
```

---

## Task 8: dev_map + PnR + 上板 V1 直通验收

**Files:** 无源码改动（只跑流程与记录）

- [ ] **Step 1: dev_map**

```bash
cd /d/code/PDS/VexiiYeshenLinux
"C:/Pango/PDS_2025.2-ads/bin/pds_shell.exe" -file pds/run_devmap_yeshen.tcl > sim/reglogs/devmap_video1.log 2>&1
grep -c YESHENMINI_DEVMAP_DONE sim/reglogs/devmap_video1.log
python scripts/check_devmap.py sim/reglogs/devmap_video1.log
grep -aA10 "Device Utilization Summary" sim/reglogs/devmap_video1.log | grep -aE "LUT|FF|DRM|APM|IO "
```

Expected: DONE=1；check_devmap PASS；LUT < 80%、DRM < 80%。

- [ ] **Step 2: PnR（tag video1）**

```bash
tasklist | grep -i pds_shell && echo "!! PnR 已在跑，停"
YESHENMINI_PNR_TAG=video1 YESHENMINI_SYNTH_MODE=speed \
  "C:/Pango/PDS_2025.2-ads/bin/pds_shell.exe" -file pds/run_pnr_yeshen.tcl \
  > sim/reglogs/pnr_video1.log 2>&1
grep -c YESHENMINI_PNR_DONE sim/reglogs/pnr_video1.log
grep -a "All Constraints Met" sim/reglogs/pnr_video1.log | tail -1
sed -n '/Performance Summary/,/====/p' sim/reglogs/pds_video1_p10.000/prj_tasks/pnr_1/place_route/report_timing/yeshen_mini_board_top.rtr
md5sum sim/reglogs/pds_video1_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit
```

Expected: DONE；All Constraints Met（cpu 108/soc 100/npu/lcd 51.923/camera/core 全 MET）。

- [ ] **Step 3: 上板（板子空闲才烧）**

```bash
tasklist | grep -iE "cdt|pds_shell" | head
python -u scripts/flash_and_verify.py --tag video1 --no-net --secs 200
```

Expected: 8 个 marker 全 PASS（SD/SDR/OpenSBI/Linux/LiteEth/dropbear/用户态/login）。

- [ ] **Step 4: 帧计数与快照活性（UART/ssh 二选一）**

```bash
# 板内：读 VIDEO STATUS 10 次（0xF0007400）
python -u scripts/board_ssh.py "for i in 1 2 3 4 5 6 7 8 9 10; do devmem 0xF0007400; sleep 0.1; done"
```

Expected: 帧序号在 1 s 内大约 +15..16（15.7 fps）；`bit0=1`（init_done）。

屏幕内容（实时彩色画面）由**用户目视**确认；若黑屏，按厂家 DELIVERY_REPORT 的
"VADJ / 相机座 J10 / 屏 J26" 顺序排查。

- [ ] **Step 5: 回归**

```bash
python -u scripts/board_bootsel_run.py --key C --tag video1 --secs 60    # CoreMark 4.59 不回退
python -u scripts/board_bootsel_run.py --key L --tag video1 --secs 60    # 回 Linux
python -u scripts/board_ssh.py "cd /root/y1 && ./y1run --frames 1 --quiet"  # 12/12
```

Expected: CoreMark 4.59（±0.5%）、y1run 12/12。

- [ ] **Step 6: 记录 + 提交**

把 dev_map 资源、PnR 时钟表、bitstream md5、帧计数、回归结果写进
`docs/superpowers/specs/2026-10-19-video-camera-lcd-overlay-design.md` §14，并提交。

---

## Task 9: 软件公共件 + `y1cam` 快照/预处理（V2-a）

**Files:**
- Create: `y1/tools/y1_common.h`
- Modify: `y1/tools/y1run.c`（改为 include 公共件）
- Create: `y1/tools/y1cam.c`（本任务只做 payload 校验 + 快照 + 预处理）
- Create: `y1/tools/build_y1cam.sh`
- Test: `y1/tools/check_cam_input.py`

- [ ] **Step 1: 抽公共件 `y1_common.h`**

把 `y1run.c` 的以下内容原样搬进头文件（加 `static`/`static inline`）：
`PAGE/PAYLOAD_*/ARENA_*/REG_BASE/R_*` 宏、`struct seg/out/hdr`、`crc32_buf`、`now_ns`、
`map_phys`、payload 头部/段 CRC 校验函数。`y1run.c` 顶部改为 `#include "y1_common.h"`，
删除重复定义。

- [ ] **Step 2: 构建并回归 `y1run`**

```bash
# 复制 build_y1run.sh → build_y1cam.sh，改三处：源文件 y1cam.c / 产物 y1/build/y1cam_rv32 /
# --install 目标 rootfs_overlay/root/y1/y1cam；其余（交叉编译器、CFLAGS、WSL 调用姿势）逐字保留。
cd /d/code/PDS/VexiiYeshenLinux
sed -e 's/y1run\.c/y1cam.c/' -e 's/y1run_rv32/y1cam_rv32/' \
    -e 's|/y1run$|/y1cam|' y1/tools/build_y1run.sh > y1/tools/build_y1cam.sh
wsl -e bash -lc 'bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_y1cam.sh --install'
ls -la y1/build/y1cam_rv32 sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/y1/y1cam
```

上板跑 `/root/y1/y1run --frames 1 --quiet` → **12/12**（证明抽取无回归）。

- [ ] **Step 3: `y1cam.c` 快照 + 预处理（核心代码）**

```c
#define FB_BASE       0x90000000UL     /* CPU 物理：DDR 偏移 0x1000_0000 */
#define FB_BANK_SIZE  0x01000000UL     /* bank 位 = 字地址 bit22 ⇒ 16 MiB（帧数据只占 0x168000） */
#define SNAP_BASE     0x90400000UL
#define CROP_X        320              /* 相机坐标 */
#define CROP_Y        40
#define FB_COL_OFF    128              /* 帧存内列 = 相机列 - 128 */
#define ROW_OFF       60

static void snap_crop(uint8_t *fb, uint16_t *snap, int bank) {
    const uint16_t *base = (const uint16_t *)(fb + bank * FB_BANK_SIZE);
    for (int y = 0; y < 640; y++)
        for (int x = 0; x < 640; x++)
            snap[y*640+x] = base[(y + CROP_Y) * 1024 + (x + CROP_X - FB_COL_OFF)];
}

static inline uint8_t exp5(uint8_t v){ return (uint8_t)((v<<3)|(v>>2)); }
static inline uint8_t exp6(uint8_t v){ return (uint8_t)((v<<2)|(v>>4)); }

static void prep_bgr_nchw_int8(const uint16_t *snap, int8_t *dst) {
    int8_t *pb = dst, *pg = dst + 640*640, *pr = dst + 2*640*640;
    for (int i = 0; i < 640*640; i++) {
        uint16_t p = snap[i];
        uint8_t r = exp5((p >> 11) & 0x1F);
        uint8_t g = exp6((p >> 5)  & 0x3F);
        uint8_t b = exp5(p & 0x1F);
        pb[i] = (int8_t)((int)b - 128);
        pg[i] = (int8_t)((int)g - 128);
        pr[i] = (int8_t)((int)r - 128);
    }
}
```

`main`：map `/dev/mem` 的 FB/SNAP/ARENA/REG；校验 payload；循环读 STATUS（`volatile
uint32_t *st = reg + 0x00`），等 `seq` 变化后取 `bank = (~(st[0] >> 1)) & 1u`
（STATUS[1] 是当前写 bank；稳定帧在反相 bank），`snap_crop` → `prep_bgr_nchw_int8` 写到
`arena + h->input_npu`；`--dump <path>` 时把 snap 原始字节写文件并打印 int8 CRC32。

- [ ] **Step 4: 主机对账脚本 `check_cam_input.py`**

```python
import sys, zlib, numpy as np
raw = np.fromfile(sys.argv[1], dtype='<u2').reshape(640,640)
r = ((raw>>11)&0x1F).astype(np.uint8); g=((raw>>5)&0x3F).astype(np.uint8); b=(raw&0x1F).astype(np.uint8)
r8=(r<<3)|(r>>2); g8=(g<<2)|(g>>4); b8=(b<<3)|(b>>2)
nchw = np.stack([b8,g8,r8]).astype(np.int16) - 128
q = nchw.astype(np.int8)
print("HOST_INPUT_CRC=%08x" % zlib.crc32(q.tobytes()))
```

- [ ] **Step 5: 上板红/绿对账**

板上：`y1cam --once --dump /tmp/cam.raw`（打印 `BOARD_INPUT_CRC=...`）。
取回文件：`python -u scripts/board_ssh.py "base64 /tmp/cam.raw" > /tmp/cam.b64`
（或分块；用 `board_ssh.get_b64`），解码后跑 `check_cam_input.py`。
Expected: 两 CRC 相等；负对照：把 B/R 平面顺序对调 → CRC 不等。

- [ ] **Step 6: Commit**

```bash
git add y1/tools/y1_common.h y1/tools/y1run.c y1/tools/y1cam.c y1/tools/build_y1cam.sh y1/tools/check_cam_input.py
git commit -m "y1cam: payload common header + camera snapshot and same-caliber int8 preprocessing"
```

---

## Task 10: NPU 调度 + YuNet 后处理 + 写框（V2-b）

**Files:**
- Create: `y1/tools/gen_deq_header.py` → `y1/tools/y1_deq.h`
- Modify: `y1/tools/y1cam.c`（NPU 启动/轮询 + 后处理 + box 写）
- Test: `y1/tools/check_post_c.py`（C vs Python 后处理对账）

- [ ] **Step 1: 生成反量化常量**

```python
# y1/tools/gen_deq_header.py
import numpy as np, yunet_post as YP, npu_frame_run as NF, quant_ref as QR
hwc = YP.synth_noface()
x = YP.to_nchw(hwc)
M = QR.Model(NF.ONNX, synth=x); M.build_params(); P = QR._params_of(M)
NF.YCAL.apply_sigmoid_fix(P["act"], M.nodes)
with open("y1/tools/y1_deq.h","w") as f:
    f.write("/* generated: 12 output dequant params (scale,zp) */\n")
    f.write("static const float DEQ_SCALE[12] = {%s};\n" %
            ",".join("%.9gf" % float(P["act"][n]["scale"]) for n in YP.OUT_NAMES))
    f.write("static const int DEQ_ZP[12] = {%s};\n" %
            ",".join(str(int(P["act"][n]["zp"])) for n in YP.OUT_NAMES))
print("Y1_DEQ_OK")
```

Run: `cd y1/tools && python gen_deq_header.py` → `Y1_DEQ_OK`。

- [ ] **Step 2: `y1cam.c` 加 NPU 运行（复用 y1run 的邮箱回放）**

启动序列（与 `y1run.c` 一致）：`*status=1; *ctrl=SOFT_RESET; *desc_a=h->desc_npu;
*desc_n=h->desc_count; *ctrl=START;` 轮询 `*status & 3`。输出地址 = `arena + h->out[i].npu`。
邮箱只在启动时回放一次（权重/参数不变），每帧只重写 input。

- [ ] **Step 3: C 版后处理（完整算法）**

```c
typedef struct { float x,y,w,h,conf; } det_t;
static float iou(const det_t*a,const det_t*b){
    float ax2=a->x+a->w, ay2=a->y+a->h, bx2=b->x+b->w, by2=b->y+b->h;
    float ix = fmaxf(0.f, fminf(ax2,bx2)-fmaxf(a->x,b->x));
    float iy = fmaxf(0.f, fminf(ay2,by2)-fmaxf(a->y,b->y));
    float inter=ix*iy, ua=a->w*a->h + b->w*b->h - inter;
    return ua>0 ? inter/ua : 0.f;
}
static int decode(const float *cls,const float *obj,const float *bbox,const float *kps,
                  int n,int stride,float thr,det_t *out,int maxn){
    int w=(int)lroundf(sqrtf((float)n)), m=0;
    for(int p=0;p<n && m<maxn;p++){
        float sc=sqrtf(fmaxf(0,fminf(1,cls[p]))*fmaxf(0,fminf(1,obj[p])));
        if(sc<thr) continue;
        int i=p/w, j=p%w;
        float cx=(j+bbox[p*4+0])*stride, cy=(i+bbox[p*4+1])*stride;
        float bw=expf(fminf(bbox[p*4+2],12.f))*stride;
        float bh=expf(fminf(bbox[p*4+3],12.f))*stride;
        out[m].x=cx-bw/2; out[m].y=cy-bh/2; out[m].w=bw; out[m].h=bh; out[m].conf=sc;
        (void)kps; m++;
    }
    return m;
}
```

（kps 不画，可忽略；`decode` 的 12 路张量按 `h->out[i].name` 匹配 cls/obj/bbox/kps 与
stride。反量化 `v = q * scale + zp` 后传入。）

NMS + 坐标映射 + 写框：

```c
/* 屏幕坐标：sx = crop_x + 192，sy = crop_y - 20；裁剪到 [0,1023]/[0,599] */
int n = 0;
for (int k = 0; k < nd && n < 16; k++) {
    int sx1=(int)lrintf(dets[k].x)+192, sy1=(int)lrintf(dets[k].y)-20;
    int sx2=(int)lrintf(dets[k].x+dets[k].w)+192, sy2=(int)lrintf(dets[k].y+dets[k].h)-20;
    if (sx1<0) sx1=0; if (sy1<0) sy1=0;
    if (sx2>1023) sx2=1023; if (sy2>599) sy2=599;
    if (sx2<=sx1 || sy2<=sy1) continue;
    *(volatile uint32_t*)(vreg + 0x10 + 8*n + 0) = (uint32_t)sx1 | ((uint32_t)sy1<<16);
    *(volatile uint32_t*)(vreg + 0x10 + 8*n + 4) = (uint32_t)sx2 | ((uint32_t)sy2<<16);
    n++;
}
*(volatile uint32_t*)(vreg + 0x08) = (uint32_t)(n<<8) | 1u;   /* 写 box（后备 bank） */
__sync_synchronize();
*(volatile uint32_t*)(vreg + 0x08) = (uint32_t)(n<<8) | 3u;   /* en + commit */
```

- [ ] **Step 4: 后处理 C/Python 对账**

```bash
# 主机导出一组真实输出张量（int8 或反量化后）到 npz，再让 C 读同一组数据
python -u y1/tools/npu_frame_run.py --img <face.jpg> --npz /tmp/outs.npz --json /tmp/outs.json
# 小工具 check_post_c.py：读 npz -> 调同一份 C 算法（编译成 host bin）-> 与 yunet_post.postprocess 比
python -u y1/tools/check_post_c.py /tmp/outs.npz
```

Expected: `POST_C: PASS dets=N iou_min>=0.99`。

- [ ] **Step 5: 上板 V2 判据**

1. 板内 `y1cam --once --dump /tmp/cam.raw`，读回快照；
2. 主机用同一个快照跑冻结参考（`quant_ref`）得到 golden dets；
3. 板内打印 `CAM_DETS=n boxes=...`；
4. 比较：框数一致，IoU ≥ 0.99；
5. 屏幕：框覆盖人脸（**用户目视**）；无人脸画面 → `n=0` 且屏幕无框（负对照）。

- [ ] **Step 6: Commit**

```bash
git add y1/tools/gen_deq_header.py y1/tools/y1_deq.h y1/tools/y1cam.c y1/tools/check_post_c.py
git commit -m "y1cam: NPU dispatch, YuNet decode+NMS in C, dequant header, box mapping"
```

---

## Task 11: 连续循环 + V3 长跑 + 回归 + 报告

**Files:**
- Modify: `y1/tools/y1cam.c`（`--loop` + 遥测）
- Create: `y1/reports/camera_list_hook.md`
- Modify: `sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/y1/`（安装二进制）

- [ ] **Step 1: 循环与遥测**

每轮打印一行（UART）：

```c
printf("CAMRUN n=%u wait_ms=%u snap_ms=%u prep_ms=%u npu_ms=%u post_ms=%u dets=%d\n",
       round, t_wait, t_snap, t_prep, t_npu, t_post, nd);
```

节奏：上一轮结束后立刻读 STATUS 等下一帧；NPU 4.5 s 期间相机继续跑（bank 交替），
下一轮重新抓最新帧。

- [ ] **Step 2: 安装进 rootfs 并重烧卡（照 `build_y1_card.sh` 既有流程）**

```bash
bash y1/tools/build_y1cam.sh
cp y1/tools/y1cam sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/y1/y1cam
bash scripts/build_y1_card.sh      # 按既有流程重建 rootfs.cpio + 卡镜像
```

- [ ] **Step 3: V3 长跑（10 分钟）**

```bash
python -u scripts/board_ssh.py "cd /root/y1 && timeout 600 ./y1cam --loop > /tmp/camrun.log 2>&1; tail -5 /tmp/camrun.log"
```

Expected: 每轮 `CAMRUN ... dets=...`；轮数 ≈ 600/4.7 ≈ 120；无 timeout/挂死；
`dets` 在有人脸时 ≥1、无人脸时 0。

- [ ] **Step 4: 全量回归**

```bash
python -u scripts/board_bootsel_run.py --key C --tag video1 --secs 60   # 4.59
python -u scripts/board_bootsel_run.py --key L --tag video1 --secs 60
python -u scripts/board_ssh.py "cd /root/y1 && ./y1run --frames 1 --quiet"  # 12/12
```

- [ ] **Step 5: 报告 + spec 收口**

在 `y1/reports/camera_list_hook.md` 记录：架构、bitstream md5、帧计数实测、每轮耗时分解、
检测对账结果、V1/V2/V3 判据、已知限制（检测 4.5 s/帧；上下各 20 行不在显示区）。

- [ ] **Step 6: Commit（不 push）**

```bash
git add y1/tools/y1cam.c y1/reports/camera_list_hook.md docs/superpowers/specs/2026-10-19-video-camera-lcd-overlay-design.md
git commit -m "camera hook V3: continuous detect loop, telemetry, 10-min run, regressions"
```

---

## 自查（Spec 覆盖）

- 直通 1:1 裁切 → Task 2（裁列 + 行偏移 + U2）
- 中央 640×640 → Task 9（snapshot 取相机 320..959 / 40..679）
- CPU+NPU 检测 → Task 9/10（NPU 调度 + 后处理）
- FPGA 叠加 → Task 3/4（overlay + CSR）
- DDR 2:1 仲裁 → Task 5（U1）
- 地址/台账 → Task 6
- 上板 V1/V2/V3 → Task 8/10/11
- 回归（Linux/CoreMark/y1run）→ Task 8/11
