#!/usr/bin/env bash
#=============================================================================
# run_video_gates.sh: 视频链单元闸门聚合（U1 / U3 / U4 / U5 / U6 / U2）
#
#   U1  DDR 2:1 仲裁器      -> DDR_ARB: PASS
#   U3  16 框叠加引擎       -> OVERLAY: PASS
#   U4  VIDEO 寄存器窗      -> VIDEO_REGS: PASS
#   U5  双目切换 mux/掐写/黑屏 -> CAM_SWITCH: PASS（负对照：裸 mux 必红）
#   U6  KEY 电平消抖单脉冲   -> KEY_TOGGLE: PASS
#   U7  软件软复位控制器     -> RST_CTRL: PASS（负对照：拆掉 req_ack 必反复复位）
#   U2  相机 -> 裁列 -> 帧存 -> DDR -> LCD 直通 -> VIDEO_PATH: PASS
#       （逐像素比对约 2.37M，单跑约 5 分钟）
#
# 每个闸门都 grep 到 PASS 才继续；全部命中后打印 VIDEO_GATES: ALL PASS。
# 任一失败立即退出并打印该闸门日志尾部，不会打印 ALL PASS。
#=============================================================================
set -euo pipefail
cd "$(dirname "$0")"

V=../../board/cam
LOG=${TMPDIR:-/tmp}/video_gates
mkdir -p "$LOG"

check() {
    local name="$1" file="$2" pat="$3"
    if grep -q "$pat" "$file"; then
        echo "$name"
    else
        echo "VIDEO_GATES: FAIL at $name (expect \"$pat\")"
        tail -20 "$file"
        exit 1
    fi
}

#---- U1: DDR 2:1 仲裁器（写串行 + wusero_last 归属 + RID 分流） -----------
iverilog -g2012 -o "$LOG/u1.vvp" tb_ddr_arbiter.v ddr_model.v \
    "$V/ddr_arbiter_2to1.v"
vvp "$LOG/u1.vvp" > "$LOG/u1.log"
check "U1 DDR_ARB: PASS" "$LOG/u1.log" "DDR_ARB: PASS"

#---- U1b: 读通道**多未完成**（桥 4 笔同时在飞；BN=1 负对照必红）-----------
#   正档：4 笔桥读的 AR 在第一笔 R 之前全部收下（MO_PEAK=4），数据逐笔正确、
#   视频 AR 不被在飞桥读堵住（V_LAT≤8，桥首笔 R 约 20 拍后才到）。
iverilog -g2012 -o "$LOG/u1b.vvp" tb_ddr_arbiter_mo.v ddr_model.v \
    "$V/ddr_arbiter_2to1.v"
vvp "$LOG/u1b.vvp" > "$LOG/u1b.log"
check "U1b DDR_ARB_MO: PASS" "$LOG/u1b.log" "DDR_ARB_MO: PASS"
if ! grep -q "MO_PEAK=4" "$LOG/u1b.log"; then
    echo "VIDEO_GATES: FAIL at U1b (MO_PEAK != 4)"
    tail -5 "$LOG/u1b.log"; exit 1
fi
iverilog -g2012 -Ptb_ddr_arbiter_mo.TB_BN=1 -o "$LOG/u1b_neg.vvp" \
    tb_ddr_arbiter_mo.v ddr_model.v "$V/ddr_arbiter_2to1.v"
vvp "$LOG/u1b_neg.vvp" > "$LOG/u1b_neg.log"
if ! grep -q "DDR_ARB_MO: FAIL" "$LOG/u1b_neg.log"; then
    echo "VIDEO_GATES: FAIL at U1b 负对照（BN=1 没有打红）"
    tail -5 "$LOG/u1b_neg.log"; exit 1
fi
if ! grep -q "MO_PEAK=1" "$LOG/u1b_neg.log"; then
    echo "VIDEO_GATES: FAIL at U1b 负对照（BN=1 时峰值不是 1）"
    tail -5 "$LOG/u1b_neg.log"; exit 1
fi
echo "U1b DDR_ARB_MO: PASS（BN=1 负对照必红：MO_PEAK=1）"

#---- U3: 16 框 2 px 边框叠加引擎 ------------------------------------------
iverilog -g2012 -o "$LOG/u3.vvp" tb_overlay.v "$V/overlay.v"
vvp "$LOG/u3.vvp" > "$LOG/u3.log"
check "U3 OVERLAY: PASS" "$LOG/u3.log" "OVERLAY: PASS"

#---- U4: 1KiB VIDEO 寄存器窗 ----------------------------------------------
iverilog -g2012 -o "$LOG/u4.vvp" tb_video_regs.v "$V/video_regs.v"
vvp "$LOG/u4.vvp" > "$LOG/u4.log"
check "U4 VIDEO_REGS: PASS" "$LOG/u4.log" "VIDEO_REGS: PASS"

