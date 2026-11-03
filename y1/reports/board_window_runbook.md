# 上板窗口 runbook（led1 = W3 NPU + LED[7:0] 完整版）

日期：2026-10-23。**窗口由用户给**；板子现在仍在 Cam known-good（`cam2lcd2_top_p4_nogauss.sbit`）。
每一步都有**判据**和**失败动作**；不做无判据的"看看"。

## 0. 前置（5 min）

1. **占用检查**（memory 规矩）：同 cwd 有没有别的会话在跑；本机有没有别的 `pds_shell`/`pds.exe`；
   COM7/8/9 与 JTAG 口有没有被占。有疑问 → 先问，不烧。
2. 比特流指纹：`sim/reglogs/pds_led1_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
   **9,188,552 B / md5 `4af41dd61859dcdaaa16467070a4b339`**（All Constraints Met），**烧前核 md5**。
3. 记录改前基线：W1 `4295b8d4…` 1,771.2 ms；W3 预测 ~1.47 s（sim conv15 −42.3%）。

## 1. 烧写 + 启动（约 3 min）

```bash
python -u scripts/flash_and_verify.py --tag led1 --secs 12 --no-net
python -u scripts/y1ctl.py ping           # 网络 + 口令通道自检（有 ssh 才继续）
```

判据：烧写脚本报 verify OK；`y1ctl ping` 回 `OK`。
失败：先读 done bit / 重烧一次（memory：断电掉配置）；仍失败 → 停下报告，不盲改。

## 2. 屏幕与 LED（**人眼判据**，30 s）

- 屏幕应与 **Cam 正常版一致**（同样的取景/色彩/无撕裂）；记录差异（位置/频率/是否只在 NPU 跑时出现）。
- LED：**led0 常亮**（PLL）、**led1 亮**（DDR）、装载后 **led2 灭**、**led3 1 Hz 闪**（Linux 心跳）、
  **led4 亮**（S99y1cam 已起）、**led6 亮**（网口 up）；led5 随 NPU busy 亮。
- 判据：led0~2 与改前**完全一致**（这是"没弄坏"的硬线）；led3 在闪 = 用户态活着。
- 失败：led3 不闪 → `y1ctl run "cat /proc/uptime"` 看内核在不在；led4 不亮 → `y1ctl run "cat /run/y1cam.pid"`。

## 3. NPU A/B（W3 vs W1，5 min）

```bash
python -u scripts/y1ctl.py run "/root/y1/y1run --frames 3"
```

判据：**12/12 CRC 全过**；RUN ms 对 W1 的 1,771.2 ms（同板同卡同会话的直接对照）。
- 若 ≥1,771 ms：W3 无收益 → 回退到 W1 档（`--tag video1wr`），并把 W3 标为"sim-only"。
- 若 ≤1,600 ms：W3 采纳；继续第 4 步。

## 4. 画质归因（**VIDEO.DBG**，2 min）

```bash
python -u scripts/video_health.py --window 0.2 --settle 5
```

判据与读法：
- `idle` Δ=0、`loaded` Δ>0 或 `WRAPPED` ⇒ **NPU 流量确实拖住视频读**（DDR 仲裁/带宽）；
- 两边都 0、画面仍差 ⇒ 与 NPU 无关，转查静态差异（裁列 128..1151 / ROW_OFFSET=60 / 时钟域）；
- `idle-3` 必须回到 0（负对照：停 y1cam 就恢复）。
- ⚠️ DBG 只有 16 位（0.655 ms 满量程）⇒ 只看"0 / 非 0 / 回卷"，**不要**当速率用。

## 5. v2 卡（含全部软件，5 min）

1. 写卡：`sw/images/sd_y1_v2.img`（md5 `dd484418272d7acce85d36b4802d2016`）raw 写到 LBA 0；
   **先核对盘号**，写后回读头表（5 条 + md5）。
2. 上电看串口：`Y1CAM-BOOT pid=…`（kmsg）；屏幕出现 YuNet 框。
3. 验证：`y1ctl run "cat /proc/uptime"`、`y1ctl get /root/y1/y1cam` 回读 md5 对上；
   `y1ctl put sw/images/rootfs_v2.cpio /root/rootfs.cpio` 走一遍 scp 通路。

## 6. 收尾

- 记录：比特流 md5、`y1run` 的 RUN ms/CRC、video_health 三行、LED/屏幕目视结论、卡镜像 md5。
- 若任一步判据红：**先还原 Cam known-good 比特流**（memory：用户要求最终屏幕与 Cam 版一致），
  再把红证据写进 `y1/reports/`，不在板上盲调。

## 6. 2026-10-24 更新：**60 MHz 候选**（优先烧这个，替 led1）

| 档 | 约束 | 结果 | 比特流 |
|---|---|---|---|
| `led1`（W3，54 MHz） | npu 18.4 ns | All Met（npu +0.652） | 9,188,552 B `4af41dd61859dcdaaa16467070a4b339` |
| **`npu60b`（W3 + 60 MHz）** | npu **16.667 ns** + PLL RATIO0=11.25 | **All Met**（npu 59.9988/60.6024、+0.166；soc +0.760 / cpu +0.249） | 9,188,552 B **`6906faf11786975061a233102cbea866`** |
| `npu60c`（+G2-c 预取） | 同上 | seed0 **−1.960（未收敛）**，其余 seed 在跑 | 待定 |

烧 `npu60b` 时新增一条判据：**`y1run` 的 RUN ms 应 ≈ 1,771.2 × 54/60 ≈ 1,594 ms**（±5%），
12/12 CRC 保留；若 RUN 反而变长 ⇒ 先查 PLL 是否真在 60 MHz（`npu` 时钟可从 `STATUS`/时序反推，或看 LED0 心跳节奏）。

⚠️ `npu60c` 若最终不收敛：**G2-c 未进交付**，交付仍是 `npu60b`；G2-c 的 RTL、闸门与
面积账（LUT +2,017 / FF +2,770 / DRM +0）已留在仓库，等结构改法（读口降宽）后再上。

## 7. 交付（2026-10-25 板级定案：**唯一交付 = `npu60b`**）

| 档 | 内容 | 板级实测 | 比特流 |
|---|---|---|---|
| **`npu60b`（唯一交付）** | 60 MHz，无 G2-c 预取 | **12/12 正确，RUN 1,357–1,360 ms** | 9,188,552 B **`6906faf11786975061a233102cbea866`** |
| ~~`npu56pf2`~~ | ~~56.25 MHz + G2-c~~ | **2/12 正确（算错）**，1,418 ms ⇒ **作废，禁止交付** | 9,188,552 B `3fb1afcd7e25b05ce0b6b59bdcaea382`（墓碑） |

★ **G2-c 预取在真硬件上不成立**（`g2c_prefetch.md §9`）：TCB 上逐字节绿的闸门没覆盖
"预取批与主批共用读口、`rd_ready` 一拍滑动"这一真实行为。**56.25 MHz 的 PLL 本身是好的**
（周期数 79.8M vs 81.6M 证明时钟确实降了），但没有预取就没有收益 ⇒ 不留。
### 7.1 一条命令版（推荐）：`y1/tools/board_ab_60mhz.sh`

```bash
bash y1/tools/board_ab_60mhz.sh --frames 3        # 默认阈值 1673.7 ms
```
自动判四件事并打印 `RESULT: PASS/FAIL`：
① VIDEO STATUS 帧序号 10 s 内递增（视频在跑）；
② `y1run` 每帧 `outputs=12/12` 且末行 `Y1RUN: PASS`；
③ RUN ns 均值 ≤ 阈值（默认 **1673.7 ms = 1,771.2×54/60×1.05**；`--limit-ms` 可改）；
④ `video_health.py` 的 idle vs loaded `vid_stall`（画质归因的数值代理）。
判据脚本本身做过**正负对照**（好样本全绿、`outputs=11/12` 与超阈值样本都变红）。

### 7.2 烧写与回滚（窗口内先做这两条，再谈验收）

```bash
# 烧 npu60b（脚本自己比 md5 并读 UART 完成标记）
python scripts/flash_and_verify.py --tag npu60b
# 烧完后必须看到的指纹
md5sum sim/reglogs/pds_npu60b_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit
#   => 6906faf11786975061a233102cbea866   (9,188,552 B)

