# P0：**NPU v2 逐层 MAC 账 + 双侧天花板**（离线；spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5-P0）

- 日期：2026-10-16
- 上游：spec §2/§4（实测锚点）、`reports/c4b_frame_runnable.md`（面积/回归账）、`reports/ts3h_wide_chain_engine.md`（宽链 LUT 墙 + 1e8 拍/run 的诚实记账）
- 交付物：`tools/mac_account.py`（逐层账 + 天花板 + 五档场景）、`tools/run_mac_account_ab.sh`（闸门，exit 0/1/2/3）、`reports/npu_v2_mac_table.txt`（生成的逐层全表）
- 本片**只读**：`gen/desc.bin`、`gen/wgt_index.json`、冻结工具（`ddr_traffic.py`/`bypass_traffic.py` 只调用不改）、RTL/报告（只读常量）。**无 RTL 改动、无 `gen/` 输出改动。**

**Status: DONE（P0 的两件事都钉死：逐层 MAC 账首次落表；算力侧天花板与带宽侧并列后，判词 = 算力侧是紧的一侧）**

---

## 0. 一句话

**344,224,000 MAC/帧**（精确值；此前只是示意数，现在有 67 单元逐层表背书）。
在板级真钟 **`npu_clk = 50 MHz`**、阵列 **64 MAC/拍** 下：

| 天花板 | 值 | 出处 |
|:--|--:|:--|
| **算力理想**（`beats = MACs/64`，spec §5-P0 指定式） | **9.30 fps** | 本片逐层账 |
| **算力 as-built（eff 多趟路径，9 拍/像素/趟）** | **1.11 fps** | `Conv3x3Slice` 恒 9 拍 × `UnitExec` 趟编排 |
| **算力 as-built + tile halo 重喂** | **0.71 fps** | 同上 + 真表 tile 网格 |
| 带宽（冻结 fuse_both 12.58 MB/帧） | 21.9 fps | `ddr_traffic.py`（已有） |
| 带宽（+冻结旁路 19.52 MB/帧） | 14.1 fps | `bypass_traffic.py`（已有） |
| 带宽（v1 as-is：+实测放大 42.30 MB/帧） | **6.52 fps** | 本片场景 (a) |
| 带宽（(b)-(e) 修完 22.6–23.9 MB/帧） | **11.6–12.2 fps** | 本片场景 (b)-(e) |

**⇒ 算力侧约束更紧，且紧得不是一个量级**：as-built 路径下算力只有 ~1.1 fps，即使只按**理想式**
（9.30 fps）也比修完后的带宽侧（12.2 fps）低。**旧的示意 bar（344 M-MAC ÷ 64 @100 MHz = 18.6 fps）
把钟算错了 2×**（板级是 50 MHz）——就算阵列利用率 100%，真值也只有 9.3 fps。
spec §7-R3 的条件成立：**目标帧率必须从本表的算力侧来定**。

---

## 1. 复现（两条命令）

```bash
# 逐层全表 + 天花板 + 五档场景（生成 reports/npu_v2_mac_table.txt 的同一真源）
PYTHONIOENCODING=utf-8 <py3.9> tools/mac_account.py --emit-table reports/npu_v2_mac_table.txt

# 闸门（正对照=冻结模型两锚点复现；负对照=几何扰动按**预测量**发火）
bash tools/run_mac_account_ab.sh        # exit 0 = 全过
```

输入口径（都只读）：`desc.bin` 解 67 条载荷 + 哨兵；逐单元**真几何**取 `wgt_index.json` 的
`own`（desc 表对链中/尾片的 `IMG_W/H/C_IN/C_OUT/GROUP` 是**链首覆盖值**——`--selftest` 对每个
plain/head 项断言两者相等、对 middle/tail 项断言覆盖关系成立）。

---

## 2. 逐层 MAC 表（全表见 `reports/npu_v2_mac_table.txt`，这里只摘骨架）

口径：`MACs = H · W · C_out · (C_in/GROUP) · taps`；`taps` 由 TYPE 派生（conv3x3→9、
depthwise→9、conv1x1→1——RTL 不按核大小省拍，见 §4）。**非 MAC 算子（maxpool/resize/add/sigmoid）
不并入 MAC**，元素数单列（表末 `NONMAC_ELEMS_TOTAL=1,988,000`）。

| 段 | 代表单元 | 每单元 MACs | 段小计 |
|:--|:--|--:|--:|
| 首层（s=2） | `Conv_0` 3→16 @320×320 | 44,236,800 | — |
| 160×160 主干 | `Conv_9` 1×1 16→32；`Conv_15` 1×1 32→64 | 13.1M / 52.4M | — |
| 80×80 / 40×40 / 20×20 块 | `Conv_19/26/33`（1×1 64→64） | 26.2M / 6.55M / 1.64M | — |
| 检测头段（idx 35–60，26 个 conv/dw） | `Conv_51..Conv_77`（1×1 + dw/3×3，C_out∈{1,4,10}） | 1.6M–26.2M | — |
| **合计（53 个 conv/dw）** | | | **344,224,000 MAC = 344.2 M-MAC/帧** |

（`MAC_TOTAL=344224000` 与旧 spec §"单帧算力 344,224,000 MAC"逐字节一致 —— 首次有逐层表背书；
闸门把这条做成硬判据。`--perturb` 负对照：`Conv_29` 的 `C_OUT += 8` ⇒ 总量恰 +819,200。）\
场景 (a) 的角色分工（哪一层的放大最贵）：`Conv_0` +1.48 MB、`Conv_2` +2.08 MB、`Conv_19/51` 各
+4.95 MB、`Conv_26/45` 各 +2.28 MB、`Conv_72` +0.93 MB（C=10 头）… 21 个 DDR 读单元合计 +21.55 MB。

---

## 3. 两个天花板并列 + **哪一侧紧**

算力（本片新增）：

| 量 | 值 | 读自 |
|:--|--:|:--|
| `TOTAL_MACS` | 344,224,000 | 本片逐层表 |
| `MAC_PER_BEAT = 64` | 8 co × 8 ci | **RTL**：`MacArray.scala`（真瓦片；`run_macarray_ab.sh` 判据把住） |
| `NPU_CLK = 50 MHz` | 20 ns | **报告**：`npu_clock.md`（PnR 实测 54.14 MHz；按 50 记账） |
| `SLICE_TAP_BEATS = 9` | 每像素/趟恒 9 拍 | **RTL**：`Conv3x3Slice.scala` `ph=1..9`（1×1 的其余 8 抽头权重为 0，**拍不省**） |
| `nPasses` | `nCi·nCo`（dense）/ `nCo`（dw 对角） | **RTL**：`UnitExec.scala` 宽路趟编排（真表无窄形状 ⇒ 全走宽路；`CHECK no_narrow_shape_units_all_wide`） |
| `beats_ideal = MACs/64` | 5,378,500 拍 = **0.1076 s ⇒ 9.30 fps** | spec 指定式 |
| `beats_issued = 9·nPasses·H·W` | 45,075,600 拍 = **0.9015 s ⇒ 1.11 fps** | eff/多趟路径 |
| `+ tile halo 重喂` | 70,848,972 拍 = **1.417 s ⇒ 0.71 fps** | 真表 tile 网格（32×32，`WT=34-2`/`HT=32`） |

`beats_issued` 的**每类多花**（`CHECK` 逐类断言，非估计）：

| 单元类 | 每 MAC 的拍数 vs 理想 | 为什么 |
|:--|:--|:--|
| dense 3×3，C_in/C_out 双满 8 块 | **1.0×**（issued == ideal） | 9 抽头 × 双满块，64 槽全有用 |
| 1×1（taps=1），双满块 | **9.0×** | 切片恒跑 9 抽头相位，8 个零权重抽头照样吃拍 |
| depthwise，C 满 8 块 | **8.0×** | 对角掩码：64 槽里只 8 个有用（`GroupedMacArray` 常数折叠） |
| C_in=3（`Conv_0`，nCi=1） | 8/3 × … | 通道补到 8（B1c 零填） |
| C_out=1/4/10（检测头） | 8/1、8/4、8/10 × | co-block 尾块补到 8 |

注记（不进 beats 口径）：单切片每像素**墙钟** = 1 收列 + 9 tap + 1 出数 = **11 拍** ⇒
单阵列墙钟上界 1.10 s/帧（issued 口径）。此模型与 `ts3h` §4-W4 的独立诚实记账
`run[4..11] ≈ 1×10^8 拍/run ≈ 1 s` **同量级**（本例 8 片链 × 5×5 tile × 多趟 ≈ 1e8 拍 —— 逐项对得上）。

**判词：算力侧紧。** 三个读法都指向同一侧：
1. **对 21.9 fps（带宽侧已知天花板）**：算力理想 9.3 fps 就已经低于它 —— 带宽侧的天花板**从来没
   被算力侧允许过**（旧示意用 100 MHz 算成 18.6 fps，恰好掩盖了这一点）；
2. **对 (e) 档 12.2 fps（带宽侧修完后）**：算力理想 9.3 fps 仍低；
3. **对 as-built（1.11 fps）**：比 v1-as-is 的带宽侧 6.52 fps 还低 **5.9×** ⇒ 就算流量一根字节不省，
   现在也是算力在拖。
⇒ **fps 目标必须按算力侧定**：① 不改切片调度（每像素 9 拍）的话，目标只能 ~1 fps 档；
② 要过 10 fps，**必须先解决"1×1 恒 9 拍"与"dw 对角只有 1/8 有用"这两条**（阵列调度/微序列问题，
不在本 P0 范围内，但 P0 把账摊开了）——这是 spec §7-R3 说的"目标可能要下调"的**定量版**。

---

## 4. 冻结模型的交叉复现（判据，闸门绿）

| 检查 | 结果 |
|:--|:--|
| `ddr_traffic.py … baseline` **现跑** | `TOTAL_BYTES=31,942,400` ⇒ **31.94 MB/帧** ✅ |
| `ddr_traffic.py … fuse_both` **现跑** | `TOTAL_BYTES=12,576,000` ⇒ **12.58 MB/帧** ✅ |
| 本工具译码**独立复算**（逐单元 `in_exact + out_exact` / head-in + tail-out） | 31,942,400 / 12,576,000 **逐字节相等** ✅ |
| desc 表口径（用表里的 `IN_BYTES`） | 31,942,432 = 冻结 + **32 B**（已知差异，见下） |
| `bypass_traffic.py`（冻结，旁路算子） | 6,945,600 B/帧（base 12.576 + 旁路 6.9456 = 19.52 MB/帧） ✅ |

**+32 B 的来历（不是误差）**：desc 表对 `C_in=1` 的**布局折**平面把有效像素向上取到 32 B 对齐
（`IN_BYTES=416=align32(400)`）：`Conv_59`/`Conv_71` 各 +16 B（闸门 `CHECK` 逐单元点名）。
ONNX 侧张量是 400 B ⇒ 冻结模型（明文"刻意不计对齐/填充浪费"）比表口径小 32 B。
闸门把"表口径 == 冻结 + 32"做成**等式判据**，不是容差。

---

## 5. 五档逐帧流量场景（带宽侧）

基（冻结）：`fuse_both 12.576 MB + bypass 6.9456 MB = 19.5216 MB/帧`（conv 侧 + 旁路算子侧；
**冻结模型不计**：权重装载、12 头张量后处理、突发对齐浪费 —— 见 §6 开口项）。
`fps_bandwidth = 275.9 MB/s ÷ MB`（与冻结模型同口径；275.9 的出处见 §6）。

| 档 | 杀了什么 | MB/帧 | ms | **fps** | 32 B 请求数 |
|:--|:--|--:|--:|--:|--:|
| (a) v1 as-is | —（宽路 tile 实测放大 + Add 两趟 4.4×） | **42.2986** | 153.3 | **6.52** | 1,321,832 |
| (b) +窗口片上留住 | `nCo` 重读（宽路每趟重读整窗） | **23.8917** | 86.6 | **11.55** | 746,615 |
| (c) +平面 32 B 补齐 | band/对齐余量（`BAND_F` 实测 1.00646） | **23.8308** | 86.4 | **11.58** | 744,711 |
| (d) +通道分块布局 NC8HW | 请求形状（**字节不变**，请求 ÷4） | **23.8308** | 86.4 | **11.58\*** | 186,178 |
| (e) +Add 单趟化 | Add 4.4×→2.0× | **22.6020** | 81.9 | **12.21** | 706,311 |

逐档细节：

- **(a)** 的读放大模型（**逐层**，不是整网乘一个 23.3）：`reads = nCo_eff · nTiles · (s·W_tile+2)(s·H_tile+2) · C_in · BAND_F`，
  其中 `nCo_eff = nCo`(dense) / 1(dw)；非 tiled 层（20×20，输入宽 ≤ `W_MAX=34`）= `nCo_eff · H·W·C_in`（整平面每趟一读）。
  模型在**两个实测作业**上标定：`c64_40x40` 模型 2,367,488 B vs 实测 2,382,784 B（+0.65%，即 `BAND_F`）；
  `dw64_40x40` 模型 295,936 B vs 实测 296,896 B（+0.32%）。闸门 `CHECK read_amp_model_calibrated_on_measured` 断言
  `模型 ≤ 实测 ≤ 模型×1.01`。逐层分解：`Conv_19`（80×80，C=64）放大 **13.1×**、`Conv_26`（40×40）**23.3×**（= 实测锚点本身）、
  `Conv_0`（s=2）2.2×、20×20 层恰 **8.0×**（= `nCo`，无 tile 只有 co 重读）。
  帧级：DDR 读单元合计 +21,548,198 B（6.48 MB 理想读 → 28.03 MB 实读）；Add +1,228,800 B（Add_44 实测 450,560 B 为 4.4×，
  Add_50 按张量缩放 = modeled）。
- **(b)** 杀 `nCo` 重读后仍有 **+3.14 MB** 的 halo/tile 窗重叠（`nTiles·win/HW`：40×40 层 **2.91×**、
  80×80 层 **1.64×**、320×320 层 **1.14×**（`Conv_0` 的 s=2 窗 `34×66` 摊在 640×640 上 = 1.10×）——
  小张量层的 halo 占比高）⇒ 窗口留住是**放大器**的主项，但窗重叠是它的残余。
- **(c)** 只值 **−60,919 B（0.26%）**：实测 band 余量在 40×40 上就是 0.65%、dw 上 0.32%（§5 标定数）——
  **本片诚实结论：补齐 32 B 的"帧率"收益 ≤1%，它的真实收益在"删掉 per-plane band 的资源面"**
  （spec §4-2 的"帧率 + 资源"里，资源是主项）。**不夸大。**
- **(d)** 字节与 (c) 相同（换布局不省字节），**省的是请求数**（`一列 8 笔遥不相邻 32 B → 1 笔覆盖 4 列`）；
  `186,178 = 744,711 ÷ 4`。**\* 标注**：(d) 的 fps 栏与 (c) 同值，是**因为** `fps_bandwidth` 公式只认字节；
  请求数改善对 **275.9 MB/s 本身**的影响**测不了**（该常数是静态桥路模型，不是"当前请求形状下"的持续带宽实测）
  ⇒ 列为**开口测量**（P2 的"请求数实测下降"判据落地后回填）。
- **(e)** Add 从实测 4.4×（两源 2× + 窗 2.2×）降到 2.0×（两源各一次，单趟重叠）——**modeled optimistic**，
  见 §6 开口项。

信息性（**未计入任何一档**）：宽路趟瓦片装载 `Σ nPasses×576 = 500,544 B/帧`（冻结模型不计权重）；
若整 blob 每帧经 DMA 主路径重装，另 +404,064 B（`wgt_blob.bin` 实测长度）——两条都计入的话 (e) 档 ≈ 23.5 MB/帧。

---

## 6. 数字分类（**measured / modeled / assumed**，逐条）

**Measured**（实测：TB 装置/板级/冻结工具在真输入上现跑）
- `31.94 MB/帧` 与 `12.58 MB/帧`：冻结 `ddr_traffic.py` 在真 `yunet.onnx` 上的现跑输出（闸门**每次现跑复现**）。
- `6.9456 MB/帧` 旁路算子：冻结 `bypass_traffic.py` 现跑（含其自带 SELFTEST_* 全绿）。
- `23.3×`（`c64_40x40`：102,400 → 2,382,784 B / 74,462 AR 突发）与 `2.9×`（`dw64_40x40`：296,896 B）：
  T-S2b 装置自报 AR 计数（`c4b_tiling_s2.md` §11.5）。
- Add 两趟 `450,560 B / 19,200 突发`（对 102,400 B 张量 = 4.4×）：`ts3e_gate_green.txt` 内存模型自报。
- 阵列 8×8=64 MAC/拍；`npu_clk=50.000 MHz`（PnR `All Constraints Met`，实测可到 54.14 MHz）。
- 表/几何本身：`desc.bin`（md5 与 `wgt_index.json` 内记录互证）与 `wgt_index.json` 的 67 单元。

**Modeled**（模型：从 RTL 结构/实测锚点按公式外推，公式与标定都写在工具里）
- 每层读放大（§5-a 公式 + 两个实测作业标定；**tail tile 读满窗**的行为只在 40×40 上实测过，其余形状是外推）。
- `Add_50` 的 1,802,240 B（按张量比例缩放 Add_44 的实测因子）。
- (b)/(c)/(e) 的省量（分别 = 去 `nCo` 因子、去 `BAND_F`、去 Add 二趟）。
- 算力 `beats_issued` / `beats_issued_tiled`（逐条读 RTL 的结构式；墙钟 11 拍/像素为注记）。
- 权重趟装载 500,544 B/帧。
- 32 B 粒度突发计数（`bytes/32`）。

**Assumed**（假设/口径，未实测）
- **`275.9 MB/s`**：`partA/ddr_path_ceiling.md` 的**静态桥路模型**（32 B / 116 ns，`bridge 6 100e6 7 125e6`），
  冻结模型把它当"可持续带宽"。**它不是"当前请求形状下的持续带宽实测"** —— 所以 (d) 的请求数收益无法换算成 fps。
- `fps_bandwidth = 275.9 ÷ bytes`：只认字节、不认请求形状（任务指定的口径）。
- (d) 的"请求数 ÷4"：spec §4-3 的设计声明（未实现、未测）。
- (e) 的"单趟 = 2.0×"：设计意图的最小读口径（Add 单趟化的窗口行为未实现、未测）。
- 旁路算子（maxpool/resize/sigmoid）自身在 tile 路径上的放大**完全没建模**（Add 是唯一有实测放大的旁路算子）。
- 每帧权重 blob 重装（+404,064 B）未计入（冻结模型统一不算权重；v1 是否每帧重发起决于主机驱动）。

---

## 7. 开口项 / 诚实边界（**没测到的不许编**）

1. **整帧从未跑过**：`c4b_frame_preflight.md` 的 54 条无通路 + 宽链 BLOCKED ⇒ 本报告所有**帧级**
   数字（五档场景、fps）都是**单元级实测锚点 + 模型**的合成，不是整帧测量。首个整帧测量仍是 S3。
2. **(d) 的请求数杠杆**：只有"请求 ÷4"的设计声明；对 275.9 MB/s 的影响 = 待测（P2 判据）。
3. **(c) 的 band 余量**只在 40×40/dw40 两个作业上实测（0.65%/0.32%）；20×20 与 s=2 的 band 行为是外推。
4. **(e) 的单趟 Add** 未实现 ⇒ 2.0× 是乐观界（另一读法：窗开销保留则省不了）。
5. **算力侧的 11 拍/像素墙钟**没有拿真作业逐拍对账（只与 s2_3x16 的 `CYCLES=587,054`
   做过量级核对：模型 404k vs 实测 587k，差 = gather 停顿，带宽侧）。
6. **非 MAC 算子时间**（maxpool/resize/add/sigmoid 在 BypassExec 上的拍数）不在算力天花板里；
   它们与 conv 在 v1 是**串行**的（LayerSched 逐单元），会进一步压低 fps —— 未建模。
7. 冻结模型的固有边界（其文件头自述）：不计突发对齐浪费、不计 12 头后处理、不计权重装载 ⇒
   所有带宽数字都是**下界**。

---

## 8. 闸门（`tools/run_mac_account_ab.sh`，exit 0/1/2/3）

| 判据 | 内容 | 结果 |
|:--|:--|:--|
| 前置 | `desc.bin` md5 == `wgt_index.json` 内记录的 md5（fec587a1…） | PASS |
| 正对照 A | **调用**冻结工具现跑：`baseline == 31,942,400`（31.94）、`fuse_both == 12,576,000`（12.58）；**不放宽** | PASS |
| 正对照 B | 本工具译码的 `DECODED_UNFUSED_EXACT / DECODED_FUSED_EXACT` == 正对照 A 的**现跑值**（两边都现算） | PASS |
| 正对照 C | `TOTAL_MACS == 344,224,000`；`--selftest` 全部 CHECK PASS（含放大模型两锚点标定、1×1=9×、dw=8×、无窄形状） | PASS |
| 负对照 | `idx 20`（`Conv_29`，中网 1×1）注入 `C_OUT += 8` ⇒ ΔMACs **恰 == 预测 819,200**（bash 从打印几何现算；单元级与总量差分两条路径一致；其余 66 行逐字不变；并断言 ≠ 预测+1） | PASS（按预测量发火） |
| 四态退出码 | 0 全过 / 1 正对照不符（实测：把期望改成 31.95 ⇒ rc=1）/ 2 负对照不等（实测：预测 +1 ⇒ rc=2）/ 3 环境错（实测：PY 指不存在 ⇒ rc=3） | 四态实测 |

---

## 9. 对 spec / 后续切片的三条直接影响

1. **目标帧率**：10 fps 档在**现在这张网表**（1 阵列 × 50 MHz × 每像素 9 拍）下不可达（上限 1.1 fps 档）；
   若按"理想式"定 10 fps，等价于要求阵列**零额外拍**（1×1 不烧 8 个空抽头、dw 不用对角掩码）——
   spec §4-4"两路合一"之外，还应把**微序列（tap 压缩）**列为独立判据项。本 P0 只负责把账摊开。
2. **P2（NC8HW）的判据要加"请求数"实测**：字节口径看不见它的收益（(c)/(d) 同为 23.83 MB）；
   建议 P2 判据 = 请求数 ÷4 的**实测**（AR 突发计数），而不是字节。
3. **P3（窗口留住）是本清单里带宽侧唯一的大头**：−18.4 MB/帧（42.30 → 23.89，(a)→(b)），
   与 spec §4-1 的"÷nCo"口径一致；P2 的字节收益 ≤1%（诚实标注），不要高估。

---
---

# P0b：**按类归因 + 每条浪费的价签**（spec §4.5/§4.6 的价格标签来源）

- 日期：2026-10-16（P0 的**离线续片**）
- 交付物：`tools/mac_account.py`（扩展：类账 + 反事实 A/B/A+B + 时钟敏感表 + blob 前提 CHECK + `--perturb-taps`）、
  `tools/run_mac_account_ab.sh`（+正对照 D、+两条能发火的负对照）、本报告、
  `reports/npu_v2b_gate_green.txt`（闸门绿证据）、`reports/npu_v2_mac_table.txt`（重新生成，含新两节）。