#---- U5: 双目切换的 mux/毛刺/掐写/黑屏 -------------------------------------
iverilog -g2012 -o "$LOG/u5.vvp" tb_cam_switch.v "$V/cam_switch.v" ../pango_prim_sim_stubs.v
vvp "$LOG/u5.vvp" > "$LOG/u5.log"
check "U5 CAM_SWITCH: PASS" "$LOG/u5.log" "RESULT: PASS"

#---- U5 负对照 ①：把时钟 mux 桩换成**裸 mux** ⇒ 毛刺判据必须打红 ----------
#   说明：无毛刺本身由硬宏 GTP_CLKBUFGMUX 保证（RTL 里没有可突变的门控逻辑）；
#   这条负对照验的是**判据本身**——TB 的窄脉冲监视器对裸 mux 必须发火。
cp ../pango_prim_sim_stubs.v "$LOG/stubs_bad.v"
sed -i 's@    assign CLKOUT = o;@    assign CLKOUT = SEL ? CLKIN1 : CLKIN0;@' "$LOG/stubs_bad.v"
if cmp -s ../pango_prim_sim_stubs.v "$LOG/stubs_bad.v"; then
    echo "VIDEO_GATES: FAIL at U5 负对照①（突变没落盘）"; exit 1; fi
iverilog -g2012 -o "$LOG/u5neg.vvp" tb_cam_switch.v "$V/cam_switch.v" "$LOG/stubs_bad.v"
vvp "$LOG/u5neg.vvp" > "$LOG/u5neg.log"
if grep -q "RESULT: PASS" "$LOG/u5neg.log"; then
    echo "VIDEO_GATES: FAIL at U5 负对照①（裸 mux 没有打红）"; exit 1
fi
grep -q "脉冲" "$LOG/u5neg.log" || {
    echo "VIDEO_GATES: FAIL at U5 负对照①（红了但不是毛刺判据）"; tail -5 "$LOG/u5neg.log"; exit 1; }

#---- U5 负对照 ②：wr_ok 恒 1（不掐写）⇒ 掐写判据必须打红 -------------------
cp "$V/cam_switch.v" "$LOG/cam_switch_bad.v"
sed -i "s@    assign wr_ok = wr_ok_r;@    assign wr_ok = 1'b1;@" "$LOG/cam_switch_bad.v"
if cmp -s "$V/cam_switch.v" "$LOG/cam_switch_bad.v"; then
    echo "VIDEO_GATES: FAIL at U5 负对照②（突变没落盘）"; exit 1; fi
iverilog -g2012 -o "$LOG/u5neg2.vvp" tb_cam_switch.v "$LOG/cam_switch_bad.v" ../pango_prim_sim_stubs.v
vvp "$LOG/u5neg2.vvp" > "$LOG/u5neg2.log"
if grep -q "RESULT: PASS" "$LOG/u5neg2.log"; then
    echo "VIDEO_GATES: FAIL at U5 负对照②（wr_ok 恒 1 没有打红）"; exit 1
fi
echo "U5 CAM_SWITCH: PASS（负对照①裸 mux / ②wr_ok 恒 1 均必红）"

#---- U6: KEY 消抖 --------------------------------------------------------
iverilog -g2012 -o "$LOG/u6.vvp" tb_key_toggle.v "$V/key_toggle.v"
vvp "$LOG/u6.vvp" > "$LOG/u6.log"
check "U6 KEY_TOGGLE: PASS" "$LOG/u6.log" "RESULT: PASS"

#---- U7: 软件软复位控制器（RST_CTRL -> 20 ms sys_rstn）----------------------
iverilog -g2012 -o "$LOG/u7.vvp" tb_rst_ctrl.v ../../board/rst_ctrl.v
vvp "$LOG/u7.vvp" > "$LOG/u7.log"
check "U7 RST_CTRL: PASS" "$LOG/u7.log" "RESULT: PASS"

#---- U7 负对照：拆掉"一个请求只兑现一次"的保险 ⇒ 请求挂住必反复复位 --------
#   这是"reboot 自锁成无限重启环"的守卫；突变锚点 = `req_s2 && !req_ack`。
cp ../../board/rst_ctrl.v "$LOG/rst_ctrl_bad.v"
sed -i 's@if (req_s2 && !req_ack) begin@if (req_s2) begin@' "$LOG/rst_ctrl_bad.v"
if cmp -s ../../board/rst_ctrl.v "$LOG/rst_ctrl_bad.v"; then
    echo "VIDEO_GATES: FAIL at U7 负对照（突变没落盘）"; exit 1; fi
iverilog -g2012 -o "$LOG/u7neg.vvp" tb_rst_ctrl.v "$LOG/rst_ctrl_bad.v"
vvp "$LOG/u7neg.vvp" > "$LOG/u7neg.log"
if grep -q "RESULT: PASS" "$LOG/u7neg.log"; then
    echo "VIDEO_GATES: FAIL at U7 负对照（挂住请求没有打红）"; exit 1