# 回滚到 Cam 正常版（用户认可的参考画面；sbit 在本仓 cam 交付目录）
python scripts/flash_and_verify.py --tag cam2lcd_p4nogauss
#   => md5 5df46d6b…
```

规则：**同一窗口里换烧两版各跑一遍**才算真 A/B；跨会话/跨窗口的数字只能当参照
（板子多会话共用，读数会被别的会话污染）。

### 7.3 屏幕一致性：三工况（用户硬约束：最终版画面 == Cam 正常版）

在**同一块板、同一场景、同一光照**下按顺序采：

1. **空闲**：不跑 `y1cam`，`python -u scripts/video_health.py --no-npu` → 记 `vid_stall` 的 idle Δ；
2. **NPU 满载**：`python -u scripts/video_health.py --window 0.2 --settle 5`（它自己起停 `y1cam --loop`）
   → 记 loaded Δ 与帧序号；
3. **CPU 满载**：板内 `for i in 1 2 3; do yes >/dev/null & done`，再采一次（可选，定位 CPU 还是 NPU）。

判读（写在 `scripts/video_health.py` 文件头）：
- idle Δ=0、loaded Δ>0 ⇒ **DDR 争用**是机制；但按 `video_screen_budget.md §2.1` 的预算，
  读数应是几拍~几十拍；若上千拍，说明假设被推翻，回到仲裁器重算。
- 两边 Δ=0 而画面仍花 ⇒ **与 NPU 无关**。按 `video_screen_budget.md §4` 走：先查相机接线
  （必须直插，杜邦线会引入固定列错误+偏色）、`0x3503`、采相位、彩条图案 `0x503D=0x80`。
- 目视仍要人判：本仓没有"相机画面自动判据"，只提供 `vid_stall` 与帧序号这两个**必要条件**代理量。

### 7.4 两个 60/56 MHz 候选的同窗 A/B 规程（预取到底值不值）

`npu56pf`（56.25 MHz + G2-c 预取）与 `npu60b`（60 MHz，无预取）**必须在同一窗口、同一场景**各跑一遍，
否则 DDR 延迟随负载/温度变化，跨窗口的数字不可比。

```bash
# ① 烧 60 MHz 基线
python scripts/flash_and_verify.py --tag npu60b
bash y1/tools/board_ab_60mhz.sh --frames 3 --limit-ms 1673.7     # 预期 ~1326 ms
python -u scripts/video_health.py --window 0.2 --settle 5        # 记录 idle/loaded vid_stall

