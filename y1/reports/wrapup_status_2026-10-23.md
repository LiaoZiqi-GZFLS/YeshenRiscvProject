# 收口状态总表（2026-10-23）

口径：**只写本仓证据**；"已验证"= 有板级或闸门数字，"预测"= 模型，"待窗口"= 需上板。

## A. NPU（主目标：改进 → 1 FPS）

| 项 | 状态 | 数字 |
|---|---|---|
| W1 LOAD 流水（66→33 拍/段） | **板上已验证** | 板级 2,074.5 → **1,771.2 ms（−14.6%）**，12/12 CRC；sim conv15 7,876,639 → 6,187,039（−21.4%） |
| W2 双 bank + 预取重叠（51→34） | 单元闸门 + PnR | sim conv15 6,187,039 → **5,317,089（−14.1%）**；PnR `video1w2c` +0.078；比特流 `ec5ba0da`；**板级待窗口** |
| W3 双写口 2 px/拍（33→17） | **单元闸门 + PnR（整板 All Met）** | sim conv15 5,317,089 → **4,549,064（−14.4%；累计 7,876,639→4,549,064 = −42.3%）**，dump 与重跑**逐字节相同**；PnR npu 域 **+0.620 ns（fmax 56.243 MHz）**；比特流 `87632714`；**板级待窗口** |
| W4 64 B band | **负结果已回退** | AR −44%、`no_valid` 仅 −1.5%、fetch bytes +11% |
| 全帧预测 | 模型 | W1 实测 1.771 s → W3 **~1.47 s**（0.68 fps） |
| 1 FPS 差距 | 结构 | 还需 ~0.47 s；下一杠杆 **G2-c**（K-band 单 op + 4 槽环）：用板级 204 拍/band 暴露量算，K=4 即可全藏 ⇒ 预测 **1.10~1.20 s**。量尺 `+RDLAT` 已进 TB，spec 见 `g2c_op_owner_spec.md` |
| npu_clk | 约束 18.4 ns / 54.0 MHz | 实测 fmax **56.243**；60 MHz 需再切 ~1.1 ns，暂不可行 |

**待窗口**：W3 上板 A/B（对 1,771.2 ms）、`video_health` 归因、G2-c 实现后的复测。

## B. 屏幕/摄像头画质（用户：比单独 cam 版明显下降）

- 已定位**结构性嫌疑**：`rd_buf` 每显示行只提前一行发取数、**显示侧不看 valid/ready** ⇒ 取数被拖慢就显示环形缓冲里的旧内容（撕裂/花屏）。
- 已做：`scripts/video_health.py`（idle vs NPU 负载的 `vid_stall` 二分）+ 修正原规程（CSR 只有 16 位，不能做 10 s 速率）。
- **未定案**：需要一次窗口测 idle/loaded 的 Δ。判读：idle 0 / loaded >0 ⇒ DDR 仲裁；两边 0 而画面差 ⇒ 静态差异（裁列 128..1151 / ROW_OFFSET=60 / 时钟域）。
- 视频 RTL 在 W1/W2/W3 中**一根线未改**。

## C. CPU 线

- 现频 **100.0 MHz**（`pll_cpu.v` RATIO0=10.125；FDC 10 ns —— 一致）。PnR 估计 **106.27 MHz**。
- 到 120 MHz（8.33 ns）需 ~1.6 ns 改进：主杠杆是 **late ALU 流水**（既有 max-ipc 结论）。
- ⚠️ `pll_cpu.v` 文件头里的"108 MHz ← 当前配置"是**陈旧注释**（值是 100 MHz）；下次改动时一并修正。
- 代码组织"按我们的方式改"未开工（独立工作区）。

## D. 软件/镜像（本轮完成）

| 产物 | 指纹 | 说明 |
|---|---|---|
| `sw/images/sd_y1_v2.img` | 10,706,432 B / `dd484418272d7acce85d36b4802d2016` | 5 段：safe 四段逐字节 + 新 rootfs（395 条） |
| `sw/images/rootfs_v2.cpio` | 2,659,360 B / 段 `bdad259f…` | 新增 `root/y1/y1cam`（**已重建** `e4806746`（含 `--loop`+16 MiB bank stride）、`y1run` **已重建** `fc4ec0b6`（含 `--unit-trace`））、`S99y1cam.sh`、`S99leds.sh`；**权限已修**（原 0666 会全部不可执行） |
| `scripts/y1ctl.py` | — | run/put/get/ls/status/ping；scp -O + tftp + 两侧 md5 |
| `scripts/initramfs_add.py` | — | newc 增改，按目标目录给 0755 |
| `scripts/video_health.py` | — | 画质 A/B 探针（16 位回卷已处理） |

