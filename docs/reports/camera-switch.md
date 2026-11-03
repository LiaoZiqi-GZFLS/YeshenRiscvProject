# 双目相机切换（CAM0/CAM1）—— 实施与验收报告

- 日期：2026-10-27
- 设计：`docs/superpowers/specs/2026-10-27-camera-switch-design.md`
- 计划：`docs/superpowers/plans/2026-10-27-camera-switch.md`
- 状态：RTL + 仿真闸门 + dev_map 完成；PnR 与上板见下文各节

## 1. 一句话

J10 双目模组的第二颗镜头（CAM1）接入；**KEY2(B22) 按键**与 **VIDEO 窗 `0x00C CAM_CTRL[0]`** 同源切换，
切换在整帧边界重启、**事件驱动黑屏**（不是定时）、切换期**掐写侧**保证 DDR 不落撕裂帧；
不按键时默认 CAM0，行为与交付版逐位一致。

## 2. 改了什么（8 个文件）

| 文件 | 内容 |
|---|---|
| `board/cam/cam_switch.v`（新，201 行） | 无毛刺像素时钟 mux（soc 域"先关旧→确认关掉→再开新"两段式 + 各自 pixel_clk 下降沿换门控）、`wr_ok` 掐写、黑屏状态机。**不做数据 mux、不复位两路 cmos**（见 §6.2） |
| `board/cam/key_toggle.v`（新，43 行） | KEY 电平持续计数消抖（19 ms @100 MHz）+ 单次脉冲；**不是**边沿计数 |
| `board/cam/video_regs.v` | `0x00C CAM_CTRL`：`[0]` RW sel / `[1]` RO ready / `[2]` RO busy；按键翻转与软件写同源，软件优先 |
| `board/cam/video_passthrough.v` | 第二份 `camera.v` + **第二套 `cmos_8_16bit`**（各用裸 PCLK）、`cam_switch` 实例、数据 mux（在整流级之后）、写侧门（`wr_en` 与 `wr_fsync` 同门控）、输出级黑屏 |
| `board/yeshen_mini_board_top.v` | CAM1 七组端口 + `key2` + `key_toggle` 实例 + 连线（端口位 146→161） |
| `constraints/yeshen_mini.fdc` | CAM1 14 球 + KEY2(B22) + `camera_clk_1` + `cam_pixel_clk`/`cam_pixel_clk_1`（各自主 cmos 的 `pixel_clk` 脚）+ `camwr_clk`（mux 输出，`create_clock` 打在内部脚）+ 异步组 |
| `pds/run_devmap_yeshen.tcl` / `pds/run_pnr_yeshen.tcl` | 新 RTL 进 PDS 源清单（首跑 Compile 报 `'key_toggle' is referenced to undefined module` 后才补的） |
| `sim/video/*` | `tb_cam_switch.v`、`tb_key_toggle.v`（新），`tb_video_regs.v`/`tb_video_path.v`（加端口与用例），`run_video_gates.sh`（加 U5/U6） |

vendor（`board/cam/vendor/**`）**零改动**；LED 一根未动。

## 3. 仿真闸门（`bash sim/video/run_video_gates.sh`）

```
U1 DDR_ARB: PASS
U1b DDR_ARB_MO: PASS（BN=1 负对照必红：MO_PEAK=1）
U3 OVERLAY: PASS
U4 VIDEO_REGS: PASS          ← 含 CAM_CTRL 读写/按键翻转/ready/busy 用例
U5 CAM_SWITCH: PASS          ← 新增；负对照（裸 mux）必红
U6 KEY_TOGGLE: PASS          ← 新增；负对照（第一拍就发）必红
U2 VIDEO_PATH: PASS          ← 2,368,008 像素、6 帧、mismatches=0、addr_errs=0
VIDEO_GATES: ALL PASS
```

两档负对照都**实测发火**（不是"设计上应该红"）：

