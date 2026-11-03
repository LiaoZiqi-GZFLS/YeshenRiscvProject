# y1 C4b-D1：卷积步长 `stride >= 2`（真帧 layer 0 能起步）

任务：**实现 conv 的 `stride >= 2`**（RTL + TB + 闸门），让真网的 **layer 0（`Conv_0`）** 从"根本起不了步"
变成"逐字节正确"。范围 = **conv 通路**（窄 + 宽/多趟），**不改描述符格式 / 不改寄存器契约 / 不建第二条算术通路**；
`stride = 1` 必须**逐字节不变**。

上游出处：`y1/reports/c4b_input_layout.md`（B3, `0c47250`）把"`DescWords.stride` **译码了但没用**"列为最大缺口 ——
真网 layer 0 的 ONNX `strides = [2,2]`、`pads = [1,1,1,1]`、`640×640 → 320×320`，而卷积数据通路**没有步长路径**。

---

## 1. 冻结口径（写进 `rtl/Conv3x3Slice.scala` 文件头；要改走 spec 修订）

```
stride ∈ [1,15]（描述符 w3[11:8]；字段 0 视作 1）。
输出 (y,x) 的窗口中心 = 输入 (s·y, s·x)；本模块"收完第 c 列"手上正好是中心为第 c-1 列的窗口
       ⇒ 目标列 c ≡ 1 (mod s)、目标行 r ≡ 1 (mod s)（r = 正在流入的输入行号）。
输入流**一个字节都不跳**（行缓冲照旧收满每行 WIDTH 列；3 个 tap 恒为**相邻**三列）；
抽稀的只是**像素相位**：非目标列/行照收历史、不进像素相位（S_CONSUME 连跑 s 拍）。
⇒ 输出 Ho×Wo（Ho = floor((H-1)/s)+1、Wo = floor((W-1)/s)+1），与 ONNX 的
   `Ho = floor((H+2·pad-K)/s)+1`（pad=1, K=3）**同式**。
右边零填充：幻影列（列 W）是目标列 ⟺ (W-1) mod s == 0；否则最后一列的像素算完直接换行。
```

**实现（`dm` / `rm` 两个 4 位模 `s` 计数器；没有除法、没有运行时取模）**：

| 量 | 含义 | 更新 | 判据 |
|---|---|---|---|
| `dm` | 已收列号 mod `s` | 每行第 0 列清 0；其余每收一列 `+1 mod s` | **目标列 ⟺ `dm === 0`** |
| `rm` | (已收行号-1) mod `s` | 每次换行 `+1 mod s`（`row 0→1` 时归 0） | **输出行 ⟺ `rm === 0`** |
| `phantomNext` | 幻影列（列 `W`）是不是目标列 | 收列 `W-1` 那一刻由 `dmNext === 0` 给 | 决定"补不补幻影拍" |

`effS = Mux(stride === 0, 1, stride)`（旧表/旧装置把该字段留 0 ⇒ 与 C4a 逐字节同形）。
**`s = 1` 时两个计数器恒 0** ⇒ 三条收列分支退化成旧的两条、`phantomNeed` 恒真
⇒ 数据通路信号**逐拍同形**（新增的三个寄存器不影响任何数值）。

**落点（"抽稀发生在哪"）**：`Conv3x3Slice` 的**调度状态机**（`when(beat)` 三分支 + `S_PIX` 的收尾分支），
**不是**算术：9 个 tap 的选择、MAC、requant（§4.4）、部分和写回（`ps_out`/`ps_valid`）**一字未改**。
`MultiPassUnit` 只把口**直通**给切片（每趟同一个步长 ⇒ 各趟像素序逐位相同 ⇒ 部分和能按同一 `pixIdx` 跨趟相加）；
`UnitExec` 直接接描述符 `dw.stride`。

---

## 2. 改动清单（文件 + md5）

| 文件 | md5 | 改了什么 |
|---|---|---|
| `y1/rtl/Conv3x3Slice.scala` | `f7507ca290890c00f3aa667f72fbbd97` | **新增 `stride` 口 + 抽稀相位**（`effS`/`dm`/`rm`/`phantR`）+ 收列三分支 + `S_PIX` 收尾 + `prime` 清相位 + 文件头 D1 一节 |
| `y1/rtl/MultiPassUnit.scala` | `32787e2bec5bfd7de550b60a222fa8b0` | 新增 `stride` 口 → **直通切片** |
| `y1/rtl/UnitExec.scala` | `337dd60df959c55cdf1723a3b0987696` | 描述符 `STRIDE` → `strideEff`（0 视作 1）；接宽/窄两条通路的切片 + `mpu`；**输入几何**（`inRows = IMG_H·s`、`inWOk` 区间判据、喂列/收料/pad 行边界）；DDR gather 的**输入平面步长** `inPix`；`stride>1 ⇒ chainLen==1` 响亮 err |
| `y1/rtl_test/MultiPassTb.v` | `6c3d5e2c99012892c9ae0f6798970b64` | `+STRIDE`（缺省 1）/`+PADV`（缺省 0）；`HO/WO/NPIX` 由步长派生；`.stride(STRIDE[3:0])`、`.pad_val(PADV)`；`MAXIW 8 → 640`；`MAXCYC` 随趟长放大 |
| `y1/rtl_test/Conv3x3Tb.v` | `73f98a082b4ef467620d96f0aa56c4bf` | `.stride(4'd1)`（显式驱动，否则 z 会让相位计数器变 x） |
| `y1/rtl_test/DwTb.v` | `97fbd4babc4f77d7955e14f0fc52e6f0` | 同上（`.stride(4'd1)`） |
| `y1/tools/stride_ref.py` | `2f567509e8f1a56735387bbd57143f2c` | **新**：步长感知的向量 + 黄金供料（两套独立实现互证） |
| `y1/tools/run_stride_ab.sh` | `9d20f122e90f5cd8b63c47a2adc8a52a` | **新**：本任务的闸门 |