## E. LED 诊断（用户：led0~4 可见）

- 语义：led0 PLL / led1 DDR / led2 装载器 / **led3 Linux 1 Hz 心跳 / led4 y1cam 在跑 / led5 NPU busy / led6 网口 up** / led7 PHY RXC。
- 依据：GPIO 外设（`0xF0002000`）早已存在，板级原先悬空；`led[4..7]`=A17/A18/C17/B17（官方 2_7/2_8，全表无冲突）。
- dev_map **PASS 0 error**（LUT 53%、DRM 74%、IO 146/400）。
- **PnR 已完成**（tag `led1`，All Met，sbit `4af41dd6…`）；S99leds 必须后台化（rcS 是 source 执行）。

## F. 上板清单（窗口由用户给）

见 `board_window_runbook.md`：烧前核 md5 → 屏幕/led0~2 不变（硬线）→ `y1run` 12/12 + RUN ms →
`video_health` → v2 卡与 scp。任一步红：先还原 Cam known-good，再留档。

## G. 未完成/继承债

- W3 上板 A/B（窗口）。
- 画质归因（窗口）。
- G2-c 实现（spec/量尺已备）。
- CPU 120 MHz + 代码组织（独立工作区）。
- 远程工具/v2 卡的板端联调（窗口）。

## H. npu 域关键路径（W3 PnR 实测，2026-10-23）

`pds_video1w3.../report_timing/*.rtr` 的 npu 域头号路径（+0.620 ns，fmax 56.243 MHz）：

- 起点：`unitExec_1` 的 **APM（DSP）级联**（P[6]→PO[0]→P[5]→P[24]→P[0]）；
- 途经：`wxSgBB_0[30]` / `wxSgBB_4[31]` → **`wxPNE_4`** → `_N401328`；
- 终点：**`wxFAdrR[*]` 的 CE**（gather 的 band 地址寄存器）。
- 逻辑 9.361 ns（54.5%）、布线 7.803 ns（45.5%）、16 级。

⇒ **不是 MAC 阵列，是 gather 的平面地址乘加链**：`wxPBB(p) = (wxGAbs + tInPixW*p) & ~31`，
其中 `tInPixW * p`（p=0..7）被综合成 DSP 乘法/级联，再与 `wxBndB` 比较出 `wxPNE`，最后压到
`wxFAdrR` 的时钟使能上。

**候选改法（未实现）**：`tInPixW` 每趟只在几何锁存时变一次 ⇒ 把 `preP(p)=tInPixW*p`（8 个值）
**在趟首锁进寄存器**，`wxPBB` 退化成 8 个加法 + 掩码。预计砍掉 4 级 DSP 级联 + 一段布线，
目标把 npu 域 fmax 从 56.24 推到 ≥60 MHz（+6.7% 全帧）；需重跑 PnR 验证，判据 npu WNS ≥ 0。

## I. 会话交接（2026-10-23 21:50，turn 预算耗尽时）

### I.1 `led1` PnR：**已完成**（W3 NPU + LED[7:0] 的完整版比特流）

- **结果：`All Constraints Met`；比特流 9,188,552 B，md5 `4af41dd61859dcdaaa16467070a4b339`**
  （`sim/reglogs/pds_led1_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`）。
- 历程：synthesis 21:17（peak 5.38 GB）→ placement 21:40（peak 5.18 GB）→ routing 21:58
  （peak 6.26 GB）→ 时序报告 → 22:08 比特流。总共 1h25m CPU。
- 工程目录：`sim/reglogs/pds_led1_p10.000/prj_tasks/pnr_1/place_route/seed_0/`
  （`run_place.log` / `run_route.log`）；时序报告在 `place_route/report_timing/yeshen_mini_board_top.rtr`，
  比特流在 `prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`。