- U5：把 `pix_clk` 换成裸 mux `sel ? pix_clk1 : pix_clk0` ⇒ 毛刺判据命中"窄高/窄低脉冲"，`RESULT: FAIL errs=2`。
  TB 末段有一段**相位扫描**（24 次不同相位换源），专门保证这条负对照能发火（早期只切 2 次时裸 mux 侥幸没被抓到）。
- U6：把"数到阈值才发"改成"第一拍就发" ⇒ 抖动 6 次按压误发 6 个脉冲，`RESULT: FAIL errs=4`。

相机档（`SIM_BYPASS_CAMERA=0`）另做了一次以 `video_passthrough` 为 root 的 iverilog 展开编译，exit 0。

## 4. 综合（dev_map）

`YESHENMINI_DEVMAP_TAG=camsw pds_shell -file pds/run_devmap_yeshen.tcl` → `YESHENMINI_DEVMAP_DONE`，0 个 `E:`。

| 项 | 基线（`build_all_devmap.log`） | 本轮 camsw | 增量 |
|---|---:|---:|---:|
| LUT | 85,591 | **85,868** | **+277** |
| Registers (FF) | 115,761 | **115,985** | **+224** |
| DRM36K | 305.0 / 415 | **305.0 / 415** | **+0** |
| APM | 263.00 / 740 | 263.00 / 740 | 0 |
| LUT as dram | 8,079 | 8,079 | 0 |
| I/O ports | 146 | **161** | **+15**（CAM1 14 + key2） |
| DRC | — | 0 条 | — |

判据：DRM 增量 = 0 ✅；LUT 增量 277 ≪ 5000 的警戒线 ✅。

## 5. 时序 / 比特流（PnR）

> 第一版（tag `camsw`，单 cmos + LUT 门控钟）当时也过了 PnR（All Met，sbit `4af2c174…`），
> 但上板画面是坏的（见 §6.2）；下表的数字是**修好之后**的 `camsw4`。

- 命令：`YESHENMINI_PNR_TAG=camsw4 pds_shell -file pds/run_pnr_yeshen.tcl`（复用同一轮 dev_map 工程 `sim/reglogs/pds_camsw4_p10.000`）
- 结果：`YESHENMINI_PNR_DONE`，**`npu_clk` 仍差 −0.096 ns（4 个种子：−0.426 / −0.096 / −0.705 / −0.636，
  无一收敛）**；其余域全部 MET。比特流正常生成。