**生成物（重新生成的网表，`gen/` 不入库；md5 供对账）**

| 网表 | md5 |
|---|---|
| `gen/Conv3x3Slice.v`（16，数值门的档） | `76816030cb60572ea41604a47f172300` |
| `gen/Conv3x3Slice_g4.v` / `_g8.v` | `1483fd10f0aba6b06b04dcbb72324d0c` / `53dee6bc5baebfcc0ed78a20f6e1956b` |
| `gen/MultiPassUnit.v`（8,32,8 规范档） | `cd7205c5a21d1dc588b4db66be4c7137` |
| `gen/DwUnit.v` | `cd7205c5a21d1dc588b4db66be4c7137`（**与 MultiPassUnit 同 md5** ⇒ "没有第二条算术通路"仍成立） |
| `gen/UnitExec.v` / `gen/UnitExec_w32.v` | `b29c5e73d399ba75eb4aa33a5d58a376` / `23c01cce7f3773477eb2130f56258cd9` |
| `gen/LayerSched.v` / `gen/NpuTop.v` | `9676f7f9b259f26cca7ed082f0067927` / `aaf5ca5e8b14e3806fbaf6d102fbfc03` |
| **`gen/stride640/MultiPassUnit.v`**（**真几何**：`WIDTH=640 PIXMAX=5120 NCOB=2`，7,581,894 B） | `5d00dc6d4ec8469d0634037992583f1f` |

生成命令（与既有档同源）：
```
cd y1 && printf 'Test/runMain SliceGen <gen> 16\nTest/runMain MultiPassGen <gen>\nTest/runMain DwGen <gen>\n
Test/runMain UnitExecGen <gen>\nTest/runMain LayerSchedGen <gen>\nTest/runMain NpuTopGen <gen>\n
Test/runMain MultiPassGen <gen>/stride640 640 5120 2\nexit\n' | bash sbt.sh
```

---

## 3. 正对照：**真 `Conv_0` 几何**逐字节

用例 = **真 `Conv_0`**：权重/参数取自转换器产物（`gen/wgt_index.json` + `gen/wgt_blob.bin`，`--lid 0`）
—— `C_IN=3 / C_OUT=16 / GROUP=1 / 3×3 / pads=1 / strides=[2,2]`、`M=57384 / z_pad=-128 / z_y=41 / bias_adj[16]`；
网表 = **真 640 列行宽**（`WIDTH=640`，即真网输入的行宽）；装置 = `MultiPassTb`（= 趟编排器）。

| 用例 | 输入 | 输出 | 结果 |
|---|---|---|---|
| **真 `Conv_0` `+STRIDE=2`** | `H_in=8` 行 × **640 列**（真行宽） | **`4 × 320`**（**横向抽稀整段为真：640 → 320**） | **MISMATCH=0** / 20480 B |
| **真 `Conv_0` `+STRIDE=1`**（同一网表同一几何的回归锚） | `H_in=8` × 640 | `8 × 640` | **MISMATCH=0** / 81920 B |
| 合成 `C_in=3 → C_out=8` `+STRIDE=2`（小尺寸、黄金**不饱和**、分辨率最好） | `H_in=4 × 8` | `2 × 4` | **MISMATCH=0** / 64 B |

黄金由 `tools/stride_ref.py` 现算（**不存硬编码 md5**）：`M/z_pad/z_y/bias_adj` **消费**转换器产物（与
`wide_exec_ref` / `run_unitexec_wide_ab.sh` **同一份**§4.4/§4.5 口径）；`requant` **逐字复用**
`wide_exec_ref.requant`（`((acc·M)>>24)>>6 + z_y` 后钳位）。`stride_ref --selftest` 里另有**两条独立锚**：
① 向量化抽稀切片 == 逐输出像素的显式 3×3 窗口（互为第二实现，`s=1/2/3` 各形状逐字节）；
② **`s=1` 时与冻结的 C4a.5b caliber（`wide_exec_ref.conv_acc`）逐字节相同**。

**`stride=1` 不变的承重证据**（三层）：
1. `stride_ref --selftest`：`s=1` 的 acc 与**冻结 caliber**逐字节相同；
2. 本闸门的 `lid0_s1` 用例（真 640 几何）`MISMATCH=0`；
3. **既有闸门全绿**（见 §6）：`run_multipass_ab.sh` 逐字节黄金不变、`run_dw_ab.sh` 的
   `md5(DwUnit.v) == md5(MultiPassUnit.v)` 结构性断言仍成立。

---

## 4. 负对照（**必须发火**）

外科式网表突变（只动 `Conv3x3Slice` 里的一行）：

```
- assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);      // 正确：读描述符 STRIDE
+ assign effS = 4'b0001;                                       // MUT：**忽略 STRIDE**（当成 stride=1）
```

| 打在哪个用例 | 期望 | 实测 |
|---|---|---|
| `lid0_s2`（真 `Conv_0`、`+STRIDE=2`） | **RED**（MISMATCH > 0） | **MISMATCH=1610**（20480 B）✓ 定点发火 |
| `lid0_s1`（同一几何、`+STRIDE=1`） | **GREEN**（MISMATCH = 0） | **MISMATCH=0**（81920 B）✓ **这一刀是外科式的** |

⇒ 这一对结果同时证明两件事：(a) 判据确实抓"步长抽稀"，(b) 突变**只**切掉步长抽稀、其余数据通路一字未动
（这正是"`stride=1` 行为未变"的**反面对照**）。
另有"黄金分辨度"守卫：`lid0` 的 `s=2` 与 `s=1` 黄金差 **81920 个 token**（>0 ⇒ 步长真的改变了输出）。

---

## 5. 哪些路径支持 / 哪些不支持（明写）