- 时序（见 I.1b）与比特流指纹已补进本文件 A/E 节。
- **若以后再需要重跑**：`TAG=led1 YESHENMINI_SYNTH_MODE=speed bash scripts/build_all.sh --only pnr`
  重跑（机器必须空闲；并发 PnR 会抢内存导致 seed 失败——W2 时踩过）。
- 判据：npu 域 WNS ≥ 0（W3 单 NPU 版是 +0.620 @18.4 ns）、soc/cpu/core All Constraints Met、
  资源不超（dev_map 已 PASS：LUT 53%、DRM 74%、IO 146/400）。

### I.2 已交付（本会话完成、有指纹）

- 卡镜像 `dd484418…`（两个过期二进制已重建；payload/desc 来源已核对）。
- `y1ctl.py`（SSH/SCP/TFTP，双侧 md5）、`video_health.py`（画质 A/B）、`initramfs_add.py`。
- LED 诊断（led[7:0]）+ S99leds + S99y1cam 自启；dev_map PASS；端口↔引脚 49/49。
- W3 网表重认证（CYCLES 4,549,064、dump 逐字节同）。
- G2-c spec（K=4、实施锚点 10 条）、TB 的 `+RDLAT` 旋钮（预取闸门的前提）。

### I.3 未完成（明确、可续）

1. **W3 上板 A/B**（对 W1 1,771.2 ms + 12/12 CRC）：等板窗口。
2. **画质下降归因**：`video_health.py` 已就绪，跑 idle vs loaded 的 `vid_stall`。
3. **1 FPS**：当前预测 1.47 s（0.68 fps）；下一步按 G2-c spec 实施（先 S1~S4+S7 的 K=2，
   再 K=4），闸门在 `+RDLAT=640` 下做；之后才轮到 npu 关键路径（tInPixW 预锁存）与写回 4 px/拍。
4. **CPU 120 MHz**：现 100 MHz / PnR 估计 106.27；需 late-ALU 流水 + 独立工作区；
   同时把 `pll_cpu.v` 的陈旧 108 注释改掉。
5. **远程工具/卡镜像的板端联调**（scp/开机自启/LED 语义）。

### I.1b `led1` PnR 结果（2026-10-23 22:05 后，布线后报告）

`prj_tasks/pnr_1/place_route/report_timing/yeshen_mini_board_top.rtr`：

| 时钟 | 请求 | 估计 fmax | Slack |
|---|---|---|---|
| soc_clk | 100 MHz | 107.759 | **+0.720** |
| cpu_clk | 100 MHz | 105.263 | **+0.500** |
| **npu_clk** | **54.348 MHz** | **56.344** | **+0.652** |
| core_clk | 125 MHz | 139.548 | **+0.834** |
| lcd_clk | 51.92 MHz | 96.413 | +8.887 |

**Design Summary: All Constraints Met.**（led[7:0] 与 GPIO 路径未引入违例；
npu 域比 `video1w3` 的 +0.620 还略好。）

---

## J. NPU 提频与预取：单一出口（2026-10-24 收口）

### J.1 已交付
| 项 | 内容 | 证据 |
|---|---|---|
| **60 MHz** | `tInPixW` 寄存 + FDC 16.667 ns + PLL `RATIO0=11.25`（675/11.25=**60.000 MHz**） | `npu60b` **All Met**（npu 60.6024、+0.166；soc +0.760 / cpu +0.249 / core +0.649），sbit **`6906faf1…`** |

⇒ 相对 54 MHz **+11.1%**。★ 板上预期 **~1,326 ms**（不是 1,594：`npu60b` 已含 W1+W2+W3，
而 1,771.2 ms 是 **W1-only** 实测；整帧模型 W1 1,771.2 → W2 ~1,612 → W3 ~1,473（54 MHz）→ ×54/60）。

### J.2 代码在库、但**未进交付**
| 项 | 状态 |
|---|---|
| G2-c band 预取（双 bank 按地址 bit5） | 功能**全绿**（conv15/c64_40 逐字节 + `GATHER_BYTES==GEXP`）；60 MHz 差 **0.86 ns** |
| 提频② `p·tInPixW` 寄存 | +1.06 ns（保留在树里） |
| 提频③ `wxPl0R/wxRowBasR` | +0.045 ns（保留在树里） |
| 提频④ tile 几何寄存（四种写法） | **关闭**：`RegNext` 版 +0.564 但 sched 挂死；其余写法要么 err，要么不提频（`npu_clk_raise.md §8.2–8.4`） |