- 本片**只读**：`gen/desc.bin`、`gen/wgt_index.json`、`gen/wgt_blob.bin`（新增只读输入）、
  冻结工具（只调用）、RTL/报告（只读）。**无 RTL 改动、无 `gen/` 输出改动。**
- 上游：本文件 §0–§9（P0）；`tools/chain_wide_ref.py` 的 L2 相位断言（1×1 的 (+1,+1) 关系，见 §P0b-2）。

**Status: DONE（三类的 issuing 与每条浪费的价签都摊开了；A/B 组合的 fps、绑定侧、时钟敏感表与闸门证据全在）**

## P0b-0 一句话

把 P0 的 45,075,600 issued 拍按类拆开后：**1×1 占 77.8%（35.05M 拍，浪费 9.49×）** —— 单笔最大是
`Conv_15` 一层（7.37M 拍 = 全帧 16.4%）；**dw 占 17.8%（8.03M 拍，8.10×）**；**dense 3×3 只占 4.4%**
（1.99M 拍，2.88×；其中 6 片 `C=1` 尾块各烧 64×，但绝对值小）。价签（@50 MHz，口径同 P0）：

| 方案 | beats | fps | 删掉 |
|:--|--:|--:|--:|
| as-built | 45,075,600 | 1.11 | — |
| **A（1×1 只发 1 拍）** | **13,920,400** | **3.59** | −31.16M（69.1% 总拍） |
| B（dw 用满阵列） | 38,036,138 | 1.31 | −7.04M（15.6%） |
| **A+B** | **6,880,938** | **7.27** | −38.19M（84.7%） |
| 理想（MACs/64） | 5,378,500 | 9.30 | −39.70M |

**组合判词**：A+B + 流量五档（(e) 12.21 fps）⇒ **算力仍绑（7.27）**；
但 **A+B 单做、流量不修**（v1 as-is 6.52 fps）⇒ 反而**带宽绑** —— 即 A+B 已足以把绑定侧翻面
（想让它翻回来，需要 clk ≥ 84.0 MHz 或继续削残差 1.279×）。
时钟：A+B 要过 10 fps 需 **≥68.8 MHz**；理想式只需 **≥53.8 MHz**（PnR 实测可闭合 54.14 **刚够**）。

## P0b-1 按类归因（类 = desc TYPE 的 1:1 映射；非估计）

| 类 | n | 有用 MACs | 占比 | 理想拍 | issued 拍 | **浪费×** | issued 占比 | 类内前 3 贵 |
|:--|--:|--:|--:|--:|--:|--:|--:|:--|
| **1×1** | 26 | 236,339,200 | 68.7% | 3,692,800 | **35,049,600** | **9.49×** | **77.8%** | `Conv_15`=7,372,800；`Conv_2`/`Conv_12`/`Conv_19`/`Conv_22`/`Conv_51` 各 3,686,400 |
| **dw** | 20 | 63,496,800 | 18.4% | 992,138 | **8,031,600** | **8.10×** | **17.8%** | `Conv_3`/`Conv_16` 各 1,843,200；`Conv_10`/`Conv_13` 各 921,600 |
| **dense 3×3** | 7 | 44,388,000 | 12.9% | 693,562 | 1,994,400 | 2.88× | 4.4% | `Conv_0`=1,843,200；`Conv_55`/`Conv_67` 各 57,600 |
| **合计** | 53 | 344,224,000 | 100% | 5,378,500 | 45,075,600 | 8.38× | 100% | — |

**按绝对 issued 拍的 Top-12（谁交的钱最多）**：

```
#idx  name     type      C_in C_out    H    W  passes  taps  issued     浪费×  占比
 10  Conv_15  conv1x1     32   64  160  160      32     9   7,372,800  9.00×  16.4%   ← 单层最大
  1  Conv_2   conv1x1     16   16  320  320       4     9   3,686,400  9.00×   8.2%
  8  Conv_12  conv1x1     32   32  160  160      16     9   3,686,400  9.00×   8.2%
 13  Conv_19  conv1x1     64   64   80   80      64     9   3,686,400  9.00×   8.2%
 15  Conv_22  conv1x1     64   64   80   80      64     9   3,686,400  9.00×   8.2%
 35  Conv_51  conv1x1     64   64   80   80      64     9   3,686,400  9.00×   8.2%
  0  Conv_0   conv3x3      3   16  320  320       2     9   1,843,200  2.67×   4.1%   ← 类内"取整"型
  2  Conv_3   depthwise   16   16  320  320       2     9   1,843,200  8.00×   4.1%
  6  Conv_9   conv1x1     16   32  160  160       8     9   1,843,200  9.00×   4.1%
 11  Conv_16  depthwise   64   64  160  160       8     9   1,843,200  8.00×   4.1%
  4  Conv_6   conv1x1     16   16  160  160       4     9     921,600  9.00×   2.0%
  7  Conv_10  depthwise   32   32  160  160       4     9     921,600  8.00×   2.0%
```

读法：**倍率与绝对值要分开看**——1×1 类平均 9.49× 里还叠着"co 尾块取整"（`C_out∈{1,4,10}` 的头层），
所以按**绝对拍数**排前 6 全是 1×1；dw 的 8× 各层都大（20 层摊平）；dense 类只有 `Conv_0`（ci 补位 8/3）
与六片 `C=1` 尾块（各 64×，但总共才 151,200 拍）值得记一笔。
**这直接回答 A 与 B 的先后：A 的绝对收益是 B 的 4.4×**（31.16M vs 7.04M 拍）。

## P0b-2 反事实 A —— 1×1 只发 1 拍（价签 −31.16M 拍 ⇒ 3.59 fps）

**前提已现场取证（只读 blob，闸门每次重扫）**：真 `wgt_blob.bin` 里 26 个 1×1 单元的
**42,697 个非零权重字节全部落在每个 `(co,ci)` 9 槽的第 0 槽**（= `(ky,kx)=(0,0)`；`CHECK
cf_a_1x1_nonzero_only_slot0` + `blob_md5_eq_wgt_index_record`），而切片的拍序是 `ph=1 → tapK=0`
（**先发槽 0**）⇒ 其余 8 拍在这 26 个单元上**权重恒 0**。

| 实现读法 | 拍数 | fps@50 | 数值 | 布局/驱动面 |
|:--|--:|--:|:--|:--|
| **① 跳拍（只留第 1 拍）** | 13,920,400 | 3.59 | 与今日**逐字节相同**（删的是 0 权重拍） | **零改动**（只改微序列：`TYPE==1×1 ⇒ taps=1`） |
| ② 只留中心拍（槽 4） | 13,920,400 | 3.59 | 与今日**不同**（见相位注记） | blob 重生成（权重搬槽 0→4）+ 装载映射改 + 驱动侧相位补偿**可以删** |

**两档拍数/帧率相同**（价签不因读法而异），差的是**改动面**。相位注记（上游证据，不是本片新结论）：
现口径下 1×1 的输出相对 ONNX 黄金是 **(+1,+1) 相位**（`tools/chain_wide_ref.py` L2 实测断言：
`Conv_6` 404,496/404,496 = 全内点；其文件头明写"真帧由驱动/表侧地址折进补偿"——**补偿落点本身是开口项**）。
读法①保持该相位（补偿照旧）；读法②会把相位**消掉**（= 少一处需要补偿的口径，算"顺手赚的简化"）。
本片**只给价签，不选读法**。

其它注记：单切片每像素墙钟 = 1 收列 + 1 tap + 1 出数 = 3 拍（vs 今日 11 拍）——**未计入 beats 口径**（同 P0）。

## P0b-3 反事实 B —— dw 用满 8 条 co 通道（价签 −7.04M 拍；★ modeled，见警示）

**趟结构照旧按 co-block**（= 今日 `nCo = ceil(C_out/8)`，**同一个**）：

| 真表 `C_out` | 趟数 | 每趟服务 | 尾块 |
|--:|--:|:--|:--|
| 64 | 8 | 8 通道 | 无 |
| 32 | 4 | 8 通道 | 无 |
| 16 | 2 | 8 通道 | 无 |
| 10 | 2 | 8 通道 | 第 2 趟 **2 通道**（`Conv_73/75/77`） |
| 4 | 1 | 4 通道（不足 8 的补位行是死料） | （`Conv_61/63/65`） |

口径：issued → ideal（`MACs/64`）⇒ dw 合计 **8,031,600 → 992,138 拍**；单做 **1.11 → 1.31 fps**。
★ 这要**一拍填满 64 个有用乘（8 通道 × 8 抽头）**，而现阵列的 x 总线是"按 ci 通道索引的一条共享列"
（`arrX(ci)=colWin(kx)(ci)(ky)`）——dw 的 64 槽里只有**对角 8 槽**是"行 r 吃自己通道"，其余 56 槽
**结构性恒 0**（分组只能落在权重掩码上，`GroupedMacArray` 文件头已证）。⇒ **B 不是微序列改动**：
要让每行同时吃自己通道的 8 个抽头，需要**数据通路改动**（每行 x 路由 / tap 向量化）。
因此本表把 B 标 **modeled 上界**；若按"逐像素整数拍"打包（72 有用 MAC / 64 每拍 ⇒ 每趟每像素 2 拍），
dw issued 的**保守界 = 2·nCo·H·W = 1,784,800 拍**（对今日 = 4.5× 收益），A+B 合计 **7,673,600 拍 ⇒ 6.52 fps**
（比 A 单独的 3.59 高 1.82×）。**可行性 = 开口测量（本片无实测）。**

## P0b-4 组合（A+B / A+B+流量五档）与**绑定侧**

| 组合 | 算力侧 | 带宽侧 | 绑定侧（min） |
|:--|--:|--:|:--|
| as-built + v1 流量 | 1.11 | 6.52 | 算力（P0 结论） |
| A + v1 流量 | 3.59 | 6.52 | 算力 |
| **A+B + v1 流量** | **7.27** | 6.52 | **带宽**（翻面！） |
| A+B + (b) 窗口留住 | 7.27 | 11.55 | 算力 |
| **A+B + 五档全做完 (e)** | **7.27** | **12.21** | **算力（7.27 绑）** |

⇒ **算力修到 A+B 之后，"带宽不修"反而变成绑定侧**——所以两条线要按"谁先落地谁绑"交替看：
A+B 落地前算力先绑（1.11~3.59 vs 6.52）；A+B 落地后如果流量还停在 v1（6.52），带宽立刻接管；
把流量推到 (b)（11.55，P0 §5 的**主项**）之后又交回算力，直到 A+B 的数字本身被推高。
**要让带宽（(e) 12.21）成为绑定侧 ⇒ A+B 的算力需 ≥12.21 fps ⇒ `npu_clk` ≥ 84.0 MHz**（或继续削残差）。

A+B 后**残差 = 1.279× ideal**（`6,880,938 / 5,378,500`，1.50M 拍）：全部是**类内取整**
（`Conv_0` 的 ci 补位 8/3、六片 `C=1` 的 co 补位 64×、`C_out=10` 的 co 尾块 1.6×）——
**第三条浪费（块内取整）还没人报价**，它是 A+B 之后通往 9.30 的唯一剩余项。

## P0b-5 时钟敏感表（**敏感度，不是测量**：`fps = npu_clk ÷ beats`）

| `npu_clk` | as-built | A | B | **A+B** | 理想 |
|--:|--:|--:|--:|--:|--:|
| **50 MHz**（现行板级钟） | 1.11 | 3.59 | 1.31 | **7.27** | 9.30 |
| 60 MHz | 1.33 | 4.31 | 1.58 | **8.72** | 11.16 |
| 75 MHz | 1.66 | 5.39 | 1.97 | **10.90** | 13.94 |
| 100 MHz | 2.22 | 7.18 | 2.63 | **14.53** | 18.59 |
| （54.142 MHz，PnR 实测可闭合） | 1.20 | 3.89 | 1.42 | **7.87** | 10.07 |

过 10 fps 的钟点：**A+B 需 ≥68.8 MHz；理想式需 ≥53.8 MHz（PnR 实测 54.14 刚够）**；
as-built 与单 B 在任何 ≤100 MHz 的都到不了。⇒ 钟能买到的量级 = 把 A+B 从 7.27 抬到 7.87（+8%，PnR 实测档），
**买不到 10 fps**（10 fps 要靠 A+B 的 RTL 改动本身 + 10~40 MHz 的钟，或理想式 + PnR 档钟的运气）。

## P0b-6 闸门（`run_mac_account_ab.sh` exit 0/1/2/3）—— P0 原有 + **P0b 新增**

| 判据 | 内容 | 结果 |
|:--|:--|:--|
| 前置（P0b 加） | 三输入互证：`desc.bin`/`wgt_blob.bin` 的 md5 == `wgt_index.json` 记录 | PASS |
| 正对照 A/B/C（P0 原有） | 冻结两锚点现跑 + 译码逐字节 == 现跑值 + `MAC_TOTAL==344,224,000` | PASS |
| **正对照 D（P0b 新）** | 闸门按 UNIT 行 `awk` 现算三类 issued/macs == 工具 `CLASS` 行；Σ三类 == Σ全部 == `CF ISSUED_BEATS`；`A_BEATS == Σall − 8·Σ_1x1(P·H·W)`（三条独立路径） | PASS（45,075,600 / 13,920,400 全等） |
| **负对照①（P0b 新）** | `--perturb-taps dw:3` ⇒ dw 类 issued **恰 == 3·Σ_dw(P·H·W)**（8,031,600 → 2,677,200），总量恰 == 其余不变 + 新值，**另两类逐字不变**；不等 ⇒ exit 2 | PASS（按预测量发火） |
| **负对照②（P0 原有 + P0b 追加）** | `idx 20` `C_OUT += 8` ⇒ ΔMACs 恰 == 819,200（原判据）；★ 追加：1×1 类 Δissued == 9·nCi·ΔnCo·H·W = 115,200、ΔA == 12,800 | PASS |
| **发火证据（P0b 实测三态）** | 红①：类交叉 +1 ⇒ **rc=1**（"类账 issued 交叉不符"）；红②：注入预测 3→4 ⇒ **rc=2**（"类抽头注入没有按预测量移动"）；红③：`PY=/nonexistent` ⇒ **rc=3**；绿运行**确定性 2×**（两次输出逐字节相同） | 四态实测 |
| 存档 | `reports/npu_v2b_gate_green.txt`（整次绿运行的完整输出） | — |

## P0b-7 数字分类（measured / modeled / assumed，只在新增项上逐条）

**Measured**（现算）
- 三类 issued/MACs 拆分与 Top-12（全部可从 `--selftest` 的 UNIT 行重算；闸门就是这么交叉的）。
- **blob 现场重扫**：42,697 个 1×1 非零权重字节全在槽 0；dw 权重散布 ≥2 槽（对照组）——本片对
  `gen/wgt_blob.bin` 只读重扫，md5 与 `wgt_index.json` 记录互证。
- A/B/A+B/理想四条拍数线与全部 fps（= beats ÷ 钟，纯算术；钟用 P0 的 50 MHz）。

**Modeled**
- 反事实 A 的**收益**（= "零权重拍不发"的微序列改动，数值等价性由 blob 槽位 + 拍序**推得**；
  真 RTL 里还**没有**这条改动——**它的实测要等实现片**）。
- 反事实 B 的**收益上界**（issued→ideal；**结构性警示见 §P0b-3**：共享 x 总线使 64/64 需要数据通路改动 ⇒
  B 的 4.5×~8× 两个界都是 model，**可行性未证**）。
- 反事实 A 的墙钟注记（11 拍/像素 → 3 拍/像素；不进 beats 口径）。
- 时钟敏感表（纯外推；54.142 MHz 档是 PnR 读数做的同样的外推）。

**Assumed**
- 反事实 A "**跳拍**读法"成立的前提：槽 0 的那一拍就是 `ph=1`（读 RTL：`tapK` 起点 0）且
  `TYPE==1×1` 能作为"taps=1"的入参投进切片（**今天没有这条入参**；`chain_1x1` 位已存在但
  **无功能读者**——T-S3f 引擎的接线项）。
- 读者若选"中心拍"读法：需 blob 重排 + 装载映射 + 驱动侧相位补偿的联动（改动面假设）。
- 五档流量、275.9 MB/s 等带宽侧口径沿用 P0（本片不动）。

## P0b-8 开口项（诚实的边界）

1. **A 的收益是"模型 + blob 取证"**，不是实跑：真 RTL 的 `taps=1` 微序列（含 1×1 与 3×3 混链时的
   节拍切换）没有实现片 ⇒ 实现后要重跑本闸门 + 单元级数值闸门。
2. **B 的可行性未证**（共享 x 总线的结构分析见 §P0b-3）；本片只给价签与两个界（4.5× / 8×）。
3. **第三条浪费（块内取整，残差 1.279× = 1.50M 拍）未报价**——A+B 落地后它就是唯一剩下的大项。
4. **1×1 的 (+1,+1) 相位补偿落点**（驱动/表侧）沿 `chain_wide_ref.py` 的开口项；它决定 A 选①还是②读法。
5. 时钟敏感表全部是外推；把 `npu_clk` 提到 >54.14 MHz 需要一次 PnR（本片不跑 PDS）。
6. 权重装载（`Σ passes×576`）与 tile halo（0.71 档）**未并入**任何反事实（口径与 P0 一致）。

---

# Slice A：**1×1 只发 1 个 tap-beat**（NPU v2 §4.6-5 / spec §5 表序 1 —— 本片把 §P0b-2 的"反事实 A"变成实走逻辑）

- 日期：2026-10-16（P0/P0b 的**落 RTL** 续片）
- 交付物：RTL（`rtl/Conv3x3Slice.scala` 的 `X1SKIP` + `rtl/MultiPassUnit.scala` 的 X1 直通口 + `rtl/UnitExec.scala` 的 `x1W`/`x1_beats`；commit `8d784c9`）、
  新闸门 `tools/run_x1skip_ab.sh` + `rtl_test/UnitExecWideTb.v` 的 `-DUE_X1OBS`（commit `00e1d44`；绿证据 `reports/npu_v2a_gate_green.txt`）、
  `tools/mac_account.py`（+`impl_a_beats()`/`IMPL_A_BEATS`）与 `tools/run_mac_account_ab.sh`（+第三条独立路径；
  commit `bffe0c3`；绿证据 `reports/npu_v2a_mac_gate_green.txt`）、本报告 + `reports/npu_v2_mac_table.txt` 同步再生成。
- 不动清单（本片纪律）：`TILING=false` 三网表 md5 逐字节冻结；描述符 8 字格式；`desc_table.py`；`PartialSumBuf.scala`；
  全部冻结参考（`conv_unit_ref.py` / `tiling_ref.py` / `multipass_ref.py` / `bypass_ref.py` / `bypass_traffic.py` / `ddr_traffic.py` / `fusion_buffer.py` / `mac_ref.py` / `chain_wide_ref.py`）**零改动**。
- 上游：spec §4.6-5、§5 表序 1（价签 `1.11 → 3.59 fps` = 本文件 §P0b-2）；分类先例 = §P0-6 / §P0b-7。

**Status: DONE（实现落 RTL + 单元级实测 9.00× + 数值逐字节不变 + fps 重新签发 3.5919 @50 MHz + 新闸门/15 回归/结构判据全绿 + dev_map 无新增违规）**

## SliceA-0 一句话

**1×1 的 tap 相位从 9 拍缩到 1 拍**（"跳拍"读法①：只留槽 0 那一拍，blob/布局/驱动零改动）：issued 拍
**45,075,600 → 13,920,400（−69.1%）**，算力侧天花板 **1.1092 → 3.5919 fps @50 MHz**（P0b 价签 3.59 命中；
差额 = 舍入位数，见 SliceA-3）。单元级**实测 9.00×**（TB 自报拍数 2304→256 / 3240→360，与模型逐位一致）、
跳掉的 8 拍在整片内存上**逐字节什么都不干**（正对照 dump 逐字节相同 + 2 条网表突变拆解后输出仍逐字节不变）。
绑定侧：3.59（算力）< 6.52（v1 带宽）⇒ **仍是算力绑**（与 §P0b-4 的翻面点一致：流量修到 (b) 11.55 后带宽才接管）。

## SliceA-1 实现（RTL，commit `8d784c9`）

- `Conv3x3Slice` +`X1SKIP`（缺省 `false`）：**类体末尾**一条 late-override `inPix ∧ one_x1 ∧ ph==1 ∧ !prime ⇒ ph := 10`
  （SpinalHDL 对同一 Reg 后写生效）⇒ 像素相位从 ph=1..9+ph=10 缩成 ph=1+ph=10；数据面/出数面一字未动
  （ph=1 的 `tapKx/tapKy/tapK=0` ⇒ 槽 0 取法与旧版**同拍同位**；bias/ps/requant 每像素每趟各一次照旧）。
  `X1SKIP` 展开里另有 tap-beat 观测计数器 `obs_beats`（`arr.en` 拍数）——`mac_account.py` 的 `taps·passes·H·W` 的实测对应物。
- `MultiPassUnit` +`X1` 直通口（缺省 `false`）；`UnitExec` 的 `mpu` 传 `X1 = TILING`，`TILING=true` 才落 `x1W`
  （`go` 拍从**描述符 TYPE=0x02** 闩存——运行期权威字段）+ `x1_beats` 观测口。
- **行数中性纪律**：三份源文件只改既有行/类体末尾追加 ⇒ `TILING=false` 三网表 md5 逐字节不变
  （`97912901…` / `618af338…` / `ddb9bb8a…`，本片复验）；只变三份 `TILING=true` 网表：
  `UnitExec_tiled.v 2b2e067e…`、`LayerSched.v 74ecebbf…`、`NpuTop.v 5ae64c30…`。

## SliceA-2 实测（新闸门 `tools/run_x1skip_ab.sh`，commit `00e1d44`；本机复跑 **RESULT: PASS**，与存档逐行复现）

装置 = `gen/UnitExec_tiled.v` + `UnitExecWideTb`（`-DUE_X1OBS`）；作业 16→16 / 8×8 / P=4 趟（每趟 64 像素）：

| 判据 | 内容 | 结果 |
|:--|:--|:--|
| 正对照（同一作业只换 TYPE） | 非 tiled：TYPE=1 **2304** 拍 → TYPE=2 **256** 拍（9.00×）；tiled：TYPE=1 **3240** → TYPE=2 **360**（9.00×）；两档 DST 逐字节 == 冻结参考，且两份**整片内存 dump 逐字节相同** | PASS |
| 负对照（槽 4 放一个非零字节） | TYPE=2 **MISMATCH=57 == 预测量 57**（发火）；同一 blob TYPE=1 ⇒ **0**（红是"跳拍"造成的） | 按预测量发火 |
| 外科式（同一个 7 从槽 4 搬到槽 0） | TYPE=2 **翻绿（0）**；槽 0 字节改变黄金 **44** 字节，DUT 两份 dump 同样差 **44** 字节（槽 0 真被吃到、且只差在这些字节） | PASS |
| 网表突变 ×2（拆跳拍条件 / 拆 TYPE 译码；锚唯一） | 拍数**回到 2304（9×）**且输出**逐字节不变**（= 跳掉的 8 个零权重拍数值上确实什么都不干） | PASS |
| 前置 | `TILING=false` 三网表 md5 冻结；真 blob 26 个 1×1、42,697 个非零字节**全在槽 0**、无 8→8 的 1×1 | PASS |