| 路径 | 状态 |
|---|---|
| **宽/多趟**（`MultiPassUnit`；真 `Conv_0` 走这条：`C_in=3→8` 零填补、`C_out=16` 两个 co-block） | **支持并逐字节证死**（§3） |
| **窄通路**（`UnitExec` 的 `Conv3x3Slice` 直连，`C_in=C_out=GROUP=1=8`） | **支持**（`strideEff` 已接、喂列/收料/pad 行边界按 `inRows = IMG_H·s` 派生；`s=1` 时逐字同值）—— 但本任务**没有**一条真 stride≥2 的窄层可用（见下），故只有 `s=1` 的回归证据 |
| **融合链**（`chainLen ≥ 2`） | **不支持 `stride > 1`**（中间张量的 H/W 逐片变，本版几何推导不覆盖）⇒ `go` 那一刻**响亮 `err` + 零搬运**（`strideChainOk`），**绝不静默** |
| **depthwise**（`0x03`，`GROUP == C_in == C_out`） | 走**同一份** `MultiPassUnit`（`DwUnit.v` 与它同 md5）⇒ 步长**结构性可用**；真网 depthwise 层都是 stride=1 ⇒ 未单独出 stride≥2 的 depthwise 用例 |
| **旁路算子**（MaxPool/Resize/Add/Sigmoid） | **不需要**：它们各有自己的几何口径（`MaxPool` 本身就是 `2×2/stride2`，`Resize` 是最近邻倍率），与卷积的 `stride` 无关 ⇒ 本任务**未动**它们（任务允许"scope to conv"） |
| **BYPS 的 `IN_BYTES`/地址** | 未动（描述符格式一字未改） |

---

## 6. 闸门尾巴（`bash y1/tools/run_stride_ab.sh`）

```
---- [0] tools/stride_ref.py --selftest（两套实现互证 + s=1 == 冻结 caliber + s>1 != s=1）----
    PASS 断言数=35
    SELFTEST_STRIDE cases=7 fails=0
---- [1] 供料：真 Conv_0（lid0）s=2 / s=1（W=640）+ 合成 3->8 s=2（W=8）----
    STRIDE_REF name=Conv_0 CIN=3 COUT=16 HIN=8 WIN=640 S=2 HO=4 WO=320 NPIX=1280 M=57384 ZY=41 ZPAD=-128 NCI=1 NCO=2 NPASS=2
    STRIDE_REF twoimpl_diff=0 tiled_diff=0 distinct=20 int32_ok=1 gold_md5=b5961a8d42a14f01c7c42ba2c1980742
    STRIDE_REF name=Conv_0 CIN=3 COUT=16 HIN=8 WIN=640 S=1 HO=8 WO=640 NPIX=5120 M=57384 ZY=41 ZPAD=-128 NCI=1 NCO=2 NPASS=2
    STRIDE_REF twoimpl_diff=0 tiled_diff=0 distinct=28 int32_ok=1 gold_md5=9d9b32bd4814c97ea7961ebc24517c7b
    STRIDE_REF name=Synth_3_8 CIN=3 COUT=8 HIN=4 WIN=8 S=2 HO=2 WO=4 NPIX=8 M=3000000 ZY=-1 ZPAD=-128 NCI=1 NCO=1 NPASS=1
---- [2] 结构证据：网表里 stride 口 + 抽稀判据（effS/dm/rm）都在 ----
  OK   stride 口（命中 2 处） / OK effS（1 处） / OK 列相位（1 处） / OK 行相位（1 处）
STRUCT: PASS
  total dangling instances: 0
---- [4] 逐用例：正对照（逐字节）+ 黄金非退化 ----
CASE lid0_s2  MISMATCH=0 distinct(gold=20,rtl=20)
CASE lid0_s1  MISMATCH=0 distinct(gold=28,rtl=28)
CASE synth38_s2 MISMATCH=0 distinct(gold=16,rtl=16)
GOLD 分辨度：lid0 s=2 vs s=1 的黄金差 81920 个 token
---- [5] 负对照：网表突变"忽略 STRIDE" ----
NEG-A lid0_s2 + 突变体：MISMATCH=1610（>0 必须）
NEG-B lid0_s1 + 同一突变体：MISMATCH=0（==0 ⇒ 外科式）
STRIDE_RESULT: PASS
RESULT: PASS     （墙钟 ≈ 39 s）
```

**既有闸门回归**：见 §7 的表（`stride=1` 逐字节不变；`gen/DwUnit.v == gen/MultiPassUnit.v` 的
"同一份算术"md5 断言仍成立）。`tools/check_dangling.py` 对 `gen/stride640/MultiPassUnit.v` 与
`gen/MultiPassUnit.v` 零悬空。

---

## 7. `UnitExec` 级的接线与几何（本闸门之外的证据）

描述符 `STRIDE` 在 `UnitExec` 里**被消费**（此前只被 `DescFetch` 译出、无人用）：

* `strideEff` → 喂给 `L_MAX` 个 `Conv3x3Slice` **和** `mpu`（`MultiPassUnit`）；
* **输入行数** `inRows = IMG_H · s`：ONNX 的 `Ho = floor((H_in+2·pad-K)/s)+1` 在 `pad=1,K=3` 下**不能唯一
  反解** `H_in`（`H_in ∈ [Ho·s-s+1, Ho·s]`）⇒ 取**上界** `Ho·s`；真网 `Conv_0` **恰落上界**（320·2 = 640）✓。
  喂列口径 = `inRows` 真行 + 1 行下边 pad 行；`s=1` ⇒ 与改动前**逐字同值**（`IMG_H`）；
* **输入宽** `inWOk`：`WIDTH ∈ [IMG_W·s - s + 1, IMG_W·s]`（`s=1` ⇒ 塌成 `IMG_W == WIDTH`，**退化成改动前
  的同一条判据**）；真网 `Conv_0`（`IMG_W=320, s=2`）⇒ `WIDTH ∈ {639,640}`，本闸门用 **640** ✓；