# ② 烧 56.25 MHz + 预取
python scripts/flash_and_verify.py --tag npu56pf
bash y1/tools/board_ab_60mhz.sh --frames 3 --limit-ms 1500       # 预期 ~1190 ms（板级标定档）～940 ms（200 拍档）
python -u scripts/video_health.py --window 0.2 --settle 5
```

判读：

| 观察 | 结论 |
|---|---|
| `npu56pf` 的 RUN 均值 **<** `npu60b` × 0.94 | 预取收益兑现（>6.7% 盈亏平衡）⇒ `npu56pf` 成为交付 |
| 判据式 | `56.25/60 ÷ 预取收益` = `1.0667/gain`；gain 1.19（板级标定）⇒ 1,188 ms；gain 1.51（200 拍）⇒ 936 ms |
| 两者相当（±6%） | 预取的板级收益在噪声内 ⇒ 保留 `npu60b`（时钟更高、RTL 更简单） |
| `npu56pf` 明显更慢 | 预取在板上没藏住（对照 §8 的装置数字），回退 `npu60b` 并复查 `GATHER_BYTES` |
| 任一版 `outputs≠12/12` | **正确性红**，立即停；先查描述符/权重而不是速度 |

⚠️ 两版都要先看 ① 帧序号递增（视频在跑）与 ④ `vid_stall`（屏幕归因），再比速度；
一次窗口只换一次比特流，中间不要让别的会话动板子。

> **2026-10-25 追加（本轮两次尝试都已回退，交付仍是 `npu60b`）**
> - 60 → 66.67 MHz（tag `npu66`，**RTL 不变**、只改 PLL/fdc）：devmap 0 error，PnR seed0
>   `Setup(Slow) = −2.490 ns`（物理 ≈17.49 ns）——比 16.667 ns 约束下的 16.501 ns **还慢**
>   ⇒ 约束收紧反被 PDS 做差（第三次实例）。**时钟线关闭**，PLL/fdc 已回退 11.25/16.667。
> - 旁路 tile 取数改 SG 批式（B1'）：仿真 CYCLES −22.6%~−29.7%，但 `resize_40x40`
>   （`inCols%32≠0`）稳定挂死 ⇒ **整段回退**（网表重生成 = `1a77a150`，与改前逐字节相同）。
> - 现场与数字：`npu_clk_raise.md §10`、`bypass_sg_spec.md §7–§8`。

## 8. 新交付候选：`b1sg`（2026-10-25，旁路 SG 批式）

| 项 | 读数 |
|---|---|
| 比特流 | 9,188,552 B **`c408792f33be7b25bf451df4dd676634`**（PnR All Constraints Met，npu 60.3938 MHz / +0.109） |
| `y1run --frames 3` | **1,262.43 / 1,262.29 / 1,262.47 ms**（均值 1,262.39）⇒ **0.792 fps** |
| 对 `npu60b` | **−7.32%**（1,362.1 → 1,262.4 ms），12/12 CRC ×3 |
| 视频 | 跑前 10 s 帧序号 Δ=2705；跑后仍递增 |
| 来源 | `y1/rtl/BypassExec.scala` 的 B1'b（`inCols%32==0` 时 SG 批式），闸门 `run_bypass_tile_ab` PASS |

⇒ 交付从 `npu60b`（60 MHz，`6906faf1`）升级为 **`b1sg`**（`c408792f`）；`npu66`（66.67 MHz）不收敛，已作废。

## 9. 收尾板端验收（2026-10-25 实测，8/8 PASS）

一条命令：`python -u scripts/board_verify_wrapup.py`

| 项 | 判据 | 实测 |
|---|---|---|
| T1 | `y1ctl ping` 通 | `PONG / Linux 5.10.1 riscv32` |
| T2 | `/proc/uptime` > 5 s | 48 s / 171 s / 257 s 三次 |
| T3a | GPIO `0xF0002004` bit1 = y1cam 在跑 | 1 |
| T3b | bit3 = 网口 up | 1（**修了 `S99leds.sh`：按 `carrier` 判，不用 `operstate`**） |
| T3c | bit0 心跳翻转 | `0xB 0xB 0xA 0xA 0xB 0xB`（1 Hz，按 `/proc/uptime` 取整秒） |
| T4 | `/run/y1cam.pid` 活 + `dmesg` 有 `Y1CAM-BOOT` | pid=96 ALIVE |
| T5 | `/root/y1/{y1cam,y1run}` | `e4806746…` / `fc4ec0b6…`（与 v2 卡一致） |
| T6 | `VIDEO.STATUS(0xF0007400)` | `init_done=1`，seq 4959→5076（5 s ⇒ **23 fps**） |

**两条板测发现（都已修）**：
1. `S99leds.sh` 原来判 `.../eth0/operstate = "up"`，但本驱动下 `operstate` **恒为 `unknown`**（`carrier=1`）
   ⇒ **led6 永不亮**。改成按 `carrier` 判。
2. 心跳原来用**循环计数**，而循环里 4 次 `devmem` 往返使周期 ~2–3 s ⇒ 不是 1 Hz。
   改成 `hb=$(cut -d. -f1 /proc/uptime)`。
   （验收脚本也相应改成"一次 ssh 连采 6 个样本"，否则两次 ssh 的间隔会与循环周期同相混叠。）

**固化进卡**：`sw/images/sd_y1_v3.img`（10,706,432 B / md5 `91eb247a50a60c8e31fd2d7d86817661`）——
只替换 rootfs 段里的 `S99leds.sh`，其余四段与 v2 **逐字节相同**。写卡命令同 §5。

## 10. 无 TF 卡 / 坏卡时的串口状态（2026-10-25 改，`sdb115`）

**病根（实测）**：SD 报文器说 **115200**（`SdUartReport`, baudDiv 868 @100 MHz）；SD 失败后线路
交给**串口装载器**，而它当时是 **28.9k**（`src/YeshenSocGlue.scala:455` 的 `UartLoader(baudDiv = 216)`，
当年的"速率实验 54→216"）⇒ 在 115200 上读**解不出可读字符**（实测：4 字节固定循环 `78 80 00 F8`，
周期 347 µs = 一个字节 @28.8k 的 10 位时间），判不了状态，只能重烧去试。

⚠️ **仓库里有两份胶合源码**：`src/NaxMiniGlue.scala`（NaxMini 线）与 `src/YeshenSocGlue.scala`
（**本板**生成 `rtl/YeshenSocGlue.v`，入口 `YeshenSocGlueMain`）。第一次改错文件 ⇒ 网表里
仍是 `12'hD7F`（3455 = 16×216）；改对后应看到 **`10'h35F`（863 = 16×54）**。判据就看这两个常量。

**修法**：`baudDiv 216 → 54`（16×54 拍 @100 MHz = **115.7 kbaud**）⇒ 三处同档
（SD 报文器 / 串口装载器 / 内核 `console=115200`）。

**现在怎么读状态（按 115200 抓串口即可）**：

| 串口上看到 | 含义 |
|---|---|
| `SDR 20xxxxxx…`（每 100 ms 一行，24 字节） | SD 装载器在跑；头部 hex 的**前两位 = {state(4), errCode(4)}** |
| 随后持续 `YSLD`（每行 5 字节，反复） | SD **失败/无卡**，线路已交给串口装载器（在等灌数据）⇒ **先查卡** |
| `Platform Console Device : uart8250` 起的内核日志 | 卡没问题，正常启动 |

判据（无卡，人眼/脚本都行）：上电后 5 s 内若只有 `YSLD` 反复 ⇒ 卡缺失/坏/没插实；
若出现 `SDR` 行但它一直不往下走 ⇒ 看那两位 hex（`state=4` = 失败，`err` 见 `SdSpi` 文件头）。

⚠️ 这条**不改变**"换卡/断电要重烧比特流"的事实（比特流是 JTAG 配置进 SRAM 的）；
但**不需要为了"看看是什么状态"而重烧**了。若将来要免掉重烧，需要把比特流写进板上的配置 flash
（`cdt_bts` 生成 .sfc 需要 `fabric_bts` 授权，本机 license 没有 ⇒ 目前不可用）。

### 10.1 卡镜像 v4（带 CRC32）与新的错误码（2026-10-25）

块 0 多了两级 CRC32（`off 128+4i` = 第 i 段；`off 160` = 表头前 160 字节），装载器**流式**校验、
不额外读卡。错误码：

| `SDR` 头两位的 err | 含义 | 处置 |
|---:|---|---|
| 1 | SD 通路错（`SdSpi` 编码 1..6，看 `dbg` 里的 `pd/st`） | 无卡/没插实/排线 |
| 2 | 魔数不对 | 卡里不是装载表（或写到了别的偏移） |
| 7 | **表头 CRC 不对** | 表项坏了，或**这张卡是旧格式**（v3 及以前没有 CRC 字段） |
| 8 | **段 CRC 不对** | 卡→FPGA 传输误码：先降 `divFast` 再复测（见 `y1/reports/sd_loader_crc_and_clock.md`） |

**兼容性**：v4 卡只能配新比特流（`TAG=sdcrc1` 及以后），旧卡在新比特流上会以 `err=7` 停住 —— 刷比特流与写卡必须**成对**。

**2026-10-26 更新（固化）**：位流已写进板上配置 flash（XT25BF128），配置时钟 **2.99→11.76 MHz**，
**断电后自动加载、不需要 JTAG**；冷启动到登录约 **17–18 s**。sbit `2c5835efb0b59478485ec11bc621c28d`；
回退用 `cam2lcd_200mini/flash_spi.bat sim/reglogs/sbit_cmd18_plain.sbit`（2.99 MHz）。

**2026-10-26 更新**：交付档改为 **`cmd18`**（12.5 MHz 数据相 + 每段一条 CMD18；`All Constraints Met`，
npu +0.094，sbit `2865829466f4361ffa9c19f9a836823c`）。卡镜像**不变**（仍 `sd_y1_v4.img`，无 CRC 变化）。
板上：启动 8/8、`state=2→3 err=0`、装载 **7.0 s**（旧 5 MHz 逐块 CMD17 是 29.5 s）。
交付卡：`sw/images/sd_y1_v4.img`（10,706,432 B，md5 见报告），段内容与 v3 **逐字节相同**，只多了 CRC 字段。