## SliceA-3 fps 重新签发（`tools/mac_account.py` + `run_mac_account_ab.sh`，commit `bffe0c3`）

**自下而上实计账**：`IMPL_A_BEATS = Σ_单元 taps_eff(类)·passes·H·W`（1×1 类 = 1 拍；其余类 = 9 拍不变）=
**13,920,400**。它被**四条独立路径**钉死（闸门每次现跑，任何一侧漂移当场红）：

| 路径 | 值 |
|:--|--:|
| ① 自下而上逐单元加总（新） | 13,920,400 |
| ② 自上而下 `Σall − 8·Σ_1x1(P·H·W)`（闸门 awk 现算） | 13,920,400 |
| ③ CF `A_BEATS`（工具反事实打印） | 13,920,400 |
| ④ **P0b 硬价签**（`CHECK impl_a_tag_p0b`） | 13,920,400 |

⇒ `FPS_COMPUTE_IMPL_A = 50 MHz ÷ 13,920,400 = **3.5919**`（P0b 价签 **3.59** = 其 2 位舍入；**无差异**）。
`IMPL_A_REMOVED = 31,155,200` 拍（69.1%）。**实测 vs 模型**：TB 自报 TYPE=2 = 256 拍 = `1 拍/像素/趟 × 4 趟 × 64 像素`
与模型**逐位相等**（非 tiled/tiled 两档皆 9.00×）——本次**没有**"实测拍数与模型不一致"的情形；
全帧 13,920,400 本身仍是"实测 67 单元表 + 新日程模型"的加总（整帧从未跑过，§7-1 依旧成立，见 SliceA-5）。
类账同步：`CLASS 1x1` 的 `issued` 行不变（那是 as-built 口径），新口径只加 `IMPL_A_*` 行与 `A 已落 RTL（实计）` 行；

负对照两条（`--perturb-taps dw:3` 按预测发火；`idx 20 C_OUT+=8` 的 ΔMACs/Δ类/ΔA 按预测发火）照旧全过；闸门 **RESULT: PASS**。

## SliceA-4 dev_map（integrated，本机现跑；`devmap_c4a.tcl`，period=10 ns）

命令：`pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl`（cwd = 仓库根；日志 `y1/pds/devmap_c4a_x1skip.log`，exit=0）。
网表 = `gen/NpuTop.v`（`5ae64c30…`，含 `X1SKIP` 与三座桥）；对照 = §3.7 基线 `pds/devmap_c4a_s37.log`：

| 资源 | §3.7 基线（s37） | Slice A | Δ |
|:--|--:|--:|--:|
| LUT | 124,108 | **124,106** | **−2** |
| FF | 149,298 | 149,299 | +1 |
| APM | 542 | 542 | 0 |
| DRM | **247.5 / 415** | **247.5 / 415** | 0 |
| Distributed RAM | 7,872 | 7,872 | 0 |
| IO | 99 | 99 | 0 |

**判据**：`Adm-4088 = 0`（现跑日志 grep 计数 0；另无 DRC-xxxx / Program Error；`LUTs as dram: 7872` 与基线同）。
读数：跳拍 = 相位计数器上的一条 late-override + 一个观测计数器 ⇒ **噪声级**改动（LUT −2 / FF +1），
DRM/APM 零变化 —— 与"只减控制逻辑、不加数据通路"的设计意图一致（DRM 余 167.5 块仍是后续窗口留住的余量）。

## SliceA-5 数字分类（measured / modeled / assumed，仅新增项；先例 = §P0-6 / §P0b-7）

**Measured**
- **9.00× 拍比**：TB 自报 `X1_BEATS`（非 tiled 2304→256、tiled 3240→360；闸门按预测量断言，不是"看着像"）。
- **跳拍数值等价性**：TYPE=1 vs TYPE=2 两份**整片内存 dump 逐字节相同**；负对照 MISMATCH==预测 57；外科式翻绿 + 44 字节
  归因；两条网表突变拆掉新逻辑后拍数回 9× 且输出逐字节不变。
- **`TILING=false` 三网表 md5** 冻结（97912901… / 618af338… / ddb9bb8a…，本片复验）。
- **dev_map 全表**（PDS 现跑）：LUT 124,106 / DRM 247.5 / APM 542 / FF 149,299 / Adm-4088=0。
- **回归**：15 闸门 PASS + `check_dangling.py` 6 网表 0 悬空（SliceA-7）。

**Modeled**
- 全帧 `13,920,400` 拍（实测 67 单元表上按新日程的逐单元加总；**不是整帧实跑**——整帧从未跑过，§7-1 不变）。
- `3.5919 fps @50 MHz` 与时钟敏感表上 A 列的 60/75/100 MHz 档（beats ÷ 钟，纯算术，口径同 P0/P0b）。
- 墙钟注记（单切片 3 拍/像素 vs 11 拍/像素）**不进** beats 口径。

**Assumed**
- **"链内 1×1 也拿 1 拍"**：真表 26 个 1×1（本片现扫）**全部是链成员**——19 `head` + 7 `middle`、0 `plain`；
  实测覆盖的是 TB 的 chainLen==1（单单元）档。宽链引擎（T-S3f）未落地前，链内那部分收益在真帧上**还没有落点**
  （按 RTL 现状会在 `go` 那一刻**响亮 err**，不是静默错值——工具头原注记）；本片**不**把该假设记入 Measured。
- 读法①保持 `chain_wide_ref.py` 记的 (+1,+1) 相位（补偿落点开口项不变）。

## SliceA-6 开口项（诚实边界）

1. **链内落点 = T-S3f**（SliceA-5 Assumed 第一条）：31.16M 拍里 head 15.18M + middle 15.97M 的收益按链内日程
   生效；TB 已证单单元档，链内档随 T-S3f 的引擎一起验收。
2. **fps 是算力侧天花板**（非墙钟；tile halo 0.71 档、非 MAC 算子时间未并入——口径与 P0 一致）。
3. 相位补偿落点（驱动/表侧）沿 `chain_wide_ref.py` 的开口项；本片读法①不动它。
4. 权重装载（`Σ passes×576`）未并入任何口径（同 P0）。

## SliceA-7 回归闸门证据（全绿；本机现跑，`PY=lxvenv python` + `PYTHONPATH=./.pydeps;../third_party/yunet/deps`）

| 闸门 | 结果 | | 闸门 | 结果 |
|:--|:--|:-:|:--|:--|
| `run_x1skip_ab.sh`（新） | **RESULT: PASS**（负对照+外科+突变全发火/翻面） | | `run_tiling2d_rtl_ab.sh` | RESULT: PASS |
| `run_mac_account_ab.sh`（+IMPL_A 三路径） | **RESULT: PASS**（13920400×4 + 3.5919 fps） | | `run_tiling2d_wide_ab.sh` | RESULT: PASS |
| `run_unitexec_ab.sh` | RESULT: PASS | | `run_wgtblob_tiled_ab.sh` | RESULT: PASS |
| `run_unitexec_wide_ab.sh` | RESULT: PASS | | `run_psbound_ab.sh` | RESULT: PASS |
| `run_chain_ab.sh` | RESULT: PASS | | `run_sched_ab.sh` | RESULT: PASS |
| `run_chaingeom_ab.sh` | RESULT: PASS | | `run_nputop_sched_ab.sh` | RESULT: PASS |
| `run_fuse_ab.sh` | RESULT: PASS | | `check_dangling.py`（6 网表） | RESULT: PASS（0 悬空） |
| `run_multipass_ab.sh` | RESULT: PASS | | `run_dw_ab.sh` / `run_dw_wide_ab.sh` | RESULT: PASS / PASS |

---

# Slice A2：**宽链拆融合（de-fuse）**（spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5.0 —— 用户裁决后第一片）

- 日期：2026-10-16
- 上游：spec §5.0（决策记录 + A2 五判据）、`docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` Task A'-1（接口钉死）、
  `reports/ts3g_chain_caliber.md`（19-run 标定表）、本文件 P0/P0b/SliceA
- 交付物：`tools/y1_convert.py`（de-fuse 落地 + 判据组；commits `8b7a75d`）、
  `tools/frame_preflight.py` + `tools/run_preflight_ab.sh`（镜像同步 + 重锚；`b108584`）、
  `tools/run_convert_ab.sh`（判据组重锚；`b30c94d`）、`tools/mac_account.py` + `tools/run_mac_account_ab.sh`（重锚；`d9a5c50`）
- **不动清单**：RTL / `gen/` 网表 / 描述符 8 字线格式 / 全部冻结参考（含 `desc_table.py`、`ddr_traffic.py`）/ `third_party/**` 零改动
- **Status: DONE**（预检 ERR {29}/{54}→空/零；表侧 FRAME-RUNNABLE: YES；arena 装得进；流量由冻结模型重发）

## A2-0 一句话

真表 19 段宽 run（52 个成员）**逐成员拆成 `plain`**（每成员一项、写自己的几何），窄 run 保留链（本网 0 段）；
`chain_len` 恒 1 ⇒ 已逐字节验证的**宽单点**路径接管整帧。代价（**冻结模型**重发）：激活侧 +19.37 MB/帧
（12.58 → 31.94 MB/帧，`fps_bandwidth` 21.94 → 8.64 @275.9 MB/s）；收益：整表几何预检**零 err**
（DISPATCH 口径的 54 条"宽层链无通路"全部消失），且切片 A 的 1×1 收益（26 个 1×1 全是链成员）**在单点路径上有落点**。

## A2-1 逐项落地（spec §5.0 的五判据）

1. **整表几何预检零 err**（`run_preflight_ab.sh` 重锚）：UNIT 口径前 `{29}` → 后 `{}`；
   DISPATCH 口径前 `54` → 后 `0`。两条负对照（`Resize_49 IMG_H 80->82` / `MaxPool_5 C_IN 16->17`）外科式 +1 发火、确定性 2×。
   ★ 注：`{29}`（Resize_43 撞旧 `tileAliOk`）与 DISPATCH 里 `inWMax>34` 那批在 **T-S3d/T-S3e 的 RTL 修复**下已不是缺口
   —— 本片的 `frame_preflight.py` 把镜像对到当前 RTL（`:2079` 的 `!tilingW` 豁免；`tileAliOk` 已去），不是放宽判据。
2. **表闸门重锚且全绿**：`run_desc_ab.sh` **锚不动**（`desc_table.py` 零改动 ⇒ 冻结向量 `a45d0da0…` 照旧，复跑 PASS）；
   `run_convert_ab.sh` 重锚并绿：新增 A2 判据组 + 红证据 E（`--inject baddefuse ⇒ rc=1`）。
3. **流量由冻结模型重发**（只调用 `ddr_traffic.py`，未编辑）：`baseline = 31,942,400 B/帧`（= 拆后表按-flag 译码，
   两向断言）vs `fuse_both = 12,576,000 B/帧`（= 冻结向量按-flag 译码）⇒ 代价 **+19,366,400 B/帧**；
   `fps_bandwidth`：拆前 21.9386 → 拆后 8.6374（@275.9 MB/s；含旁路则 14.13 → 7.09）。
   ★ 口径注：这是**冻结模型口径**（不计 tile 读放大）；v1 as-built 的读放大账（P0 §5 场景 (a)）此时
   会**叠加在全部 53 个 conv 单元上**（不再只有 head），`mac_account.py --scenarios` 的表已按新表重算（信息性）。
4. **Arena 硬门**：分配器高水位 `ARENA_TOP = 0x01C505C0`（phys `0x81C505C0`）≤ 预留区上界 `0x0200_0000`
   （物理 `0x8200_0000`；余 3,865,152 B）⇒ `ARENA_FIT ok=1`。
   ★ **分配器零改动**：冻结 bump arena 本就为**每个张量**（含链中张量）分配槽位 —— 逐 run 断言
   `SRC(k) == DST(k-1)`（33/33，`DEFUSE_CHAIN_ADDRS ok=1`）⇒ 拆后中间张量全部有**真实** DDR 写-读对。
5. **端到端驱动一致**：`npu_frame_run.py` **零代码改动**（表读取/折叠改写哨兵/12 路计划全部照旧）；自检
   `--dry` 2× 逐字节相同（`DRY_OUTPUTS=12 / DRY_FOLD_REWRITES=0 / DRY_HARD=0 / DRY_RESULT: PASS`），
   `run_frame_ab.sh RESULT: PASS`。

## A2-2 与 C3 冻结向量的差（**验签名**，不放宽）

`TABLE_DIFF_FIELDS_ALLOWED ok=1`：`{IN_BYTES:7, SRC_ADDR:34}`（H1/§3 原有）∪
`{FLAGS:52, C_IN:17, C_OUT:6, GROUP:20}`（**仅被拆的宽 run 成员**；FLAGS 差必须恰是"链角色→plain"、
几何差必须恰是 own 且不落在链首）—— 任何越界差 ⇒ 判据红（实测 `baddefuse` 红证据同时咬这条）。

## A2-3 指纹与不变量（before → after）

| 产物 | before | after | Δ |
|:--|:--|:--|:--|
| `gen/desc.bin`（2176 B = 68×32 B） | `fec587a1…` | **`4bd68b36…`** | 52× FLAGS→plain + middle/tail 写 own 几何（7 IN_BYTES/34 SRC_ADDR 与 H1 期相同） |
| `gen/wgt_blob.bin`（404,064 B） | `aa135f0f…` | **`aa135f0f…`（逐字节不变）** | 53 段 offset/nbytes/aligned/md5 全等 |
| `gen/wgt_mult.bin`（268 B） | `ff2ed3c6…` | **`ff2ed3c6…`（逐字节不变）** | M 表逐字等 |
| `gen/wgt_index.json`（203,131 → 226,970 B） | `145fc56c…` | **`723a5185…`** | +`defuse` 段 / 每单元 `defused_wide_run` / `own`+QUANT_SHIFT / `table_diff` 强化 |

不动清单逐条复验：`requant_mult`、`centering`（z_pad/bias_adj/刻度）、`src2_add`（Add 的 k）、`src_addr_fold`（34 条 H1 改写）、
`layout_fold` 全部**逐字相等**；描述符 8 字线格式一字未动（`ROUNDTRIP_BAD=0 RAW_WORD_BAD=0`）。

## A2-4 判据组（`y1_convert.py --gate` 新输出；正+负）

- `DEFUSE_RUNS total=19 defused=19 kept_narrow=0 defused_members=52`（链长直方图 15×2+2×4+1×6+1×8）；
- `DEFUSE_ALL_PLAIN ok=1`（被拆 run 全成员 plain；保留 run 全 narrow 且角色合法——本网 0 段）；
- `DEFUSE_CHAIN_ADDRS ok=1 checked=33`；`ARENA_FIT ok=1`；`DEFUSE_TRAFFIC …`（两向 == 冻结）；
- **负对照（能发火）**：`NEGCTL_DEFUSE_HEAD … FIRED=1`（被拆成员塞回 `head` ⇒ 判据红）；
  端到端 `--inject baddefuse ⇒ rc=1`（判据红 + `validate` 响亮拦 `head without tail` + 流量判据连带红）。

## A2-5 消费表的闸门批量重跑（本机现跑）

- **全绿**：`run_preflight_ab` / `run_convert_ab` / `run_desc_ab` / `run_mac_account_ab` / `run_frame_ab` /
  `run_chaingeom_ab` / `run_wgtdma_ab` / `run_wgtdma_geom_ab` / `run_wgtdma_wide_ab` / `run_addsrc2_ab` /
  `run_layoutadapt_ab` / `run_bypass_cblk_ab` / `run_paramdel_ab` / `run_dw_ab` / `run_dw_wide_ab` /
  `run_nonwide_wide_ab` / `run_wide_tail_ab` / `run_unitexec_wide_ab` / `run_x1skip_ab` / `run_tiling_ab` /
  `run_tiling2d_ab` / `run_tiling2d_rtl_ab` / `run_tiling2d_wide_ab` / `run_layout_ab`
- **保持先红（设计使然）**：`run_chain_wide_ab` —— 宽链在当前网表上仍无通路（红签名与 `ts3f_red_first.txt` 逐字一致；
  A2 之后**真帧不再需要**宽链）。
- **既有红（与 A2 无关，明写）**：`run_stride_ab` 在 `iverilog` 编译步即红
  （`rtl_test/MultiPassTb.v:83` 引 `ps_clr` 不在 `gen/MultiPassUnit.v` 的端口上 —— TB/网表错位，本片未动任何 RTL/TB/网表；
  它也不在 SliceA/A'-2 的回归清单里）。另：`run_chaingeom_ab`/`run_addsrc2_ab`/`run_layoutadapt_ab` 需要
  `PYTHONIOENCODING=utf-8` / `PATH` 里带 `iverilog`（msys64 ucrt64）才跑得动 —— 环境口径，非 A2 回归（复跑全绿）。

## A2-6 诚实边界

1. **"表侧 FRAME-RUNNABLE: YES" 不等于整帧已跑通**：预检是 RTL 判据的 Python 镜像；整帧在**真几何网表**上的
   实际可跑性仍待 S3 上板终证（口径同 P0 §7-1）。
2. **链内 1×1 收益的落点**：拆融合把 26 个 1×1（原全部是链成员）放到**单点**路径上 —— 这正是 A 的收益兑现面；
   但真帧的拍数实绩仍待整帧测量（口径同 SliceA-5）。
3. **`defuse` 记录里 `own` 新增 `QUANT_SHIFT` 键**（= 冻结 `QUANT_SHIFT_BY_TYPE[TYPE]`，conv 恒 6）—— 纯 metadata 增项，
   权重/requant/centering 数值零变化（见 A2-3）。
4. `--dry` 的 `fold_src_rewrite` 哨兵维持 0（H1 自洽）；H1 的**口径含义**在 A2 后收紧为"每个链中张量都真的被前驱写 DDR"。

---

# Slice B-1：**depthwise 用满 8 条通道 —— 可行性与接口钉死**（spec §5 表序 3；**设计+测量片，不改产品 RTL**）

- 日期：2026-10-16
- 交付物：探针 `rtl_test/DwLaneProbe.scala`（三档：BEFORE / AFTER2 / AFTER1 + 外科锚）+ `rtl_test/DwLaneGen.scala`
  + 装置 `rtl_test/DwLaneTb.v` + 闸门 `tools/run_dwlane_ab.sh`（绿证据 `reports/npu_v2b1_gate_green.txt`）+
  `pds/devmap_dwlane.tcl`（三档探针各自的 dev_map）+ `tools/dw_lane_account.py`（价格重签发，四条锚）。
- **不动清单（本片纪律）**：`y1/rtl/**` **零改动**（探针与装置都在 `rtl_test/` 下，独立网表、独立闸门）；
  `gen/` 只**新增**四个探针网表（`DwLaneBefore/After2/After1/After1Mut5.v`，与既有产物零冲突）；
  全部冻结参考（`conv_unit_ref.py`/`tiling_ref.py`/`multipass_ref.py`/`bypass_ref.py`/`bypass_traffic.py`/
  `ddr_traffic.py`/`fusion_buffer.py`/`mac_ref.py`/`chain_wide_ref.py`）**零改动**（只**调用**）；
  `desc_table.py` 与其它切片的 `gen/` 输出**零改动**。
- 上游：spec §4.5-② / §4.6-6（价签 `1.11 → 1.31`（单做 B）、**`A+B = 7.27`（标 modeled 上界）**、
  保守界 `2 拍/像素/趟 ⇒ 6.52`）、本文件 §P0b-3（★ "B 不是纯调度"的结构警示）。

**Status: DONE（把 P0b 的 "modeled 上界" 换成**钉死的接口 + 实测的价签**；结论 = **有条件 go（AFTER1 档）**，
但 `A+B` 单独**到不了 10 fps**，且 dw 的 8× **不可能**收到 P0b 的"理想式"1×（除非加乘法器））**

## B1-0 一句话

现 dw 路径的浪费来自两件事的乘积：**对角趟**（趟数 = `nCo`，`UnitExec.isDwW`）+ **每拍 8/64 lane 有用**
（x 是**一条 8 宽广播总线**，`arrX(ci)=colWin(tapKx)(ci)(tapKy)` 喂给 8 行 co）⇒ 9 拍/像素/趟、
64 槽里 8 个有用（P0b 实测 8.10×，占全帧 issued 17.8%）。

**结构发现（本片核心）**：把**抽头当内维**（lane `(r,j)` 算 `x[r][j]·w[r][j]`）**不需要 8×8 交叉开关** ——
因为 9 个抽头对同一像素**同一拍就全在 `colWin` 里**（窗口与 576 B 权重都是寄存器），
AFTER 档的 x 就是 `colWin(j%3)(r)(j/3)`、w 就是 `WeightStore` 对角 entry 的 `mem[r*72+r*9+j]`
—— **两条都是静态寄存器直连、零多路选择器**。真正要加的只有**"逐 lane 的 dw/dense 二选一"**
（一张网表要同时服务 dense 的广播与 dw 的逐 lane）+（AFTER1 档）一行 8 个乘法器。

**实测价签（探针 dev_map，同一器件/同一口径 = Mapping Summary）**：

| 档 | 每像素每趟 tap 拍 | LUT | FF | DRM | LUT-as-dram | APM |
|:--|--:|--:|--:|--:|--:|--:|
| **BEFORE**（as-built：广播 x、9 拍） | 9 | 4,184 | 6,601 | 0.0 | 0 | 64.00 |
| **AFTER2**（tap-inner 打包、**无新乘法器**） | 2 | 4,765 | 6,601 | 0.0 | 0 | 64.00 |
| **AFTER1**（tap-inner + **第 9 抽头行**） | 1 | 4,501 | 6,601 | 0.0 | 0 | **72.00** |
| Δ(AFTER2 − BEFORE) | −7 | **+581** | +0 | +0 | +0 | **+0** |
| Δ(AFTER1 − BEFORE) | −8 | **+317** | +0 | +0 | +0 | **+8** |

（AFTER1 复跑第二遍**逐字相同** ⇒ dev_map 确定性；读数出处：`y1/pds/devmap_dwlane_{before,after2,after1}.log`
的 `Mapping Summary`；裸探针 IO 501 > 400 ⇒ 按 M0/layersched 先例 dev_map 在 IO DRC 中止、资源取 Mapping Summary。）

**拍数实测（TB 自报 `arr.en` 计数，按预测量断言）**：BEFORE 9.00 拍/像素/趟、AFTER2 2.00（**4.50×**）、
AFTER1 1.00（**9.00×**）—— 六个形状（真表 dw `C∈{4,10,16,32,64}` + 基准 `C=8`）全等，三档输出**逐字节相同**
且 **== 冻结黄金**（`multipass_ref.conv_tiled` 现跑）。

**价格重签发（`dw_lane_account.py`，四条锚全 PASS）**：