* **B3 的 DDR gather**（`XDMA_EN=1` 时读激活）的平面步长/组数由 `pixPer`（= **输出**平面）改成
  `inPix = inRows × WIDTH`（= **输入**平面）；`s=1` ⇒ `inPix == pixPer`（逐字同值）；
* `stride > 1` 且 `chainLen > 1` ⇒ **响亮 `err` + 零搬运**。

**未能验证（诚实清单）**：

1. **`UnitExec` 级的 stride≥2 端到端数值**：`UnitExecTb` 在 time 0 硬断言 `IMG_W == 网表 imgW`（stride=1
   语义）；跑 stride≥2 需要 `IMG_W = 320 / WIDTH = 640` 的**新 TB 口径**。本任务把集成证据落在
   **单元级**（`MultiPassUnit`，即真 `Conv_0` 实际走的那条多趟通路）+ `UnitExec` 的**静态接线/几何**上。
   要补的话：给 `UnitExecWideTb` 加 `+STRIDE`（照 `MultiPassTb` 的样子，缺省 1）—— 属下一片。
2. **整帧 640×640 的 RTL 仿真不可行**：真帧一趟 = 641×640 列 × 2 趟 ≈ **9M 周期**，iverilog 下 > 1 小时
   ⇒ 本闸门用**真 640 列的 8 行条带**（横向几何 100% 为真、纵向 4 行输出）。这与既有真层闸门
   （`run_unitexec_wide_ab.sh` 用 `H=4/W=64`）是**同一条**取舍。
3. **同一 `Ho` 的"另一个解"**：若某层 `H_in < Ho·s`（`H_in` 与 `Ho·s` 之间可选），本单元按上界喂 ⇒ 会
   多喂 1 行（真帧 `Conv_0` 不在这一档）。描述符里**没有**输入图高 ⇒ 这是驱动方/布局口径的事，已明写。
4. **窄通路的 stride≥2 数值**：真表里没有可用的一条（窄通路 = `C_in=C_out=GROUP=1=8`，9 个真单元都是
   stride=1）⇒ 只有 `s=1` 回归证据。
5. **`MultiPassTb` 的 `+STRIDE`/`+PADV`** 是新口；`run_multipass_ab.sh`（不带这两个 plusarg）逐字节不变
   （缺省 1 / 0）—— 见 §6 的回归表。
6. **真 `Conv_0` 黄金有半区饱和**：该层 `bias_adj` 全为正（仅 co 5/10 为负）、配 `M=57384 / z_y=41`
   （转换器发布的配对，与 `run_paramdel_ab.sh` / `wide_exec_ref` **同一份**）⇒ 约一半像素落在 `+127` 轨道，
   判据在那儿分辨率低。**这一条与既有真层闸门同源**，且"完全分辨"的角色由 §3 的合成小用例承担
   （`distinct=16`、`MISMATCH=0`）。

---

# D1b：**集成 `UnitExec` 级**的 `stride >= 2` 数值收口（关闭 D1 §7「未能验证」第 1 条）

上游：本节关闭 D1（`0766cbe`）报告 §7 的遗留第 1 条 ——
*「`UnitExec` 级的 stride≥2 端到端数值待给 `UnitExecWideTb` 加 `+STRIDE`（下一片）」*。

**本片 RTL 一行未改**（承重证据见 §1）：D1 已把 `stride` 接到 `Conv3x3Slice`/`MultiPassUnit`/`UnitExec`；
本片只**给装置加口**（`+STRIDE`）、给**闸门加判据**、并**新增一档 `WIDTH=640` 真行宽的生成配置**
（既有两份网表 md5 逐字不变），把"步长抽稀"逐字节证到**集成 `UnitExec` 的真行宽**上。

---

## 1) 改动清单（文件 + md5）

| 文件 | md5 | 改了什么 |
|---|---|---|
| `y1/rtl_test/UnitExecWideTb.v` | `274a2b806f3a9cbb6620baa90b682e02` | **新增 `+STRIDE=<1..15>`（缺省 1）**：只驱动描述符 `desc3` 的 `STRIDE` 域（`w3[11:8]`）；`+H`/`+W` 仍是**输出**几何；`TB WIDE:` 自报行加 `STRIDE=` |
| `y1/tools/stride_ref.py` | `1f669483b1dc425fdfc1aa3c21e3979e` | **新增落盘 `xcol.hex`**（= **集成 `UnitExec` 的 `wide_x` 列流**：一趟"行主序、一拍一列 = 一像素 8 通道"）与 `job.txt` 的 `NCOL`；`x.hex`/`w.hex`/`b.hex`/`gold.hex` 的**口径一字未改**（D1 闸门 `run_stride_ab.sh` 逐字节不变） |
| `y1/tools/run_stride_exec_ab.sh` | `523af25733356eb337c9e99536d29d41` | **新**：本片闸门（5 个用例 + 两份网表 + 正/负对照 + 交叉对账 + 结构 + 定位） |
| `y1/rtl_test/UnitExecGen.scala` | `9a31883914dd64e39b6eaa895ee64f13` | **新增第三份生成配置** `UnitExec_w640.v`（`C=8 WIDTH=640 IMG_H_MAX=4 L_MAX=8`）—— 真行宽档（既有两份配置一字未动） |

**RTL 零改动；网表：既有两份 md5 逐字不变 + 新增真行宽一档（实测对账）**：

| 网表 | 本片实测 md5 | D1 报告 §2 的 md5 |
|---|---|---|
| `gen/UnitExec.v`（`WIDTH=64`，小档用例） | `b29c5e73d399ba75eb4aa33a5d58a376` | `b29c5e73d399ba75eb4aa33a5d58a376`（**逐字相同**） |
| `gen/Conv3x3Slice.v` | `76816030cb60572ea41604a47f172300` | `76816030cb60572ea41604a47f172300`（**逐字相同**） |
| `gen/MultiPassUnit.v` | `cd7205c5a21d1dc588b4db66be4c7137` | `cd7205c5a21d1dc588b4db66be4c7137`（**逐字相同**） |
| `gen/UnitExec_w640.v`（**新**：`WIDTH=640` **真行宽**，17,412,882 B） | `297419cb7f3044c6a265b1ba404402d6` | —（本片新增） |