fi
grep -q "无限重启环" "$LOG/u7neg.log" || {
    echo "VIDEO_GATES: FAIL at U7 负对照（红了但不是自激判据）"; tail -5 "$LOG/u7neg.log"; exit 1; }
echo "U7 RST_CTRL: PASS（负对照：拆掉 req_ack 后请求挂住必反复复位）"

#---- U2: 相机(旁路) -> 居中裁列 -> 帧存 -> DDR -> LCD 直通 -----------------
#   源列表与 README 的 U2 命令一致；overlay.v 是 video_passthrough 的实例，
#   stub_rd_fram_buf.v 替代真 rd_fram_buf IP，stub_rambuf_sync.v 替代
#   厂家的同步读 RAM 原语。
U2_SRC=(
    tb_video_path.v ddr_model.v stub_rd_fram_buf.v
    "$V/video_passthrough.v"
    "$V/overlay.v"
    "$V/vendor/camera/camera.v"
    "$V/vendor/camera/camera_data.v"
    "$V/vendor/tutorial/cmos_8_16bit.v"
    "$V/vendor/tutorial/fram_buf.v"
    "$V/vendor/tutorial/wr_buf.v"
    "$V/vendor/tutorial/rd_buf.v"
    "$V/vendor/tutorial/wr_ctrl.v"
    "$V/vendor/tutorial/rd_ctrl.v"
    "$V/vendor/tutorial/wr_cmd_trans.v"
    "$V/vendor/tutorial/wr_rd_ctrl_top.v"
    "$V/vendor/sync_vg.v"
    "$V/vendor/stub_rambuf_sync.v"
)
iverilog -g2012 -DROW_OFFSET=60 -o "$LOG/u2.vvp" "${U2_SRC[@]}"
vvp "$LOG/u2.vvp" > "$LOG/u2.log"
check "U2 VIDEO_PATH: PASS" "$LOG/u2.log" "VIDEO_PATH: PASS"

#---- U8: LCD 读源选择（GUI 第二帧存，GUI_CTRL[0]）-------------------------
#   正档：cam -> gui -> cam 三档，逐像素对常量像素；AR 区域必须整帧一致；
#         写地址绝不许进 GUI 区。
#   跑 14 个 LCD 帧，单跑约 12 分钟。
U8_SRC=(
    tb_gui_src.v ddr_model.v stub_rd_fram_buf.v
    "$V/video_passthrough.v"
    "$V/overlay.v"
    "$V/vendor/camera/camera.v"
    "$V/vendor/camera/camera_data.v"
    "$V/vendor/tutorial/cmos_8_16bit.v"
    "$V/vendor/tutorial/fram_buf.v"
    "$V/vendor/tutorial/wr_buf.v"
    "$V/vendor/tutorial/rd_buf.v"
    "$V/vendor/tutorial/wr_ctrl.v"
    "$V/vendor/tutorial/rd_ctrl.v"
    "$V/vendor/tutorial/wr_cmd_trans.v"
    "$V/vendor/tutorial/wr_rd_ctrl_top.v"
    "$V/vendor/sync_vg.v"
    "$V/vendor/stub_rambuf_sync.v"
)
iverilog -g2012 -o "$LOG/u8.vvp" "${U8_SRC[@]}"
vvp "$LOG/u8.vvp" > "$LOG/u8.log"
check "U8 GUI_SRC: PASS" "$LOG/u8.log" "GUI_SRC: PASS"

#---- U8 负对照：选择位**立刻跟随**（不等帧首）⇒ 帧内跨区读判据必须打红 ----
#   突变锚点 = `else if (rd_frame_rst) gui_sel_ddr <= gui_s2;`
cp "$V/video_passthrough.v" "$LOG/video_passthrough_bad.v"
sed -i 's@else if (rd_frame_rst) gui_sel_ddr <= gui_s2;@else gui_sel_ddr <= gui_s2;@' \
    "$LOG/video_passthrough_bad.v"
if cmp -s "$V/video_passthrough.v" "$LOG/video_passthrough_bad.v"; then
    echo "VIDEO_GATES: FAIL at U8 负对照（突变没落盘）"; exit 1; fi
U8N_SRC=("${U8_SRC[@]}")
U8N_SRC[3]="$LOG/video_passthrough_bad.v"
iverilog -g2012 -DFAST -o "$LOG/u8neg.vvp" "${U8N_SRC[@]}"
vvp "$LOG/u8neg.vvp" > "$LOG/u8neg.log"
if grep -q "GUI_SRC: PASS" "$LOG/u8neg.log"; then
    echo "VIDEO_GATES: FAIL at U8 负对照（立刻跟随没有打红）"; exit 1
fi
grep -q "mixed_frame" "$LOG/u8neg.log" || {
    echo "VIDEO_GATES: FAIL at U8 负对照（红了但不是跨区判据）"; tail -5 "$LOG/u8neg.log"; exit 1; }
echo "U8 GUI_SRC: PASS（负对照：立刻跟随换源 ⇒ 帧内跨区读必红）"

echo "VIDEO_GATES: ALL PASS"