| 臂 | beats | fps@50 MHz | 绑定侧（对 v1 流量 6.52） |
|:--|--:|--:|:--|
| as-built | 45,075,600 | 1.1092 | 算力 |
| A（已落 RTL） | 13,920,400 | 3.5919 | 算力 |
| **A + dw AFTER2** | **7,673,600** | **6.5158** | **算力**（6.5158 < 6.52，**不翻面**） |
| **A + dw AFTER1** | **6,781,200** | **7.3733** | 算力（+流量 (b) 11.55 后仍算力） |
| 理想（MACs/64） | 5,378,500 | 9.2963 | — |

**⇒ 修正 P0b 的 7.27**：`A+B = 7.27 fps` 的前提是 dw 收到"理想式 1×"（992,138 拍）——**本片证它结构性不可达**：
64 lane 的阵列 + 沿列归约 ⇒ 每输出值 9 个乘、一拍最多吃 8 个"归约项" ⇒ **2 拍/像素/趟是地板**（56% 占用率），
再往下要**加一行乘法器**（AFTER1）。P0b 的**"保守界 2 拍（6.52 fps）"其实就是可达界**，不是保守。

## B1-1 现 dw 通路的**逐行复原**（file:line）

| 环 | 在哪 | 逐字口径 |
|:--|:--|:--|
| 路由 | `rtl/UnitExec.scala:1395` `isWide=!narrowShape`；`:1384-1385` `narrowShape`（**排除 dw**） | 真表 20 个 dw **全走宽通路** |
| 判 dw | `rtl/UnitExec.scala:1406` `isDwW = (GROUP!=0) && (GROUP==C_in) && (C_in==C_out)` | 描述符字段 ⇒ 运行期权威 |
| 对角趟 | `:2157-2159`（下一趟 = `(wCob+1, wCi=wCob+1)`）；`:2721` `wide_passes = Mux(isDwW, nCo, nCi*nCo)` | 趟数 `nCo`（不是 `nCi*nCo`） |
| 收料/偏置/清门 | `:1845` `wCollectCiOk`；`:1786` `wBiasR`；`:2364` `ps_clr` | 对角趟 = 每个 co-block 唯一一趟 ⇒ 成品直接收 |
| 切片 | `:1472-1476` `mpu = new MultiPassUnit(...)` ⇒ `rtl/MultiPassUnit.scala:137` `Conv3x3Slice(GROUP=1,...)` | **GROUP=1**：dw 掩码**不在切片里**，落在**装载器零填**（`:404-436` §B1c、`:974` `wzNeedW`、`:2042-2050`、`:2651-2653`） |
| 拍节拍 | `rtl/Conv3x3Slice.scala:371-401`（`tapKx/tapKy/tapK` 走 9 相位）、`:411` `arr.io.en := inPix && !phZero && !phTen` | 每像素恒 **9 个 tap 拍**（1 收列 + 10 相位 = 11 拍墙钟） |
| **x 操作数** | `:405-408` `arrX(ci) := colWin(tapKx)(ci)(tapKy)`；`:410` `arr.io.x := arrX`；`rtl/GroupedMacArray.scala:63` 直通；`rtl/MacArray.scala:64` `x: Vec(SInt(8),8)`、`:85` `prod(ci)=x(ci)*w(co)(ci)` | **8 宽广播**给 8 行 co ⇒ dw 的 64 槽**只有对角 8 槽**有用 |
| w 操作数 | `rtl/WeightStore.scala:80-94` 每个 `(co,ci)` 一个 9 选 1（`k`）；`:93` 组掩码展开期常量折叠 | 宽通路 `GROUP=1` ⇒ 掩码落**装载器零填**（对角趟只有 `cl==cil` 非 0） |
| requant / 部分和 | `rtl/Conv3x3Slice.scala:494-516`（`accTot = acc + ps_in + bias`；`ps_out`；三级流水 requant）；`rtl/MultiPassUnit.scala:174-196`（PSB 读/写）；`:177` `ps_clr` | dw 每趟是成品 ⇒ `ps_in` 恒 0；**这半边一条都不用改** |
| 喂列 | `rtl/UnitExec.scala:1789` `mpu.io.x := wXCol`（一拍一列 = 本 ci 块 8 通道） | 对角趟列流 = `nCo` 块 × `(H+1)×W` 列 |

**必须改的线（= 接口钉死）**：
1. `Conv3x3Slice`：新增 **`dw_mode`**（additive 口，只在 `TILING=true` 的展开里存在 —— 与 slice A 的 `one_x1`
   同一套接线法）；dw 档像素相位 **9 → 2（AFTER2）/ 1（AFTER1）**拍；`arrX` 从"8 宽广播"改成
   **逐 lane**：`xLane(r,j) = Mux(dw_mode, colWin(j%3)(r)(j/3), arrX_dyn(j))`。
2. `MacArray`：x 口逐 lane（`Vec(Vec(SInt(8),8),8)`，或 additive 的 `dw_x` 口 + 模式位）；
   AFTER1 档再加 `x8/w8`（第 9 抽头行）+ `acc += sum + x8·w8`（每行一个加法器）。
3. `WeightStore`：additive 的 **dw 对角读口** `dwTile(r)(j) = mem[r*PER_GROUP*9 + r*9 + j]`（+ `dwTile8`）。
   ★ 实测前提：**不需要**动 blob / 装载器 / 描述符 —— 现零填对角瓦片的 `(r,r)` entry 的第 `j` 个抽头
   就是"通道 r 的抽头 j"（C=4/10 的尾块同样成立，闸门六形状全证）。
4. `UnitExec`：把 `isDwW` 接到 `mpu.io.dw_mode`（一行，同 `x1W` 手法）；
   **装载器 / 趟循环 / 收料门 / `ps_clr` / `wide_passes` 一条都不用改**（拍数自动跟着切片相位变）。

## B1-2 备选形状与取舍

| 形状 | 拍/像素/趟 | 价钱（实测/推理） | 判词 |
|:--|--:|:--|:--|
| **AFTER1**（tap-inner + 第 9 抽头行） | **1** | LUT +317 / **APM +8** / DRM 0（**实测**） | **推荐**：拍数 = dw 的结构地板（72 MAC/拍 > 64）、LUT 比 AFTER2 还小 |
| **AFTER2**（tap-inner 打包） | **2** | LUT **+581** / APM +0（**实测**） | 备选：APM 零成本；但 beat-B 的逐 lane 权重掩码（3:1）比"加一行乘法器"更费 LUT |
| "dw = 抽头轴上的 grouped-1×1"（ci 轴扩成 72 宽） | 9 | 推理：576 entry 只有 72 个非零 ⇒ **拍数一分不省** | **否决**（换说法，不省拍） |
| 逐 lane **动态** ci 交叉开关（每 lane 一个通道选择器） | 2 | 推理：64 个 9:1 × 8 bit ≈ 上千 LUT，**无收益** | **否决**（更贵、无收益） |
| 行 = 像素、列 = 抽头（8 通道共 8 像素） | 2 | 推理：与 tap-inner 同拍数同结构，还要多一份窗口副本 | 等价，**不推荐** |
| 用 ps 缓冲把 beat-B 的 56 个空槽填"另一个像素" | 理论上 <2 | 推理：累加器只有 8 行、跨像素要 ps 往返（每 tap 拍一次） | **否决**（吃掉节省） |

## B1-3 实测装置（正对照 + 拍数 + 两条负对照，全绿；证据 `reports/npu_v2b1_gate_green.txt`）

- 装置 = `rtl_test/DwLaneTb.v` + 三档探针网表（**一份 TB、四份网表各编一份**；MODE 0 用 `-DMODE0`）；
  向量/黄金 = **冻结** `multipass_ref.py` 现跑；窗口/相位/幻影列口径逐条照抄 `Conv3x3Slice` 的 `s=1` 档。
- 正对照：三档 × 六形状 MISMATCH=0（对冻结黄金）且三档 Y **逐字节互等**；
- 拍数：`BEATS == taps·NB·NPIX`（9/2/1）**实测**，BEFORE→AFTER1 = **9.00×**；
- 负对照 A（**第 9 抽头切除**：瓦片 `mem[r*72+r*9+8]` 置 0）+ B（**路由突变**：lane 5 的 `kx` 由 2 改成 0）
  ⇒ 三档/突变档 MISMATCH **恰 == python 现算的预测**（前提 = 闸门里断言的"同一 acc 模型 + requant
  **逐字节复现冻结黄金**"）；正规网表在同一作业上 == 0（红来自注入、不是夹具）。

## B1-4 成本落地（把探针读数摊到集成网表）

- 探针是**一份切片当量**（LineBuffer + 576 B 权重 + 8×8 阵列 + 相位 FSM + requant）；BEFORE 4,184 LUT
  vs 真 `Conv3x3Slice` ~6,202 LUT（spec §4-4）⇒ **只引用 Δ，不引用绝对值**。
- **只加在宽通路的那个切片实例上**（dw 只在宽通路跑；`MultiPassUnit.sl` 是唯一实例）⇒
  **AFTER1：+317 LUT / +8 APM**；集成读数预测 124,106→**124,423 LUT（77.9%）**、542→**550 APM（74.3%）**，
  DRM 不动（247.5/415）。
- **最坏情形（改动落在 `Conv3x3Slice` 全体 9 个实例）**：+2,853 LUT / +72 APM ⇒ **126,959 LUT（79.4%）/
  614 APM（83.0%）** —— 仍在帽内（LUT 159,800 / APM 740），但**吃掉 36% 的 APM 余量**。
  ⇒ 接口必须做成 **`TILING=true` 才存在的 additive 口**（同 `X1SKIP`/`one_x1`），把代价钉在**一个实例**上。
- **未测/风险**：① 逐 lane x 的 2:1 选择器**多一级 LUT 在乘法器输入锥上**（R3-1/R3-2 治的就是这条锥）——
  dev_map 不测时序，**实现片必须重跑 PnR**；② 采集/喂列速率（每像素 11→3~4 拍）未测。

## B1-5 数字分类（measured / modeled / assumed，先例 = P0-6 / P0b-7 / SliceA-5）

**Measured**
- 三档 dev_map 全表（LUT/FF/DRM/LUT-as-dram/APM）+ AFTER1 复跑逐字相同（确定性）。
- 拍/像素/趟 9.00 / 2.00 / 1.00（TB 自报 `arr.en`，六形状按预测量断言）。
- 三档数值逐字节 == 冻结黄金；两条负对照按预测量发火。
- 四条价格锚复现：MAC_TOTAL=344,224,000 / as_built=45,075,600 / impl_a=13,920,400 / dw 类=8,031,600。

**Modeled**
- 帧级 beats/fps（= 真表 67 单元几何 × 实测拍比；**整帧从未端到端跑过**，P0 §7-1 不变）。
- "dw 换成打包实计"的地板（AFTER2 6,171,162 / AFTER1 5,278,762 拍）与钟点（76.7 / 67.8 / 52.8 MHz）。
- 集成网表 Δ 预测（+317/+8 摊一个实例、+2,853/+72 摊九个）—— 探针是等价瘦身版，**不是集成实测**。

**Assumed**
- 产品改动落在"宽通路那一个切片实例"上（接口按 additive 口设计；若实现者加进 `Conv3x3Slice` 全体，
  代价按 ×9 计）。
- 数值等价性从"探针三档逐字节 == 黄金"外推到产品 RTL（实现后要重跑本闸门 + 既有闸门 —— 同 SliceA 口径）。

## B1-6 开口项（诚实的边界）

1. **本片零 RTL 改动**：所有 Δ 都是**探针**读数（B1-4 的集成读数预测**未实测**）。
2. 逐 lane x 选择器的**时序**未测（乘法器输入锥多一级）—— 实现片的 PnR 判据项。
3. `C`（块内取整，残差 1.279×）**仍未报价**；B1 之后它就是通往 10 fps 的唯一剩下的大项（spec §5 表序 4）。
4. 采集/写回侧的拍数未建模（宽通路喂列/收料是逐字节取、比计算慢 8× 的老问题，`UnitExec` 文件头明写）。
5. AFTER1 的"第 9 抽头行"是**新乘法器**（+8 APM/实例）：本片只测成本，**不判断**它是否该进 P4 的
   "两路合一"预算（那里 LUT/APM 是共用的）。

---

# Slice B1 收尾（verify / measure / account）：AFTER1 落 RTL 之后的复核与判词

- 日期：2026-10-16
- 上游：RTL commit `eab699a`（四处 additive 口 + 集成闸门 `tools/run_dwpack_ab.sh`）；§Slice B-1 的
  go 判词（`ΔLUT ≤1,000/实例 ∧ ΔAPM ≤8/实例 ∧ ΔDRM 0 ∧（10 fps 走 A+B1+C 且 npu_clk ≥53 MHz）`）。
- 本段只做**复核/测量/记账**：`y1/rtl/**`、`y1/tools/run_dwpack_ab.sh` 一字未动；无重设计。

**Status: BLOCKED（面积判据）—— `ΔLUT = +1,131 > 1,000`（超 +131 = 13%）。**
其余全部成立：字节闸门全绿、`TILING=false` 三网表逐字冻结、"只有三份 TILING=true 网表动"经独立树复证、
实测拍比 9.00×、两条负对照按预测量发火 + 外科式翻绿、fps 7.3733 逐位复现、`Adm-4088=0`、ΔAPM +4 ≤8、
ΔDRM 0；PnR 判词见 B1v-6。

## B1v-1 网表重生成 + 归因（"additive"从声明升级为**实测**）

从**当前源**重生成全部 22 个 `*Gen`（8 个结构性 Gen + 其余 13 个 + `DwLaneGen` 四档），记录 md5。
关键 md5：

| 网表 | md5 | 与 B1 前（`288f9b5`）比较 |
|:--|:--|:--|
| `gen/UnitExec.v` | `979129017535dc82ab9e6d89bea31080` | **逐字节不变**（冻结） |
| `gen/UnitExec_w32.v` | `618af3381eadcb4d7c6964cd4338a825` | **逐字节不变**（冻结） |
| `gen/UnitExec_w640.v` | `ddb9bb8addc01f94e2ea8ae8b6b898e6` | **逐字节不变**（冻结） |
| `gen/UnitExec_tiled.v` | `2b85b0b26af5e80563f60708200c0e76` | 变（2b2e067e→，= eab699a 绿证据同一值） |
| `gen/LayerSched.v` | `d81a6ebe6e0ae93e4ae808368741ac5e` | 变（74ecebbf→） |
| `gen/NpuTop.v` | `2dd28a8cdadbb15ef371676259d0cf6a` | 变（5ae64c30→） |
| `Conv3x3Slice{,_g4,_g8}.v` | `131a6594…` / `3c55fcf8…` / `ecdb69cc…` | **B1 前后逐字节相同**（见下"陈旧产物"） |
| `MacArray.v` / `WeightStore{,_g4,_g8}.v` / `GroupedMacArray{,_g2,_g4,_g8}.v` / `MultiPassUnit.v` / `DwUnit.v` | （见 gen，全部） | **逐字节不变** |
| 探针四份 `DwLaneBefore/After2/After1/After1Mut5.v` | `62ba43a8…` / `3bc55a82…` / `518691e0…` / `54371a15…` | 重生成只记账 |

**独立树归因实验（本段新增的证据）**：把 `288f9b5`（B1 之前的 HEAD~1）拉进**独立 worktree**
（`D:/code/PDS/vxy_wt_b1base`），用同一套 `*Gen` 重生成一遍，逐文件对比 ⇒ 44 份网表里**只有那三份
`TILING=true` 网表不同**；其余 41 份（含三份冻结网表、`Conv3x3Slice*`、`MacArray`、`WeightStore*`、
`GroupedMacArray*`、`MultiPassUnit`/`DwUnit`、DmaEngine、四桥……）**逐字节相同** ⇒ B1 的
"additive / 行数中性"**被独立复证**（不是自证）。

**顺带修掉的陈旧产物**：重生成前 `y1/gen/Conv3x3Slice{,_g4,_g8}.v` 还是**更早年代**的值（与 B1 无关：
B1 前后两份源在两个独立树里生成这三份**逐字节相同**）⇒ 本次把三份**刷新**到当前源的真值；消费它们的
三条数值闸门（dense / group=4 / dw，B1v-2）用新值全绿。

## B1v-2 字节闸门 + 全回归（本机现跑；`PY=lxvenv python`；`iverilog=/c/msys64/ucrt64/bin`）

| 闸门 | 结果 | 用时 | | 闸门 | 结果 | 用时 |
|:--|:--|--:|:-:|:--|:--|--:|
| `run_dwpack_ab.sh`（B1 集成闸门） | **PASS** | 266s | | `run_chain_ab.sh` | PASS | 44s |
| `run_dw_ab.sh` | PASS | 21s | | `run_chaingeom_ab.sh` | PASS | 33s |
| `run_dw_wide_ab.sh` | PASS | 628s | | `run_fuse_ab.sh` | PASS | 40s |
| `run_multipass_ab.sh`（13 形状+负对照） | PASS | 116s | | `run_x1skip_ab.sh` | PASS | 90s |
| `run_unitexec_wide_ab.sh` | PASS | 62s | | `run_psbound_ab.sh` | PASS | 7s |
| `run_unitexec_ab.sh` | PASS | 59s | | `run_sched_ab.sh` | PASS | 224s |
| `run_tiling2d_wide_ab.sh` | PASS | 1165s | | `run_nputop_sched_ab.sh` | PASS | 116s |
| `run_tiling2d_rtl_ab.sh` | PASS | 422s | | `run_mac_account_ab.sh` | PASS | 7s |
| `run_wgtblob_tiled_ab.sh` | PASS | 765s | | `run_preflight_ab.sh` | PASS | 2s |
| `run_dwlane_ab.sh`（B-1 探针闸门复跑） | PASS（9/2/1 拍） | — | | `run_wgtdma_ab.sh` | PASS | 301s |
| `run_numeric_ab.sh` dense/group=4/dw | 三档 JUDGE-GREEN | — | | `run_wgtdma_geom_ab.sh` | PASS | 709s |
| `run_weightstore_ab.sh`（三档） | JUDGE-GREEN | — | | `run_wgtdma_wide_ab.sh` | PASS | 212s |
| `run_grouped_ab.sh`（GROUP 1/2/4/8） | JUDGE-GREEN | — | | `check_dangling.py gen/*.v` | PASS（44/44 文件，0 悬空） | — |
| `run_macarray_ab.sh` | JUDGE-GREEN | — | | | | |

- `run_dwpack_ab.sh` 的重跑输出与已入库 `reports/npu_v2b1rtl_gate_green.txt` **逐字节相同**（diff 空）。
- 环境口径注记：`run_grouped_ab` / `run_macarray_ab` 在"iverilog 不在 PATH"的默认环境里 **rc=1**
  （日志明写 `找不到 iverilog`），`run_numeric_ab` 是**带参探针**（无参 rc=1 是预期）——三者都不是回归；
  本表读数 = 设 `PATH=/c/msys64/ucrt64/bin:$PATH` 后复跑（先例：`c4b_*` 报告的同一现象）。

## B1v-3 实测拍比 9.00×（TB 自报 `X1_BEATS`；六形状）与两条负对照 + 外科

| 形状 C | pos（1 拍/像素/趟） | BEFORE（掐 `dw_mode`，9 拍） | 拍比 | neg sel（预测/实测） | neg tap8（预测/实测） |
|--:|--:|--:|--:|:--|:--|
| 4 | 128（nCo=1） | 1152 | **9.00×** | 26/26 | 35/35 |
| 8 | 128 | 1152 | **9.00×** | 39/39 | 39/39 |
| 10 | 256（nCo=2） | 2304 | **9.00×** | 81/81 | 59/59 |
| 16 | 256 | 2304 | **9.00×** | 89/89 | 87/87 |
| 32 | 512（nCo=4） | 4608 | **9.00×** | 178/178 | 138/138 |
| 64 | 1024（nCo=8） | 9216 | **9.00×** | 263/263 | 352/352 |

- 六形状 DST 逐字节 == 冻结黄金；BEFORE 与 pos 的**整片 dump 逐字节相同**（7,864,320 B × 6）。
- 外科式（C=16，被换 lane 权重置 0）：同一 `sel` 突变网表翻绿（MISMATCH=0 = 预测量），拍数 256（预测 256）。
- **"firing negative + surgical"两件套 + BEFORE 对照 = 本段要求的第 4/5 项，全部现场跑出并逐条对账。**

## B1v-4 fps 重新签发（`tools/dw_lane_account.py`）：**7.3733 逐位复现，与模型无差异**

工具现跑（四条锚 `MAC_TOTAL=344,224,000` / `as_built=45,075,600` / `impl_a=13,920,400` / `dw 类=8,031,600`
全 PASS）：`A + dw AFTER1 = 6,781,200 拍 ⇒ **7.3733 fps @50 MHz**`（B-1 modeled **7.3733**，逐位相同——
**没有需要"调整模型"的分歧**）。其余臂：A = 13,920,400（3.5919）；A+AFTER2 = 7,673,600（6.5158）；
地板重算 AFTER1 → 5,278,762（9.4719）；10 fps 钟点：A+B1 ≥ **67.8 MHz**、AFTER1+C ≥ **52.8 MHz**。

## B1v-5 dev_map（integrated）：`Adm-4088 = 0`；**ΔLUT = +1,131 ⇒ 超预算**

命令（cwd = 仓库根）：`/c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl`
（两遍 exit=0）：B1 遍日志 `y1/pds/devmap_c4a_b1.log`（网表 `NpuTop.v 2dd28a8c…`）；
**同日本底遍** `y1/pds/devmap_c4a_b1base.log`（把 pre-B1 的 `NpuTop.v 5ae64c30…` 换回、其余一字不动后重跑，
跑完已还原 `2dd28a8c…`）。**基线为什么可信**：同日本底遍与今天 04:02 的 Slice A 日志
（`devmap_c4a_x1skip.log`）**逐数相同**（124,106 / 542 / 247.5）；且自 `8d784c9` 以来
`git diff -- y1/rtl/` 只有 B1 的六份 scala、非 NPU 网表（DmaEngine/四桥）重生成逐字节不变 ⇒ Δ 只可能来自
`NpuTop.v`。（`devmap_c4a.tcl` 自 Slice A 未改。）

| 资源 | 同日本底（B1 前） | **B1** | Δ | B-1 规则 | 判定 |
|:--|--:|--:|--:|:--|:--|
| LUT | 124,106 | **125,237** | **+1,131** | ≤1,000 | **FAIL（超 +131 = 13%）** |
| FF | 149,299 | 149,364 | +65 | （未设阈） | — |
| APM | 542 | **546** | **+4** | ≤8 | PASS |
| DRM | 247.5 / 415 | **247.5 / 415** | **0** | =0 | PASS |
| LUTs as dram | 7,872 | 7,872 | 0 | — | — |
| IO | 99 | 99 | 0 | — | — |
| `Adm-4088` | 0 | **0** | — | =0 | PASS |