★ **RTL 与既有网表一字未改**（`Conv3x3Slice.scala`/`MultiPassUnit.scala`/`UnitExec.scala` 未动；
`gen/UnitExec.v` 与 D1 报告 §2 **逐字相同**）⇒ `stride=1` 路径"逐字节不变"的**结构性理由**是这张表。
`UnitExecGen` 的**第二次生成**（确定性 2×）三份网表 md5 全部**逐字相同**（`md5sum -c` OK）。
`tools/check_dangling.py` 对三份网表**全部零悬空**。

---

## 2) `UnitExec` 级的几何口径（本闸门怎么把 stride 喂进去）

`UnitExec` 的 `WIDERUN` 通路（`rtl/UnitExec.scala`）在 `go` 那一刻把描述符 `STRIDE`（`w3[11:8]`，字段 `0`
视作 1）译成 `strideEff`，**同时**接给宽层多趟的 `MultiPassUnit`（`mpu.io.stride`）与窄通路的切片
（`slices(i).io.stride`）；喂列几何随 `s` 派生：**每趟 `inRows = IMG_H·s` 个真行**（各 `WIDTH` 列）
+ **1 行 DUT 自己合成的 pad 行（= `z_pad`）**；本网表行宽须落在 `inWOk = WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]`
（`s=1` ⇒ 退化成 `IMG_W == WIDTH`）。

本闸门用**两档网表**（`gen/UnitExec.v` 的 `WIDTH=64` 小档 + `gen/UnitExec_w640.v` 的 `WIDTH=640` **真行宽**档），
五个用例全部落各自网表的 `inWOk`：

| 用例 | 网表 | 输入（`stride_ref --emit`） | 描述符（`+H`/`+W`/`+STRIDE`） | DUT 每趟喂 | 输出 | 黄金来源 |
|---|---|---|---|---|---|---|
| **`s2_real`** | W=64 | **真 `Conv_0`**（`--lid 0`）`H_in=8 × 64` | `IMG 4×32` / `STRIDE=2` | `8 × 64` 列 | `4 × 32` | `stride_ref`（D1 的那一份） |
| **`s1_real`**（回归锚） | W=64 | 同一真层 `H_in=4 × 64` | `IMG 4×64` / `STRIDE=1` | `4 × 64` 列 | `4 × 64` | 同上（== `run_unitexec_wide_ab.sh` 的 lid0） |
| **`s2_synth`** | W=64 | 合成 `C_in=16 → C_out=16`（`n_ci=2` ⇒ 打**跨 ci 趟累加** + 步长） | `IMG 2×32` / `STRIDE=2` | `4 × 64` 列 | `2 × 32` | 同上 |
| **`s2_real640`** ★ | **W=640** | 真 `Conv_0` `H_in=8 × 640`（**真行宽**） | `IMG 4×320` / `STRIDE=2` | `8 × 640` 列 | **`4 × 320`（横向抽稀整段为真：640 → 320）** | 同上 |
| **`s1_real640`**（真行宽锚） | **W=640** | 同一真层 `H_in=4 × 640` | `IMG 4×640` / `STRIDE=1` | `4 × 640` 列 | `4 × 640` | 同上 |

★ `s2_real640` 的黄金与 D1 闸门（`run_stride_ab.sh`）的 `lid0_s2`（`WIDTH=640`、`H_in=8`、`s=2`）**同一份**
（同工具、同向量、同几何 ⇒ 值 md5 `b5961a8d42a14f01c7c42ba2c1980742`）。
★ `WIDTH=640` 档的**输出存储上限** `PIXW = WIDTH·IMG_H_MAX = 2560` ⇒ 用例必须 `IMG_H·IMG_W ≤ 2560`
（`s2_real640`：`4·320=1280` ✓；`s1_real640`：`4·640=2560` 恰落上限 ✓）——闸门把这一条当作**前提对账**
（读 DUT 自报的 `RTL_MAXPIX`）。

真 `Conv_0` 的权重/参数**全为真**（`C_in=3 C_out=16 GROUP=1 3×3 pads=1 strides=[2,2]`；`M=57384 z_pad=-128
z_y=41 bias_adj[16]` 取自 `gen/wgt_index.json` + `gen/wgt_blob.bin`，与 `run_unitexec_wide_ab.sh` / B2 / B3
**同一份**）。空间范围是**条带**（`WIDTH=64` 而非真帧的 640）—— 理由与 D1 闸门同源，见 §6。

---

## 3) 正对照（逐字节，**集成 `UnitExec`**）

