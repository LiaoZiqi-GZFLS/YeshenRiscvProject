# sim/video —— 视频链单元闸门（U1~U4）

## U2：相机 → 居中裁列 → 帧存 → DDR → LCD 直通（先红后绿）

```bash
cd sim/video
SRC="tb_video_path.v ddr_model.v stub_rd_fram_buf.v ../../board/cam/video_passthrough.v \
  ../../board/cam/overlay.v \
  ../../board/cam/vendor/camera/camera.v ../../board/cam/vendor/camera/camera_data.v \
  ../../board/cam/vendor/tutorial/cmos_8_16bit.v ../../board/cam/vendor/tutorial/fram_buf.v \
  ../../board/cam/vendor/tutorial/wr_buf.v ../../board/cam/vendor/tutorial/rd_buf.v \
  ../../board/cam/vendor/tutorial/wr_ctrl.v ../../board/cam/vendor/tutorial/rd_ctrl.v \
  ../../board/cam/vendor/tutorial/wr_cmd_trans.v ../../board/cam/vendor/tutorial/wr_rd_ctrl_top.v \
  ../../board/cam/vendor/sync_vg.v ../../board/cam/vendor/stub_rambuf_sync.v"

# 红：DUT 行偏移退回厂家默认 0（期望仍是行 60）——必红
iverilog -g2012 -DROW_OFFSET=0  -o /tmp/u2_red.vvp   $SRC && vvp /tmp/u2_red.vvp   | tail -3
# 绿：ROW_OFFSET=60
iverilog -g2012 -DROW_OFFSET=60 -o /tmp/u2_green.vvp $SRC && vvp /tmp/u2_green.vvp | tail -3
```

判据：绿 = `VIDEO_PATH: PASS`（checked_px≈2.1M、mismatches=0、addr_errs=0）；
红 = `VIDEO_PATH: FAIL mismatches=…`。

说明：
- `stub_rd_fram_buf.v`：rd_fram_buf IP 的行为替身（真 IP 依赖 `GTP_DRM18K_E1` 原语，
  iverilog 无法细化）；wr_fram_buf 用厂家 `vendor/stub_rambuf_sync.v`（同步读）。
- `ddr_model.v` 地址口径 = 厂家 32-bit 字地址（每个 256-bit beat 地址 +8），
  burst 内背靠背出数（否则 rd_cmd_done 展宽成 2 拍，行指针一次 +2 行）。
- 期望行用 `EXP_ROW_OFFSET`（默认 60）而非 `ROW_OFFSET`：`-DROW_OFFSET=0` 只动 DUT，
  才点得亮红灯。
- **`overlay.v` 必须进 SRC 列表**：`video_passthrough.v` 自 Task 3 起实例化 overlay
  （`ovl_en=0` 时纯旁路），漏了它就是 `Unknown module type: overlay`。

## U3：16 框 2 px 边框叠加引擎（先红后绿）

```bash
cd sim/video
# 绿
iverilog -g2012 -o /tmp/u3.vvp tb_overlay.v ../../board/cam/overlay.v && vvp /tmp/u3.vvp | tail -3

# 红（负对照）：把边框厚度 2 改成 3，内圈点必须误命中 -> FAIL
sed -i "s/16'd2/16'd3/g" ../../board/cam/overlay.v     # 只改 border 判据 4 处
iverilog -g2012 -o /tmp/u3_red.vvp tb_overlay.v ../../board/cam/overlay.v && vvp /tmp/u3_red.vvp | tail -3
sed -i "s/16'd3/16'd2/g" ../../board/cam/overlay.v     # 还原
```

判据：绿 = `OVERLAY: PASS`；红 = `OVERLAY: FAIL errs=4`
（`innerL/innerR/innerT/innerB` 四个内圈点被 3 px 边框误命中）。

TB 覆盖：
1. box0 = (100,100)-(199,199) 写 shadow bank → commit → vsync 切 bank（`active_bank=1`）；
2. 4 条边命中 `0x07E0`；
3. 框内心部 + 紧贴边框的内圈（102/197）保持原值；
4. 框外保持原值；
5. `ovl_en=0` 旁路；
6. 无 commit 的第二个 vsync 不切 bank（框仍在）；
7. 双 bank：新 box 写 shadow bank + commit 后旧框消失、新框出现。

说明：
- commit 是 `wr_clk` 域 toggle → `lcd_clk` 3FF + vsync 挂起消费，**一次 commit 只切一次
  bank**；TB 在 commit 后等 8 拍再打 vsync（CDC 走完），计划原文只隔 1 拍会切不过去。
- 行首预取由 `hs` 上升沿触发，32 拍读完 32 word；TB 等 60 拍再比较（含拆表寄存）。
- 像素比较不用 `bq[{k,1'b0}]` 变量位选（部分综合器不接受），预取完成时拆成
  `bx1/by1/bx2/by2` 四个数组。

## U4：VIDEO 寄存器窗（1 KiB：状态/控制/16 框）

```bash
cd sim/video
iverilog -g2012 -o /tmp/u4.vvp tb_video_regs.v ../../board/cam/video_regs.v && vvp /tmp/u4.vvp | tail -3
```

判据：`VIDEO_REGS: PASS`。负对照把 `EXP_CNT` 改成 `8'h22`（TB 里有锚点注释）必 FAIL。

## U1：DDR 2:1 仲裁器（桥 ID=0 / 视频 ID=1）

```bash
cd sim/video
iverilog -g2012 -o /tmp/u1.vvp tb_ddr_arbiter.v ddr_model.v ../../board/cam/ddr_arbiter_2to1.v
vvp /tmp/u1.vvp | tail -3

# 红（负对照）：v_rvalid 不按 RID 分流 -> 桥读数据串到视频侧
sed -i "s|assign v_rvalid = m_rvalid && (m_rid == 4'h1);|assign v_rvalid = m_rvalid;|" \
  ../../board/cam/ddr_arbiter_2to1.v
iverilog -g2012 -o /tmp/u1_red.vvp tb_ddr_arbiter.v ddr_model.v ../../board/cam/ddr_arbiter_2to1.v
vvp /tmp/u1_red.vvp | tail -3
git checkout -- ../../board/cam/ddr_arbiter_2to1.v    # 还原
```

判据：绿 = `DDR_ARB: PASS`；红 = `DDR_ARB: FAIL errs=0 v_spur=6 ...`（RID 分流监视抓到
`v_rvalid && v_rid!=1`）。

说明：
- 视频侧授予只看 `v_awvalid`：厂家 `wr_ctrl` 是 `axi_wvalid = axi_wready`（wvalid 由本模块
  的 `v_wready` 派生），仲裁若同时要求 `v_wvalid` 会死锁；桥侧仍要求 `b_awvalid && b_wvalid`。
- W 数据按 `wsel` 组合选择：源在每拍握手后才换下一拍，若在握手拍把 `wdata` 打进寄存器，
  下一拍永远晚一拍（背靠背 burst 会重复上一拍）。
- `b_wlast/v_wlast` 用最后一拍的属主 `last_sel` 回送，不用当前 `wsel`（新 burst 可能已授予）。
- TB 的 `dbg_v_ar_wait` 检查：桥读在途时视频 AR 挂起，等待计数必须增长。

## 全部闸门

```bash
cd sim/video && bash run_video_gates.sh
```

判据：`VIDEO_GATES: ALL PASS`（依次 U1/U3/U4/U2；U2 逐像素比对约 2.37M，单跑约 5 分钟）。