- Mapping Summary 侧：B1 = LUT 125,238 / **as-logic 117,366** / regs 149,377；本底 = LUT 124,107 /
  as-logic 116,235 / regs 149,312 ⇒ **+1,131 全部落在 LUT-as-logic**（LUTRAM 与 DRM 零变化）。
- 与 B-1 探针预测的差距：探针 modeled **ΔLUT +317 / ΔAPM +8**；集成实测 **+1,131 / +4**
  （LUT 是探针模型的 3.6×、APM 比模型低 4）。**原因未逐单元归因**（探针是等价瘦身版 4,184 LUT vs 真切片
  ~6,202 LUT —— 这句只是解释方向，**不是实测**）。这不是"×9 最坏情形"（+2,853），仍是单实例当量。
- 量级备注（不粉饰）：器件**装得下**（125,237/159,800 = 78.4%，余 34,563 LUT）；超的是 B-1 钉死的价签，
  不是器件上限。

## B1v-6 PnR 时序（`YESHENMINI_SYNTH_MODE=speed`）

- **本轮定稿时仍在跑**（截至本段提交）：命令
  `YESHENMINI_PNR_TAG=b1 YESHENMINI_SYNTH_MODE=speed pds_shell -file y1/pds/pnr_c4a.tcl`（cwd = 仓库根），
  工程目录 `sim/reglogs/pds_pnr_c4a_b1_p10.000/`，日志 `y1/pds/pnr_c4a_b1.log`（入口 B：从零
  compile→synthesize(speed)→dev_map→pnr(4 seeds)→report_timing→比特流；判据 = `All Constraints Met`
  + `YESHENMINI_PNR_C4A_DONE` + 比特流存在）。
- 已确认：PnR 自己在 compile 阶段吃进去的就是 **B1 网表**（日志 `Elaborating module Conv3x3Slice_1
  (line number: 86989)` 与 `2dd28a8c…` 的行号对得上）。
- 参照系：Slice A/§3.7 的 PnR 读数 = `npu_clk` **54.142 MHz**（50 MHz 约束 +1.530 ns）；10 fps 的
  A+B1+C 路径需要 **≥52.8 MHz**。
- 判词：**见本节的下一版（定稿时插入：All Constraints Met 与否 + 实测周期/fmax vs 54.14 / 52.8）。**

## B1v-7 数字分类（measured / modeled / assumed）与判词

**Measured**
- 全部 44 份网表 md5（22 个 Gen 重生成）；**独立树差分**：B1 只动三份 `TILING=true` 网表，其余逐字节同。
- 27 道闸门/判据本机现跑全绿（B1v-2 表）；`check_dangling` 44/44 文件 0 悬空。
- `run_dwpack_ab.sh` 重跑 == 已入库绿证据（逐字节）；拍比 9.00× ×六形状；两条负对照按预测量发火 + 外科翻绿。
- fps 四条锚 + 7.3733（工具现跑）。
- dev_map 全表两遍（B1 / 同日本底）：**ΔLUT +1,131 / ΔAPM +4 / ΔDRM 0 / Adm-4088=0**。

**Modeled**
- 帧级 beats/fps（真表 67 单元几何 × 实测拍比；整帧从未端到端跑过，P0 §7-1 不变）。
- `+1,131` 的**归因解释**（dw 逐 lane 2:1 + 第 9 抽头行 + dw 读口在真切片/集成上下文里的综合代价）
  —— 方向性说法，**未做逐单元实测归因**。

**Assumed**
- 面积口径：integrated dev_map（同一 tcl/器件/约束）的 Δ 与 B-1 "一个实例" 假设对应（只有宽通路的
  `MultiPassUnit.sl` 带 dw 口）。
- dwpack 的 6 形状/几何（H=8,W=16）对真表全部 dw 单元的代表性（与 B-1 探针同一形状表）。

**判词：BLOCKED（面积判据）**
- 触发项 = B-1 go 条件的 LUT 预算：**实测 +1,131 > 1,000**（超 13%）。其余条件（ΔAPM ≤8、ΔDRM=0、
  `Adm-4088=0`、PnR ≥52.8 MHz —— 见 B1v-6）分别成立/待判。
- 后果（清晰化）：B-1 的"有条件 go（AFTER1）"**条件不成立**；本 slice 以 BLOCKED 结项。
  **改法（降 LUT 的替代实现）属重设计，本段按纪律不做** —— 交给下一片决策。

## B1v-8 开口项（诚实边界）

1. **B1v-6 的 PnR 定稿**（本段提交时仍在跑；若 PnR 也不再闭合，则叠加一条 decision-changing 结论）。
2. **+1,131 的逐单元归因未做**（哪个模块吃掉多少 LUT/FF）；探针模型 +317 与集成实测 +1,131 的差距
   只有方向性解释。
3. 采集/喂列速率未测（承接 B1-6 开口项 4）。
4. `C`（块内取整）仍未报价（承接 B1-6 开口项 3；它是 A+B1 之后通往 10 fps 的最大项）。

---
---

# Slice C-1：**残差（ci-pad / 尾块）的可回收性与价格 —— dense ci-inner 的接口钉死 + 实测**（spec §5 表序 4；**设计+测量片，不改产品 RTL**）

- 日期：2026-10-16
- 交付物：逐层价签工具 `tools/c_tail_account.py`（绿证据 `reports/npu_v2c1_account_green.txt`）+ 探针
  `rtl_test/CiPackProbe.scala` / `rtl_test/CiPackGen.scala` / 装置 `rtl_test/CiPackTb.v` / 闸门
  `tools/run_cipack_ab.sh`（绿证据 `reports/npu_v2c1_gate_green.txt`）+ `pds/devmap_cipack.tcl`（两档日志入库）。
- **不动清单（本片纪律）**：`y1/rtl/**` **零改动**（探针与装置都在 `rtl_test/` 下，独立网表、独立闸门）；
  `gen/` 只**新增**三个探针网表（`CiPackBase/Dci/DciMut5.v`，与既有产物零冲突）；
  全部冻结参考（`conv_unit_ref.py`/`tiling_ref.py`/`multipass_ref.py`/`bypass_ref.py`/`bypass_traffic.py`/
  `ddr_traffic.py`/`fusion_buffer.py`/`mac_ref.py`/`chain_wide_ref.py`）**零改动**（只**调用**）；
  `desc_table.py` 与其它切片的 `gen/` 输出**零改动**。
- 上游：spec §5 表序 4、§P0b-4（残差 1.279×）、§Slice B-1/B1v（B1 的 go 条件与 BLOCKED）、`tools/dw_lane_account.py`
  （地板 5,278,762.5）。

**Status: DONE（可达项钉死 + 实测价签；结论 = **对 DCI 单项 go（有实测价签）**，但 **"C 在现钟下过 10 fps" = no-go**：
残差里 90.7% 可回收（实测 3.00×/9.00×），可回收部分落地后 10 fps 仍要 **≥54.18 MHz** > 实测 **52.6704 MHz**；
差的那 150,960 拍恰是**不可现表达**的 1×1 co 尾块）**

## C1-0 一句话

A+B1 的残差 **1,502,437.5 拍**（= A+B1 6,781,200 − 地板 5,278,762.5，本片逐层复算**零遗漏**）由三块组成，
但只有两块是"真能动的"：

| 块 | 拍 | 机制（本片逐行复原的判词） | 可回收性 |
|:--|--:|:--|:--|
| `Conv_0`（`C_in=3` 补位）| 1,152,000 | **拍序**：tap-major 下 ci 是 lane（3/8 有用），9 个 tap 拍照付 | **可回收**（DCI，本片探针） |
| 六片 `1→1 3×3`（`C=1`）| 148,837.5 | 同上（一拍 64 槽 9 个有用乘） | **可回收**（同一张网表） |
| 1×1 co 尾块（`C_out∈{1,4,10}`，12 单元）| 201,600 | **ceil(C_out/8) 的整趟取整**（一个只装 1/4/2 行的趟照付 `nCi·H·W` 拍）| **不可现表达**（要跨单元 co 打包或跨像素行打包） |
| dw 尾块（`C=4/10`，6 单元）| **0** | AFTER1 后一趟服务整个 co-block ⇒ 空闲行**不额外吃拍** | 不需要（免费，**正例**） |

**DCI（dense ci-inner）实测**：真表 `Conv_0` 拍比 **3.00×**（9→3）、真表 `1→1` **9.00×**（9→1）、
数值在 Base/Dci 两档**逐字节 == 黄金**（双实现互证）+ 三组对照（GARB / tap-8 切除 / 路由突变）全按预测量发火；
价签（探针 dev_map，同源同器件）：**ΔLUT +920 / ΔFF 0 / ΔDRM 0 / ΔAPM −4**（另有 p8 A 级寄存纪律 +152，合计
**+1,072/切片当量**）。
**修正后的 10 fps 算术**：A+B1+DCI = **5,418,000 拍 ⇒ 需 ≥54.18 MHz**；实测 PnR 上限 **52.6704 MHz** ⇒ 9.7214 fps。
把**不可现表达**的 1×1 co 尾块也算进来（5,216,400 拍 ⇒ 52.16 MHz）才闭合 —— 所以 C 的正确判词是
**go（DCI 单项，价签实测）/ no-go（"C 单独把 10 fps 拉进现钟"）**，10 fps 仍要时钟或 co 打包那条线。

## C1-1 现几何处理（**file:line 复原**；"真 waste"与"空闲 lane"分开）

| 环 | 在哪 | 逐字口径 |
|:--|:--|:--|
| ci 分块 | `rtl/UnitExec.scala:952` `nCi=ceil(C_in/8)`；`:956` `nCo=ceil(C_out/8)` | **趟数取整是唯一"多出整趟"的来源**（两个维度都算） |
| 趟序 | `:2157-2163`（下一趟 = `(wCob+1, wCi)` 循环）；`:1804` `wPassIdx=wCob*nCi+wCi`；`:2721` `wide_passes` | dense = `nCi*nCo` 趟；dw = 对角 `nCo` 趟 |
| ci 零填 | `:974-975` `wzNeedW`（`C_in%8`/`C_out%8`/`GROUP` 三类）；`:968` `wzEnd=nCi*nCo*576`；`:1073/1079-1082` 零填充写口 | 装 `wRam` 前先逐字节清 0：`cil ∈ [C_in%8, 8)`、`cl ∈ [C_out%8, 8)`、跨组位置全 0 |
| 落点 | `:1049-1056`（映射式）+ `:1067-1069` `wlWideDest` | `pass*576 + cl*72 + cil*9 + tap` —— **权重瓦片 8×8×9，补位/空行都在瓦片内** |
| 尾块出料 | `:1455-1467` `wideCoRows = C_out`（**不是** `nCo*8`）、`wideWrBytes/Words`；收料门 `:1845-1847` | 末 co-block 是**部分尾块**：只写前 `C_out` 行（C4b-C1 已支持） |
| x 广播 | `rtl/Conv3x3Slice.scala:405-411` `arrX(ci)=colWin(tapKx)(ci)(tapKy)`、`arr.en` = ph=1..9 | **每像素恒 9 个 tap 拍**（与核/通道数无关）；ci 是 lane ⇒ `C_in=3` 时 5 条空转 |
| 喂列 | `rtl/UnitExec.scala:1613` `xSrcCol`、`:1789` `mpu.io.x := wXCol` | 一拍一列 = 本 ci-block 的 8 通道（`C_in=3` 的补位通道由 gather 侧无源、权重零填兜底） |
| 权瓦片读 | `rtl/WeightStore.scala:80-95`（dense 每个 (co,ci) 一个 9 选 1）；`:113-121`（B1 的 dw 对角口） | dense 读按 `k`（tap）选；dw 口按静态下标 |

**"哪一部分是真 waste"（本片的关键判词）**：

1. **co 尾块（`C_out%8≠0`）= 真多付拍**：`nCo=ceil(C_out/8)` 把 1/4/2 行装进一个**整趟**——该趟的
   `nCi·H·W` 拍**照付**（1×1 的 A 档 = 1 拍/像素/趟）。12 个单元合计 **201,600 拍**是**凭空多出来的**。
   单元级证据：`Conv_72`（64→10，2 趟）第 2 趟只服务 2 个通道却付 `8×6400 = 51,200` 拍；
   "值得的"只有 `8×6400×2/8 = 12,800` ⇒ 每单元多付 38,400。
2. **ci 补位（`Conv_0`，`C_in=3`）= 不是多出整趟，是拍序错配**：`nCi=1` 恰好整块，9 个 tap 拍的**拍数
   与"满 8 通道 dense"一字不差** ⇒ 严格按"issued 拍"看，它**没有**比 8 通道 dense 多付一拍；
   浪费在"每拍只有 3/8 条 ci lane 有用"。⇒ 要回收**只能换拍序**（ci 进拍、tap 进 lane = 本片 DCI），
   **不是**"补 5 条 lane"能省出来的。六片 `1→1 3×3` 同一条。
3. **dw 尾块 = 空闲 lane 免费的正例**：AFTER1 的 1 拍/像素/趟一趟服务整个 co-block（`C=10` 的尾块
   2 行、`C=4` 的 4 行都在**同一拍**里）⇒ 相对地板（dw 按 `nCo·H·W` 计）残差 = **0**。这是本项目
   "空闲 lane ≠ 浪费"的锚：**先问它有没有多出拍，再算价签**。
4. **另一条已免费的**：`C_in=3` 的 5 条补位 lane 上喂**任意垃圾**都不影响输出（证明：GARB 档，
   权重零填兜底）—— 补位 lane 的"数据源"不需要任何工程。

## C1-2 逐层残差价签（`tools/c_tail_account.py`；A+B1 实计 − 地板，**零遗漏对账**）

口径：`delta(单元) = beats_A+B1 − floor`，`floor` = 非 dw 按 `MACs/64`、dw 按 `nCo·H·W`（= `dw_lane_account.py`
的 FLOOR 逐位同值）。全表只列非零行（合计 **1,502,437.5** == 残差）：

| idx | 单元 | 真几何 | H×W | 趟 | beats_AB1 | 地板 | delta | 机制 |
|--:|:--|:--|:--|--:|--:|--:|--:|:--|
| 0 | `Conv_0` | 3→16 3×3 s2 | 320×320 | 2 | 1,843,200 | 691,200 | **1,152,000** | ci-pad（拍序）|
| 38/50 | `Conv_55/67` | 1→1 3×3 | 80×80 | 1 | 各 57,600 | 900 | 各 **56,700** | 拍序 |
| 37/49 | `Conv_54/66` | 64→1 1×1 | 80×80 | 8 | 各 51,200 | 6,400 | 各 **44,800** | co 尾块 |
| 55 | `Conv_72` | 64→10 1×1 | 80×80 | 16 | 102,400 | 64,000 | **38,400** | co 尾块 |
| 43 | `Conv_60` | 64→4 1×1 | 80×80 | 8 | 51,200 | 25,600 | **25,600** | co 尾块 |
| 40/52 | `Conv_57/69` | 1→1 3×3 | 40×40 | 1 | 各 14,400 | 225 | 各 **14,175** | 拍序 |
| 39/51 | `Conv_56/68` | 64→1 1×1 | 40×40 | 8 | 各 12,800 | 1,600 | 各 **11,200** | co 尾块 |
| 57 | `Conv_74` | 64→10 1×1 | 40×40 | 16 | 25,600 | 16,000 | **9,600** | co 尾块 |
| 45 | `Conv_62` | 64→4 1×1 | 40×40 | 8 | 12,800 | 6,400 | **6,400** | co 尾块 |
| 42/54 | `Conv_59/71` | 1→1 3×3 | 20×20 | 1 | 各 3,600 | 56.25 | 各 **3,543.75** | 拍序 |
| 41/53 | `Conv_58/70` | 64→1 1×1 | 20×20 | 8 | 各 3,200 | 400 | 各 **2,800** | co 尾块 |
| 59 | `Conv_76` | 64→10 1×1 | 20×20 | 16 | 6,400 | 4,000 | **2,400** | co 尾块 |
| 47 | `Conv_64` | 64→4 1×1 | 20×20 | 8 | 3,200 | 1,600 | **1,600** | co 尾块 |
| （其余 40 个单元：1×1 满块 = 恰好理想；dw 满块/尾块 = `nCo·H·W`）| | | | | | | **0** | — |

**分账**：co 尾块（1×1，12 单元）**201,600**；ci-pad/拍序（`Conv_0` + 六片 `C=1`）**1,300,837.5**（其中
`Conv_0` 1,152,000 + 六片 148,837.5）；dw 空闲行 **0**。**合计 1,502,437.5 == A+B1 − 地板** ✅
（工具内两条 CHECK：逐层求和 == 残差；`Conv_0`/六片/dw 三组分别对锚）。

## C1-3 钉死的接口（DCI = "ci 进拍、tap 进 lane"）与**不可现表达**的项

**可回收的那一块（1,363,200 拍）钉成一条 additive 档（只 `TILING=true` 展开，同 `one_x1`/`dw_mode` 接线法）**：

1. `Conv3x3Slice` +`dci_mode`（入）与 `c3_cin`（入，4 bit；本片覆盖 `C_in ≤ 4`，真表只需 {3,1}）：
   像素相位 `9 → C_in` 拍（`dci_mode=1` 时 `tapMax = c3_cin`）；x 操作数逐 lane 从"通道 r"改成
   **"当前 ci 拍号"**：`xLane(r,j) = colWin(j%3)(ci_b)(j/3)`（`(kx,ky)` 仍静态、只多一条 ci 索引的 4:1 读）；
   第 9 抽头仍吃 `x8/w8`（AFTER1 那一行，reuse）。
2. `WeightStore` +`c3_ci`（入，2 bit）+`c3Tile/c3Tile8`（出）：`c3Tile(r)(j) = mem[r*72 + c3_ci*9 + j]` ——
   **瓦片内部**（`Conv_0` 的 `cil∈[3,8)` 由装载器零填）⇒ **blob / 装载器 / 描述符 / arena 零改动**。
3. `MultiPassUnit`：两口透传（同 `dw_mode` 手法）；`UnitExec`：`go` 那拍由描述符闩
   `isDciW = 宽路 ∧ dense ∧ GROUP==1 ∧ nCi==1 ∧ 0<C_in≤4`，一行接进 `mpu`（`laneSel = isDwW || isDciW`）。
4. ★★ **本片实测发现的接口补丁（不是可选项，是正确性前提）**：`MacArray` 的第 9 抽头行
   `p8 = x8·w8` 是**组合**进 B 级（`rtl/MacArray.scala:128-129`），而 B 级用的是**上一拍**锁存的
   `ps` ⇒ 单拍静态档（AFTER1 的 dw，`x8/w8` 是常数）看不出来，**多拍档（每拍换 ci）会错位**：
   实测 tap-8 单抽头作业在 DCI 档输出 0（Base 档正确）。⇒ 钉死：**`p8` 必须与 `ps` 同纪律进 A 级寄存器**
   （`en` 锁存、`clr` 清零；dw 档静态值逐位不变）。探针里已按此实现（价签含它：见 C1-5）。
5. 数值等价：整数加法重排（每个 ci 拍 9 个抽头并进同一 acc；≤ 9,363,456 的界不变），
   requant/bias/ps/出料一字未动 ⇒ **两档逐字节 == 黄金**（C1-4）。

**不可现表达的两条（本片给结构判词，不给价签）**：

- **1×1 co 尾块 201,600 拍**。两条回收路都撞口径：
  (i) **跨单元 co 打包**：`Conv_54/60/66/72` 的 SRC 同址（`SRC=0x01b3e800`，四个分支吃同一张 64×80×80 特征图），
  co 合计 1+4+1+10=16 = **恰好 2 个满块** ⇒ 语义上可行；但 8 字描述符只带**一段权重 + 一个 DST**（装载器
  按"表序前缀和"取段、WR 相位按一个 `DST` 出料）⇒ 要 **多段权重 + 逐 co-block DST** 的表/装载/写回三处改动，
  **现口径装不下**（属 P2 类改动能顺带解决的面）。
  (ii) **跨像素行打包**（行 = 像素、列 = 抽头）：要 10 列窗口（现 `colWin` 只有 3 列）+ 出料侧
  `[co][像素]` 转置写口径 ⇒ 窗口/边缘/写回三处重做 —— 是 P4 量级，不是探针能便宜定价的。
- **dw 尾块跨像素**（理论 10,500 拍）：同一机制（同 (ii)）。
- 旁证：`chain_1x1` 位在 `TILING` 档存在（`rtl/UnitExec.scala:472`），但**产品里没有功能读者**：
  唯一用途是 `:2770` 对 `desc TYPE` 的**一致性断言**（1×1 的权威真源 = `TYPE==0x02`，`:2855-2862` 明写）；
  A2 又已把宽 run 全部拆成 `plain`（`chainLen==1`）⇒ "把尾块并进下个单元的链头"这条路**今天没有落点**。

## C1-4 实测装置（探针 + 闸门；`tools/run_cipack_ab.sh`，绿证据入库）

- 装置 = `rtl_test/CiPackTb.v` + 三份探针网表（**一份 TB、三份网表各编一份**；Base 用 `-DBASE`）；
  向量/黄金 = 闸门 inline python **现算**，黄金由**第二实现**（冻结 `tools/wide_exec_ref.py` 的 `conv_acc`）互证；
  作业全部用**真表权重**：`Conv_0`（3→16，2 趟）/ `Conv_67`（1→1）+ 冻结 `multipass_ref.build_one(8,8,8)`（dw）。
- 判据（全绿，2× 逐行确定性）：
  1. 正对照：每作业 Base 与 Dci **各自 MISMATCH=0**（对黄金）且两档 Y **逐字节互等**；
  2. 拍数**实测**：`Conv_0` Base 1152 → Dci **384（3.00×）**；`1→1` Base 576 → Dci **64（9.00×）**；
     dw8 两档 32 拍（1 拍/像素/趟，B1 的档没被 C 碰坏）；
  3. **补位 lane 免费**：lane ≥ `C_in` 喂**确定性垃圾** ⇒ 两档仍 == 黄金（权重零填负责）；
  4. 负对照 A（tap-8 切除）：两档 MISMATCH **恰 == python 预测**（5 / 3）⇒ 第 9 抽头行承重；
  5. 负对照 B（c3 lane 5 路由改错）+ 外科式：突变网表 MISMATCH **恰 == 预测**（6 / 44），
     且突变输出 **== `gold_mut` 逐字节**（正规网表同作业 == 0）⇒ 红是 c3 路由造成的；
  6. dw 档回归：dw8 作业在 Base 与 Dci 两档都 **== 冻结 `multipass_ref` 黄金**。
- 附带修掉的两个**夹具级**缺陷（记一笔，防后来者踩）：黄金的 `bias` 是 **int32**（2 位十六进制会把
  `-14255` 截成 `0x51`）；pad 行（`row==H`）不能被 GARB 污染。

## C1-5 dev_map（探针，同源同器件；`pds/devmap_cipack_{base,dci}.log` 入库，2× 逐行确定性）