```
---- [5] 逐作业：集成 UnitExec 的 DST 区逐字节 == 黄金 + 自报 + 退化守卫 ----
    [s2_real] TB WIDE: CIN=3 COUT=16 H=4 W=32 GROUP=1 STRIDE=2 SRC=131072 DST=2097152 INB=1536 QSHIFT=6 LID=0 M=57384 ZPAD=-128 ZY=41 NCOL=1024 NCI=1 NCO=2
    [s2_real] TB WIDE RTL: imgC=8 imgW=64 RTL_MAXPIX=256 WIDE_ON=1 WIDE_PASSES=2 RTL_M=57384 RTL_ZPAD=-128 RTL_ZY=41 RTL_LAYER=0
    [s2_real] DONE_SEEN=1 ERR_SEEN=0 NFED=1024/1024 RD_PEAK=0 RD_BYTES=0 WGT_BYTES=0 WR_BYTES=2048 AR=0 AW=16 B=16 WBASE=0
    [s2_real] RESULT: PASS   MISMATCH=0  DST_NEIGHBOR32_BAD=0  FIRST_IDX=-1
JOB s2_real    net=n64  STRIDE=2 M=57384   ZPAD=-128 ZY=41  n_ci=1 n_co=2 passes=2 NCOL=1024  | DST_MISMATCH=0 neigh=0 distinct(gold=19) imgW=64  in [63,64]
JOB s1_real    net=n64  STRIDE=1 M=57384   ZPAD=-128 ZY=41  n_ci=1 n_co=2 passes=2 NCOL=512   | DST_MISMATCH=0 neigh=0 distinct(gold=26) imgW=64  in [64,64]
JOB s2_synth   net=n64  STRIDE=2 M=3000000 ZPAD=-128 ZY=-1  n_ci=2 n_co=2 passes=4 NCOL=1024  | DST_MISMATCH=0 neigh=0 distinct(gold=48) imgW=64  in [63,64]
    [s2_real640] TB WIDE: CIN=3 COUT=16 H=4 W=320 GROUP=1 STRIDE=2 SRC=131072 DST=2097152 INB=15360 QSHIFT=6 LID=0 M=57384 ZPAD=-128 ZY=41 NCOL=10240 NCI=1 NCO=2
    [s2_real640] TB WIDE RTL: imgC=8 imgW=640 RTL_MAXPIX=2560 WIDE_ON=1 WIDE_PASSES=2 RTL_M=57384 RTL_ZPAD=-128 RTL_ZY=41 RTL_LAYER=0
    [s2_real640] DONE_SEEN=1 ERR_SEEN=0 NFED=10240/10240 RD_PEAK=0 RD_BYTES=0 WGT_BYTES=0 WR_BYTES=20480 AR=0 AW=160 B=160 WBASE=0
    [s2_real640] RESULT: PASS   MISMATCH=0  DST_NEIGHBOR32_BAD=0  FIRST_IDX=-1     (CYCLES=64237)
JOB s2_real640 net=n640 STRIDE=2 M=57384   ZPAD=-128 ZY=41  n_ci=1 n_co=2 passes=2 NCOL=10240 | DST_MISMATCH=0 neigh=0 distinct(gold=20) imgW=640 in [639,640]
JOB s1_real640 net=n640 STRIDE=1 M=57384   ZPAD=-128 ZY=41  n_ci=1 n_co=2 passes=2 NCOL=5120  | DST_MISMATCH=0 neigh=0 distinct(gold=27) imgW=640 in [640,640]
GOLD 分辨度：s=2 vs s=1 的黄金差 W=640: 40960 / W=64: 4096 个 token（>0 ⇒ 步长真改了输出）
    GOLD640 s2_real640 值md5=b5961a8d42a14f01c7c42ba2c1980742（D1 §6 的 lid0_s2 = b5961a8d42a14f01c7c42ba2c1980742）
```

* 五个用例的 `DST` 区都 **`MISMATCH=0`**（逐字节 == `stride_ref` 黄金），邻居 32 B 未动；
  `WR_BYTES == C_OUT·IMG_H·IMG_W`、`AW=B=C_OUT·IMG_H·IMG_W/128`
  （2048/128=16、4096/128=32、1024/128=8、20480/128=160、40960/128=320 ✓）；
* **真行宽档**（`WIDTH=640`）两个用例的 `imgW=640` 落在 `inWOk`（`s=2`：`[639,640]`；`s=1`：`[640,640]`），
  且 `IMG_H·IMG_W ≤ RTL_MAXPIX=2560`（前提对账）；
* **自报对账**：`WIDE_ON=1`、`WIDE_PASSES == n_ci·n_co`（2/2/4/2/2 ✓）；
* 宽层不读 DDR：`RD_PEAK=RD_BYTES=0`（与既有宽层闸门同口径）；
* **真行宽黄金与 D1 闸门 §6 的 `lid0_s2` 同值**（`b5961a8d42a14f01c7c42ba2c1980742`）⇒ 参考侧与 D1 **同一份**。

**"`stride=1` 与既有作业是同一个"的承重证据（§3 交叉对账）**：同一次 `--emit`，两个**独立工具**各给一份，
逐字节相同 ⇒ 本闸门的 `s1_real` **就是** `run_unitexec_wide_ab.sh` 的 `lid0_Conv_0` 用例（同装置、同网表、
同向量、同黄金）：

```
---- [2] 交叉对账：s=1 的列流/黄金 与 冻结 C4a.5b 口径（wide_exec_ref）逐字节同 ----
    CROSS xcol.hex(s=1) vs wide_exec_ref x.hex   : MISMATCH=0 （期望 0）
    CROSS gold.hex(s=1) vs wide_exec_ref gold.hex: MISMATCH=0 （期望 0）
```

---

## 4) 负对照（**必须发火**，且**定位到第一个不符的输出元素**）

外科式网表突变（只动 `Conv3x3Slice` 里的一行，与 D1 §4 **同一刀**）：

```
- assign effS = ((stride == 4'b0000) ? 4'b0001 : stride);      // 正确：读描述符 STRIDE
+ assign effS = 4'b0001;                                       // MUT：**忽略 STRIDE**（当成 stride=1）
```

| 打在哪个用例（网表） | 期望 | 实测 |
|---|---|---|
| `s2_real`（W=64、`+STRIDE=2`） | **RED**（MISMATCH > 0） | **MISMATCH=170**；**首个不符元素 `FIRST_IDX=192` ⇒ `co=1 y=2 x=0`** ✓ |
| `s2_real640`（**W=640 真行宽**、`+STRIDE=2`） | **RED**（MISMATCH > 0） | **MISMATCH=1613**；**首个不符元素 `FIRST_IDX=1611` ⇒ `co=1 y=1 x=11`** ✓ |
| `s1_real`（W=64、`+STRIDE=1`） | **GREEN**（MISMATCH = 0） | **MISMATCH=0** ✓ 外科式 |
| `s1_real640`（**W=640 真行宽**、`+STRIDE=1`） | **GREEN**（MISMATCH = 0） | **MISMATCH=0** ✓ 外科式 |

两份网表**各打一刀**（同一个外科式突变），四处结果一致。