### J.3 已排除的下一步
- **4 px/cycle 写回**：W2 已把 LOAD 与 STREAM 双缓冲重叠 ⇒ LOAD 不再暴露，预计零收益 ⇒ 不做。

### J.4 板级验收（一条命令）
```bash
bash y1/tools/board_ab_60mhz.sh --frames 3
```
四项自动判：视频帧序号递增 / 每帧 `outputs=12/12` + `Y1RUN: PASS` / RUN 均值 ≤ **1673.7 ms** / `vid_stall` idle-vs-loaded。
判据做过离线正负对照（`outputs=11/12`、超阈值样本都会变红）。

### J.5 2026-10-24 晚：路线 B'（预取进交付）+ 过约束口径

| 项 | 结果 | 证据 |
|---|---|---|
| 60 MHz + G2-c（`npu60k`，4 seed 全跑） | **无解**：−0.860 / −1.399 / **−0.015**（最好）/ −1.377；布线 100%、收敛 0% | `npu_clk_raise.md §8.5/§8.6` |
| 放松约束到 17.778 ns（`npu56pf` seed0） | **反而更差**：物理 18.245 ns（−0.467）vs 紧约束的 16.682 ns | `npu_clk_raise.md §9` |
| 正确口径（`npu56pf2`） | 约束 **16.667**、PLL **56.25 MHz**；seed0 物理 **17.263 ns** ⇒ 真实余量 **+0.515 ns** | `fdc:201` 上方注释、commit `1dc3fc1` |
| G2-c 装置实测 | conv15：零延迟 4,549,064 → 200 拍延迟 6,826,424（`MISMATCH=0`）；`no_valid` 1.25M→3.52M ⇒ **藏掉 61% 的 RTT** | `g2c_prefetch.md §8` |

判交付余量的公式（**必须**按这个算，报告里的 −x.xxx 不是硬件违例）：

```
真实 slack = 报告 slack + (17.778 − 16.667) = 报告 slack + 1.111 ns
```

**`npu56pf2` 收口（2026-10-25 01:36）**：4 seed 全跑（0: −0.596 / 1: −2.294 / 2: −1.474 / 3: −0.937），
流选 **Best Slack Seed 0**；比特流 9,188,552 B，md5 **`3fb1afcd7e25b05ce0b6b59bdcaea382`**。
npu 物理最差路径 **17.263 ns**（估计 57.93 MHz）⇒ 实跑 56.25 MHz（17.778 ns）下真实余量 **+0.515 ns**；
其余域 soc +0.473 / cpu +0.380 / camera +1.606 / lcd +8.713。
`pll_50m` 的综合网表参数已核：`STATIC_RATIO0=12`（=56.25 MHz）。
⇒ **预取第一次进了交付候选**。三点标定（`g2c_prefetch.md §8.2`）：75 拍档实测 5.31M 拍（模型误差 1.5%）
⇒ 预取收益 1.264×；**板级预期 ~1,119 ms / 0.894 fps**（`npu60b` 是 1,326 ms / 0.754 fps，**−15.6%**），
200 拍则 ~942 ms / **1.061 fps**。板级仍需同窗 A/B（`board_window_runbook.md §7.4`）。

### J.6 `npu56pf2` 交付前的功能认证（2026-10-25 02:52，当前树重跑）

| 闸门 | 判据 | 结果 |
|---|---|---|
| `run_b1_tilebuf_ab.sh` | conv15 / c64_40 逐字节 == 冻结黄金 + `GATHER_BYTES==GEXP` + `b1_play=0` 负对照发火 | **PASS**：conv15 `MISMATCH=0`、924,800 字节；c64_40 `MISMATCH=0`、123,904 字节；负对照 `GB_OK=0`、991,232（×9.03）|
| `run_nputop_sched_ab.sh` | 7 个作业 + 非法表负对照 + C2 两项回归 | **PASS**（含"非法表 TYPE=0x77 ⇒ 响亮 err、零设备搬运"）|