| 档 | LUT | LUT-as-dram | FF | DRM | APM | IO |
|:--|--:|--:|--:|--:|--:|--:|
| Base（B1 当量 + p8 A 级纪律）| 4,653 | 0 | 6,601 | 0 | 72.00 | 502 |
| **Dci（Base + c3 ci-inner）** | **5,573** | 0 | 6,601 | 0 | **68.00** | 507 |
| Δ（Dci − Base）= **c3 的实测增量** | **+920** | 0 | **0** | **0** | **−4** | +5 |

- 交叉锚：`DwLaneAfter1`（B1 落地档）= 4,501 ⇒ **Base − AFTER1 = +152 LUT**（= p8 的 A 级寄存纪律
  + `MacArray` 的 `Mux(dw_mode, p8r, 0)` 门；FF 不变）⇒ **C 的总价签（切片当量）≈ +1,072 LUT**
  （= 152 + 920：**实测**，两档读数之差；未做逐单元归因）。
- 摊到集成（**modeled**，用 B1 的探针→集成比例 1,131/317 ≈ 3.57× 作先验）：≈ **+3,830 LUT** ⇒
  LUT 125,237 → ≈129,1k（/159,800，余量 34,563 吃掉 ~11%）；APM 546 不变量级（探针 ΔAPM 是 **−4**）。
  ★ 这个 3.57× 是**弱先验**（B1 的 Δ 是另一条路），实现片**必须**重测集成 Δ。
- `Adm-4088 = 0`（两档日志 grep 计数 0）；DRC 只有裸探针的 IO 超限（502/507 > 400，先例同 B-1）。

## C1-6 修正后的 10 fps 算术与 **go / no-go**

锚：**实测** PnR（B1 网表，`All Constraints Met`）= **52.6704 MHz**
（`sim/reglogs/pds_pnr_c4a_b1_p10.000/prj_tasks/pnr_1/place_route/report_timing/*.rtr` 的 Performance
Summary：requested 50 / estimated **52.6704** / slack +1.014 ns）。10 fps 预算 = 52.6704 ÷ 10 =
**beats ≤ 5,267,040**。

| 臂 | beats | clk@10fps | @52.6704 MHz | 口径 |
|:--|--:|--:|--:|:--|
| A+B1（已落 RTL）| 6,781,200 | 67.8 MHz | 7.77 fps | modeled（实测拍比×真表几何）/ B1v-4 |
| **A+B1+DCI（本片探针）** | **5,418,000** | **54.18 MHz** | **9.72 fps** | modeled（探针实测拍比 3.00×/9.00×） |
| A+B1+DCI+1×1 co 尾块 | 5,216,400 | 52.16 MHz | **10.10 fps** | 后项**不可现表达** |
| 地板（dw_lane_account）| 5,278,762.5 | 52.79 MHz | 9.98 fps | 连地板都在实测钟**之上**（0.22%）|

**判词（两条，分别可执行）**：

- **go（DCI 单项）**：价签**实测**（+920 探针 / +1,072 含 p8 纪律 / 拍比 3.00× 与 9.00×，两档对黄金逐字节）；
  决策规则 = **ΔLUT(探针) ≤ 2,000 ∧ ΔDRM = 0 ∧ 拍比实测 == 预测 ∧ 两档 Y 逐字节互等** —— 全过。
  ★ 实现片**必须**补三条：集成 ΔLUT（3.57× 只是先验）、`TILING=false` 三网表逐字节冻结、
  **重跑 PnR**（c3 的 4:1 读与模式选择器落在**乘法器输入锥**上——与 B1 同一条锥）。
- **no-go（"C 单独把 10 fps 拉进现钟"）**：DCI 后仍需 **54.18 MHz > 52.6704**；缺的 **150,960 拍**
  恰落在**不可现表达**的 1×1 co 尾块（201,600）里 ⇒ 10 fps 在现钟下**要**：① 时钟 ≥54.2 MHz（+2.9%，
  需一次 PnR 运气）**或** ② DCI + co 尾块（需表/装载/写回三处口径改动）**或** ③ 再削 25% 的 dw 真空闲
  （跨像素，P4 量级）。**不要把 5,278,762.5 的"地板"当成可达**——它假设 1×1 尾块被**免费**修掉，
  而那条路今天没有口径落点（C1-3）。

## C1-7 数字分类（measured / modeled / assumed，先例 = P0-6 / P0b-7 / SliceA-5 / B1v-7）

**Measured**
- 探针闸门全套（拍比 3.00×/9.00×、两档对黄金逐字节、GARB、两条负对照按预测量发火 + 外科式
  `gold_mut` 逐字节、dw8 对冻结黄金）；闸门 2× 逐行确定性。
- `tools/c_tail_account.py` 现跑：四条 P0/SliceA 锚 + `A+B1=6,781,200` + `FLOOR=5,278,762.5` +
  残差 **1,502,437.5** 逐层零遗漏对账；`Conv_0` DCI 复算 1,228,800 / 六片 `C=1` 134,400 / co 尾块 201,600。
- dev_map 全表两档（Base 4,653 / Dci 5,573）+ 2× 逐行确定性；`DwLaneAfter1` 4,501 交叉锚。
- PnR 实测 52.6704 MHz（.rtr Performance Summary 原文；`All Constraints Met`）。

**Modeled**
- 帧级 beats/fps（真表 67 单元几何 × 实测拍比；**整帧从未端到端跑过**，P0 §7-1 不变）。
- C 的**集成** ΔLUT ≈ +3,830（3.57× 比例先验 + 探针读数）；`Conv_0` 的 DCI 收益中"72 MAC/拍 overshoot"
  的 76,800 拍（= 1,228,800 − 1,152,000）是算术外推，不是独立测量。
- "1×1 co 尾块跨像素/跨单元可回收 201,600"（机制推理 + SRC 同址实测；**没有**实现/没有探针）。

**Assumed**
- 探针 `pad_val = 0`（真 `Conv_0` 的 `z_pad = -128`；z_pad 投递是 `UnitExec` 的路，C 不碰它）；
- `C_in ≤ 4` 是 DCI 的钉死域（真表 {3,1}；`C_in ∈ 5..7` 的 dense 真表**不存在**）；
- 集成价签的 3.57× 先验（实现片必须重测）；探针形状 (H=8, IW=8) 对真表的代表性。

## C1-8 开口项（诚实的边界）

1. **集成 ΔLUT 未测**（探针 ≠ 集成；B1 的 317→1,131 就是前例）——实现片的第一条判据。
2. **时序未测**：c3 的逐 lane 4:1 读 + 模式选择器在乘法器输入锥上；**必须重跑 PnR**，
   且同一次 PnR 是"10 fps 要 ≥54.18 MHz"这句话的最终裁判。
3. **1×1 co 尾块（201,600）无价签**：两条回收路都不在现口径里（C1-3 明写缺什么）。
4. **p8 的 A 级寄存纪律**会同时改进产品 `MacArray`（B1 已落的 dw 档逐位不变）——但本片**没改产品 RTL**，
   实现片要把这条写进它的改动清单（否则 DCI 多拍档**静默错值**）。
5. 探针未覆盖：`C_out%8≠0` 的 dense 尾块（真表 dense 无此形状）、`nCi≥2` 的 dense（真表无）、
   c3 与 1×1 跳拍同层（互斥）。
6. 采集/喂列速率未建模（承接 B1-6 开口项 4）；墙钟（每像素 1 收列 + C_in 拍 + 1 出数）仍是**注记**。

---

# Slice C-2：**DCI（ci-inner）落进产品 RTL 的验证与结账**（spec §5 表序 4 的落地片；**verify / measure / account**）

- 日期：2026-10-16
- 上游：RTL 落码 + 全量重生成 commit `27b7c58`（p8r 的 A 级寄存纪律 + 四处 additive 口）；集成闸门 commit `8a2d1ce`
  （`tools/run_dci_ab.sh`，绿证据 `reports/npu_v2c2_gate_green.txt`）。本片**零 RTL 改动**。
- 交付物：本节；`reports/npu_v2c2_dwpack_gate_green.txt`（重锚后的 B1 闸门绿证据，2× 逐行确定）；`pds/devmap_c4a_c2.log`
  （integrated dev_map 现跑，退出 0）。唯一工具侧改动 = `tools/run_dwpack_ab.sh` 两处**文本锚重锚**（见 C2-3）。
- **不动清单**：`y1/rtl/**` 本片零改动；九件冻结参考（`conv_unit_ref.py`/`tiling_ref.py`/`multipass_ref.py`/`bypass_ref.py`/
  `bypass_traffic.py`/`ddr_traffic.py`/`fusion_buffer.py`/`mac_ref.py`/`chain_wide_ref.py`）零改动；`desc_table.py`、
  `PartialSumBuf.scala` 未触；`third_party/**` 只读；描述符格式未动。

**Status: DONE（面积 go 条件过：集成 ΔLUT +991 ≤ 2,000；`Adm-4088 = 0`；ΔDRM = 0）**
器件余量 126,228/159,800 = **79.0%**（余 33,572 LUT）。B1 的历史 BLOCKED（+1,131 > 1,000）不因本片消失 ——
含 C2 的**累计**增量见 C2-5；时序裁判（c3 的 4:1 读/模式选择器在乘法器输入锥上）留给**下一轮 PnR**，本片按纪律不跑。

## C2-0 一句话

DCI 从探针进产品网表后：**实测拍比 3.00×（真 `Conv_0`）/ 9.00×（DCI 机制口径：合成 1→8 dense）**、四个作业
（真 `Conv_0` / 真 `Conv_55` / 合成 1→8 / tap8）**逐字节 == 冻结参考**、`p8r` 的受控 A/B 与 c3 路由负对照按预测量
发火 + 外科式翻绿、A/B1/C2 三条通路在同一张网表上互证、`TILING=false` 三网表逐字节冻结、**集成 ΔLUT +991
（≤2,000）/ ΔDRM 0 / `Adm-4088=0`** ⇒ **go（DCI 单项，集成价签实测）**。项目位置修正为
**A+B1+DCI = 5,418,000 拍 ⇒ ≥54.18 MHz**（承 B1 轮实测 PnR 上限 52.6704 MHz ⇒ 建模 **9.72 fps**）。

## C2-1 集成闸门复跑（`tools/run_dci_ab.sh`；本机现跑 2 遍；入库绿证据 = `reports/npu_v2c2_gate_green.txt`）

- 第 1 遍（现跑）：`RESULT: PASS`，106s；第 2 遍与已入库绿证据 diff = **仅 mktemp 目录名 3 行**（数据行逐字节同）⇒ 2× 逐行确定性。
- 尾部判词（现跑原文）：
  - 正对照（产品网表 `gen/UnitExec_tiled.v`，md5 `76450464…`）：`c0`（真 `Conv_0`）`X1_BEATS=384` / `MISMATCH=0`；
    `c1`（真 `Conv_55`）128 / 0；`x18`（合成 1→8）128 / 0；`tap8` 128 / 0 —— 全部 == 冻结参考（双实现互证）。
  - **实测拍比（DCI 关的受控突变 `_zz_dci_mode <= 1'b0`）**：`c0` 1152 → **384（3.00×）**；`x18` 1152 → **128（9.00×）**；
    两档**整片 dump 逐字节相同**（拍序重排不改数值）。
  - **c1 的实测边界**（承 C-1 建模修正）：DCI 关（dw 开）128 == DCI 开 128；dw+DCI 双关 1152 ⇒ **dw 谓词先收**；
    三档 dump 全等 ⇒ dense/dw/c3 同一作业数值一致。
  - **N1（p8r 的受控 A/B）**：B 级第 9 抽头改回组合积 ⇒ `tap8` `MISMATCH=94`（== 预测量 `#(gold_tap8≠gold_bias)`）
    且 dump == bias-only 黄金；正规网表 == 0 ⇒ `p8r` 的 A 级纪律**必要且充分**。
  - **N2（c3 路由改错）+ 外科式**：lane 4 改读 lane 5 瓦片 ⇒ `lane45` `MISMATCH=90`（== 预测量）且 dump == `gold_mut`；
    槽 5 := 槽 4（一个权重字节）⇒ 翻绿（`MISMATCH=0`）⇒ 红↔绿只由该字节造成。
  - 前置重扫：DCI 定义域 = 7 个真单元（`Conv_0` + 六片 `1→1`）；`TYPE==2` 单元 26 个、`C_in` 全 > 4 ⇒
    **DCI 与 1×1 跳拍在真表上互斥**（未覆盖组合，见 C2-9）。

## C2-2 字节闸门套件 + 组合检查（A / B1 / C2；本机现跑）

| 闸门 | 网表 | 结果 | 用时 | 备注 |
|:--|:--|:--|--:|:--|
| `run_dci_ab.sh`（C2） | `UnitExec_tiled` | PASS | 106s | 3.00×/9.00×；正/负/外科全按预测量 |
| `run_x1skip_ab.sh`（A） | `UnitExec_tiled` | PASS | 98s | 非 tiled 2304→256、tiled 3240→360（9.00×）；负对照 57；突变回 2304 且 dump 逐字节不变 |
| `run_dwpack_ab.sh`（B1，**重锚**） | `UnitExec_tiled` | PASS | 320s | 六形状 1 拍/像素/趟 + 逐字节 == 冻结黄金；BEFORE 9.00×；负对照按预测发火（见 C2-3） |
| `run_unitexec_ab.sh` | `UnitExec.v`（冻结） | PASS | 58s | 多作业 + 负对照 |
| `run_unitexec_wide_ab.sh` | `UnitExec.v`（冻结） | PASS | 63s | |
| `run_multipass_ab.sh` | `MultiPassUnit.v`（冻结） | PASS | 135s | 13 宽形状 + 负对照 |
| `run_dw_ab.sh` | `DwUnit.v`（冻结链） | PASS | 22s | 窄 dw 三档 |
| `run_dw_wide_ab.sh` | `UnitExec.v`（冻结） | PASS | 664s | 宽路 dw 对角 |
| `run_tiling2d_wide_ab.sh` | `UnitExec_tiled` | PASS | 1522s | 宽路 tiling + 负对照 |
| `run_tiling2d_rtl_ab.sh` | `UnitExec_tiled` | PASS | 383s | RTL tile 循环 |
| `run_wgtblob_tiled_ab.sh` | `UnitExec_tiled` | PASS | 961s | tiled × WGTblob |

**组合（三条切片在同一网表上互证）**：
- **A 在有 B1+C2 的网表上**：`run_x1skip_ab.sh` 全绿（A 的跳拍/负对照/两条网表突变全按预测量；输出逐字节 == 冻结 `tiling_ref`）。
- **B1 在有 A+C2 的网表上**：`run_dwpack_ab.sh` 六形状 1 拍/像素/趟 + 逐字节 == 冻结黄金；BEFORE 对照 9.00× 且 dump 逐字节不变。
- **C2 在有 A+B1 的网表上**：`run_dci_ab.sh` 正对照 + 拍比 + 两条负对照全绿。
- **B1∩C2 实测**：真 `1→1 3×3`（同时满足 `isDwW` 与 DCI 定义域）由 **dw 谓词先收**（DCI 关/开同 128；双关 1152；
  三档 dump 逐字节相同）—— 这是"两条通路共存不打架"的直接证据。
- **互斥边界**：`TYPE==2 ∧ C_in≤4`（A∩C2）与真表 `1×1 dw`（A∩B1）在真表上**为空**（闸门前置现场重扫）；
  合成层也未覆盖这两组同层组合（C-1 已记录的开口项，本片不变）。

## C2-3 本片发现 + 修复：B1 闸门（`run_dwpack_ab.sh`）在 C2 网表上的**文本锚重锚**

- **发现**：C2 RTL 把第 9 抽头积从组合 `x8·w8` 改成 A 级寄存器 `p8r`（C-1 钉死的正确性前提）⇒ SpinalHDL 展开里
  该行的线名改变（旧：`_zz_acc_0_7 = (dw_mode ? _zz_acc_0_8 : 16'h0)`；新：`_zz_acc_0_8 = (dw_mode ? _zz_acc_0 : 18'h0)`、
  `_zz_acc_0_7` = 符号扩展、`_zz_acc_0` = p8r 寄存器）。B1 闸门的**结构判据②**与 **tap8 突变锚**仍指向旧文本
  ⇒ 现跑以 `exit 3`（前置缺失，"锚不唯一 ⇒ 闸门自身不可信"）中止 —— **是测试前提陈旧，不是设计回归**
  （证据：重锚后同一网表全绿，且负对照计数与 B1 轮逐项相同）。
- **修复（测试侧，最小改动，`git diff` 10 增 6 删）**：结构判据②/突变锚唯一性表/tap8 突变三处文本
  旧→新；head 注释补一段重锚说明（语义：dw 档把第 9 抽头并进 acc；切除 = 该项恒 0 —— **一字未变**）。
- **重锚后现跑（2× 逐行确定，diff 空）**：六形状正对照逐字节 == 冻结黄金、`X1_BEATS == 1·nCo·H·W`；
  BEFORE（掐 `dw_mode`）9.00× 且 dump 逐字节不变（7,864,320 B × 6）；负对照
  sel/tap8 逐形状 = (26,35)/(39,39)/(81,59)/(89,87)/(178,138)/(263,352) —— **与 B1v-3 入库表逐项相同**；
  外科式（权重置 0）翻绿 ⇒ 重锚后的切除打的还是同一项。绿证据 = `reports/npu_v2c2_dwpack_gate_green.txt`。

## C2-4 全回归（本机现跑；`PY=lxvenv` + iverilog/ucrt64）

| 闸门 | 结果 | 用时 | | 闸门 | 结果 | 用时 |
|:--|:--|--:|:-:|:--|:--|--:|
| `run_sched_ab.sh` | PASS | 238s | | `run_chain_ab.sh` | PASS | 46s |
| `run_chaingeom_ab.sh` | PASS | 27s | | `run_fuse_ab.sh` | PASS | 41s |
| `run_psbound_ab.sh` | PASS | 8s | | `run_nputop_sched_ab.sh` | PASS | 130s |
| `run_mac_account_ab.sh` | PASS | 9s | | `run_preflight_ab.sh` | PASS | 2s |
| `run_wgtdma_geom_ab.sh` | PASS | 747s | | `run_wgtdma_ab.sh` | PASS | 312s |
| `run_wgtdma_wide_ab.sh` | PASS | 211s | | `check_dangling.py gen/*.v` | PASS（47/47 文件，0 悬空） | — |

- 环境口径注记（两条，皆**环境**问题不是闸门问题）：① `run_chaingeom_ab.sh` 在**未导出 `PYTHONIOENCODING=utf-8`**
  的会话里，其 inline python 打印 `⇒` 会在 GBK stdout 上抛 `UnicodeEncodeError`，导致负对照①误报"没发火"
  （rc=2）—— 设 `PYTHONIOENCODING=utf-8` 复跑 **PASS**（负对照①②实际发火）。② `run_dwpack_ab.sh` 的首次
  FAIL 见 C2-3（重锚后 2× 绿）。
- `run_dci_ab.sh` 重跑与入库绿证据逐字节同（C2-1）；`run_x1skip_ab.sh` 现跑输出与 Slice A 入库绿证据**逐行相同**
  （唯一差异 = 只记账的 `TILED_NL_MD5` 行，2b2e067e→76450464）。

## C2-5 integrated dev_map（`pds/devmap_c4a_c2.log`；`devmap_c4a.tcl`，period=10 ns，cwd=仓库根，退出 0）

- 网表 = `gen/NpuTop.v eccdc786…`（含 p8r + DCI）；**pre-C2 基线 = 同 tcl 上一轮（B1）日志 `pds/devmap_c4a_b1.log`
  （网表 `2dd28a8c…`）**，两轮同源同器件同约束；pre-B1 = `pds/devmap_c4a_b1base.log`（124,106 LUT）。

| 资源 | pre-B1（b1base） | B1（b1） | **C2（本跑）** | Δ(B1→C2) | 累计 Δ(pre-B1→C2) |
|:--|--:|--:|--:|--:|--:|
| LUT | 124,106 | 125,237 | **126,228** | **+991** | **+2,122**（B1 +1,131 + C2 +991） |
| FF | 149,299 | 149,364 | 149,368 | +4 | +69 |
| APM | 542 | 546 | **542** | **−4** | 0 |
| DRM | 247.5 / 415 | 247.5 / 415 | **247.5 / 415** | **0** | 0 |
| Dist.RAM | 7,872 | 7,872 | 7,872 | 0 | 0 |
| IO | 99 | 99 | 99 | 0 | 0 |
| `Adm-4088` | 0 | 0 | **0** | — | — |

- **go 规则（C-1 钉死）**：ΔLUT ≤ 2,000 ∧ ΔDRM = 0 ∧ 拍比实测 == 预测 ∧ 两档 Y 逐字节 —— **全过**（本条 = 集成补测的那条）。
- 交叉对照（Mapping Summary）：本跑 LUT 126,230 / as-logic 118,358 / regs 149,381（B1 轮 = 125,238 / 117,366 / 149,377）
  ⇒ 增量仍全部落在 LUT-as-logic；`LUTs as dram: 7872` 与基线同。无 DRC-0018 / DeviceMap-2003 / Program Error；
  `dev_map` 正常收尾（`Y1_C4A_INTEGRATED_DEVMAP_DONE`）。
- **modeled 先验 vs 实测（诚实对账）**：C-1 用 B1 的"探针→集成 ×3.57"外推 ≈ +3,830 LUT —— **实测 +991，先验严重高估**
  （3.57× 未复制；本次集成 Δ ≈ 探针合计 +1,072 的 0.92×）。可信读数 = 本行 +991。
- 量级备注：器件装得下（79.0%）；超 B-1 自己那条 ≤1,000 规则的是 **B1 的 +1,131**（历史结论不变）；C2 未再叠加超规。

## C2-6 冻结与网表指纹（本片现跑）

- **`TILING=false` 三网表逐字节冻结**（多个闸门前置项现场重验）：
  `gen/UnitExec.v 979129017535dc82ab9e6d89bea31080`、`gen/UnitExec_w32.v 618af3381eadcb4d7c6964cd4338a825`、
  `gen/UnitExec_w640.v ddb9bb8addc01f94e2ea8ae8b6b898e6`。
- **C2 改动（TILING=true 三份，与 `27b7c58` 记录一致）**：`gen/UnitExec_tiled.v 76450464a58c3a25310ccb5459f8f567`
  （2b85b0b2→76450464）、`gen/LayerSched.v 104e3e55d4c406b2c4fd060913a112c4`（d81a6ebe→104e3e55）、
  `gen/NpuTop.v eccdc786a3ebcfb253b066ef491fd790`（2dd28a8c→eccdc786）。
- `gen/*.v` 全树 47 份：`check_dangling.py` **47/47 文件 0 悬空**。`y1/gen/` 为 gitignore（指纹以 md5 记账，惯例同前）。

## C2-7 修正后的程序位置（fps 算术；与 §C1-6 同口径）

- 锚（现读）：PnR（B1 网表，`sim/reglogs/pds_pnr_c4a_b1_p10.000/.../report_timing/yeshen_mini_board_top.rtr`）
  `npu_clk requested 50 / estimated **52.6704 MHz** / slack +1.014 ns`、`All Constraints Met`。