⇒ 同时证明：(a) 判据确实抓"步长抽稀"；(b) 突变**只**切掉步长抽稀，其余数据通路一字未动（这正是
"`stride=1` 行为未变"的**反面对照**）。★ 诚实记录：突变体在 `s2_real`/`s2_real640` 上**装置自己判 FAIL**
（`NFED=388/1024`、`3844/10240`）—— 因为步长抽稀被切掉后，切片**按 stride-1 每列出一个像素**，`UnitExec` 的
"本趟收工" = "看到第 `H·W` 个 `y_valid`"（`wEmitCnt == pixPer-1`）**提前触发** ⇒ 该趟少喂列。这与 D1 闸门的
NEG-A 同形（D1 的装置也不 PASS），**数值判据仍独立发火且定位**，故判据的牙不受影响。

---

## 5) 闸门尾巴（`bash y1/tools/run_stride_exec_ab.sh`）

```
---- [0] tools/stride_ref.py --selftest（两套实现互证 + s=1 == 冻结 caliber + s>1 != s=1）----
    PASS 断言数=35
    SELFTEST_STRIDE cases=7 fails=0
---- [1] 供料：stride_ref --emit —— 真 Conv_0 s=2/s=1（W=64 与 W=640 两档）+ 合成 16->16 s=2 ----
    STRIDE_REF name=Conv_0    CIN=3  COUT=16 HIN=8 WIN=64  S=2 HO=4 WO=32  NPIX=128  NCI=1 NCO=2 NPASS=2
    STRIDE_REF name=Conv_0    CIN=3  COUT=16 HIN=4 WIN=64  S=1 HO=4 WO=64  NPIX=256  NCI=1 NCO=2 NPASS=2
    STRIDE_REF name=Synth_16_16 CIN=16 COUT=16 HIN=4 WIN=64 S=2 HO=2 WO=32 NPIX=64  NCI=2 NCO=2 NPASS=4
    STRIDE_REF name=Conv_0    CIN=3  COUT=16 HIN=8 WIN=640 S=2 HO=4 WO=320 NPIX=1280 NCI=1 NCO=2 NPASS=2
    STRIDE_REF name=Conv_0    CIN=3  COUT=16 HIN=4 WIN=640 S=1 HO=4 WO=640 NPIX=2560 NCI=1 NCO=2 NPASS=2
    GOLD640 s2_real640 值md5=b5961a8d42a14f01c7c42ba2c1980742（D1 §6 的 lid0_s2 = b5961a8d42a14f01c7c42ba2c1980742）
---- [2] 交叉对账：s1_real(W=64) 的列流/黄金 与 冻结 C4a.5b 口径（wide_exec_ref）逐字节同 ----
    CROSS xcol.hex(s=1,W=64) vs wide_exec_ref x.hex   : MISMATCH=0 （期望 0）
    CROSS gold.hex(s=1,W=64) vs wide_exec_ref gold.hex: MISMATCH=0 （期望 0）
---- [3] 结构证据：两份网表里 stride 口 + 抽稀判据（effS/dm/rm）都在 ----
  [gen/UnitExec.v]      OK stride 口(2) / effS(1) / 列相位(1) / 行相位(1)  STRUCT: PASS / 悬空 0
  [gen/UnitExec_w640.v] OK stride 口(2) / effS(1) / 列相位(1) / 行相位(1)  STRUCT: PASS / 悬空 0
---- [4] iverilog 编译（UnitExecWideTb + AxiMemModel + 两份网表 / 两份突变体）----
    好网表编译 OK（WIDTH=64 与 WIDTH=640 两档）；突变体编译 OK（外科式：只动切片里的那一行）
---- [5] 逐作业：集成 UnitExec 的 DST 区逐字节 == 黄金 + 自报 + 退化守卫 ----
（五个用例的逐字证据见 §3；全部 DST_MISMATCH=0）
---- [6] 负对照：网表突变"忽略 STRIDE" ⇒ s=2 必红（定位首个不符元素）+ s=1 必绿（外科式）----
NEG-A s2_real    + 突变体（n64 网表）：MISMATCH=170（>0 **必须**）  首个不符输出元素: FIRST_IDX=192  co=1 y=2 x=0
NEG-A s2_real640 + 突变体（n640 网表）：MISMATCH=1613（>0 **必须**） 首个不符输出元素: FIRST_IDX=1611 co=1 y=1 x=11
NEG-B s1_real    + 同一突变体（n64 网表）：MISMATCH=0（==0 ⇒ 这一刀只切掉步长抽稀）
NEG-B s1_real640 + 同一突变体（n640 网表）：MISMATCH=0（==0 ⇒ 这一刀只切掉步长抽稀）
STRIDE_EXEC_RESULT: PASS
RESULT: PASS     （墙钟 ≈ 182 s）
```

---

## 6) 能证 / 不能证（诚实清单）

**能证**：**集成 `UnitExec`** 上，真 `Conv_0` 的**真权重/参数/步长/pads**在 `s=2` 下 DST 区**逐字节 == 参考**
（`MISMATCH=0`），横向抽稀整段为真（64 → 32）；`s=1` 与冻结 C4a.5b 口径**同作业逐字节**（列流与黄金两处
独立对账 0 差）；跨 `ci` 趟累加 + 步长的合成用例也逐字节；负对照**定点发火并定位**首个不符元素，且对 `s=1`
**外科式**（0 差）。

**不能证 / 未做（明写）**：

1. **真帧 640×640 整帧未仿真**（不可行：真帧一趟 ≈ 641×640 列 × 2 趟 ≈ **9M 周期**）⇒ 本闸门在集成
   `UnitExec` 上用 **真行宽的 8 行条带**（`WIDTH=640`、`H_in=8` ⇒ 输出 `IMG 4×320`；
   **横向抽稀整段为真：640 → 320**，纵向 4 行输出）—— 与 D1 的 `run_stride_ab.sh` **同一条取舍**；
   另有 `WIDTH=64` 小档（`IMG 4×32`）作对照。**纵向整帧（320 输出行）未仿真**：纵向 stride 抽稀（`rm` 相位）
   在 4 个输出行里被走到，但"整张 320 行"的纵向几何没有真跑。