日志：`y1/build/cert_b1.log`、`y1/build/cert_sched.log`。净表 `gen/NpuTop.v` = **`761f1b28`**（RTL 自 16:13 未动；
之后只改了 `fdc`/`pll` 与文档）⇒ 交付比特流 `3fb1afcd` 的功能依据就是这两份 PASS。

### J.7 板级窗口实测（2026-10-25 03:03–03:41）：G2-c **判死**，交付定格 `npu60b`

同板同卡、同一条命令（板内 `/root/y1/y1run --frames 1`）：

| 比特流 | 档 | RUN ns | 帧时间 | 输出 |
|---|---|---|---|---|
| **`npu60b`** | 60 MHz，无预取 | 1,357,441,720 / 1,360,223,780（两次） | **1,357–1,360 ms** | **12/12** |
| `npu56pf2` | 56.25 MHz + G2-c | 1,418,421,490 | 1,418.4 ms | **2/12**（只 obj_8/obj_16 对） |

- 比值 1.043（60→56.25 应为 1.067）⇒ **PLL 确实出 56.25 MHz**，问题**不在时钟**。
- 换算周期数 79.8M vs 81.6M ⇒ 预取只省了约 2%，装置里的 21% 没兑现。
- ⇒ **G2-c 在真硬件上既算错也没收益**：预取批与主批共用 DdrMaster 读口、仅靠 `rd_ready` 一拍互斥，
  真板的 CDC/仲裁会让这一拍滑动 ⇒ 数据落错 bank。**路线 B' 作废，`npu56pf2` 禁止交付。**
- 板子已恢复 `npu60b` 并复测 `12/12`（本表第一行第二次读数）。
- 图/摄像头不受影响：视频帧序号 10 s 内 Δ=189 递增、`vid_stall` idle≈0.15 ms（预算 25.9 ms）。

⇒ **本轮 NPU 净交付：60 MHz（`npu60b`，板上 12/12、1,357–1,360 ms，约 0.74 fps）**；
预取这条线以"板级红"关闭，下一步若要继续必须改成**两批各自独立的完成/账本**（大改），且先过板级小作业 A/B。

### J.8 `npu60b` 板级验收（2026-10-25 03:54，一条命令，三帧）

`bash y1/tools/board_ab_60mhz.sh --frames 3 --limit-ms 1500` → **RESULT: PASS**

| 项 | 读数 |
|---|---|
| 视频在跑 | `STATUS[31:8]` 帧序号 10 s 内 Δ=189 ✔ |
| NPU 正确性 | **3/3 帧 `outputs=12/12`**，12 个张量 `crc` 全部 `OK`（含 cls/obj/bbox/kps × 8/16/32） |
| 速度 | **mean 1,362.1 ms**（min 1,357.4 / max 1,371.6）⇒ **0.734 fps**（阈值 1,500） |
| 屏幕归因 | `vid_stall` idle 0.087 ms / loaded 0.211 ms（**预算 25.9 ms/行** ⇒ 余量 ~120×，视频读没有被饿） |

★ 同轮修掉验收脚本的一个真实缺陷：直连 `ssh` 跑 `y1run` 会掉会话（只回
`sh: C:/Program: not found`）⇒ 第 ② 步改成**板内后台跑 + 落 `/tmp/y1run.log` + 轮询抓取**
（`board_ab_60mhz.sh`，本行即由改后脚本产出）。

### J.9 回退后的树**功能已认证**（2026-10-25）

G2-c 与提频②③全部撤回后，`UnitExec.scala` 回到"杠杆①"（= 交付 `npu60b` 的源码态）。
按本仓口径 **不拿文本 md5 当逻辑判据**：行号变化必然改网表 md5，故把两道闸门**重锚**到新网表
（`run_b1_tilebuf_ab.sh` 的 `EXPECT_UE/W32/W640`），再用闸门本身证明**功能等价**：