- `tools/c_tail_account.py` 现跑（RESULT: PASS）：**A+B1+DCI = 5,418,000 拍 ⇒ @10 fps 需 ≥54.18 MHz；
  @52.6704 MHz ⇒ 9.7214 fps（建模 ≈9.72）**；+co 尾块（不可现表达）5,216,400 才过 10 fps 预算；缺口 150,960 拍。
- **本片不跑 PnR**（纪律）；"≥54.18 MHz"的最终裁判 = 下一轮 PnR（c3 4:1 读 + 模式选择器在乘法器输入锥上，与 B1 同一条锥）。

## C2-8 数字分类（measured / modeled / assumed，先例 = P0-6 / P0b-7 / SliceA-5 / B1v-7 / C1-7）

**Measured**
- `run_dci_ab.sh` 2× 现跑（正对照 384/128/128/128 逐字节 == 冻结参考；拍比 3.00×/9.00× 与两档 dump 相等；
  N1 94、N2 90 按预测量发火 + 外科式；dw 谓词先收的三档 dump 相等）。
- 字节闸门套件 + 全回归 20 道本机现跑全绿（C2-2/C2-4 表）；`check_dangling` 47/47。
- B1 闸门重锚后 2× 逐行确定的六形状读数（1 拍/像素/趟、BEFORE 9.00×、负对照六组 == B1v-3 入库表）。
- integrated dev_map 全表（本跑）：**ΔLUT +991 / ΔFF +4 / ΔAPM −4 / ΔDRM 0 / `Adm-4088=0`**。
- `TILING=false` 三 md5（多个闸门前置现场重验）；C2 三份 TILING=true md5 与提交记录一致。

**Modeled**
- 帧级 beats/fps（真表 67 单元几何 × 实测拍比；**整帧从未端到端跑过**，P0 §7-1 不变）。
- "C 在现钟下过 10 fps = no-go"（54.18 > 52.6704）—— 算术，非实测 PnR。

**Assumed**
- 探针形状对真表的代表性（承 C-1）；六片真 `1→1` 的 134,400 拍"由 B1 先收"的**归因**（实测于 c1/TB 层，
  帧级受益并入总量不变量）。
- B1 闸门重锚的文本映射（旧式 dw 门 → 新式 dw 门 + p8r）按语义等价处理（负对照计数逐项相同是其实测旁证）。

## C2-9 开口项（诚实的边界）

1. **PnR 未跑**：c3 的模式选择器在乘法器输入锥上；"≥54.18 MHz"与"9.72 fps"的最终判词在下一轮时序/面积片。
2. **A∩C2 / A∩B1 同层组合未覆盖**（真表为空 + 合成未做）：互斥是**现状事实**，不是"已验证的组合"。
3. **B1 的 +1,131 / C2 的 +991 未逐单元归因**（延续 B1v-8 第 2 条；本轮 C2 先验 ×3.57 失效已被实测修正）。
4. 整帧未端到端跑（承 P0/SliceA/B1v/C1 各片的同一条边界）；采集/喂列速率仍未建模。
5. `run_dwpack_ab.sh` 的重锚把"B1 在 C2 网表上逐位不变"从探针外推到集成六形状——这是 B1∩C2 的**数值**证据；
   B1 的 AFTER1 探针归因（§B-1）不因本片改变。

---
---

# Y1-Timing 轮：**npu_clk 追钟（≥54.18 MHz）** —— 18.4 ns 约束 + 实测最坏路径的定向修复

- 日期：2026-10-16
- 上游：`constraints/yeshen_mini.fdc`（`npu_clk` 20 ns ⇒ 本轮改 **18.4 ns**，对应 54.3478 MHz 请求；10 fps 需 ≥54.18 MHz）、
  §C2-7 的缺口算术（A+B1+DCI = 5,418,000 拍）、B1 轮 rtr（`sim/reglogs/pds_pnr_c4a_b1_p10.000/.../report_timing/yeshen_mini_board_top.rtr`）
- 交付物：`y1/pds/pnr_c4a_t18a.log`（**无修复**基线 @18.4 ns，tag `t18a`）、`y1/pds/pnr_c4a_t18b.log`（**修复后** @18.4 ns，tag `t18b`）、
  `y1/rtl/UnitExec.scala` 的「Y1-Timing」一节（三处行内增改 + 文件尾注释）、`y1/pds/devmap_c4a_t1.log`（修复后集成 dev_map）、
  `reports/npu_v2t_gate_green.txt`（闸门绿证据）
- 判据：PnR `All Constraints Met` + 比特流存在 + `YESHENMINI_PNR_C4A_DONE`；A/B 同约束（18.4 ns）同综合档（speed）

**Status: DONE（目标达成）—— 18.4 ns 约束下 `All Constraints Met`；`npu_clk` estimated **56.2683 MHz**（17.7720 ns，slack +0.628）
≥ 54.18 MHz ⇒ 建模 **≈10.39 fps ≥ 10 fps**。修复 = LUT 净 ≈0 / FF 净 +1（PDS 把 288 份副本合并成 1 份，见 T-3）。**

## T-0 一句话

B1 轮最坏 `npu_clk` 路径**不是** B1/C2 挡在乘法器输入锥上的 mux，而是 **`mzRam` 的 M 广播网**：
一张 `fanout=216` 的裸网直落 9 个消费者的 requant 乘法锥（布线 6.5–8.8 ns、占 63–65%；startpoint 直接是 DRAM 读出，
= C4a-R2 落的 `mR` 一级寄存被本代 PDS 流程挪掉/吸收）。修法 = 在 M 广播锥前**再压一级寄存器**（逐消费者副本写法，
TILING 门控、行数中性）；PDS 前端把 9 份副本合并回 1 份（实测报文在案）⇒ 生效结构 = 单级再寄存。实测最坏到达
21.094 → **18.824 ns**（−2.27 ns），18.4 ns 约束 **All Constraints Met**、est **56.2683 MHz**。

## T-1 最坏路径复核（B1 轮 rtr，verbatim；`npu_clk` 20 ns 约束、speed 档）

| # | Startpoint → Endpoint | 到达 | Slack | 结构 |
|:-:|:--|--:|--:|:--|
| 1 | `u_soc/u_npu/layerSched_1/unitExec_1/mzRam_4/gopdrm_18k/CLKB` → `.../unitExec_1/sliceRest_2/pLoR_1[30]/opit_0/D` | 21.094 | +1.014 | `QB tco 1.644 → net rtl_m[15]（fanout=216，布线 8.777）→ APM 级联 m1→m2→m3（1.897/1.431/1.506 + 内布线 0+1.213+2.072）→ D`；Logic 6.478 (34.9%) / Route 12.062 (65.1%) |
| 2 | `.../mzRam_2/gopdrm_18k/CLKB` → `.../unitExec_1/mpu/sl/pLoR_5[36]/opit_0/D` | 21.050 | +1.032 | 同构（路由 7.159，Logic 35.0%/Route 65.0%） |
| 3 | `.../mzRam_2/gopdrm_18k/CLKB` → `.../unitExec_1/mpu/sl/N1258_m4/gopapm/Z[47]` | 19.951 | +1.086 | 同构（路由 6.459，Route 62.8%） |

**判词：B1/C2 的输入锥 mux 不是头号 violator（refuted）** —— 本 rtr 里 `npu_clk` 的最坏 6 条（3 条 setup 全在上面、3 条 hold）
**没有一条**经过 `MacArray`/dw-lane/c3 读口；`npu_clk` WNS=+1.014（四个 seed 里只有 seed 0 收敛：`Total:1/4`）。

## T-2 诊断（逐 violator 的结构性原因）

- **共同根因 = 高扇出广播（项目史"复发"，同 R3-6 味）**：`rtl_m` 单 bit **fanout=216**、布线 6.5–8.8 ns；被广播的是
  **整层恒定**的 requant 乘子 `M`（`mzRam` 参数表读出）。**不是逻辑深度**（Logic Levels 仅 3）、**不是布线拥塞**（该网自身
  布线即占 63–65%，是**跨片距离 + 单网带 216 个负载**），也不是"加法树先加宽"（乘子是 33×32 直乘，APM 级联 3 级的逻辑
  共 4.8 ns，属正常）。
- **放大器**：C4a-R2 专门加的 `mR` 一级寄存（`mRRaw → mR`）在本代 PDS 里**没保住**——B1 rtr 的 startpoint 直接是
  **DRAM 输出 `QB`**（tco 1.644）；即寄存器被挪进/穿过了 DRAM 读出（speed 档 `-retiming` 语境）。于是 `M` 从"寄存器输出"
  退回"DRAM 输出"，广播锥把 DRAM 的时钟出延时也吃了进去。
- **为什么 216 个负载**：消费者 = 8 个链片（`conv`+`sliceRest_0..6`）与宽通路 `MultiPassUnit` 内那一片，共 **9 个实例**；
  每实例 requant 的 stage-1（`aHiS·M`）与 stage-2（`aLoR·M`）两条乘法都用 M ⇒ ≈24 负载/bit × 9。

## T-3 修法与 A/B（一次改一处；同约束 18.4 ns、同综合档 speed）

**修法（v1，落地）**：`y1/rtl/UnitExec.scala` 三处**行内增改**（行数中性）——`mR` 行尾追加 `mRB1`（L_MAX 份链片副本）
与 `mRBm`（宽通路副本）两条 `if (TILING)` 门控寄存器；`slices(i).io.requant_m` 与 `mpu.io.requant_m` 两处既有赋值
改成 `if (TILING) mRB1(i)/mRBm else mR`（`TILING=false` ⇒ 逐字原文 ⇒ 三份冻结网表逐字节不变，实测见 T-5）。
**数值口径**：逐字同 R2 的论证——`M` 在一层内恒定、首次 requant 远在 `go` 之后 ≥13 拍 ⇒ 再迟一拍不改变任何一次乘法的输入值；
副本初值 = 表初值（`2^24` 单位乘子）= `mR` 复位值。

**实测发现（诚实记录，v1 的"意外"）**：PDS 前端的 redundant-instance 消除**把 9 份副本合并回 1 份**（报文
`Removed inst mRB1_1..7/mRBm that is redundant to mRB1_0[31:0]`）⇒ 生效结构 = `mR` 之后再单压一级寄存 + 单张广播网。
（同片做了**受控对照 v2**：把副本放进 `Conv3x3Slice` 内部、D = 各实例自己的输入网，`runMain` 重生成 + dev_map 实测
**同样被合并**：`Removed ... mpu/sl/mMul redundant to conv/mMul`；净面积同样≈0。⇒ 该合并是**跨层级的结构性行为**，
"逐消费者副本"在本代 PDS 上**注定价签为 0、收益为 1 级**；v2 diff 更大故不保留。）

**A/B（同一张 C2 网表、同一 18.4 ns 约束）**：

| 档 | 网表 | `npu_clk` 结论 | 最坏路径到达 | 备注 |
|:--|:--|:--|--:|:--|
| **BEFORE** | C2（无修复） | 20 ns 轮实测 WNS **+1.014**（est 18.986 ⇒ 52.6704 MHz）⇒ 18.4 ns **换算 −0.586** | 21.094 | B1 轮 rtr（同网表同档）；18.4 ns 基线 t18a 本轮现跑（见 T-6 开口项） |
| **AFTER** | C2+v1 | **All Constraints Met**；est **17.7720 ns = 56.2683 MHz**、slack **+0.628**、TNS 0、违例端点 0 | **18.824** | `pds_pnr_c4a_t18b_p10.000`（seed 0 收敛；比特流 9,188,552 B；`YESHENMINI_PNR_C4A_DONE`） |

**After 的最坏路径（verbatim，`npu_clk` setup #1）**：`mzRam_2/gopdrm_18k/CLKB` →`QB tco 0.672`→ net `conv_requant_m[1]`
（fanout=216，布线 **7.776**）→ `sliceRest_5/N1188_m1 PO`（1.897）→ `m2 P`（1.431 + 1.270）→ `m3 P`（1.506 + 1.637）→
`N1188_m4/gopapm/Z[12]`；到达 **18.824**（Logic 5.506=34.0% / Route 10.683=66.0%）。——仍是同一张广播网，但
**DRAM 侧 tco 1.644→0.672（再寄存按就近映射落进 DRAM 输出）、路由 8.777→7.776、端点前移一级**，合计 −2.27 ns。

## T-4 约束推进（`constraints/yeshen_mini.fdc`：`npu_clk` `-period {20.000}` ⇒ `{18.400}`、`waveform {0 10.0}` ⇒ `{0 9.2}`）与 t18b 定稿

- 入口 B（从零 compile→synthesize(speed)→dev_map→pnr(4 seeds, seed 0 收敛)→report_timing→比特流）；命令
  `YESHENMINI_PNR_TAG=t18b YESHENMINI_SYNTH_MODE=speed pds_shell -file y1/pds/pnr_c4a.tcl`（cwd=仓库根）。
- **Performance Summary（t18b rtr）**：

  | Clock | Requested | Estimated | Period | Slack |
  |:--|--:|--:|--:|--:|
  | **npu_clk** | **54.3478 MHz** | **56.2683 MHz** | 18.4000 / **17.7720** | **+0.628** |
  | cpu_clk | 100 | 108.0847 | 10.0000 / 9.2520 | +0.748 |
  | core_clk | 125 | 137.0238 | 8.0000 / 7.2980 | +0.702 |
  | rst_clk | 125 | 210.2165 | 8.0000 / 4.7570 | +3.243 |
  | rgmii_clk | 125 | 189.9335 | 8.0000 / 5.2650 | +2.735 |
  | clk_in | 27.0270 | 209.4241 | 37.0000 / 4.7750 | +32.225 |

  `Design Summary : All Constraints Met.`
- 修复后 `npu_clk` WNS=+0.628（TNS 0，违例端点 0）；最坏三条 setup：① `mzRam_2→sliceRest_5/N1188_m4 Z`（0.628，见 T-3）②
  `unitExec_1/N1068/gopapm → wOutMem WEA[0]`（0.742）③ `mzRam_2→sliceRest_5/N1188_m4 Z[23]`（0.750）。**头号 violator 已从
  "DRAM 输出 直落乘法锥" 变为 "同网但由再寄存级驱动"** —— 该网的**下一刀**（真正切扇出）留给后续轮次（T-6）。

## T-5 闸门与冻结（本机现跑；绿证据 = `reports/npu_v2t_gate_green.txt`）

- **`TILING=false` 三网表逐字节冻结（多道闸门前置现场重验 + 本轮重生成复核）**：
  `gen/UnitExec.v 979129017535dc82ab9e6d89bea31080`、`gen/UnitExec_w32.v 618af3381eadcb4d7c6964cd4338a825`、
  `gen/UnitExec_w640.v ddb9bb8addc01f94e2ea8ae8b6b898e6` —— **md5 未变**（修复只在 `TILING=true` 展开里落硬件）。
  ★ 勘误：任务书里写的 `979129129017535dc82ab9e6d89bea31080` 是**笔误**（33 个十六进制字符）；真值以本行 32 位为准。
- 修复后 `TILING=true` 三网表（t18b 实际跑的字节）：`gen/UnitExec_tiled.v 3bc5d65253a5321db54bacee24112baf`、
  `gen/LayerSched.v a51f298514997af9cfde4eb73d6e4348`、`gen/NpuTop.v 6a317d18491a540b09db3dd1134aafdd`（其余 44 份 gen 产物
  逐字节不变，含 `Conv3x3Slice.v` / `MultiPassUnit.v` / `DwUnit.v`）。
- **字节闸门（三条切片闸门，修复后网表上现跑）**：`run_dci_ab.sh` **PASS**（正对照 `c0` 384 / `c1` 128 / `x18` 128 / `tap8` 128 全
  == 冻结参考；拍比 3.00×/9.00×；N1=94、N2=90 按预测量发火 + 外科翻绿）；`run_x1skip_ab.sh` **PASS**（9.00×；负对照/外科/两条突变
  全按预测量）；`run_dwpack_ab.sh` **PASS**（六形状逐字节 == 冻结黄金；BEFORE 9.00×；负对照 + 外科全绿）。
- **回归闸门（本机现跑，exit=0 全过）**：`mac_account` / `preflight` / `psbound` / `fuse` / `chaingeom` / `chain` / `unitexec` /
  `unitexec_wide` / `multipass` / `dw` / `sched` / `nputop_sched` / `tiling2d_rtl` / `tiling2d_wide` / `wgtblob_tiled`（15 道）；
  `check_dangling.py gen/*.v` 47/47 文件 0 悬空。
- **dev_map（`pds/devmap_c4a_t1.log`，集成、与 C2 基线同 tcl 同器件）**：LUT **126,222**（C2 126,228 ⇒ **−6**）、FF **149,369**
  （⇒ **+1**）、APM 542（0）、DRM 247.5（0）、Dist.RAM 7,872（0）；`Adm-4088 = 0`；两遍收尾标记齐全。
  ⇒ **修复的实测价签 ≈ 0 LUT / +1 FF**（288 份副本被合并吃回；`Mapping Summary`：LUT 126,224 / as-logic 118,352 / regs 149,382）。

## T-6 fps 重新签发与判词

- 程序位置不变：A+B1+DCI = **5,418,000 拍**（§C2-7）。@ est **56.2683 MHz**：5,418,000 / 56.2683e6 = **0.096290 s/帧 ⇒ 10.385 fps**；
  按**请求频率**（54.3478 MHz）保守算 = **10.030 fps**。——**≥10 fps 达标（两条读法都过）**；@ 旧实测 52.6704 MHz 的 9.7214 fps 作废。
- 判词：**10 fps 目标（算力侧，A+B1+DCI）在 18.4 ns 约束下闭合**；`npu_clk` 请求 54.3478 MHz、est 56.2683 MHz（slack +0.628）。
- 数字分类（先例同上）：**Measured** = 两条 PnR 的 est/slack、dev_map 全表、15+3 道闸门、冻结 md5、t18b 最坏路径明细；
  **Modeled** = 10.385/10.030 fps（帧级 beats × 实测钟；整帧仍未端到端跑，承 P0 §7-1）；**Assumed** = PDS 合并报文的
  "等价于单级再寄存"解释（报文在案，未做逐单元物理回读）。
- 开口项（诚实边界）：① **t18a（无修复 @18.4 ns 基线）在定稿时仍在 4-seed 循环里**（seed_0 布线已完成、place 档 slack
  −1.884 ns；t18a 定稿读数在下一版补；**收盘复核见 §T-9 第 5 条**）；② 广播网**本身**（fanout 216、~7.8 ns 路由）仍在，只是前面多压了一级寄存并在
  合法位置收口——真正的切扇出（逐消费者副本若要不被 PDS 合并，需抗合并写法）留给后续轮次；③ 本轮结论对 **speed 综合档**
  成立（与 B1 轮同档），换 ads 档需重测；④ 板级 PLL 仍是 50 MHz 配置，`npu_clk` 的真钟若要 >54.35 MHz 需在板级 bring-up
  时改第二颗 GPLL 的分频参数（单独步骤，本片不做）。

## T-7 比特流 ↔ 源认证（收盘复核；本机现跑）

- **全量重生成（两遍）**：29 条 Gen 调用（23 个 Gen 对象；`DwLaneGen`×4 档、`CiPackGen`×3 档、`BypassExecGen`×2 档）对 `gen/`
  全量重生成 A/B 两遍；**A 遍输出 == 收盘前磁盘全量（diff 空）、A == B（diff 空）** ⇒ 逐字节确定、当前 `gen/` == 当前 HEAD
  源输出（无 stale 产物）。覆盖 47 网表 + 2 个 `SigmoidUnit` LUT bin；`desc/wgt_blob/wgt_mult` 为模型产物（非 Gen），md5 一并记账、未变。
- **关键指纹**（与 C-2/§T-5 逐字一致）：

  | 网表 | md5 |
  |:--|:--|
  | `UnitExec.v`（TILING=false，冻结） | `979129017535dc82ab9e6d89bea31080` |
  | `UnitExec_w32.v`（冻结） | `618af3381eadcb4d7c6964cd4338a825` |
  | `UnitExec_w640.v`（冻结） | `ddb9bb8addc01f94e2ea8ae8b6b898e6` |
  | `UnitExec_tiled.v` | `3bc5d65253a5321db54bacee24112baf` |
  | `LayerSched.v` | `a51f298514997af9cfde4eb73d6e4348` |
  | `NpuTop.v` | `6a317d18491a540b09db3dd1134aafdd` |

- **"t18b 消费的字节"证据链（0 差）**。★ 权威记录 = **t18b 自己的工程实录**（compile 日志 / 合并报文 / `.rtr`）；
  `sources_info.log` **不能**当选"编译时读的字节"——它是流程**收尾时刻的磁盘快照**（t18b 于 15:43:41 写，记的是**没被采用的
  v2 实验档**：`7,324,373 B @15:07:35`；t18a 同性质：14:09:33 快照记的是 13:58:51 修复档）。
  1. **读取窗口**：t18b compile = 14:08:55–14:22:38（`prj_tasks/syn_1/compile/run.log` 时间戳）；该窗口内磁盘 `gen/NpuTop.v`
     的唯一版本 = **13:58:51 写入**（t18a sources_info@14:09:33 快照实拍其 size = `7,325,119 B`；下一写点在 15:07:35）。
  2. **冗余结构**：t18b 自己的 compile 日志合并报文 = `mRB1_1..7` + `mRBm` + `primeR_1..7`（15 条）⇔ 当前 `NpuTop.v` 的寄存器
     副本结构（mRB 家族 9 实例 ⇒ 恰删 8；primeR 8 实例 ⇒ 恰删 7）**逐条一致**。
  3. **行号图**：t18b compile 日志里 **23 个 NPU 模块的声明行号** ⇔ 新重生成的 `NpuTop.v` **逐行相等（0 差）**。
  4. **网名**：t18b `.rtr` 最坏路径的广播网 `conv_requant_m[1]`（fanout=216）∈ 当前 `NpuTop.v`；同窗口读同一文件的 devmap t1
     （14:59）行号图 == t18b 图（0 差）。
  5. **A/B 结构可分辨性（同一 compile-log 口径）**：无修复（t18a）→ 修复（t18b）= `UnitExec` 之后全部模块 **+27 行**（修复行
     全在 UnitExec 体内）；v2 实验档（devmap t2）= 无修复 + 切片模块体内 **+3 行** ⇒ 三档指纹互异、可区分。
- **闭合判词：CLOSED**。"HEAD → 重生成网表 → t18b 消费的 `NpuTop.v` → PnR → `.sbit`" **无断链**；末环口径**明写**：为结构等价
  证据（size 7,325,119 B + 23 点行号图 + 冗余结构 + 网名），**不是**对 13:58:51 原字节的 md5（该文件已被 15:07/15:52 两次重写
  覆盖，磁盘无归档副本），其读取窗口内无并行写入。**未见任何一条链节对不上。**
