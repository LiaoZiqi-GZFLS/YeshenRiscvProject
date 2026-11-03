# Y1 两道闸门 —— 合并结论

- 日期：2026-10-08
- spec：`docs/superpowers/specs/2026-10-08-yunet-accelerator-small-design.md`
- 计划：`docs/superpowers/plans/2026-10-08-y1-gates.md`
- 工程目录：`y1/`

---

## 一句话结论

**G1（面积）= PASS。R1（DDR 带宽）= 静态上界通过，但"可达"实测尚未做（需上板）。两闸门的组合裁决 = 有条件可行。**

⇒ **可以着手写 Y1 核心的完整计划**；但 **R1 的板端实测（A2）必须在架构定稿前完成** —— 它是全系统的绑定约束，而 `DDR3Bridge` 的结构性上限可能把它压到需求线以下。

---

## 1. G1 面积闸门 —— **PASS**

**被测对象**：`y1/gen/Conv3x3Slice.v`，md5 **`e54fc5232644745ad113c1d80e879f16`**，51,879 行，`WIDTH=640`、`GROUP=1`（权重存储 576 项，是三种 GROUP 里最大的 ⇒ 最坏情况）。

**证据来源**：`y1/pds/devmap_slice.log` 的 `Device Utilization Summary`（第 597 行起）。PDS exit 0，**0 个 `DRC-0018`/`DeviceMap-2003`/`Program Error`**，完成标记 `Y1_SLICE_DEVMAP_DONE`，耗时 3m50s。

```
| APM                   | 40        | 740           | 6
| FF                    | 87409     | 319600        | 28
| LUT                   | 26447     | 159800        | 17
| Distributed RAM       | 0         | 39500         | 0
| DRM                   | 0         | 415           | 0
| IO                    | 156       | 400           | 39
```

| 资源 | 切片 | G1 阈值 | 判定 | SoC 基线 | SoC+切片 | 器件 | ≤ 器件？ |
|---|---|---|---|---|---|---|---|
| LUT | 26,447 | ≤ 30,000 | **PASS**（余量 3,553） | 14,130.5 | 40,577.5 | 159,800 | **YES** |
| APM | 40 | ≤ 100 | **PASS** | 4 | 44 | 740 | **YES** |
| DRM | 0 | ≤ 60 | **PASS** | 23.5 | 23.5 | 415 | **YES** |
| FF | 87,409 | —（不在 G1 内） | — | 17,124 | 104,533 | 319,600 | **YES**（33%） |

**`G1 PASS`。**

### 与 M0 的对照（同一器件、同一个"面积装不下"的问题）

| | 被否的第三方加速器（M0） | 本切片（Y1） |
|---|---|---|
| LUT | **232,746 / 159,800 = 145.65%** ❌ | **26,447 / 159,800 = 17%** ✔ |
| APM | **740/740 = 100%**（饱和） | **40 / 740 = 6%** |
| DRM | **415/415 = 100%**（饱和 + 71 处溢出） | **0 / 415 = 0%** |
| 乘法器 | 1152 个 | **64 个**（一拍 64 MAC） |

⇒ **面积差约 8.6×**。根因就是 M0 找到的那一条：第三方设计为 ~7 GMAC 的网配了 1152 个乘法器；本设计只需要 YuNet 的 344 M-MAC/帧。

### 两个值得记下的事实

1. **DRM = 0 是真的**：640 宽 × 8 通道 × 2 行的 int8 行缓冲**落到了寄存器**（FF 87,409），没有被推断成 BRAM。所以本设计的 BRAM 压力确实为零 —— M0 里那种 DRM 饱和不会重演。
2. **FF 是这里的头号成本（87,409，28%）**：行缓冲用触发器实现。G1 不含 FF 且 SoC+切片仍只占 33%，所以过闸；但若要进一步省面积，**行缓冲改 BRAM（或降宽度/降通道）是第一个该看的地方**。注意这会与"想省 DRM"矛盾，需要用实测取舍。

## 2. R1 DDR 带宽闸门 —— **静态通过，实测未做**

**静态上界（A1，已完成，`y1/reports/ddr_bandwidth.md`）**：本仓源码实证两条口径

| 口径 | 位宽 | 时钟 | raw 上界 | vs 需求 @15fps 458 / @10fps 305 MB/s |
|---|---|---|---|---|
| DDR3 IP 用户口（我们 fabric 看到的） | 256 bit = 32 B/beat | `core_clk` 125 MHz | **4000 MB/s** | 都 OK |
| SoC 访存总线侧（经 `DDR3Bridge` 从口） | 64 bit = 8 B/beat | `cpu_clk` 100 MHz | **800 MB/s** | 都 OK |

⇒ **raw 上界不构成算术否决**（`RESULT: 继续实测`）。证据见 `board/yeshen_mini_board_top.v:378/405`、`third_party/ddr3_ip_200h/ddr3_test/ddr3_test.v:20/45/295`、`constraints/yeshen_mini.fdc:121`、`src/soc/DDR3Bridge.scala:113/130`。

**但 raw 不是可达**，而且这里有一条**结构性上限**（A1 从 `DDR3Bridge` 头注释里读到的，不是推测）：

- **单 outstanding**；
- **一笔 DDR 事务只发 1 个 256-bit beat**（`ddrAwLen/ddrArLen ≡ 0`）—— 因为 DDR3 IP 的 W 通道**没有 wvalid**（wready 高即采样），两个 beat 之间必须过一次跨域握手，做不到背靠背；
- **每拍过一次 4 相 CDC 握手**。