- 比特流：`sim/reglogs/pds_camsw4_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  （已留档 `deliver/sbits/camsw4_20261028.sbit`，**9,188,552 B**，md5 **`7944b0130185b8ca439b001403a75b61`**）

Setup 松弛（Slow Corner，`report_timing/yeshen_mini_board_top.rtr`，被选种子）：

| 域 | WNS (ns) | 违例端点 | 备注 |
|---|---:|---:|---|
| soc_clk | +0.677 | 0 | 100 MHz |
| cpu_clk | +0.424 | 0 | 100 MHz |
| **npu_clk** | **−0.096** | 859 | 估计 59.655 MHz / 16.763 ns；**本轮 4 个种子都没收敛** |
| camera_clk_0 | +0.902 | 0 | |
| camera_clk_1 | +0.938 | 0 | |
| cam_pixel_clk / _1 | +18.651 / +17.741 | 0 | 两套 cmos 各自的 ÷2 输出 |
| **camwr_clk（新）** | **+14.991** | 0 | 硬宏 mux 输出，50 MHz / 20 ns，317 端点 |
| lcd_clk | +7.410 | 0 | |
| core_clk | +0.501 | 0 | 125 MHz |

- `npu_clk` 的处置：它与本次改动无关（NPU 侧 RTL 一个字没动，历史上一直在 ±0.1 ns 量级摆动：
  `npu60b` +0.013、`camsw` +0.024、`b1sg` 附近亦同）。**本比特流按"相机验证用"口径使用**；
  若要做交付版，需再花一轮 PnR（`YESHENMINI_SYNTH_MODE=speed` 或加种子）把它收正。

## 6. 上板验收

烧写（**修复版 `camsw4`**）：`python -u scripts/flash_and_verify.py --tag camsw4 --secs 120 --no-net`
→ `done bit = 1`，8 个启动 marker 全 `[ok]`（SDR 帧 / OpenSBI / Linux / LiteEth / dropbear / 用户态 / 登录提示符）⇒ **启动 PASS**。

板上只读判据（ssh，`camsw4`）：

| 判据 | 结果 |
|---|---|
| `devmem 0xF000740C`（CAM_CTRL） | **`0x2`** = sel=0(CAM0) / ready=1 / busy=0 |
| `STATUS[31:8]` 帧计数 1 s 差分 | `0x95A → 0x96E`（20 帧/s，出帧正常） |

> 目视判据（CAM0 颜色/噪点是否恢复正常、KEY2 切换后 CAM1 是否正常）待人工确认——
> 用户对上一版（`camsw`）的报告是"形状对但颜色错、满屏噪点"，对 `b1sg` 是"画面正常"。

第一版（`camsw`）的其余判据（寄存器读写/切换语义/帧存像素/KEY2 同源位）当时都已过，
RTL 之后只改了前端结构与时钟 mux，上述行为未变；`camsw4` 复测了第 1/3 条（见上表）。

| # | 判据 | 结果 |
|---|---|---|
| 2 | 切换后 ready/busy 语义正确 | `camsw` 已 **PASS**：写 `1` → `0x3`；写回 `0` → `0x2`（`camsw4` 未重测，逻辑未改） |
| 4 | 帧存里有真实像素（不是全黑/全 0） | `camsw` 已 **PASS**（`0x90000000` 起非零且随时间变化） |
| 5 | **KEY2 实体按键切换** | **未测**（需人工按键；寄存器路径已证同源位可切） |
| 6 | **屏幕画面与 Cam known-good 一致** | **待目视**（这是本轮修改的唯一目标，见 §6.2） |
| 7 | CAM1 缺失可恢复 | 未构造该场景（本次两颗都在） |
| 8 | `y1run` 12/12 回归 | **FAIL —— 但与本次改动无关**，见下 |

### 6.1 `y1run` 失败的**真因：测试污染**（2026-10-27 定案，此前两次归因均作废）

**结论：NPU 没有 bug。** 早先看到的 `Y1RUN: FAIL` 与"非确定性 CRC"是**两个进程抢同一颗 NPU** 造成的：

- 板上自启服务 `/etc/init.d/S99y1cam.sh` 常驻 `y1cam --loop`，**一直在反复驱动同一颗 NPU**、反复写同一批输出缓冲区；
- 取证：`done` 之后读 `STATUS`（NPU 窗 `0xF000C000+0x04`），单元计数仍在 **0x43 → 0x0D → 0x02 循环** ⇒ 有别的东西在反复重启它；
- `ps` 命中 `y1cam --loop`（PID 96 / 1205）；
- **kill 掉它之后，同一份 `camsw` 比特流连跑 3 次全部 `outputs=12/12` `Y1RUN: PASS`**（`ns≈1.29 s`）。

⇒ 之前"NPU 比特流不可靠 / DDR 边际"两条归因**都作废**（前者把并发写缓冲当成了数据错，后者把 `arena 回读 CRC 不符` 当成了 DDR 故障）。

| 判据 | 结果 |
|---|---|
| `camsw` + 停 y1cam，y1run ×3 | **3/3 PASS（12/12）**，`ns` 1.284 / 1.284 / 1.292 s（离散步长小，确定性） |
| `camsw` + y1cam 在跑，y1run ×n | FAIL 且每次 CRC 不同（污染态，**判据无效**） |
| **反向对照**：恢复 y1cam 后再跑 y1run ×2 | **重新 FAIL**（含一次 `arena 回读 CRC 不符`）⇒ 因果双向闭合 |
| 产品路径 `y1cam --once` | PASS：抓帧 → `desc`/`wgt_mailbox` CRC OK → NPU done 1.296 s → 后处理（本次画面无人脸，`CAM_DETS=0`） |

**防复发**：新增 `scripts/board_y1run_ab.py` —— 先停 `y1cam` 循环、跑 N 次 y1run、解析判据、再恢复自启；
停不掉就 **拒绝继续**（exit 3），不给污染态出结论的机会。用法：

```bash
python -u scripts/board_y1run_ab.py --n 3      # RESULT: PASS (3/3)
```

> 教训（写进交付口径）：**板上有常驻 NPU 消费者**。任何"单次 NPU 判据"（y1run / `npu_frame_run`）
> 都必须在停掉 `y1cam` 之后跑；`STATUS` 单元计数在 `done` 之后仍在变，就是"还有别人在跑"的指纹。

> 说明：`sim/reglogs/` 被 gitignore ⇒ dev_map/PnR 原始日志不入库，本文第 4/5/6 节的数字是它们的手抄摘要。

### 6.2 上板发现：CAM0（不切换）画面"花了" —— 根因与结构修订

**症状（用户目视）**：`camsw` 比特流上电后屏幕画面**形状/几何正确、颜色错、满屏噪点杂色**；且
**不按 KEY2、只用 CAM0 也这样**。

**对照实验（证明是本次改动引入）**：

| 比特流 | 交付前状态 | 屏幕 |
|---|---|---|
| `b1sg`（改动前的产品位流） | 原样 | **正常** |
| `camsw`（第一版双目） | 只加了双目切换 | **颜色错 + 噪点**（CAM0 不切换也花） |

**根因**：第一版把"两路原始数据 mux + 门控时钟 mux"插在厂家 `cmos_8_16bit` **之前**：

```
第一版： camera0/1 → 负边沿采样 → [数据 mux] ┐
                camera0/1 PCLK → [门控 mux] ┴→ 单个 cmos_8_16bit → 帧存