- **裁决闸门收盘复跑**（本机现跑；env：`PY=lxvenv` + `PATH+=iverilog(msys64/ucrt64)` + `PYTHONIOENCODING=utf-8` +
  `PYTHONPATH='./.pydeps;../third_party/yunet/deps'`；逐条明细入证据文件 §七）：

  | 闸门 | 结果 | 用时 | | 闸门 | 结果 | 用时 |
  |:--|:--|--:|:-:|:--|:--|--:|
  | `run_x1skip_ab.sh`（A） | **PASS**（9.00××2；负对照/外科/2 突变全按预测） | 95s | | `run_multipass_ab.sh` | **PASS** | 135s |
  | `run_dwpack_ab.sh`（B1） | **PASS**（六形状 1 拍/像素/趟 + dump 逐字节；BEFORE 9.00×） | 280s | | `run_dw_ab.sh` | **PASS** | 24s |
  | `run_dci_ab.sh`（C2） | **PASS**（3.00×/9.00×；N1=94/N2=90 按预测 + 外科翻绿） | 110s | | `run_dw_wide_ab.sh` | **PASS** | 654s |
  | `run_tiling2d_rtl_ab.sh` | **PASS** | 438s | | `run_unitexec_ab.sh` | **PASS** | 63s |
  | `run_tiling2d_wide_ab.sh` | **PASS**（负对照①②③按预测发火，含 631 / 20582 类） | 1533s | | `run_unitexec_wide_ab.sh` | **PASS** | 62s |
  | `run_wgtblob_tiled_ab.sh` | **PASS**（前置=三冻结 md5 + blob→wRam 映射互证；负对照全按预测） | 1108s | | `check_dangling.py gen/*.v` | **PASS**（47/47 文件 0 悬空） | — |

## T-8 交付物（比特流）

| 轮 | 比特流路径 | 大小 | md5 | 生成时刻（本机） | `npu_clk` 约束 |
|:--|:--|--:|:--|:--|:--|
| B1 轮（C-2 前） | `sim/reglogs/pds_pnr_c4a_b1_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit` | 9,188,552 B | `125ecf8bc62f44e1d572ef4990115e45` | 2026-10-16 09:54:06 | 20.000 ns |
| **时序轮（t18b，本交付）** | `sim/reglogs/pds_pnr_c4a_t18b_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit` | 9,188,552 B | **`71a9959b963637470bbd75bcd07507e3`** | 2026-10-16 15:45:39 | 18.400 ns |

- 两轮**同 size、异 md5** ⇔ 修复确在比特流内（判据本体仍是 `.rtr`：`npu_clk` 请求 54.3478 / est 56.2683 MHz，
  18.4000→17.7720 ns，slack +0.628，`Design Summary : All Constraints Met.`）。本轮工程日志 = `y1/pds/pnr_c4a_t18b.log`（wrapper）
  + `sim/reglogs/pds_pnr_c4a_t18b_p10.000/`（工程目录）；约束档 = commit `602d134`（fdc 20.000→18.400 ns、`-waveform {0 9.200}`）。
- **本比特流从未上板**——板级 PLL 仍是 50 MHz 配置（§T-6④），上板/改分频是用户排期的独立步骤；本轮全部结论都是离线口径。

## T-9 收盘诚实边界（本轮**没有**验证的清单）

1. **整帧从未端到端跑过**（承 P0 §7-1 / A2-6）：10.385 fps 依旧是"实测拍比 × 真表几何 × PnR 实测钟"的**合成值**，不是墙钟。
2. **拆融合的带宽价签仍挂着**（A2-1 冻结模型口径）：激活侧 31.94 MB/帧、**含旁路 ≈38.9 MB/帧 ⇒ 7.09 fps** @275.9 MB/s；流量侧
   "窗口留住"这张牌**未打**。算力 10.39 fps > 带宽 7.09 fps ⇒ 上板前的整帧绑定侧**可能转回带宽**——不要把本轮的 10.39 当"帧率达标"。
3. **`run_stride_ab.sh` 先存红未触**（A2-5 已记录：`rtl_test/MultiPassTb.v:83` 引 `ps_clr` 不在 `gen/MultiPassUnit.v` 端口上——TB/网表
   错位）；本轮切片未碰它，红仍在。
4. 时序结论只对 **speed 综合档**（T-6③）；广播网本体未切扇出（T-6②）；板级 PLL 仍 50 MHz（T-6④）。
5. **t18a（无修复 @18.4 ns 基线）：seed 0 已出读数 = `Setup(Slow) −0.939 ns`（16:41 完成；`Worst Slack(place) = −1884`、
   `Worst Slack(pre route) = −1128`）——18.4 ns 下**不闭合**（与 t18b 修复后的 slack +0.628 成 A/B）；**定稿 `.rtr` 读数仍缺**：
   四 seed 循环仍在跑（seed 1 起于 16:41），待其收尾后补记。
6. 本认证的**末环口径 = 结构等价**（T-7）：13:58:51 的 `NpuTop.v` 原字节已被覆盖、无归档副本；其余 5 份 PDS 输入
   （`DmaEngine.v` + 4 个 CDC/sync）自 12:25:2x 起未被再写、size 与 t18b 的 sources_info 记录逐字相同。

---
---

# Y1-Timing-T18c 轮：**过约束 → 收敛 → 重发比特流**（板级 PLL 抬钟 50 → 56.250 MHz）

- 日期：2026-10-16
- 上游：本文件 §T-4/§T-6（18.4 ns 闭合：est 56.2683 MHz、slack +0.628）、§T-8（交付物表）、§T-9（收盘残差）、§C2-7（A+B1+DCI = 5,418,000 拍）
- 交付物：`board/pll_50m.v`（RATIO0 13.5→12.0、DUTY0 13→12；PFD/VCO 一字未动）+ 注释同步
  （`constraints/yeshen_mini.fdc`、`board/yeshen_mini_board_top.v`、`board/yeshen_mini_soc.v`，commit `b8d72c0`）、
  本节的 t18c PnR 判词与新比特流记录；t18c 工程 `sim/reglogs/pds_pnr_c4a_t18c_p10.000/`
  （wrapper 日志 `y1/pds/pnr_c4a_t18c.log`、`y1/pds/pnr_c4a_t18c.exit`）
- 命令：`YESHENMINI_SYNTH_MODE=speed YESHENMINI_PNR_TAG=t18c pds_shell.exe -file y1/pds/pnr_c4a.tcl`（cwd = 仓库根；入口 B
  从零 compile→synth(speed)→dev_map→pnr；seed 0 收敛，`Total 1/4`）
- ★ tag 说明：任务示例给的 `c4a_t18c` 会经模板拼成 `pds_pnr_c4a_c4a_t18c_p10.000`（模板自带 `c4a` 前缀），故按
  t18a/t18b 先例取 tag=`t18c` ⇒ 工程目录 `pds_pnr_c4a_t18c_p10.000`（与 T-8 表命名一致）

**Status: DONE（板级钟抬到约束档 + 比特流重发；PnR `All Constraints Met`；新交付比特流 = d8993bfe…）**

## T18c-0 一句话

板级第二颗 GPLL 的 `RATIO0` 13.5 → **12.0**（VCO=675/PFD=27 一字未动）⇒ clkout0 = 675/12 = **56.250000 MHz（精确）**，
落在 **[fdc 请求 54.3478, t18b 实测 56.2683]** 区间并贴住上沿；fdc 约束 **18.400 ns 一字未改**。t18c PnR（speed 档、同约束）
`All Constraints Met`，Performance Summary 与 t18b **逐数相同**（npu_clk est **56.2683 MHz** / slack **+0.628**；pnr stage 行与
worst-setup 路径块逐字相同 ⇒ 布线 DB 等价）；新比特流 `d8993bfed723a4564470c0107f84360f`（9,188,552 B）与 t18b `71a9959b…`
**只差 18 字节**（其中 6 字节在中段 = GPLL 配置载荷位置特征）。建模 fps（5,418,000 拍 ÷ 56.25 MHz）= **10.3821**（旧 50 MHz 板钟 = 9.2285）。

## T18c-1 PLL 频率账（窗口/检查逐条取自本机 PDS `ipm2l_pll/ui.tcl:pllCheck_adv`，不猜）

| | 旧（N2b–t18b） | **新（T-18c）** |
|:--|:--|:--|
| PFD（= CLKIN_FREQ/RATIOI） | 27/1 = 27 MHz | 27/1 = 27 MHz（不变；∈[10,450] ✓） |
| VCO（= PFD×RATIOM×RATIOF） | 27×1×25 = 675 MHz | 27×1×25 = 675 MHz（不变；∈[600,1200] ✓） |
| RATIO0 / DUTY0 | 13.5 / 13 | **12.0 / 12** |
| clkout0（= VCO/RATIO0） | 675/13.5 = **50.000000 MHz** | 675/12.0 = **56.250000 MHz（精确）** |

- 合法性（逐条对齐 `pllCheck_adv` 的**实现**）：RATIO0 = 12.0 在 1/8 网格上（= 12 + 0/8）；duty 检查
  `duty ≤ 2·odiv−1` ⇒ 12 ≤ 23 ✓；clkout 检查 `clkout ≤ fout_max = 800` ✓；PFD/VCO 窗口见上表。
- **取值依据（VCO=675 的 1/8 格点枚举，≥54.3478 MHz 者）**：12.375→54.5455 / 12.25→55.1020 / 12.125→55.6701 /
  **12.0→56.25** / 11.875→56.8421 —— **12.0 是不超过 t18b 实测上限 56.2683 MHz 的最高格点**（56.25 ≤ 56.2683，差 0.033%）；
  11.875（56.8421）越出实测上限、不在任何已闭合证据的覆盖内，故不取。

## T18c-2 fdc 状态：**约束行一字未改**（并交代"何时才需要改"）

- `create_clock -name {npu_clk} [get_pins {u_pll_npu/u_gpll/CLKOUT0}] -period {18.400} -waveform {0 9.200}` **保持原样**
  （本切片对 fdc 只动注释：N2/N2b 段补 T-18c 注记 + 修 "`{20.000}` ⇒ 50.000MHz" 的历史文本——**行本体未动**）。
- "约束是否该等于新板钟"：**不需要**。本约束的角色是 PnR 的**认证地板（请求值）**；板钟是"被认证对象"。三值关系
  请求 54.3478 ≤ **板钟 56.25** ≤ 实测 56.2683 ⇒ 板钟被已闭合轮次的实测覆盖。若要让约束 **=** 板钟，须收到
  17.778 ns（t18b est 17.7720 对 17.778 只剩 +6 ps 余量）——那是一次**更紧**的新 PnR 请求、不在本切片范围，
  且会显著抬高"重发比特流"的收敛风险；**未做，如实标注**（见 T18c-8-2）。

## T18c-3 PnR 判词（t18c；seed 0 收敛）

- 判据三件套：`y1/pds/pnr_c4a_t18c.exit` = **`exit=0`** + wrapper 尾部 **`YESHENMINI_PNR_C4A_DONE`** + 比特流存在（T18c-4）。
- **`.rtr` Performance Summary（verbatim 行）**：`npu_clk 54.3478 MHz 56.2683 MHz 18.4000 17.7720 0.628`；
  `Design Summary : All Constraints Met.`；Setup(Slow)：npu_clk WNS **+0.628**、TNS 0、违例端点 **0**（共 494,547 端点）；
  `grep -c VIOLATED` = **0**。
- **`.rtr` Clock Summary（任务⑤ sanity 项）**：`npu_clk 18.4000 {0.0000 9.2000} Declared 117570
  {u_pll_npu/u_gpll/gpll_inst/CLKOUT0}` ⇒ 周期 18.4 / 独立根钟（Declared）/ 对象 = 第二颗 PLL 输出脚，与 fdc 意图逐项一致。
- 最坏 npu_clk setup 路径 = **与 t18b 同一条**（T-3 治过的广播网，逐字相同）：`mzRam_2/gopdrm_18k/CLKB → QB tco 0.672 →
  net conv_requant_m[1]（fanout=216，布线 7.776）→ sliceRest_5/N1188_m1→m2→m3 → Z[12]` 到达 18.824、slack 0.628
  （Logic 5.506=34.0% / Route 10.683=66.0%）。
- **确定性证据（本轮新增，把"只差 PLL"钉死）**：t18c 与 t18b 的 pnr stage 行**逐字节相同**
  （`Running Pnr with seed 0 succeeded … Setup(Slow): 0.049 … Worst Slack(place): 675 … Wire Length: 2.02427e+06`；
  该行是 seed 收敛指标，最终判词以上面 rtr 为准），且六个时钟的 Performance Summary 逐数相同 ⇒ 布线数据库等价。
- **源指纹（编译前/后两测相同，md5）**：`board/pll_50m.v 06ccf8dd25a904968a9f5ebad542629b`、`board/yeshen_mini_board_top.v
  e26224ff62cfe0c659aff7c5b3a9789c`、`board/yeshen_mini_soc.v 497650e2ee6e2efc8fbee093de14bdf6`、
  `constraints/yeshen_mini.fdc e89a0530cb2d9b1f989af49121505802`（== commit `b8d72c0`）；`gen/` 侧与 §T-7 认证值逐字相同
  （`UnitExec_tiled 3bc5d652…` / `LayerSched a51f2985…` / `NpuTop 6a317d18…`；`TILING=false` 三网表 `97912901…/618af338…/ddb9bb8a…` 未变）
  ⇒ t18c 与 t18b 的**消费源只差 `pll_50m.v`**。

## T18c-4 新比特流 + 与 t18b 的差异

| 轮 | 比特流路径 | 大小 | md5 | 生成时刻（本机） | npu_clk 约束 / 板钟 |
|:--|:--|--:|:--|:--|:--|
| t18b（旧交付） | `sim/reglogs/pds_pnr_c4a_t18b_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit` | 9,188,552 B | `71a9959b963637470bbd75bcd07507e3` | 2026-10-16 15:45 | 18.400 ns / 板钟 50 MHz |
| **t18c（新交付）** | `sim/reglogs/pds_pnr_c4a_t18c_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit` | 9,188,552 B | **`d8993bfed723a4564470c0107f84360f`** | 2026-10-16 19:25 | 18.400 ns / **板钟 56.25 MHz** |

- **逐字节差分 = 18 字节**（`cmp -l` 计数；两轮同 size；分段 4 + 6 + 8 = 18）：文件头 4 字节（偏移 108/110/113/114，元数据区）+
  中段 6 字节（1,193,413 / 1,193,421-23 / 1,193,499-500 —— 与 GPLL 配置载荷的位置特征一致）+
  近文件尾 8 字节（9,188,101-04 / 9,188,141-44，校验类）。
- **归因（证据链，非猜测）**：布线 DB 与 rtr 逐字相同（T18c-3）⇒ 逻辑面零差；t18c 编译入口读到的唯一变源 =
  `board/pll_50m.v` ⇒ 中段 6 字节 = GPLL 分频配置。★ **未做** sbit 反向解包逐位读回 RATIO0（见 T18c-8-3）。

## T18c-5 fps 重新签发（**从拍数 × 真钟重算，不重用 10.385**）

`fps = 真钟 ÷ 拍数`，拍数 = **A+B1+DCI = 5,418,000**（§C2-7 的"计算程序"口径；本切片不改拍数）：

| 钟 | fps | 说明 |
|:--|--:|:--|
| 50 MHz（旧板钟） | 9.2285 | 刷 t18b 比特流的实际值 |
| 54.3478 MHz（fdc 请求） | 10.0310 | 保守读数 |
| **56.25 MHz（新板钟，精确）** | **10.3821** | 5,418,000 ÷ 56.25e6 = 0.096320 s/帧 |
| 56.2683 MHz（t18b/t18c 实测 est） | 10.3854 | 上界读数（比新板钟快 0.033%） |

⇒ 新板钟 56.25 MHz 下建模 **10.3821 fps ≥ 10 fps**（三条读数全过线）。

## T18c-6 数字分类（measured / modeled / assumed）

**Measured**
- PDS 全流程现跑（t18c，17:49–19:25）：`All Constraints Met`、rtr 全表（npu_clk 54.3478→56.2683 MHz / 18.4→17.7720 ns /
  +0.628）、Clock Summary 行、worst-setup 路径块、seed 0 收敛行；`exit=0` + `YESHENMINI_PNR_C4A_DONE`。
- 新比特流 9,188,552 B / `d8993bfe…`；与 t18b 的 `cmp -l` = 18 字节；两轮 pnr stage 行与 rtr 逐字相同。
- 消费源 md5（PnR 前/后两测相同）；`TILING=false` 三网表 md5 复验未变（本切片零 RTL/gen 改动）。
- 频率账：675/12 = 56.25 MHz 精确；1/8 格点枚举逐点复算（见 T18c-1）。

**Modeled**
- `10.3821 fps`（拍数 × 真钟的纯算术；**整帧仍未端到端跑过**，承 P0 §7-1 / T-9-1）。
- "中段 6 字节 = GPLL 配置"的归因（由布线 DB 等价 + 唯一变源推得；sbit 未反向解包）。

**Assumed**
- 27 MHz 参考晶振的标称频率与 ppm 容差（板钟 = 56.25 MHz × 晶振偏差；npu 域与其他域异步 ⇒ 只线性影响 fps）。
- 上电 GPLL lock 与板级 bring-up 行为（无板上验证，见 T18c-8-1）。

## T18c-7 停顿项（stragglers）清单

**本切片更新**（改动落盘）：

| 位置 | 处理 |
|:--|:--|
| `board/pll_50m.v` | RATIO0/DUTY0 参数 + 文件头【T-18c 追加】全量算术（窗口/格点/duty/取值依据） |
| `constraints/yeshen_mini.fdc` | N2/N2b 段补 T-18c 注记 + 修正 "`{20.000}`⇒50.000MHz" 的历史文本（**约束行本体未动**） |
| `board/yeshen_mini_board_top.v` | 文件头【6】/ PLL 例化块 / 时钟线注释：50.000→56.250（标注旧值为历史） |
| `board/yeshen_mini_soc.v` | 文件头【10】/ 输入口 / NpuTop 例化注释：同上 |

**查过、无需改**：

| 位置 | 结论 |
|:--|:--|
| `y1/tools/npu_frame_run.py`（主机驱动） | 无 npu_clk/频率假设（墙钟超时 `--timeout 120s` 等 IRQ/`CTRL.done`，NPU self-timed）⇒ 换钟透明 |
| `scripts/*`（flash/board/eth helpers） | 无 npu_clk 频率引用 |

**刻意不改（列出理由）**：

| 位置 | 理由 |
|:--|:--|
| `y1/reports/npu_clock.md`（N6 轮）、`c4a_timing.md`、`c4b_tiling_s2.md`、`c4b_wgtdma.md`、`dma_phase2b.md`、本文件 T-6/T-8 各节 | 点时刻证据文档（历史读数保留；现行状态以本节 + fdc + board 头注为准——先例：T 轮也未回改更早报告） |
| `y1/tools/mac_account.py`（`NPU_CLK_HZ=50e6`）、`dw_lane_account.py`（@50MHz 列）、`c_tail_account.py`（`PNR_FMAX_MEAS=52.6704e6`） | 冻结记账口径（闸门按精确值锚定，改它 = 重锚全部价格表）；新 fps 在本节按 5,418,000 × 真钟直接重算 |
| `board/pll_100m_125m.v` 头【N2 追加】段 | 历史推理（"为何需要第二颗 GPLL"），作为历史仍准确 |
| `docs/superpowers/specs/2026-10-16-y1-npu-v2-single-skeleton-design.md` §5 | 设计/决策史（T-4 轮同样未回改 spec） |

## T18c-8 诚实残差 / 疑问 / 开口项

1. **帧从未上板**（承 P0 §7-1 / T-9-1）：10.3821 fps 是"实测拍比 × 真表几何 × 真钟"的合成值。本切片**零板级访问**
   （无 JTAG/COM/烧写），新比特流**未烧写**——上板 + 用 `npu_frame_run.py` 量墙钟仍是用户排期的独立步骤。
2. **板钟贴近实测上限**：56.25 与实测 est 56.2683 差 0.033%（周期 +5.8 ps）。若板级真实时序落在 est 的乐观侧，
   这条余量可能不足；回退旋钮 = RATIO0 12.125（55.6701 MHz，+0.6% 余量，fps −1% ⇒ 10.27）。当前按任务书偏好
   "贴住上沿"取值。
3. **sbit 反向解包未做**："GPLL 配置在比特流里生效"的证据 = 布线 DB 等价（T18c-3）+ 18 字节差 + 编译读到的唯一变源；
   **没有**从 sbit 位流里逐位读出 RATIO0=12.0。板上上电读 CLK 属板级步骤。
4. **带宽侧可能接管**（承 T-9-2）：算力侧 10.38 fps > 冻结模型带宽侧（拆融合后 31.94 MB/帧 ⇒ 8.64 fps；含旁路
   ≈7.09 fps @275.9 MB/s）⇒ 整帧上板时绑定侧**可能转回带宽**；本切片只把**算力侧**推过 10 fps 线。
5. **`run_stride_ab.sh` 先存红未触**（承 A2-5 / T-9-3）：`rtl_test/MultiPassTb.v:83` 引 `ps_clr` 不在
   `gen/MultiPassUnit.v` 端口上 —— 本切片未碰它，红仍在。
6. 结论只对 **speed 综合档 + 本 t18c 源**（`b8d72c0`）成立；广播网本体（fanout 216）仍未被切扇出（承 T-6-②）。

## T18c-9 提交与指纹

- 提交序列：`b8d72c0`（PLL 参数 + 三处注释同步 + fdc 注记/历史文本修正；commit 后 `board/*.v`/`fdc` 未再变，
  md5 前/后两测相同）→ `5b0a831`（本节报告 + `.exit` 入库）→ `755a2ff`（本节差分分段计数勘误 4+6+8=18）。
  `y1/pds/pnr_c4a_t18c.exit` = `exit=0` 入库（仓库惯例）；wrapper 日志 `*.log` / `*.sbit` 按 T-8 先例不入库
  （`*.log` 在 .gitignore；比特流在 `sim/reglogs/` 亦 ignore，交付路径见 T18c-4）。


---

# S3-上板：**t18c 首次上板 + 真帧首跑**（详见 `reports/npu_v2_board_frame.md`）

- 日期：2026-10-16。**Status: PARTIAL**（烧写/启动 PASS；帧首错单元已钉死）。
- 一句话：t18c（`d8993bfe…`）上板 + 启动 8/8 PASS；驱动默认参数在 `desc[0]` 响亮 err
  （根因 = `XDMA_EN=0`，真帧必须 `--xdma-en`）；加 `--xdma-en` 后 **`desc[0..2]` 首次板上 done**
  （墙钟 0.735/1.256/1.578 s，**首次实测**），**首个失败单元 = `desc[3]`（MaxPool）**，
  根因 = 每层布局位（信箱区 7 道 2）未投递（F1 §4.4 必办项；镜像 `--layout zero` 逐项复现首错单元）。
  **无完成帧 ⇒ 无 measured fps / 无 12 路 / G7 = n/a**。
- 新增工具：`tools/npurun_t.c`（板内单进程帧计时器）；`scripts/board_ddr.py` 两处传输重试修复
  （`8fb54d9` / `5749821`）、`pds/flash_yeshen.tcl` 的 `YESHENMINI_JTAG_PORT`（`3e2cede`）。