⇒ 可达带宽 ≈ 32 B ÷ (一次 CDC 往返的周期数) @125 MHz。**往返 8 拍 → ~500 MB/s；16 拍 → ~250 MB/s** —— 正好压在 305/458 MB/s 这条线上。

**所以 R1 的结论是"待实测"，不是"通过"。** A2（板端用户态实测，含缓存负对照）与条件式的 A3（AXI 主口微基准）**尚未执行**，因为它们要动物理板，按约定等用户的授权。

## 3. 组合裁决

| 闸门 | 状态 | 依据 |
|---|---|---|
| **G1 面积** | **PASS** | LUT 17% / APM 6% / DRM 0%；SoC+切片四项全 YES |
| **R1 带宽** | **静态通过，可达待实测** | raw 4000/800 MB/s；但 bridge 单笔+每拍 CDC 握手，可达落在需求线附近 |

**裁决：有条件可行。**
- **可以**写 Y1 核心的完整计划（指令编码、控制 FSM、行缓冲管理、寄存器表、AXI 主口）—— 面积已证明有充足余量（LUT 只用 17%，够放控制与 DDR 接口）。
- **但 A2 的 DDR 实测必须在架构定稿前做完**：若可达 < 305 MB/s，"逐层特征落 DDR"这条范式要改成层融合/行缓冲复用，那会推翻指令/控制层的设计。

## 4. 可复现性

| 结论 | 命令 | 指纹 / 日志 |
|---|---|---|
| G1 面积 | `/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_slice.tcl`（cwd 必须是仓根） | `y1/pds/devmap_slice.log`；被测网表 md5 `e54fc5232644745ad113c1d80e879f16` |
| 数值正确性 | `bash tools/run_numeric_ab.sh dense 8 8 16 16 21`（g4/dw 用 `RTL=…_g4.v` / `…_g8.v`） | 三档 `MISMATCH=0` |
| 结构 | `python tools/check_dangling.py gen/*.v`、`bash tools/check_no_xilinx.sh gen` | 全 PASS |
| R1 静态 | `python y1/partA/ddr_ceiling.py 32 125e6` 与 `8 100e6` | `y1/reports/ddr_bandwidth.md` |
| 确定性 | 每个生成器连跑两次 `md5sum gen/*.v` | 全一致（`headerWithDate=false` + `headerWithRepoHash=false`） |

## 5. 未验证 / 已知缺口（如实列）

1. **无时序**：`dev_map` 是综合 + 器件映射，**不含布局布线与时序**。切片能否在 100 MHz 收敛未知。
2. **功能仿真只到"层"级**：三档数值对账都发生在**单层 3×3 卷积**这一级，**没有**端到端（12 个头张量）、没有多通道/多层调度、没有与 ONNX Runtime 的对齐。spec 的 G4 未做。
3. **R1 的可达带宽未测**（A2/A3 待授权）。
4. **FF 偏重**：行缓冲落寄存器（87,409 FF）。若要压缩，这里是第一处。
5. **测试钩子**：切片带一个只读常量输出 `grp`（`GROUP` 的值），用途是让同一个 TB 能识别自己拿到的是哪个 GROUP 变体。它不承载数据通路逻辑，但是一处"为测试而加"的端口。
6. **`waddr` 宽度告警**：iverilog 在 g4/g8 变体上会报 `waddr expects 8/7 bits, given 10`；高位被裁剪且装载地址从不超出范围，所以无害 —— 但它是"TB 与变体宽度不一致"的痕迹。
7. **M0 遗留教训在这里继续适用**：**PDS 忽略 `ram_style`**（M0 实测 `Sdm-2008 … ignore` ×164）⇒ 不能用它去指挥存储器映射；本设计的权重与行缓冲索性都用寄存器，绕开了这个坑。
8. **未做 PnR、未上板、未烧写**。

---

## 6) 补记：数值网表 WIDTH=16 vs 面积网表 WIDTH=640（**后补约定，不改任何结论/数字**）

第 1 节的面积数字取自 **WIDTH=640** 的网表（md5 `e54fc5232644745ad113c1d80e879f16`）；第 4 节"数值正确性"
那条命令（`bash tools/run_numeric_ab.sh dense 8 8 16 16 21`）吃的网表是 **WIDTH=16**。这是**两份分别生成**的网表：

- **面积（G1）**：`cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 640\nexit\n' | bash sbt.sh` —— 面积指纹钉在 **WIDTH=640**（第 1 节 md5 即此产物）。
- **数值判据**：`cd y1 && printf 'Test/runMain SliceGen D:/code/PDS/VexiiYeshenLinux/y1/gen 16\nexit\n' | bash sbt.sh` —— 数值门吃 **WIDTH=16** 的网表。

⇒ 跑数值判据前**必须**先用 **WIDTH=16** 重生成；面积那次的 **WIDTH=640** 网表**不能**拿来跑数值判据
（否则 LineBuffer 按 640 数行、装置喂 16 列，窗口语义错位 ⇒ 以前会以"大范围 MISMATCH"静默暴露）。
**已加响亮保护（不会静默复发）**：切片新增只读常量输出 `imgW`（= 生成时的 `WIDTH`），TB 在 **time 0**
对 `+IW` 与 `imgW` 对账，不符立即 `$fatal`（与既有 `grp`/`+GROUP` 同一招）。面积数字**未改**
（证据 = 已提交的 `y1/pds/devmap_slice.log`，WIDTH=640）。