| 闸门 | 判据 | 结果 |
|---|---|---|
| `run_b1_tilebuf_ab.sh` | ① `TILING=false` 三网表 md5 冻结（`451102f3/0f549d2e/dbfc18db`）② Conv_15 逐字节 + `GATHER_BYTES==924800` ③ c64_40 逐字节 + `123904` ④ **变异负对照**（`b1_play=0`）必须红且红点唯一 | **PASS**（负对照 `MISMATCH=0` 但 `123904→991232` 计数翻 8 倍 ⇒ 红点唯一可归因） |
| `run_nputop_sched_ab.sh` | 7 作业逐字节、非法表两类负对照、权重信箱 W1/W2 正负对照、C2 回归 | **PASS**（4 处 `RESULT: PASS`） |

日志：`y1/build/final_b1.log`、`y1/build/final_sched.log`。

### J.10 净结算：路线 B' 的源码残留已清

`board/pll_50m.v` 仍停在 B' 的 `RATIO0=12.0`（56.25 MHz），而 `fdc` 已是 16.667 ns、
交付比特流 `npu60b` 里也是 60 MHz ⇒ **源码与交付件不一致**。
已回 `11.25/11`（commit `d058c7a`），并清掉 fdc 里 B' 的"故意过约束"注释
（口径与实测保留在 `npu_clk_raise.md §9`）。

### J.11 交付件 `b1sg` 的全量回归（2026-10-25，40 道闸门）

`y1/gen/_regrun.sh` 全表：**28 PASS / 8 FAIL**（日志 `y1/build/regrun_b1sg.log`）。
逐条归因（**没有一条落在 b1sg 改动的路径上**）：

| 红闸门 | 现象 | 归因 |
|---|---|---|
| `run_unitexec_wide_ab`、`run_stride_exec_ab` | 编译期 `Unable to bind cyc_fetch/cyc_emit/...`（5–10 s） | **继承债**：`UnitExecWideTb.v` 的逐相位计数器在当前 `gen/UnitExec*.v` 里已不存在（TB 与网表漂移），与 BypassExec 无关 |
| `run_layoutadapt_ab` | 扫跑时 `rc=1`，**单独跑 = PASS（rc=0）** | **不稳定**（非 b1sg；正作业 COL/DST=0，突变体照常发火） |
| `run_tiling_ab` | `M_two_step mismatch on 1 shapes ⇒ converter M not consumed` | 转换器侧离线参照（本次未动 `y1_convert.py`） |
| `run_wgtdma_geom_ab` / `run_paramdel_ab` / `run_wide_tail_ab` / `run_nonwide_wide_ab`(rc=3) | 4–10 s 快红 / 前置缺失 | 同族：网表或前置产物缺位（未逐一展开，均不涉及 `BypassExec`） |
| **b1sg 自己的闸门** | `run_bypass_tile_ab` **PASS（13 作业）**、`run_nputop_sched_ab` **PASS**、`run_bypass_ab` PASS、`run_b1_tilebuf_ab` PASS | —— |

★ 结论：交付件的**功能面**由 b1sg 自己的闸门 + 板上 12/12×3 覆盖；其余红是**继承的装置/参照债**，
本轮不背（已在表里逐条留证）。

### J.12 读墙与 1 FPS 的关系（2026-10-25，决定性）

装置实测（`DdrBridgeReadPerfTb` + `+QD` 旋钮，LAT=640、产品档 K=4）：**32 B 与 128 B 突发同为 24.2–24.9 MB/s**，
QD 8→4 无差 ⇒ 读通道 ≈ **24 MB/s**，与突发/请求数无关。本帧 gather 22.57 MB ⇒ **光读 ≈ 1.0 s**。
当前 1.262 s 距此地板 ~25%（其余为可重叠的算）。
⇒ **1 FPS 恰等于"读墙地板 + 零串行"**；再快只能抬 AXI 在飞（DDR IP/桥侧，非 NPU RTL）。

> ★ **2026-10-25 更正**：此处 22.57 MB 用了"每 tile 读满 34 列"的模型，**没按 RTL 的 tile
> 边界裁剪**。按裁剪口径整帧 = **17.42 MB（×1.143）**，地板 ≈ **720–790 ms**；
> 因此"1 FPS == 地板"不成立 —— 1,262 ms 里 fill 约 790 ms、算约 470 ms 且**零重叠**，
> 1 FPS 可由**重叠**拿到。推导与设计见 `gather_overlap_spec.md`。