2. **同一 `Ho` 的"另一个解"（`H_in < Ho·s`）**：本单元按上界喂（`inRows = IMG_H·s`）；真帧 `Conv_0` 恰落上界。
   描述符里没有输入图高 ⇒ 这是驱动方/布局口径的事（D1 §7 第 3 条，未变）。
3. **窄通路的 stride≥2**：真表里没有可用的一条（窄通路 = `C_in=C_out=GROUP=1=8`，真单元全是 stride=1）
   ⇒ 仍只有 `s=1` 回归证据（D1 §7 第 4 条，未变）。
4. **融合链 `chainLen ≥ 2` 的 stride>1**：仍**响亮 err + 零搬运**（D1 的 `strideChainOk`；本片未动）。
5. **`+STRIDE` 是新口**：既有宽层闸门（`run_unitexec_wide_ab.sh`，不带 `+STRIDE`）**逐字节不变**（缺省 1）
   —— 见 §7 的回归表。
6. **真 `Conv_0` 黄金有半区饱和**（`bias_adj` 多正、`M=57384 z_y=41`）⇒ 约一半像素落 `+127` 轨道，
   判据在那儿分辨率低；"完全分辨"的角色由 `s2_synth`（`distinct=48`）承担。**与既有真层闸门同源。**
7. **`gen/UnitExec_w640.v` 的一条编译告警（明写，无害）**：`mid_rd_col` 观察口在 `WIDTH=640` 档是 **10 位**
   （`log2Up(640)`）而装置声明 6 位 ⇒ iverilog 打一条 "Padding high bits of the port"。该口**仅观察**
   （只有 `state==IDLE` 时才被 `FusionBuf` 取用；宽通路运行期不吃）⇒ 保证既有 `WIDTH=64` 档**零告警**
   才保持 6 位。`WIDTH=640` 档的 `AW=B=160/320`、`WR_BYTES`、`DONE_SEEN` 与数值判据全部正常。

---

## 7) 回归（本片）与相关文件

* **既有闸门全绿**（`y1/tools/run_*_ab.sh`，**43/43 `rc=0`**；`run_numeric_ab` 是**带参**探针 ⇒ 跳过；
  `run_grouped/linebuffer/macarray/twoclock/weightstore` 走 `JUDGE-GREEN` 口径、不打印 `RESULT:` 行）：

```
run_addsrc2_ab PASS         run_axilite_cdc_ab PASS    run_bypass_ab PASS
run_chain_ab PASS           run_convert_ab PASS        run_ddrcopy_ab PASS
run_ddrmaster32_ab PASS     run_ddrread_ab PASS        run_ddrwrite_ab PASS
run_desc_ab PASS            run_dw_ab PASS             run_dw_wide_ab PASS
run_frame_ab PASS           run_fuse_ab PASS           run_fuse_head_ab PASS
run_fusionbuf_ab PASS       run_grouped_ab (JG)        run_hostregs_ab PASS
run_inlayout_ab PASS        run_irqrst_cdc_ab PASS     run_layout_ab PASS
run_layoutadapt_ab PASS     run_linebuffer_ab (JG)     run_macarray_ab (JG)
run_mem_cdc_ab PASS         run_multipass_ab PASS      run_nonwide_wide_ab PASS
run_nputop_ab PASS          run_nputop_sched_ab PASS   run_paramdel_ab PASS
run_quant_ab PASS           run_sched_ab PASS          run_stride_ab PASS
run_stride_exec_ab PASS     run_tiling_ab PASS         run_twoclock_ab (JG)
run_unitexec_ab PASS        run_unitexec_wide_ab PASS  run_weightstore_ab (JG)
run_wgtdma_ab PASS          run_wgtdma_geom_ab PASS    run_wgtdma_wide_ab PASS
run_wide_tail_ab PASS
```

  `+STRIDE` 缺省 1 ⇒ **既有作业逐字节不变**（尤其 `run_unitexec_wide_ab.sh` 的 `lid0_Conv_0` 与
  `run_stride_ab.sh`；后者的参考 `stride_ref.py` 只是**多落一个 `xcol.hex`**，`x/w/b/gold` 口径未动）。
* **台账**：`scripts/check_addr_map.py` ⇒ `PASS: address ledger consistent (16 sites reconciled)`（SoC 台账未动）。
* **悬空**：`tools/check_dangling.py` 对 `gen/UnitExec.v` / `_w32.v` / `_w640.v` **三份全部零悬空**。
* **网表确定性（2×）**：RTL 零改动；`UnitExecGen` 的第三份配置**只增不改** ⇒ `gen/UnitExec.v` /
  `gen/UnitExec_w32.v` 的 md5 与 D1 报告 §2 **逐字相同**，且**连续两次生成**三份网表 md5 **全部相同**
  （`md5sum -c` OK）。
* **RTL 相关回归**（本片改动后复跑）：`run_unitexec_ab` / `run_unitexec_wide_ab` / `run_chain_ab` /
  `run_sched_ab` / `run_nputop_ab` / `run_nputop_sched_ab` / `run_stride_ab` / `run_stride_exec_ab` 全绿。
* 相关文件：装置 `y1/rtl_test/UnitExecWideTb.v`（`+STRIDE`）；生成配置 `y1/rtl_test/UnitExecGen.scala`（`UnitExec_w640.v`）；
  供料 `y1/tools/stride_ref.py`（`xcol.hex`/`NCOL`）；闸门 `y1/tools/run_stride_exec_ab.sh`；
  接线 `y1/rtl/UnitExec.scala`（D1 的「C4b-D1」一节：`strideEff`/`inRows`/`inWOk`）。