现在  ： camera0 → 负边沿采样 → cmos_8_16bit #0 ┐
        camera1 → 负边沿采样 → cmos_8_16bit #1 ┴→ [数据 mux] → 帧存
                                                     ↑ pixel_clk 做无毛刺 mux
```

`cmos_8_16bit` 靠 pclk 采样把两个字节拼成 RGB565（`cnt` 相位决定高低字节配对），采样点必须**紧贴引脚**。
把 mux LUT 与门控时钟插到它前面，在 85k LUT 的整板工程里插进来的布线/逻辑延迟足以把**字节配对顶错**；
而 href/vsync 仍是对的 ⇒ 几何不变、只毁颜色，叠加采样点抖动就是满屏噪点。
（参考工程 `cam2lcd_200mini` 只有 6.5k LUT，同结构侥幸能跑 —— 所以"照抄参考工程"在这一条上不成立。）

**结构修订**（`6626771`）：

1. **每路相机各自一套 `cmos_8_16bit`，各用裸 PCLK** —— CAM0 这条路与改动前**逐字同构**（同样的
   负边沿采样 + 同样的 `pclk=camera_clk_0`）；数据/`de`/`vs` 的 mux 挪到两套整流级**之后**。
2. `cam_switch` 只保留：`pixel_clk` 无毛刺 mux、`wr_ok` 掐写、黑屏状态机。
   - 时钟 mux 换成**硬宏 `GTP_CLKBUFGMUX`**（不是 LUT 门控）：宏内部对 `SEL` 在两个输入钟域
     各做两段同步、双向确认后才换源，切换过程把输出钳在低电平。LUT 拼的门控钟在 PDS 里
     既不是合法时钟根（见下），也拿不到时钟树的低 skew。
3. **切换时不再复位两路 cmos**（`rstn0/rstn1` 只跟各自 SCCB 的 `init_done`）：两路 `pixel_clk`
   始终在跑，关掉一路时它的 enable 一定能被自己的下降沿清掉。若在切换时复位所选 cmos，该路
   `pixel_clk` 会停（厂家模块的 `enble` 要等下一个 VS 才重启）⇒ 门控互锁清不掉、切回去黑屏。
4. fdc 跟着改：`cam_pixel_clk`/`cam_pixel_clk_1` 各落在自己那套 cmos 的输出脚（不再是同一 pin，
   去掉 `-add`）；写侧 `camwr_clk` 建在**硬宏的 `CLKOUT` 脚**上（与 `lcd_clk`、`rgmii_clk` 同姿）。

> **中间版本（已废弃，留作教训）**：先用"两路 enable 先关后开 + 下降沿换门控"的 LUT 方案做了一版，
> PDS 在 dev_map 日志里给了 `Timing-4121`（`camwr_clk` 建在 `u_camsw/N14/Z` —— LUT 输出脚 ——
> "not defined on a right clock source object"）与 `SDC-2030`（"Source of the clock 'camwr_clk'
> cannot be found, it may have been optimized"），后面引用它的 `set_clock_groups` 全被忽略。
> 也就是说**写侧那一域实际没被约束**，而 PnR 不会因为"约束没生效"而报错 —— 只能从日志里抓。

**验证**：

- 闸门 `VIDEO_GATES: ALL PASS`（U1/U1b/U3/U4/U5/U6/U2）。
- U5 两条负对照都**实测发火**：① 把时钟 mux 桩换成裸 mux ⇒ 窄脉冲判据命中（`errs=2`）；
  ② `wr_ok` 恒 1 ⇒ 掐写判据命中（`errs=1`）。裸 mux 的判据靠 TB 末段 24 次不同相位、间隔
  0.4–5 µs 的换源扫描保证有效（早期只切 2 次时裸 mux 侥幸没被抓到）。
  > 说明：无毛刺本身由硬宏保证，仿真里验的是**同语义桩** + 判据本身活着。
- 相机档（`SIM_BYPASS_CAMERA=0`）以 `video_passthrough` 为 root 的 iverilog 展开编译 exit 0。
- dev_map（tag `camsw4`）：LUT **85,701** / FF **116,040** / DRM **305** / IO 161 / USCM 13
  （USCM 12→13 = 时钟 mux 硬宏真的占了一个时钟网络资源），0 个 `E:`；日志里 `camwr_clk`
  只剩 `Timing-4121` 一样板提示（与 `soc_clk`/`cpu_clk`/`npu_clk`/`lcd_clk` 的 `Timing-4120`
  同性质，都是"建议写成 generated clock"），**不再有** `SDC-2030`（源被优化掉）与
  `SDC-2039`（引用它的 `set_clock_groups` 落空）。

## 7. 已知限制

- 切换有约 0.5 s 黑屏（`T_SETTLE=400 ms` 专供新相机 AEC/AWB 收敛 + 等满 2 帧），不是无缝切换。
- 无角标；当前相机靠 `CAM_CTRL[0]` 读回或软件读回后点灯。
- CAM1 缺失时切过去会停在黑屏（`switch_busy=1` 可读），需再按一次回 CAM0。
- `sim/reglogs/` 被 gitignore ⇒ dev_map/PnR 原始日志不入库，本文第 4/5 节的数字是它们的手抄摘要。

---

## 8. 2026-10-29 结构修订：同一时刻只让一路相机出图

### 8.1 证据链（全部来自板上帧存实读）

用两把**互相独立**的读路（板上 `y1cam --once --dump` 走 CPU mmap、H2 硬件读存服务走 DMA）
对同一时刻的帧存取样，结论一致；再配合下列对照把范围一步步收窄：

| 判据 | 结果 | 排除的解释 |
|---|---|---|
| CAM0 / CAM1 分别抓 | 两路坏得**一模一样**（脉冲坏点 3.3% / 3.8%，色度离散度同量级） | 单目前端/单颗传感器 |
| **两个 bank 各抓一次** | 坏点率 3.83% vs 3.79%、色度离散度相同 | 读错 bank / 半写帧 |
| 停掉 `y1cam --loop`（NPU 满载）再抓 | 3.29% → 3.49%，指标不变 | DDR 争用 / 写路被饿死 |
| 字节序枚举（LE / BE / 字节移位 ±1..±3，六种） | 最好一档 `mean|R−G|` 仍 41/255、`mean|B−G|` 51/255（干净参考是 12/10.6） | 字节/位序错、字节配对错位 |
| 16 个 bit 的横向 toggle 率 | 全在 5–21%，每个 bit 都承载连贯图像 | 位平面随机化 |
| 帧存内容逐帧比对 | 坏点**逐帧换位置**（两帧坏点交集 2.7%），样本在平坦区 | 静态映射错、固定图案 |
| **212d3a2 诊断版：CAM1 整颗按住复位** | **CAM0 立刻干净**（网表/布局一字未改） | 布线/布局拥挤 |

形态本身：G（亮度）空间连贯、`|dx=1| < |dx=2| < |dx=3|`；坏点多集中在**平坦区**且
幅度大、多为**单比特翻转** ⇒ 是**采样点余量不足**的特征，不是映射或逻辑错。

### 8.2 结论与改法

第二路相机的**活动**（传感器出图 + 第二套整流级 + 第二路 pixel_clk）把第一路本就临界的
采样点顶出余量。于是：

- `cam_switch` 新增 `en0/en1`，直接门控 `camera.v` 的 `rst_n`（PWDN/RESET/SCCB）：
  **未选中的那一路整颗复位** ⇒ 传感器停、pixel_clk 停、整流级停。
- 换源必须先把目标那一路"叫醒"再换（硬宏 `GTP_CLKBUFGMUX` 的握手要有两个钟的沿）：
  ```
  S_RUN  --sel 变化-->  S_POWER（放行目标，等 init_done + 目标 pixel_clk 翻转 >= 32 次）
         --条件满足-->  S_FLIP （翻 mux，保持 SW_RST_CYC=1 ms 让硬宏交接）
         --到时-------->  S_RUN （顺手把旧那一路断电）
  ```
  切换期间 `wr_ok=0`、`black=1`，屏幕看到的就是原有的 ~0.5 s 黑屏窗口。
- `sel` 在 S_POWER 中途又变：清翻转计数、当拍不许换源（防止拿上一路的沿去确认这一路）。

### 8.3 验证

- `bash sim/video/run_video_gates.sh` → **VIDEO_GATES: ALL PASS**
  （U1/U1b/U3/U4/U5/U6/U2）。U5 的 TB 已按新时序重写：上电只放行 CAM0、切换必须
  "目标先上电 → 换源 → 关旧路"，并断言换源前后 `pix_clk` 确实分别来自 `pix_clk0/1`。
  两条负对照仍**实测发火**：① 裸 mux → 毛刺判据（errs=2）；② `wr_ok` 恒 1 → 掐写判据（errs=1）。
- dev_map（tag `camwd1`）：0 error / 0 DRC；LUT **87,739.5**（55%）、FF 119,613（38%）、
  DRM 312（76%）、APM 257（35%）、IO 161、USCM 13。
- PnR（tag `camwd1`）：**Design Summary : All Constraints Met**（seed 1 / strategy 3 / 10 ns 真约束，未过约束）。
  CPU 域 **+0.614**、soc +0.406、npu +0.115、camera_clk_0 +1.165 / camera_clk_1 +1.659、
  camwr_clk +13.481、core→phy_dq +0.062。比特流 `c6f9d6c2`（9,188,552 B）。
  注：`camera_clk_*` 的正 slack 只说明 **FPGA 内部**那段满足 10 ns，**不覆盖**传感器在连接器上的
  数据有效窗（那条总线没有 I/O 时序约束），所以它不能当作"采样余量已够"的证据。
- 上板 A/B：`c6f9d6c2` 上板换源序列（0x5→0x3→0x2）**实测正确**，但**画面仍然花**。
  ⇒ 本节"第二路的活动把第一路顶出余量"这条归因**被后续对照实验推翻**，见 §9。


## 9. 2026-10-30 定案：真因是 `cmos_8_16bit` 前多了一级寄存器（上板验收通过）

### 9.1 结论

**`cmos_8_16bit.pdata_i/de_i/vs_i` 必须直连引脚，中间不能有任何寄存器或组合门。**

厂家模块内部（以 `vendor/tutorial/cmos_8_16bit.v` 源码为准，**没有 IDDR**）：

```verilog
pdata_i_reg <= pdata_i;                  // pclk 正沿
pdata_out1  <= {pdata_i_reg, pdata_i};   // 两拍拼成一个 RGB565 字
```

若在 `pdata_i` 前面插一级**负沿**寄存器，正沿看到的永远是"上一次负沿采到的字节"
⇒ **整个数据流晚一个字节** ⇒ 拼出来是 `{byte[n], byte[n-1]}` 而不是 `{byte[n+1], byte[n]}`
⇒ **只毁颜色不毁形状**（亮度仍基本对，色度全错）。

> 更正：`6626771` 之后的注释曾写"内部用 `GTP_IDDR_E1` 在 pclk 两个沿取字节"，**这句是错的**，
> 已在 `video_passthrough.v` 与 fdc 里改正。

### 9.2 三次对照（同板、同传感器、同场景，隔夜可重复）

| 比特流 | 前端接法 | 画面 |
|---|---|---|
| `5df46d6b`（= `ff5c236`，台账里的 "Cam 正常版"） | `pdata_i` **直连引脚** + PCLK 过 `GTP_CLKBUFG` | **干净** |
| `6626771` 之后 | `pdata_i` 前加 `cam_d_d0`（pclk 负沿寄存级） | 花（色偏 + 满屏杂色） |
| `3f699ed` | 只把 `GTP_CLKBUFG` 加回来、寄存级没拆 | **仍花**（impulse 3.52% vs 旧铁证 3.56%） |

⇒ 同时推翻 §8 的两条旧归因：
- "第二路的活动把第一路顶出余量"（`212d3a2` 那次 CAM1 按住复位 CAM0 就好）是**相关不是因果**；
- "采样余量随布局漂移"也不是主因——加 `set_input_delay` **不解决问题**（拓扑错，不是余量问题）。

### 9.3 改法

1. 两路 `cmos_8_16bit` 的 `pdata_i/de_i/vs_i` **改回直连引脚**，删掉
   `cam_d_d0/cam_href_d0/cam_vsync_d0`(+`_1`) 两级寄存器；PCLK 仍过 `GTP_CLKBUFG`。
2. **取消 `en0/en1`**：两路相机模块与前端**常开**（复位只跟各自 SCCB `init_done`）。
   理由：`GTP_CLKBUFGMUX` 换源要等两个钟各自的沿，任一路 `pixel_clk` 停了 SEL 永远换不过去；
   常开后切换只剩"掐写 → 守卫 → 翻钟 → 计数 → 放行"。`cam_switch` FSM 简化成
   `S_RUN / S_WAIT / S_FLIP`，换源守卫保留（价值转为**掉线保护**）。
3. fdc：相机输入 `-min 0.000 → 1.500`。`-min 0` 是"数据可以在时钟沿那一刻才变化"的
   非物理假设；pin 直连后中间不再有 FF 提供额外数据延迟，它直接暴露成
   `camera_clk_1` hold −0.133 ns（1 端点）。1.5 ns 是**保守 tH 假设**（无 OV5640 手册）。
   `-max` 仍 5.0。

### 9.4 验收

- `bash sim/video/run_video_gates.sh` → **VIDEO_GATES: ALL PASS**（11 项）。
  U5 新增判据：`rst_drops == 0`（切换全程不得复位任何一路）、目标未 `init_done` 不换源、
  目标 `pixel_clk` 停摆不换源；两个负对照仍翻红（裸 mux → 毛刺；`wr_ok=1` → 掐写）。
- dev_map（tag `camfix4`）：0 error；LUT 87,789.5（55%）、FF 119,592（38%）、DRM 312（76%）、APM 257（35%）。
- PnR（tag `camfix4`）：**Some Constraints Violated**（见 §9.5），相机两域
  `camera_clk_0 +2.843` / `camera_clk_1 +2.881`，hold 全正（最差 +0.102）。
  比特流 **`a7e1fa1a36e04f253ac9bcb9d8b60df4`**（9,188,552 B）。
- 上板：启动 8/8 PASS（含 `misoHi=1`），整帧取证（`scripts/verify_cam_frame.py`，1024×600 两 bank）：

  | 指标 | 修前（`rst1`） | **修后（`camfix4`）** |
  |---|---|---|
  | `uniq565` | 232 / 263 | **6143 / 5917** |
  | 非黑像素里 `R=0` 占比 | **72.5%** | **1.4% / 1.6%** |
  | 全零字节 | 59.9% / 61.1% | **0.63% / 0.69%** |
  | 色度散布 `B−G` | 7.4 | **3.5** |

  ⚠️ 两次取数**光照不同**（凌晨 vs 上午），`zeros%` 的差值含光照因素；但 `R=0` 与
  `uniq565` 是结构性量级变化，且与屏上目视一致。
- **用户目视验收：正常（颜色正确，真实场景）**。

### 9.5 已知限制

1. `camfix4` 严格说不是 All Met：唯一违例是 `core_clk → phy_dq_sysclk_0`
   **setup −0.031 ns / 1 端点**。两条 DDR PHY lane 的约束是对称的（都有
   `set_multicycle_path 2` + `±0.4 ns` uncertainty），这条路径本身在 0 附近摆动
   （历史 `+3.2 / +0.069 / −0.011 / −0.013 / +0.030 / −0.031`），与相机改动无关。
   上板表现：SD 装载无 CRC 错、8/8 启动判据过。
2. 画面上仍有**横向彩色细条纹**（单行高、品红/绿/青，右侧更密）。`impulse` 指标因此
   仍停在 ~3.5%（该指标已失去区分度）。怀疑方向：DDR 写/读争用或行首相位，未定位。

### 9.6 横向彩条：已排除的六条（2026-10-30，B 轮）

上板取证用的都是**帧存原始数据**（`scripts/verify_cam_frame.py` 走 H2 硬件读存，
绕开 LCD 读出通路），所以"屏上看到的"就是"存进去的"。

| 已排除 | 判据 |
|---|---|
| LCD 读出通路 | 数据取自帧存本身，异常已在里面 |
| DDR 残留（写丢失后留旧数据） | 连抓两帧：逐像素仅 **2.34%** 相同，**没有任何一行** ≥90% 相同 ⇒ 每帧都新写 |
| 整行水平平移（写侧 burst/行首对齐） | 平移搜索 ±12 像素，最佳恒为 `k=0`，平移后残差不变好 |
| 字节配对相位翻转 | 异常行**局部**做字节交换后更差（`mean|R-G|` 32→66，`|B-G|` 24→54） |
| 工频 / LED 闪烁 | 异常行的行距中位 **2**、最大 80，**无周期**；20 行粒度的垂直色度轮廓也无周期性 |
| DDR 争用（写被 NPU 挤掉） | **NPU 满载 vs 空闲**：异常行 12 vs 29（负载上去反而略降，在噪声内） |

形态特征（供下一步）：异常行为**整行或行的右半段**被替换成**中段偏亮的全彩数据**
（异常行 R 均值 14.8/31、G 27.3/63、B 13.3/31；正常行 9.5/25.6/…），每帧位置不同。

⇒ 剩余主要嫌疑是**传感器/模拟侧**（暗场高增益下的行相关色噪）。
**待验**：白天同场景再抓一次——若明显减轻/消失即为增益相关，不是 FPGA 通路问题。
