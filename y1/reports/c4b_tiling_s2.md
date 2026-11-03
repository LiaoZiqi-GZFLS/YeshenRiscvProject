# T-S2 报告 —— **2-D tile 的物理尺寸（`dev_map` 仲裁）+ `W_MAX` 收窄**

- 日期：2026-10-14
- spec：`docs/superpowers/specs/2026-10-13-y1-runtime-width-and-tiling-design.md`
  **§2**（缓冲随 `P=W×H` 放大）、**§3/§3.1**（方案 C + `rowW`）、**§4.1/§6-R4**（tile 尺寸与"以 `dev_map` 为准"）、
  **§5 T2**（判据）、**§7 S2**（本片范围）
- 上游：`0b24bf0`（T-S0：离线钉死 halo 规则）、`b87407f`+`744a7a0`（T-S1：运行期 `rowW`，分配仍按 `W_MAX=640`）
- ★★ **T-S2R 追加**（本文件 §10）：**RTL tile 循环 + 行跨步 halo gather**（编译期开关 `TILING`）——
  逐字节证书 + 两条负对照 + `dev_map`（含新循环）+ 两个 bug（零扩符号 / tile 抢 DMA 装载）的受控实验。
- 本片**未做**：PnR / 板级（S3）。

**Status: DONE（面积判据达成；**RTL tile 循环 + halo gather 已交付并逐字节证死**；宽通路的 tiling 仍是开口项，见 §10.7）**

---

## 0. 一句话结论

1. **spec §4.1 推荐的 tile 尺寸（64×32 ⇒ `W_MAX=66 / H_TILE=32`）装不下器件**：
   独立 NPU 探针 `dev_map` **失败**，`Adm-4088 ×195`（DRM 不够，`wOutMem_*` / `mpu/psb/mem_*`
   从 DRM 掉进 LUTRAM），退出码 1。**spec §3 的"1.29 MB 装得下"是按字节算的估值，被 `dev_map` 否掉。**
2. 按 spec §4.1/§6-R4 自己点名的**回落档 32×32**（`W_MAX=34 / H_TILE=32`）：
   同一探针 `dev_map` **成功、`Adm-4088 = 0`**，`DRM 319/415 = 77%`（LUT 62%、APM 74%、FF 37%、DistRAM 14%）。
   ⇒ **采用 `W_MAX=34 / H_TILE=32`**，并把 `LayerSched`/`NpuTop` 两处钉点改到它。
3. **已交付（T-S2R，见 §10）**：`UnitExec` 内的 **2-D tile 循环 + 行跨步 halo gather**（编译期开关
   `TILING`，板级 `LayerSched` 已打开）⇒ **"整层 tile 拼接 == 整层"逐字节**（7 个用例：`s=1` 的
   320×320 / 160×160 / 64×32 / 80×80 / 40×40 / 20×20 + `s=2` 的 32×32）；两条负对照（"漏一趟" /
   "不给 halo"）都发火且**定位/分类**；`dev_map`（**含新循环**）**`Adm-4088 = 0`**。
   ⇒ 窄通路（`C_in==C_out==8 ∧ GROUP==1 ∧ 非 DW`、`s∈{1,2}`、单单元、非头）的**任意 `IMG_W×IMG_H`**
   现在都能跑 tile 循环。**宽通路**（真表 `C∈{1,4,16,64}`）的 tiling **仍是开口项**（§10.7：
   走"`go` 那一刻响亮 err + 零搬运"，绝不静默错值）。

---

## 1. 本片交付物

| 文件 | 动作 | 说明 |
|:--|:--|:--|
| `y1/rtl/NpuTop.scala` | 改 | `LayerSched(C=8, WIDTH 640→34, IMG_H_MAX 8→32)` + 注释（几何判词） |
| `y1/rtl_test/LayerSchedGen.scala` | 改 | 同上（`LayerSched` 的生成参数）+ 头注释（Y1-frame/T-S1/T-S2 三代几何的判词） |
| `y1/rtl_test/LayerSchedTb.v` | 改 | conv 项对账 `IMG_W == imgW` → **`IMG_W <= imgW`**（T-S1 的 `rowW` 契约；`s=1` 时与旧式同值） |
| `y1/tools/run_sched_ab.sh` | 改 | 自报期望从"编译期常量"改成 `WMAX=34/HMAX=32/MAXPIX=1088`（几何旋钮显式化） |
| `y1/reports/c4b_tiling_s2.md` | 新 | 本文件 |

**未改**（`git status` 可核）：`rtl/UnitExec.scala`、`rtl/BypassExec.scala` 与所有其它 RTL；
`third_party/**`；冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/
`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`/`tiling_ref.py`）；**描述符格式一字未动**。

---

## 2. 几何：三个数字与它们的出处

| 量 | 值 | 出处 / 为什么 |
|:--|:--|:--|
| `W_MAX`（= `UnitExec.WIDTH` = 物理行宽 = **分配**口径） | **34** | `= W_TILE(32) + 2`（halo 左右各 1 列）；**由 `dev_map` 仲裁**（§3） |
| `H_TILE`（= `IMG_H_MAX` = 输出/部分和存储的行数上限） | **32** | 2-D tile 的行数；`maxPix = 34·32 = 1088` |
| `rowW`（运行期行宽，T-S1 引入） | 运行值 `= IMG_W·s` | `go` 拍闩存；界限 `1 ≤ rowW ≤ W_MAX` **自动**把住（S1 已建好，本片未改一行） |

**分配口径随 `W_MAX`/`H_TILE` 缩小的存储**（`P = W_MAX·H_TILE = 1088`）：

| 结构 | RTL | 64×32（`P=2112`） | **32×32（`P=1088`）** | 640×8（`P=5120`，Y1-frame） |
|:--|:--|--:|--:|--:|
| `PartialSumBuf.mem` | `PartialSumBuf.scala:101`（`NCOB·PIXMAX` 字 × 64 B） | 1.03 MB | **544 KB** | 2.62 MB |
| `wOutMem` | `UnitExec.scala:1295`（`PIXW·NCOB` 字 × 8 B） | 132 KB | **68 KB** | 320 KB |
| `outMem`+`outMemT` | `UnitExec.scala:1162,1178` | 33 KB | **17 KB** | 80 KB |
| `BypassExec.outMem` | `BypassExec.scala:184` | 16.5 KB | **8.5 KB** | 40 KB |
| `FusionBuf ×9` | `FusionBuf.scala:144`（`3·WIDTH` 字） | 13.9 KB | **7.2 KB** | 138 KB |
| **合计（这几项）** | | ≈ **1.27 MB** | **≈ 645 KB** | ≈ 3.20 MB |
| 器件 PG2L200H | | 415 × DRM36K ≈ 1.87 MB | 同 | 同 |

⇒ 字节账**看起来** 645 KB 远小于 1.87 MB，但**字节不等于 DRM**（Pango 把 512-bit 宽字按
`DRM36K` 的行/列模式切分，且 `readAsync` 的组合读口会退化）—— **只有 `dev_map` 说了算**（§3）。

---

## 3. `dev_map` 判词（独立 NPU 探针，`YESHENMINI_C4A_MODE=nputop`）

**复现命令**（工作目录 `D:/code/PDS/VexiiYeshenLinux`；**只 dev_map，不出比特流、不 PnR**）：

```bash
# ③ 生成（几何在 LayerSchedGen.scala / NpuTop.scala 两处钉点）
cd y1 && printf 'Test/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nTest/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh
# ④ dev_map（后台；约 20 min）
cd /d/code/PDS/VexiiYeshenLinux && YESHENMINI_C4A_MODE=nputop \
  /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl \
  > y1/pds/devmap_c4a_nputop_s2.log 2>&1 ; echo "exit=$?"
```

### 3.1 `W_MAX=66 / H_TILE=32`（spec §4.1 推荐，tile 64×32）—— **失败**

| 判据 | 结果 | 证据 |
|:--|:--|:--|
| `Adm-4088`（DRM 不够 ⇒ 掉 LUTRAM） | **195 条** | `pds/devmap_c4a_nputop_s2.log` |
| `dev_map` 退出码 | **1（失败，无 Utilization Summary）** | 同上，`Run process "Device Map" failed` |
| 首号受害者 | `layerSched_1/unitExec_1/mpu/psb/mem_*`、`unitExec_1/wOutMem_*`、`mzRam_*`、`fb/mem`、`bufRest_*/mem`、`biasMem` | 同上（**连 512 B 的 `mzRam` 都拿不到 DRM ⇒ DRM 真的被耗尽**） |

按 RAM 族计数：`mpu/psb/mem` **116**、`wOutMem` **64**、`mzRam` 6、其余（`FusionBuf ×9`+`biasMem`）11。

**根因（承重件，不是布线/约束）**：随行宽×行数放大的两个 512-bit/64-bit 宽存储
`PartialSumBuf.mem`（`8·2112` 字 × 512 bit = 8.65 Mbit）与 `wOutMem`（`8·2112` 字 × 64 bit = 1.08 Mbit）
在 Pango 的 DRM 切分下**远超 415 块 DRM 的可用组合**。⇒ **spec §3 的"1.29 MB 装得下"不成立**，
必须按 §4.1/§6-R4 的回落档走。

### 3.2 `W_MAX=34 / H_TILE=32`（spec 点名的回落档，tile **32×32**）—— **成功**

| 判据 | 结果 |
|:--|:--|
| `Adm-4088` | **0** |
| `dev_map` | **成功**（`Y1_C4A_NPUTOP_DEVMAP_DONE`，退出码 0） |

`Device Utilization Summary`（探针日志 `y1/pds/devmap_s2b_nputop.log`）：

| 资源 | Used | Available | 利用率 |
|:--|--:|--:|--:|
| LUT | 97,901 | 159,800 | **62%** |
| FF | 115,814 | 319,600 | 37% |
| APM | 544 | 740 | 74% |
| DRM | **319** | 415 | **77%** |
| Distributed RAM | 5,448 | 39,500 | 14% |

### 3.3 Δ vs 前基线（口径明示）

| 基线 | 出处 | LUT | FF | APM | DRM | `Adm-4088` |
|:--|:--|--:|--:|--:|--:|--:|
| **Y1-frame 真几何**（`WIDTH=640, IMG_H_MAX=8`），独立 NPU 探针 | `pds/devmap_frame640_nputop.log` | n/a（失败，无表） | n/a | n/a | n/a | **418** |
| C3 定点几何（`WIDTH=32, IMG_H_MAX=16`），`LayerSched(L=8)` 单独综合 | `reports/c3_area.md` §（`LUT 58,788 / FF 68,203 / APM 323 / DRM 8.0`） | 58,788 | 68,203 | 323 | 8.0 | 0 |
| **T-S2 本片**（`WIDTH=34, IMG_H_MAX=32`），独立 NPU 探针 | 本报告 §3.2 | **97,901** | **115,814** | **544** | **319** | **0** |

**读数**：`Adm-4088` 418 → **0**（Y1-frame 的硬判词被消掉）；代价 = DRM 8.0 → **319**（+311，器件 77%）、
LUT 58.8k → 97.9k（+66%，器件 62%）、APM 323 → 544（74%）。**余量**：LUT 39%、DRM 23%、APM 26%。
⇒ **"装得下"达成，但 DRM 只剩 96 块余量** —— 这解释了为什么 64×32 一定不行（64×32 的 `P` 是 32×32 的 1.94 倍）。

> **口径诚实项**：表里第一行与本片**同一装置**（独立 NPU 探针）⇒ 418 → 0 是可比的；
> 第二行是**另一口径**（`LayerSched` 单独综合，无 `DescFetch`/`HostRegs`/`DdrMaster` 顶层）⇒ 只作旁证。
> **板级（integrated）`dev_map` 与 PnR 本片未跑**（S3 / 控制器）。

---

## 4. RTL tile 循环：T-S2 时的**设计 + 未交付**状态

> ★★ **本节是历史**：**T-S2R 已按本节的设计（并修了 §10.3 的两个 bug）把 tile 循环交付了** ——
> 权威内容见 **§10**（实现 / halo gather 映射 / 流量 / `dev_map` / 负对照证据 / 回归 / S3 清单）。
> 本节保留，因为 §4.2 的 halo 取法与 §4.3 的改动点清单仍是实现的工作底稿。

### 4.1 为什么未交付（诚实记账）

本片把预算花在**"面积判据"这个唯一的硬门**上（它需要**两次 20 min 的 `dev_map`** 才收敛，
且第一次就把 spec 的推荐尺寸否掉了）。tile 循环是对 `UnitExec` **数据通路**的承重改造
（见 §4.3 的 5 个改动点），按剩余预算无法做到"逐字节证书 + 负对照"，**不做"半实现 + 无证书"的提交**。

### 4.2 设计（照 T-S0 钉死的 halo 规则，**逐字**；见 `reports/c4b_tiling2d.md` §1）

**编译期**：`WT = WIDTH - 2`（= 32）、`HT = IMG_H_MAX`（= 32）—— **不需要新参数**
（`W_MAX = W_TILE + 2`、`H_TILE = IMG_H_MAX` 这两条恒等式就是 S2 的旋钮语义）。

**运行期（描述符冻结，`dw` 就是全层几何）**：`Wo=imgW`、`Ho=imgH`、`s=strideEff`。

- tile 网格：`oy0 = ty·HT`、`ox0 = tx·WT`、`oy1 = min(oy0+HT, Ho)`、`ox1 = min(ox0+WT, Wo)`;
  `th = oy1-oy0`、`tw = ox1-ox0`。
- **本片的 halo 取法（行跨步窗口读）**：窗口 = 该 tile 全部输出像素的精确感受野
  （左闭右开，T-S0 逐字）：`iy=[s·oy0-pt, s·(oy1-1)-pt+KH)`、`ix=[s·ox0-pl, s·(ox1-1)-pl+KW)`。
  为**使 `Conv3x3Slice` 的输出序号与全局输出行/列一一对齐**（`s` 的抽稀相位在切片内部，
  见 `Conv3x3Slice.scala` 文件头「C4b-D1」），喂料起点取
  **`Fy = s·(oy0-1)`、`Fx = ox0-1`**，喂 `nRow = s·th + 2` 行、`nCol = tw + 2` 列
  （`nCol ≤ W_MAX = 34` ⇒ **`sw=1` 是本档的前提**）。此时
  **切片输出的第 `q` 行 ↔ 全局输出行 `oy0-1+q`**、**第 `j` 列 ↔ 全局输出列 `ox0-1+j`**
  ⇒ **丢弃 `q=0` 与 `j=0`（以及 `j>tw` / `q>th`）**，保留 `q∈[1,th] × j∈[1,tw]`。
  切片自身合成的**上/左/右零填充**恰好落在被丢弃的那一圈（窗口起点之外）⇒ **无需额外造 pad**；
  越界的**真行/真列**由驱动方代以该算子的 `pad` 值（`z_x`，`s=1` 时即 §4.5 的 `z_pad`）。
- 输出：tile 内像素按 `(q-1)·tw + (j-1)` 存 `outMem`；WR 相位**每行一笔**写到
  `DST + ((oy0+q-1)·Wo + ox0)·C`。

### 4.3 改动点清单（照做即可；每点都标了**为什么**）

| # | 位置 | 改动 | 关键约束 |
|:--|:--|:--|:--|
| 1 | `UnitExec.scala:708-715` | `inRows = imgH·s` → **`nRow = s·th+2`**；`rowW = inWMax` → **`rowW = nCol = tw+2`** | `rowW ≤ W_MAX` 由 `inWOk` 自动把住 |
| 2 | `:1730-1737`（`RDSTART`）/`:1841`（`rd_ready`） | **一笔 RD → 每窗口行一笔**（行基址 `srcA + Gy·(inWMax·C)`） | `DdrMaster` 要求 `src%32==0 && len%32==0`（`DdrMaster.scala:379-383`）⇒ 行起址要**下对齐到 4 像素**（C=8）并**丢弃前缀 ≤3 拍 + 后缀 ≤3 拍**；越界的真行**不发 RD**、整行填 `z_pad` |
| 3 | `:1847-1858`（生产侧）/`:1903-1930`（消费侧） | `pcol` 0..`nCol-1`、`pwant` 0..`nRow-1`；每窗口行结束时**注入 tile 起点/终点外的 pad 列** | 列越界（`Fx<0` 或 `Fx+nCol>inWMax`）必须**代以 `z_pad`**（否则切片读到的邻列是垃圾） |
| 4 | `:1166`（`outMem.write`）/`:1928` | 写使能加 **`q∈[1,th] ∧ j∈[1,tw]`**，写址改 `(q-1)·tw + (j-1)`；`pixIdx` 只对合法像素 +1 | 需要一个**输出行计数器**（当前只有 `ocol(i)` 列计数），`pixTotal` 改 `th·tw` |
| 5 | `:1786-1808`（`WRWAIT/WRSTART/WRRUN`）+ `:2009`（`runStart`） | WR 改**每 tile 行一笔**（`th` 笔），`rdWord` 取 `outMem[(q-1)·tw + ri]`；**tile 之间**再脉冲 `prime`（`:2095`）并复位 #1..#4 的计数器 | `prime` 必须**每 tile** 打一次（切片的 `LineBuffer` 相位在整层内是连续的，见 `Conv3x3Slice.scala:「prime」`）；**tile 循环的收工**要保证最后一笔 WR 之后才 `DONE` |

**范围（本档明写）**：窄通路（`C_in==C_out==8 ∧ GROUP==1 ∧ 非 DW`）、`chainLen==1`、`!isHead`
（输出落 DDR）、`sw==1`。**其余几何**（含真表的宽通路：`C=1/4/16/64` 的 dw/dense、`Conv_0` 的 `s=2`）
由 `go` 那一刻**响亮 err + 零搬运**拦住（沿用 `inWOk` 那条路径的形状）。
★ `s=2` 的**非对称 halo**（T-S0 §1：下/左 +1、上/右 +0）要求喂料起点不是 `s·(oy0-1)` 而是
**相位对齐的 `s` 倍数行**，且要**丢弃第 0 行输出**以外的相位；**属 S2b**（真表里唯一的 `s=2` 是
`Conv_0`，走宽通路 ⇒ 窄档先只做 `sw=1, sh=1`）。

### 4.4 判据（T2 的验收，**本片未跑**）

- 正：**整层 tile 拼接 == 整层**逐字节。黄金复用冻结件 `tools/tiling_ref.py --gate2d`
  （T-S0 已证 `tile(+halo) == 整层`：27/27 halo 项 + conv1x1 26 + 旁路 8 全 `MISMATCH=0`）。
  RTL 侧的等价装置：新的 `UnitExec` tiled 网表 + 一个把"整层 `SRC`"喂进去的 TB，
  对 `DST` 与 `tiling_ref` 的整层黄金逐字节对账（**"漏一趟"与"错 tile 跨步"两条负对照必发火**）。
- 负：`tools/tiling_ref.py --inject2d tile-drop`（漏最后一个 tile）⇒ `rc=1`、`positive_mismatch>0`（**已备**）；
  `--inject2d halo-nofire` / `misalign-nofire` 是**判据自身有牙**的自检（已在 T-S0 发火）。
- 流量：`tools/tiling_ref.py` 的 `TRAFFIC2D` 行。**32×32 tile 的口径**：内点 halo 因子
  `34·34/(32·32) = 1156/1024 = 1.129`（+12.9%，比 64×32 的 +9.6% 大）。
  真表 27 个 halo 层的 `Σ in_bytes = 8,300,832 B` ⇒ 上界 `+12.9% = +1.07 MB`
  ⇒ 总 **13.65 MB/帧**；融合感知下界（只有 `Conv_0` 从 DDR 读）`12,576,000 + 158 KB ≈ 12.73 MB/帧`。
  **两者都远低于预算 27.59 MB/帧。**

---

## 5. 回归（本片实测）

**几何改动的**影响面**只到"编译 `gen/LayerSched.v` / `gen/NpuTop.v` 的闸门"**（其它闸门编译
`gen/UnitExec*.v` / `gen/BypassExec.v` … 与本次改动**无关**，且这些网表**逐字节未变**）。

| 闸门 | 结果 | 备注 |
|:--|:--|:--|
| `run_sched_ab.sh` | **PASS**（★ **上一片的既有红被本片消掉**） | 红因是 `800921f` 把 `WIDTH` 钉成 640 而 TB 仍是 `W=32`；本片把几何收到 34 并把 TB 判据改成运行期界限 `IMG_W<=imgW`（`s=1` 时与旧式同值） |
| `run_nputop_sched_ab.sh` | **PASS** | 作业 `W=32,H=8` ⇒ `rowW=32 ≤ 34`、`maxPix=1088 ≥ 256`；9 个作业（含 W1/W2 权重数值 + 负对照）全绿 |
| `run_nputop_ab.sh` | **PASS** | 块拷贝路径（不经 `LayerSched`） |
| `run_unitexec_ab.sh` / `run_bypass_ab.sh` / `run_chain_ab.sh` / `run_fuse_ab.sh` / `run_fusionbuf_ab.sh` / `run_multipass_ab.sh` / `run_dw_ab.sh` / `run_tiling_ab.sh` / `run_tiling2d_ab.sh` / `run_stride_exec_ab.sh` / `run_wide_tail_ab.sh` / `run_nonwide_wide_ab.sh` / `run_layoutadapt_ab.sh` / `run_inlayout_ab.sh` / `run_addsrc2_ab.sh` / `run_paramdel_ab.sh` / `run_wgtdma_ab.sh` | **PASS** | 与本次改动无关的既有闸门（网表未变） |
| `scripts/check_addr_map.py` | **PASS**（17 站点 reconciled） | |
| `tools/check_dangling.py gen/NpuTop.v` | **PASS**（0 悬空） | |
| `tools/check_dup_modules.py` | **PASS**（77 源 / 81 module / 0 重名） | |
| `run_roww_ab.sh`（T1，30 min） | **未复跑** | 它编译 `gen/UnitExec_w640.v`，本片**未改** `UnitExecGen` ⇒ 网表与 T-S1 判定时**逐字节相同**（仅记账）；几何钉点不影响它 |

---

## 6. 网表指纹与确定性

| 网表 | 大小 | md5 |
|:--|--:|:--|
| `y1/gen/LayerSched.v`（`WIDTH=34, IMG_H_MAX=32, L_MAX=8`） | 8,446,462 B | `e8326292cc7386e3191cccc6f64db1bf` |
| `y1/gen/NpuTop.v`（同上） | 8,502,487 B | `fcc3de2862f7c472f8c408f66d07ef06` |

- **确定性 2×**：`gen/` 与本片探针用的 `gen34/`（同一参数、两次独立生成）**md5 逐字节相同**
  ⇒ 网表可复现（见 §3 的命令；`gen34/` 已删除，md5 记录在此）。
- 失败档（`W_MAX=66`）的指纹（留档）：`gen/NpuTop.v` = `d98824432c92d4b168e63dd2e0ba4e8f`。
- `gen/` 在 `y1/.gitignore` 里（与前几片同口径：**网表不入库，只记 md5**）。

---

## 7. 我**能**证 / 我**不能**证（诚实边界）

**能证**：
1. spec §4.1 推荐的 **64×32 tile（`W_MAX=66`）装不下器件** —— `dev_map` **失败 + `Adm-4088 ×195`**（独立 NPU 探针）。
2. spec 点名的回落档 **32×32（`W_MAX=34`）装得下** —— `dev_map` **成功 + `Adm-4088 = 0`**，全表见 §3.2。
3. `sched` / `nputop_sched` 两条编译 `LayerSched`/`NpuTop` 的端到端闸门**逐字节 PASS**
   （`W=32` 的层在 `W_MAX=34` 网表上正确；且 `run_sched_ab` 的既有红被消掉）。
4. 结构判据（台账 17 站点 / 悬空 / 重名）全绿。
5. 网表确定性（两处独立生成 md5 相同）。

**不能证（本片未做）**：
1. **RTL tile 循环 + halo gather 未实现** ⇒ **没有**"整层 tile 拼接 == 整层"的 RTL 逐字节证书，
   **没有**"漏一趟/WRONG STRIDE"的 RTL 负对照发火。§4 只给**设计**（halo 规则本身已在 T-S0 逐字节证死）。
2. **`W_MAX=66` 被否 ⇒ tile 尺寸从 64×32 改成 32×32**；这意味着 spec §3 的流量估值（+6.3%/+0.94%）
   要按 §4.4 的 +12.9%/+1.3% 重算（**仍在预算内**，但 spec 的数字要更新）。
3. **板级（integrated）`dev_map` 与 PnR 未跑** ⇒ 没有"板级也装得下 / `All Constraints Met`"的证据。
4. **没有比特流、没有上板** ⇒ 12 路输出 / G7 = n/a（S3）。
5. 宽通路（真表的 `C=1/4/16/64`、`Conv_0` 的 `s=2`）的 tiling **未做**。

---

## 8. S2b / S3 必须做什么

**S2b（RTL，本片的未交付项）**
1. 按 §4.3 的 5 个改动点实现 tile 循环 + 行跨步 halo gather（**建议加编译期开关 `TILING: Boolean = false`**，
   只在 tile 档例化时打开 ⇒ `gen/UnitExec.v`/`_w32`/`_w640` 等既有网表**逐字节不变**，既有闸门零改动）。
2. 新闸门：整层 tile 拼接 == 整层逐字节 + `--inject2d tile-drop` 型负对照（RTL 侧）发火。
3. **宽通路**的同一套 tiling（`MultiPassUnit` 的 `wOutMem` 与 `mpu` 喂列）；`s=2` 的**非对称 halo** 相位。
4. 每段 `dev_map` 记账（`W_MAX=34` 的 DRM 已到 77%，任何新增宽存储都要重新仲裁）。

**S3（PnR → 板 → 12 路 + G7）**
1. **PnR**（控制器跑；本片**未跑**）：`y1/pds/pnr_c4a.tcl`（`YESHENMINI_SYNTH_MODE` 选档），
   目标 `All Constraints Met`；用本片的 `gen/NpuTop.v`（md5 `fcc3de28…`）。
2. 重下比特流 → `npu_frame_run.py --run --xfer net` → 12 路输出 + **G7 容差**
   （IoU ≥ 0.5 / 关键点 L2 ≤ 2 px / |Δconf| ≤ 0.1 / 检出数差 ≤ 1）。
3. 板级（integrated）`dev_map` 全表 + PnR Δ 记账。

---

## 9. 判据清单（本片的单行结论）

```
[1] dev_map @ W_MAX=66/H_TILE=32（tile 64x32，spec §4.1 推荐） : FAIL（Adm-4088 x195，DRM 不够）
[2] dev_map @ W_MAX=34/H_TILE=32（tile 32x32，spec §6-R4 回落）: PASS（Adm-4088 = 0；DRM 319/415=77%）
[3] sched / nputop_sched / nputop / unitexec / bypass / chain / fuse / fusionbuf / multipass /
    dw / tiling / tiling2d / stride_exec / wide_tail / nonwide_wide / layoutadapt / inlayout /
    addsrc2 / paramdel / wgtdma                                 : PASS
[4] check_addr_map(17 sites) / check_dangling / check_dup_modules: PASS
[5] 网表确定性 2x（两次独立生成 md5 逐字节相同）                  : PASS
[6] RTL tile 循环 + halo gather + 整层拼接逐字节 + 两条负对照    : **已交付**（§10，退 0）
RESULT: DONE（面积判据达成；RTL tile 循环 + halo gather 交付并逐字节证死；宽通路 tiling 见 §10.7）
```

---

## 10. ★★ T-S2R：RTL tile 循环 + halo gather（**已交付**）

### 10.1 交付物

| 文件 | 动作 | 说明 |
|:--|:--|:--|
| `y1/rtl/UnitExec.scala` | 改 | `TILING: Boolean = false` 编译期开关 + **2-D tile 循环 + 行跨步 halo gather**（`s∈{1,2}`）+ 两个 bug 的修复（§10.3） |
| `y1/rtl/LayerSched.scala` | 改 | `new UnitExec(..., TILING = true)` —— **板级 `NpuTop` 里也带 tile 循环**（否则 `dev_map` 测不到新循环） |
| `y1/rtl_test/UnitExecGen.scala` | 改 | 第 4 份网表 `gen/UnitExec_tiled.v`（`C=8 / WIDTH=34 / IMG_H_MAX=32 / L_MAX=8 / TILING=true`） |
| `y1/rtl_test/UnitExecTb.v` | 改 | `+TILED` 档：跳过 `IMG_W==imgW` 与 `maxPix` 的 time-0 对账（tile 循环按 **整层几何** 收描述符）；判据 = 跑完 + 无 err + `busy==0` |
| `y1/tools/run_tiling2d_rtl_ab.sh` | 新 | T2 的 RTL 闸门：正对照 7 例 + 负对照 2 条，退 0/1/2/3，单 `RESULT:` |
| `y1/reports/c4b_tiling_s2.md` | 改 | 本节 |

**未改**：`third_party/**`；冻结工具（`tiling_ref.py` / `conv_unit_ref.py` / `mac_ref.py` / `ddr_traffic.py` / …）；
**描述符格式一字未动**；`rowW` 运行期口径原样保留（tile 循环只是把 `rowW` 在 `RDSTART` 闩成**窗口宽** `tNCol`）。

### 10.2 实现与 halo gather 映射（口径逐字照 §4.2 + T-S0 钉死的 halo 规则）

**编译期**（**无新参数**）：`WT = WIDTH-2 = 32`（`s=1`）/ `(WIDTH-2)/2 = 16`（`s=2`）；`HT = IMG_H_MAX = 32`。
两条恒等式 `W_MAX = W_TILE + 2`、`H_TILE = IMG_H_MAX` 就是旋钮语义。

**运行期**（描述符 `dw` 就是**整层**几何）：`s = strideEff`、`Wo = imgW`、`Ho = imgH`；
tile 网格 `oy0 = ty·HT`、`ox0 = tx·WT`、`oy1 = min(oy0+HT, Ho)`、`ox1 = min(ox0+WT, Wo)`；`th/tw` 是 tile 尺寸；
`tNtx = ⌈Wo/(s·WT)⌉`、`tNty = ⌈Ho/HT⌉`。

**窗口（左闭右开精确感受野，T-S0 逐字）**：起点 `Fy = s·(oy0−1)`、`Fx = s·(ox0−1)`；喂 `nRow = s·th+2` 行 ×
`nCol = s·tw+2` 列。切片输出第 `q` 行 / 第 `j` 列 ↔ 全局 `oy0−1+q` / `ox0−1+j`
⇒ **只保留 `q∈[1,th] × j∈[1,tw]`**（`q=0`、`j=0`、`j=tw+1` 是被丢的 halo 环，切片自身合成的上/左/右零填充
恰好落在那一圈）。`s=2` 的抽稀相位在切片内部 ⇒ 保留 `q∈[1,th]` 就得到 T-S0 钉死的**非对称 halo**
（下/左 +1、上/右 +0），**不需要任何 `s` 分支**。

**halo gather（行跨步窗口读，每个窗口行一笔 RD）**：

```
for pwant = 0 .. nRow-1:                       # 窗口行
  iy = Fy + pwant                              # 全局输入行
  if iy ∉ [0, inHi) 或 窗口无真数据: 整行 pad（z_pad），不发 RD      # ← 越界真行**不读**
  else: 一笔 32 B 对齐读 src = srcA + iy·(inWi·C) + aLo·C,  len = (aHi−aLo)·C
        for pcol = 0 .. nCol-1:                # 窗口列
          g = Fx + pcol
          if g ∉ [WinLo, WinHi): 写列 pad（z_pad），不吃拍
          else: 丢前缀拍（tBcol < g）→ 收该拍（全局列 g 的像素）→ 写 bufs(0)
        排空后缀拍（tBcol → aHi），等主口回 IDLE 才换下一行
```

其中 `[aLo, aHi)` 是真实列区间 `[WinLo, WinHi)` 的 **4 像素（32 B）上下对齐**
（`DdrMaster` 的 `src%32==0 && len%32==0` 契约）。**三条实测血泪**（都写进了行内注释）：
① 收拍三态（丢前缀 / 收真列 / 排空后缀）**必须都带 `rd_valid` 门控**，否则 `tBcol` 与主口实际拍的数脱节
⇒ 提前停手 ⇒ 主口永不 `done`、整帧挂死；② 行 RD 的 `src/len` **必须寄存**（`tRowSrcR/tRowLenR`）——
`DdrMaster` 的 `CHK` 在 `start` 的**下一拍**才读 `io.src/io.len`，组合一拍脉冲到那拍已回 FSM 默认（`len=0`）；
③ DRAIN 的换行判据用 **`!busy`**（不是拍数）。
**收工**：`tPixIdx == th·tw`（tile 内保留像素到齐）+ 所有活跃切片读满 `tNRow` 行 + 中间缓冲 pad 完；
**WR**：每 tile 行一笔，写 `DST + ((oy0+q)·Wo + ox0)·C`，`tw` 个字。

**halo 规则（逐字，来自 `tiling_ref.py` / `c4b_tiling2d.md` §1，未重推）**：conv3x3/dw `s=1` ⇒ ±1 行/列；
`Conv_0` `s=2` ⇒ 非对称（下/左 +1、上/右 +0）；conv1x1/maxpool/resize/add ⇒ 0。
后四族是**旁路算子**（`BypassExec`，逐点/行流式），其 0-halo 附加约束（maxpool 输入边偶数对齐 /
resize 输出边偶数对齐 / add 第二操作数同 tile 网格）被 **32×64 的倍数网格**自动满足
⇒ 它们**不需要 halo gather**，本片未改（`BypassExec` 的存储本就是 tile 几何 `34×32`）。

### 10.3 两个 bug（都被闸门抓死）与受控实验

**① 零扩符号 bug（本片要收的那个）**：`tGCol = tFx + pcol.asSInt.resize(26)`。
`pcol` 是 `cw = log2Up(WIDTH) = 6` 位 `UInt`，`.asSInt` 把**第 5 位当符号位** ⇒ `pcol ≥ 32` 变负；
生成网表里就是 `_zz_tGCol = {{20{pcol[5]}}, pcol}`（**符号复制**）。
后果：窗口右沿的两列被 `tGInWin` 判成 pad ⇒ **每个 tile 的最后 2 条输出列错**。
修复：`pcol.resize(26).asSInt`（**先零扩、再当有符号**）⇒ 网表变成 `_zz_tGCol = {20'd0, pcol}`。

**受控实验**（同源、只改这一行、重生成网表 ⇒ 两个 netlist 的 Verilog 差异**恰好 3 行**）：

| 变体 | `gen/UnitExec_tiled.v` md5 | `run_tiling2d_rtl_ab.sh` |
|:--|:--|:--|
| 病态 `pcol.asSInt.resize(26)` | `f79359331483fce3c1d90a23ae77add6` | **RED**：`s1_64x32` `MISMATCH=997`；**错列 x∈{30,31,62,63}**（= tile0/tile1 的最后两列）× 全部 32 行 |
| 修复 `pcol.resize(26).asSInt` | `7d8da7e0f6f9dd0bc3ac8cd59b0bc278` | **GREEN**：7/7 用例 `MISMATCH=0` |

（口径：`pcol ∈ [0,33]`，只有 `pcol ≥ 32` 触发 ⇒ 每 tile 恰 2 列 × `th` 行。）

**② tile 分支抢 DMA 装载**（集成档才暴露）：`IDLE` 里 tile 分支排在 `dmaEn` **之前** ⇒ 走 tile 的窄层
**跳过 `WGTLD`**（权重不装、`RDSTART` 直接起跑）。准星：`run_wgtdma_ab` 的 J1 少装**恰一段 576 B**
（`WGT_BYTES 2304 → 1728`，J1 的 X 段就是那张窄的 plain conv）。
修复：tile 分支内**先判 `dmaEn`** —— `WGTLD → WGTRUN → RDSTART`（`WGTRUN` 收工那一拍进 `RDSTART`，
那时 `tilingR` 已闩 1 ⇒ 直接走 tile 相位）；判据用**装载器自己的前提** `dmaGeomOk && dmaWinOk`，
**不**并 `inWOk` —— `inWOk` 的界是"整层行宽 ≤ `W_MAX`"，而 tiling 的**行宽是窗口宽** `tNCol ≤ WIDTH`
（恒成立：`tNCol = s·tw+2 ≤ s·TWT+2 = WIDTH`）⇒ 整层行宽可以远大于 `W_MAX`（**这正是 tiling 的意义**）。

### 10.4 判据证据（`y1/tools/run_tiling2d_rtl_ab.sh`，退 0/1/2/3，单 `RESULT:`）

装置：`gen/UnitExec_tiled.v` + `UnitExecTb.v（+TILED）` + `AxiMemModel.v`；向量/黄金 = 冻结
`tools/conv_unit_ref.py`（`build` 的同口径 `mac_ref` 算术；`s=2` 只改取样相位）—— **不写第三条参考**。

**正对照**（整层激活喂进去、RTL 内部切 tile；判据 `DST == 整层黄金` **逐字节**）

| 用例 | 输出几何 | tile 网格 | MISMATCH | SRC 未动 | dst 邻域未动 |
|:--|:--|:--|--:|--:|--:|
| `s1_320x320` | 320×320 | 10×10（含边 tile） | **0** | 0 | 0 |
| `s1_160x160` | 160×160 | 5×5 | **0** | 0 | 0 |
| `s1_64x32` | 64×32 | 2×1 | **0** | 0 | 0 |
| `s1_80x80` | 80×80 | 3×3（边 tile 宽 16） | **0** | 0 | 0 |
| `s1_40x40` | 40×40 | 2×2（边 tile 宽 8） | **0** | 0 | 0 |
| `s1_20x20` | 20×20 | 1×1（单 tile、无接缝） | **0** | 0 | 0 |
| `s2_32x32` | 32×32 | 2×1（`s=2` **非对称 halo**） | **0** | 0 | 0 |

（320/160/80/40/20 = 真表 FPN 上 dw/conv3x3 的实际 `H×W`，见 `gen/wgt_index.json`；**装置口径**：
`UnitExecTb.v` 在 time-0 硬判 `C_IN==C_OUT==8` ⇒ 本闸门的 C=8 是**窄通路**，halo 规则与 C 无关。）

**负对照①（漏一趟，必发火 + 定位）**：突变 `tNtx-1 -> tNtx-2` ⇒ 最后一列 tile 不跑
⇒ `MUT_MISMATCH=8165`，错配点全局列 `XMIN=32 / XMAX=63` ⇒ **100% 落在被漏掉的 `tx=1` 列带**。
**负对照②（不给 halo，必发火 + 分类）**：突变 `tWinLo+1 / tWinHi-1`（丢左右各 1 列 halo）
⇒ `NH_MISMATCH=991`，但**错的列只有 4 列**（`x∈{0,1,31,32}`，全在 tile 边界）⇒ **接缝类**（tile 内部全对）。
两者互为对照：①是**整条列带全错**、②是**只有接缝错**（= `tiling_ref.py`「边界环占比」口径的 RTL 版）。

### 10.5 DDR 流量（caliber 明示）

**冻结口径（T-S0 / §4.4，**逐字引用、未重推**）**：32×32 tile 的内点 halo 因子 `34·34/(32·32) = 1.129`
（+12.9%，比 64×32 的 +9.6% 大）⇒ 上界 `12,576,000 + 8,300,832×0.129 = **13.65 MB/帧**`；
融合感知下界（只有 `Conv_0` 从 DDR 读）`≈ **12.73 MB/帧**`。预算 `27.59 MB/帧`。

**RTL 的真实 caliber（本片实测，比冻结口径**更保守**）**：行读必须 **32 B（4 像素）对齐**
⇒ 一个 34 列窗口的**内点行**实际读 `aHi − aLo = **40 像素**`（闸门装置自报 `RD_BYTES_PEAK = **320 B**`，
逐字节坐实）⇒ 逐行放大 `40/34 = 1.176`；内点 tile 的真实因子 `(40/32)·(34/32) = **1.328**`。
⇒ 上界 `12,576,000 + 8,300,832×0.328` = **15.30 MB/帧（+21.7%）**；
融合感知 `12,576,000 + 1,228,800×0.328 ≈` **12.98 MB/帧**。
**两者都仍 < 27.59 MB 预算**（余量 1.8× / 2.1×）。**越界真行不发 RD** ⇒ 边界 tile 不额外读；
`TILED_WR_BYTES` 是"每个 tile 行一笔"的峰值，与输出字节数自洽（WR 总量 = `C_out·H·W`，无放大）。

> **口径诚实项**：spec/§4.4 的 +12.9% 是**理想**窗口（`34` 列整读）；RTL 受 `DdrMaster` 的 32 B 粒度约束，
> 每行多读 ≤6 像素 ⇒ 真实值比理想高 ~17.6%。两条都在预算内，但**记账要用 15.30 MB 这条**。

### 10.6 `dev_map`（独立 NPU 探针，`YESHENMINI_C4A_MODE=nputop`，**含新 tile 循环**）

复现命令见 §3（`LayerSched.scala` 已 `TILING = true` ⇒ `gen/NpuTop.v` 里带新循环）：
```bash
cd y1 && printf 'Test/runMain UnitExecGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nTest/runMain LayerSchedGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nTest/runMain NpuTopGen D:/code/PDS/VexiiYeshenLinux/y1/gen\nexit\n' | bash sbt.sh
cd /d/code/PDS/VexiiYeshenLinux && YESHENMINI_C4A_MODE=nputop \
  /c/Pango/PDS_2025.2-ads/bin/pds_shell.exe -file D:/code/PDS/VexiiYeshenLinux/y1/pds/devmap_c4a.tcl \
  > y1/pds/devmap_c4a_nputop_s2r.log 2>&1 ; echo "exit=$?"
```

| 资源 | T-S2 基线（`TILING` 未开，§3.2） | **T-S2R（`TILING=true`，含新循环）** | Δ |
|:--|--:|--:|--:|
| `Adm-4088` | **0** | **0** | **0** ✅ |
| DRM | 319 / 415 = **77%** | **319 / 415 = 77%** | 0 |
| LUT | 97,901 = 62% | **101,480 = 64%** | **+3,579** |
| FF | 115,814 = 37% | **116,192 = 37%** | +378 |
| APM | 544 = 74% | **549 = 75%** | +5 |
| Distributed RAM | 5,448 = 14% | **6,536 = 17%** | +1,088 |
| IO | 392 = 98% | **392 = 98%** | 0 |
| `dev_map` | 成功 | **成功**（`Y1_C4A_NPUTOP_DEVMAP_DONE`） | — |

**读数**：**`Adm-4088` 保持 0**（DRM 319/415 = 77% 不动 —— tile 循环**不加宽存储**，只加控制/计数与一条行读通路）
⇒ 新循环的代价是 **LUT +3.6k（+3.7% 相对）/ FF +378 / APM +5 / Dist.RAM +1.1k**，全部在余量内（LUT 剩 36%、DRM 剩 23%）。
日志：`y1/pds/devmap_c4a_nputop_s2r.log`。

### 10.7 回归（T3 闸门 + 结构判据 + 确定性）

**口径诚实项**：`LayerSched.scala` 打开 `TILING` ⇒ `gen/LayerSched.v` / `gen/NpuTop.v` 变的**内容**是激活 tile 相位；
而 `gen/UnitExec.v` / `_w32` / `_w640`（`TILING=false`）**行为**不变（tile 分支的 `elsewhen(tilingOkC)` 里
`tilingOkC ≡ 0` ⇒ 新增节点全在**死支**上），但 SpinalHDL 的 `_zz_*` 编号会顺移 ⇒ **网表文本会变**
⇒ 凡编译这些网表的闸门**全部重跑**（不是"网表未变 ⇒ 不重跑"）。

| 闸门 | 结果 | 备注 |
|:--|:--|:--|
| `run_tiling2d_rtl_ab.sh`（**T2，本片新**） | **PASS**（退 0） | 正对照 7/7 `MISMATCH=0`；负对照①/②都发火 |
| `run_wgtdma_ab.sh` | **PASS** | ★ **本片修的红**：修前 `WGT_BYTES 2304→1728`（tile 抢 DMA 装载） |
| `run_sched_ab.sh` / `run_nputop_sched_ab.sh` / `run_nputop_ab.sh` | **PASS** | 编译 `LayerSched.v`/`NpuTop.v` ⇒ 走**新循环**的端到端回放仍逐字节对 |
| `run_dw_ab.sh` | **PASS** | 同上（宽通路，不激活 tile） |
| `run_paramdel_ab.sh` | **PASS** | 逐层参数投递（`UnitExec.v`） |
| `run_unitexec_ab.sh` / `run_unitexec_wide_ab.sh` / `run_bypass_ab.sh` / `run_chain_ab.sh` / `run_fuse_ab.sh` / `run_fuse_head_ab.sh` / `run_fusionbuf_ab.sh` / `run_multipass_ab.sh` / `run_stride_exec_ab.sh` / `run_layoutadapt_ab.sh` / `run_inlayout_ab.sh` / `run_addsrc2_ab.sh` / `run_wide_tail_ab.sh` / `run_nonwide_wide_ab.sh` / `run_wgtdma_geom_ab.sh` / `run_wgtdma_wide_ab.sh` / `run_tiling_ab.sh` / `run_tiling2d_ab.sh` / `run_roww_ab.sh` | **PASS** | 见下方"回归清单"（逐闸门 exit code） |
| `scripts/check_addr_map.py` | **PASS**（17 站点 reconciled） | |
| `tools/check_dangling.py gen/NpuTop.v` | **PASS**（0 悬空） | |
| `tools/check_dup_modules.py` | **PASS**（77 源 / 81 module / 0 重名） | |
| 网表确定性 2×（两次独立生成，md5 逐字节相同） | **PASS** | 见 §10.8 指纹表 |

**回归清单（逐闸门 exit code，本片**在修完 §10.3-② 之后**重跑）**

```
【批次 A】编译 gen/UnitExec_tiled.v / gen/LayerSched.v / gen/NpuTop.v
  tiling2d_rtl=0  wgtdma=0  sched=0  nputop_sched=0  nputop=0  dw=0  paramdel=0
【批次 B】编译 gen/UnitExec.v / _w32 / _w640（TILING=false）
  bypass=0  unitexec=0  unitexec_wide=0  fuse_head=0  fuse=0  chain=0  fusionbuf=0
  stride_exec=0  layoutadapt=0  inlayout=0  addsrc2=0  wgtdma_geom=0  wgtdma_wide=0
  wide_tail=0  nonwide_wide=0  multipass=0  tiling=0  tiling2d=0  roww=0
【结构】
  check_addr_map=0（17 sites reconciled）  check_dangling=0（0 悬空）  check_dup_modules=0（77 源/81 module/0 重名）
【确定性】两次独立生成 md5 逐字节相同 = 0
合计 26/26 闸门 exit 0
```

> **诚实记账**：本片**第一次**批量（网表还是修前那份）里 `paramdel=1` / `wgtdma=1`。前者是我在
> **闸门运行期间并发重生成网表**（`gen/UnitExec.v` 被覆写）撞出来的**假红**（重跑 = 0）；后者是
> **真红**（§10.3-②，tile 分支抢 DMA 装载）⇒ 修完重跑 = 0。两次批量**都在这里留档**。

**未复跑**（口径明示）：`run_twoclock_ab.sh`（两时钟装置，非 T3 清单；它编译 `gen/NpuTop.v`，
本片改过该网表 ⇒ **建议 S3 前复跑**）、`run_axilite_cdc_ab.sh` / `run_mem_cdc_ab.sh` / `run_irqrst_cdc_ab.sh` /
`run_frame_ab.sh` / `run_normform/quant/numeric/...`（与本次改动无关的既有闸门）。

### 10.8 网表指纹（本片，`git` 不入库，只记 md5）

| 网表 | 参数 | 大小 | md5 |
|:--|:--|--:|:--|
| `y1/gen/UnitExec.v` | `C=8 WIDTH=64 IMG_H_MAX=4 L_MAX=8 TILING=false` | 3,713,375 B | `d4a39c46f3c78ebf9cc4ea53e8bc2e50` |
| `y1/gen/UnitExec_w32.v` | `WIDTH=32 IMG_H_MAX=8` | 3,617,443 B | `1b59596658ca343e348778e501b0ce61` |
| `y1/gen/UnitExec_w640.v` | `WIDTH=640 IMG_H_MAX=4` | 17,446,289 B | `b10eca08c6c29b3fd89efb34392c19e4` |
| **`y1/gen/UnitExec_tiled.v`** | **`WIDTH=34 IMG_H_MAX=32 TILING=true`** | 7,930,964 B | **`7d8da7e0f6f9dd0bc3ac8cd59b0bc278`** |
| `y1/gen/LayerSched.v` | `C=8 WIDTH=34 IMG_H_MAX=32 L_MAX=8`（`UnitExec` **TILING=true**） | 8,476,475 B | `ed4d1f263a43d074db7026c779214dfd` |
| `y1/gen/NpuTop.v` | 同 `LayerSched` + HostRegs/DdrMaster/DescFetch | 8,532,500 B | `c11e30015b4a02ac4d446f3a5e2a7056` |

受控实验用的两个 `UnitExec_tiled.v`：病态 `f79359331483fce3c1d90a23ae77add6` / 修复 `7d8da7e0f6f9dd0bc3ac8cd59b0bc278`。

### 10.9 我**能**证 / 我**不能**证（诚实边界）与 S3 清单

**能证**（本片）：
1. 窄通路（`C_in==C_out==8 ∧ GROUP==1 ∧ 非 DW`、`s∈{1,2}`、单单元、非头）的 **tile 循环 + halo gather
   在 `32×32`（`W_MAX=34/H_TILE=32`）上"整层拼接 == 整层"**逐字节**（7 例，含 320×320/160×160 真几何
   与 `s=2` 非对称 halo），**SRC 与 dst 邻域都不被误写**。
2. 两条负对照**都发火且定位/分类**（漏一趟 → 整条列带；不给 halo → 只有接缝列）。
3. 零扩符号 bug 的**受控实验**（同源单行改动 ⇒ RED/GREEN + 错列指纹 `x∈{30,31,62,63}`）。
4. `grep` 可复核：`UnitExec.scala` 里 `tGCol` 只有 `pcol.resize(26).asSInt` 一种写法；生成网表里**无**
   `{{20{pcol[5]}}` 形态。
5. `dev_map`（含新循环）`Adm-4088 = 0`，全表见 §10.6；T3 闸门 + 结构判据 + 确定性 2× 全绿。

**不能证 / **未交付**（开口项）**：
1. **宽通路（真表 `C∈{1,4,16,64}`）的 tiling** —— 本档的 `tilingShapeOk` 要求窄通路；真表的
   conv3x3/dw（`Conv_0` 3→16、`Conv_3` 16ch dw、`Conv_55` 1→1 …）**全是宽通路** ⇒ 它们的 tile 循环**未交付**。
   宽描述符在 tiling 网表上由 `go` 那一刻**响亮 err + 零搬运**（`isWide ⇒ wideGeomOk` 要求 `IMG_W == WIDTH(34)`）
   拦住 ⇒ **绝不静默错值**，但**也没有**"宽通路 tile 拼接 == 整层"的证书。**这是 S2b 的剩余项**：
   要给 `MultiPassUnit` 的 `wOutMem` / 列喂料加同一套 tile 编排 + 一条**平面（NCHW）行跨步 halo gather**。
   ★ 装置侧还有一道硬前提：`rtl_test/UnitExecTb.v` 在 time-0 **硬判 `C_IN==C_OUT==8`**
   ⇒ 宽通路要么扩装置、要么用 `UnitExecWideTb`。
2. **`s>2`** 的 tiling（`tilingOkC` 只放 `s∈{1,2}`）—— 真表只有 `Conv_0` 一个 `s=2`，未用到 `s>2`。
3. **旁路算子（conv1x1/maxpool/resize/add）的"tile 网格对齐"** 只在**几何等价**层面成立
   （halo=0 + 32/64 倍数网格满足"偶数对齐/同网格"三条约束），**未**做一次"旁路层整层拼接 == 整层"的 RTL 证书
   （冻结件 `tiling_ref.py --gate2d` 的旁路 8 项已离线证；RTL 侧属既有 `bypass` 闸门）。
4. **板级（integrated）`dev_map` 与 PnR 未跑** ⇒ 没有"板级也装得下 / `All Constraints Met`"的证据。
5. **没有比特流、没有上板** ⇒ 12 路输出 / G7 = n/a。

**S3（PnR → 板 → 12 路 + G7）必须做的**
1. **PnR**（控制器跑；本片**未跑**）：`y1/pds/pnr_c4a.tcl`（`YESHENMINI_SYNTH_MODE` 选档），目标 `All Constraints Met`；
   用本片的 `gen/NpuTop.v`（md5 **`c11e30015b4a02ac4d446f3a5e2a7056`**）。
   ★ 关注点：新循环把 `tGCol`/`tRowIY`/`tFx` 这类 26 位有符号加法的**组合锥**引进了 `RDSTART`/生产者路径 ——
   若 `npu_clk` 收紧，先查这几条（它们与 `wCob` 那条已修的锥不同源）。
2. 重下比特流 → `npu_frame_run.py --run --xfer net` → **12 路输出 + G7 容差**
   （IoU ≥ 0.5 / 关键点 L2 ≤ 2 px / |Δconf| ≤ 0.1 / 检出数差 ≤ 1）。
3. 板级（integrated）`dev_map` 全表 + PnR Δ 记账；并把 §10.5 的 **15.30 MB/帧**口径带进帧级流量对账。
4. （可选）**S2b**：宽通路 tiling（含 `Conv_0` 的 `s=2` 真层），把 §10.9-1 的开口收掉。

### 10.10 判据清单（本片的单行结论）

```
[T2-0] run_tiling2d_rtl_ab.sh 正对照（320x320/160x160/64x32/80x80/40x40/20x20 + s=2 32x32）
       : PASS（7/7 MISMATCH=0，SRC/邻域未动）
[T2-1] 负对照① 漏一趟（tNtx-1->tNtx-2）                : PASS（MISMATCH=8165，XMIN=32 ⇒ 定位到被漏列带）
[T2-1b] 负对照② 不给 halo（tWinLo+1/tWinHi-1）          : PASS（MISMATCH=991，错列 4 ⇒ 接缝类）
[T2-2] dev_map @ W_MAX=34/H_TILE=32 + TILING=true       : PASS（Adm-4088 = 0；DRM 319/415=77%；LUT 64%）
[T2-3] 受控实验 零扩符号 bug（同源单行）                 : RED（MISMATCH=997，x∈{30,31,62,63}）/ GREEN（0）
[T3]   23 闸门 + check_addr_map(17)/check_dangling/check_dup_modules : PASS（§10.7）
[T3]   网表确定性 2x                                     : PASS（§10.8）
[!]    宽通路（C∈{1,4,16,64}）的 tiling                  : **未交付**（S2b；走响亮 err + 零搬运）
RESULT: DONE（窄通路 tile 循环 + halo gather 交付并逐字节证死；dev_map 含新循环归零）
```

---

## 11. ★★ T-S2b：**宽通路 2-D tile 循环**（平面行跨步 halo gather + 每 tile 多趟）

- 日期：2026-10-14
- 上游：`8eeaa45`（本片：宽路 tile 闸门 + gather 死锁修复）；T-S2R `f1bc65f`（窄路 tile 循环）。
- **Status: WIP（未达 DoD）** —— 宽路 tile 循环**已实现并跑通装置**（真表宽几何 6/7 作业 `RESULT: PASS`），
  但 **DST 与整层黄金不是逐字节**（每 tile 首像素错，N ≤ 55 字节/层）、**`s=2` 未收工（timeout）**、
  **两条负对照未跑到**、**`dev_map` 判词在飞**。**诚实记账如下**。

### 11.1 交付物（`8eeaa45`）

| 文件 | 动作 | 说明 |
|:--|:--|:--|
| `y1/rtl/UnitExec.scala` | 改 | 宽路 tile 循环（§11.2）+ **gather 死锁修复**（§11.3） |
| `y1/rtl_test/UnitExecWideTb.v` | 改 | `+TILED_W` 模式（不喂列流 / 开 `XDMA_EN` / 判据=跑完+无err+busy落0） |
| `y1/tools/run_tiling2d_wide_ab.sh` | 新 | T2 宽路闸门：真表宽几何正对照 + 两条负对照（漏趟/不给 halo） |
| `y1/rtl/UnitExec.scala`(先前 `8be5a8c`) | 改 | 宽路 tile 起手（`tilingWideC`/`wx*` gather/`wt*` 掩码 WR/`ps_clr`）+ DdrMaster `wstrb` + MultiPassUnit `ps_clr` |

`third_party/**` 与冻结工具（`tiling_ref.py`/`multipass_ref.py`/…）**未改**；**描述符格式一字未动**。

### 11.2 实现与**平面（NCHW）行跨步 halo gather 映射**

**编译期**（无新参数）：`WT = WIDTH-2`（s=1）/`(WIDTH-2)/2`（s=2）；`HT = IMG_H_MAX = 32`。

**运行期**：`tilingWideC`（`go` 那刻闩存）= `TILING ∧ isWide ∧ chainLen==1 ∧ !isHead ∧ s∈{1,2} ∧ C_out≠0 ∧
nCo≤8 ∧ LAYER_ID<64 ∧ H·W%8==0 ∧ IMG_W/H≠0 ∧ XDMA_EN ∧ (HW = inH·inW) % 32 == 0`。tile 网格/窗口
与窄路**同一套寄存器**（`tT*`/`tF*`/`tNCol`/`tNRow`），`tFy=tS·(oy0−1)`、`tFx=tS·(ox0−1)`，喂 `nRow=s·th+2` 行 ×
`nCol=s·tw+2` 列，只保留 `q∈[1,th]×j∈[1,tw]`（halo 环丢弃，T-S0 规则逐字，含 `s=2` 非对称）。

**平面读（与窄路的 NHWC 行读**不同**）**：输入是**通道平面** `(c,p)` 落 `SRC + c·HW + p`（`HW=inH·inWi`）。
窗口行的一段**行跨步**、且 `HW%32==0` 时 8 个平面的 32 B band 边界重合 ⇒ **每窗口行按"32 列一个 band"逐
平面读**：绝对字节 `gAbs = srcA + wCi·8·HW + iy·inWi + g`，band 基址 `wxBB = gAbs & ~31`，band 内下标
`wxIdx = gAbs[4:0]`；对 `pl=0..7` 各发**一笔 32 B RD** @ `wxBB + pl·HW` ⇒ 一拍一列 = 8 平面的同一像素
（= `mpu.io.x` 的形状）。列/行越界 ⇒ `z_pad` 列（不吃 RD）。

**每 tile 多趟**：每个 tile 内重跑 `nCi×nCo` 趟（dense）/ `nCo` 趟（depthwise 对角），**复用**既有
`MultiPassUnit`/`PartialSumBuf`；`ps_clr` 在"某 co-block 的第 1 趟"（dense `ci==0`；dw 唯一对角趟）举起
⇒ 累加器清零语义 = "上电初值 0"。

**写回**：每 `(co, tile 行)` 一笔 **32 B 对齐 + `wstrb` 掩码** burst（段 = `tTw` 字节，起点可能不对齐）——
冻结的 NCHW 布局下"任意 `Wo`、任意 `s`"能写回去的**唯一**手段（`DdrMaster.io.wstrb`，见 `8be5a8c`）。

**★ 未覆盖（响亮 err + 零搬运，非静默）**：`HW%32≠0` 的真层（真表只有 `20×20`，`HW=400`）被
`tilingWideC` 挡住 ⇒ 真表里 **20×20 的宽层**（`Conv_59` 1→1、`Conv_73/75/77` 10ch 等）**跑不了** tile。

### 11.3 两个真坑（本片抓死）

**① gather 跨趟 RD 悬等死锁（★ 本片修）**：`MPU` 驱动的**趟收工**（`wEmitCnt==wxPixTot-1`）与 gather 的
RD **不同源** ⇒ 一趟可能在 gather **正有一笔 RD 在飞**时收工；下一趟 `wSt==2` 把 `wxSt:=1` **重置**掉，
那笔 RD 成了**孤儿**；`wxK=0` ⇒ `rd_ready=0` ⇒ 孤儿永不 `done` ⇒ `busy` 恒 1 ⇒ **死锁**。实测签名
（装置调试口）：`cyc=658 dstate=RDSTR wxK=0 wxSt=2 needB=1 fPl=0`（4M 拍 `timeout`）。
**修复**：FETCH 里**无条件认领主口**（`wxK:=True`）；若进来时主口已忙 ⇒ `wxOrphan:=True`，先把它排空，
`done` 那拍**丢弃其数据并重取本 band 的 plane 0**；并把 `wxFAdrR` 变成**唯一**地址源（`DdrMaster.CHK` 在
`start` 下一拍读 `io.src` ⇒ 组合一拍脉冲不够）。修后 6/7 作业收工。

**② 每 tile 首像素错（★ 未修，开口项）**：正对照 `DST` 与整层黄金的差异**只有**若干个字节，且**全部**落在
"tile 的第一个保留像素"`(oy0, ox0)` 上（实测：`c1_80x80` 2 字节 @ `(64,32),(64,64)`；`c4_40x40` 4 字节 @
`(32,32)`×4 通道；`c64_40x40` 38 字节 @ `(32,32)`；差值小且有符号）。定位：该像素是**唯一同时用到"上 halo
行 r=0"与"左 halo 列 j=0"的保留像素** ⇒ 嫌疑 = 窗口**首行/首列**（halo）在**换 band / 换 row** 那一拍的取数
相位。**未在预算内修掉** ⇒ **DoD 的"逐字节"未达成**。

### 11.4 判据证据（`y1/tools/run_tiling2d_wide_ab.sh`）

**黄金/权重瓦片 = 冻结件复用**（`tiling_ref.conv_tiled` + `multipass_ref.weight_tiles`/`bias_of`）
—— **不写第三条参考**。装置 `UnitExecWideTb.v(+TILED_W)` + `AxiMemModel.v` + `gen/UnitExec_tiled.v`。

**正对照（真表宽几何，`gen/wgt_index.json` 口径）—— 装置全 PASS，数值近逐字节（未达 DoD）**

| 作业 | 几何 | GROUP | 趟数 | 装置 | DST vs 整层黄金 |
|:--|:--|--:|--:|:--|:--|
| `c1_80x80` | 1→1 80×80 | 1 | 1 | PASS | **MISMATCH=2**（@`(64,32),(64,64)`） |
| `c4_40x40` | 4→4 40×40 | 1 | 1 | PASS | **MISMATCH=4**（@`(32,32)`） |
| `c16_160x160` | 16→16 160×160 | 1 | 4 | PASS | **MISMATCH=51** |
| `c64_40x40` | 64→64 40×40 | 1 | 64 | PASS | **MISMATCH=38** |
| `dw16_80x80` | 16ch dw 80×80 | 16 | 2（对角） | PASS | **MISMATCH=30** |
| `dw64_40x40` | 64ch dw 40×40 | 64 | 8（对角） | PASS | **MISMATCH=55** |
| `s2_3x16` | 3→16 64×64 **s=2** | 1 | 2 | **FAIL timeout** | 未收工 |

=> **装置层面**：宽层（含 depthwise 对角趟、部分 co-block 尾块）**能收工**、邻居字节未被改；
**数值层面**：**不是**逐字节（开口项 §11.3-②）。

**负对照**：脚本已备（漏趟 `tNtx-1→tNtx-2`；不给 halo `tWinLo+1`/`tWinHi-1`），但正对照未全绿 ⇒
**未跑到**（脚本在正对照红时 `exit 1`）。

### 11.5 DDR 流量（caliber 明示，★ 宽路比窄路**贵得多**）

**口径**：宽路 tile 循环**每趟都要把整个 tile 窗口重读一遍**（`nCo` 个 co-block 各把 `nCi` 个 ci-block 的
平面读一遍 ⇒ 同一 `ci` 平面的窗口被读 `nCo` 次）。**实测**（装置自报 `AR` 突发数 × 32 B）：

| 作业 | 输入字节 | `AR` 突发 | RD 字节 | 放大 |
|:--|--:|--:|--:|--:|
| `c64_40x40` | 102,400 | 74,462 | 2,382,784 | **23.3×** |
| `dw64_40x40` | 102,400 | 9,278 | 296,896 | 2.9×（对角趟省掉 `nCi` 倍扇出） |
| `c16_160x160` | 409,600 | (见日志) | — | — |

⇒ **宽路 tile 的上界口径不是 §10.5 的 +21.7%，而是 ~`nCo`×（`34·34/32·32`）×（行 32 B 对齐 40/34）**；
`C=64` dense 的 **23×** 说明**流量**是宽路 tiling 的**承重反对项**（融合感知下"窗口从片上取"才有救）。
**这是本片最重要的负面结论**：宽路 tiling 在**流量**上可能不划算（与窄路的 +21.7% 不同口径）。

### 11.6 `dev_map`（独立 NPU 探针，含新循环）

本轮在飞（`y1/pds/devmap_c4a_nputop_s2b.log`，`YESHENMINI_C4A_MODE=nputop`，后台、未杀）。**判词待补**。
基线（T-S2R，含窄路新循环）：`Adm-4088 = 0`，DRM 319/415=77%，LUT 101,480=64%，FF 116,192，APM 549。
宽路循环**只加控制/计数 + 一条行读通路**（不加宽存储）⇒ **预期 `Adm-4088` 保持 0**；以日志为准。

### 11.7 我**能**证 / 我**不能**证（诚实边界）

**能证**：① 宽路 tile 循环**已实现且在真表宽几何上跑通装置**（6/7 `RESULT: PASS`，含 `C=1/4/16/64` 与
depthwise 对角趟）；② 一条**承重死锁**的根因与修复（§11.3-①，有调试口签名）；③ `tilingWideC` 对
`HW%32≠0`（真表 20×20）与其它不合几何**响亮拦住**。

**不能证 / 未达 DoD**：① 正对照**不是**逐字节（每 tile 首像素错，§11.3-②）；② `s=2`（`Conv_0`）**未收工**；
③ 两条负对照**未跑到**；④ `dev_map` 判词**未出**；⑤ T3 回归 / 网表确定性 / 报告口径**未跑**；
⑥ 板级/PnR/比特流（S3）。

### 11.8 判据清单（本片单行结论）

```
[T2b-1] 宽路 tile 正对照（真表宽几何 C=1/4/16/64 + depthwise） : 装置 6/7 PASS；DST **非**逐字节（每 tile 首像素，N<=55）
[T2b-2] s=2（Conv_0 式）                                      : FAIL（timeout，未收工）
[T2b-3] 负对照 漏趟 / 不给 halo                                : **未跑到**（正对照未全绿）
[T2b-4] dev_map（含宽路新循环）                               : 在飞（`pds/devmap_c4a_nputop_s2b.log`）
[!]     流量口径                                               : ★ 宽路 tile ~nCo×(34·34/32·32)×(40/34)；C=64 dense **23×**（承重反对项）
RESULT: WIP（宽路 tile 循环已实现 + 真表宽几何装置跑通；**未达 DoD**：逐字节/s=2/负对照/dev_map 待收）
```

> ★ §11 是 `8eeaa45` 时的**历史记账**（当时正对照红、负对照未跑到）。**开口项 §11.3-② 与 `s=2` 已在
> T-S2b-i（§12）收口**，本闸门现已退 0；读现状请看 §12。

---

## 12. ★★ T-S2b-i：宽路 tile 循环**收口**（每 tile 首像素 + `s=2` 挂起 + 闸门接线）

- 日期：2026-10-14
- 上游：`8eeaa45`（§11）、`f1bc65f`（T-S2R 窄路）
- **Status: DONE** —— 正对照 **7/7 逐字节**（含 `s=2`）、两条负对照**全发火且定位/分类正确**、
  `run_tiling2d_wide_ab.sh` **退 0**、`TILING=false` 三份既有网表**逐字节不变**。
- 提交：`0dd0c27`（首像素）、`6b1f042`（`s=2` + 非 tiled 逐字节不变）、`3db59a4`（闸门接线/坐标修正）。

### 12.1 缺陷 1 根因：gather 的"起趟相位"（每 tile 第 0 列读**残留 band**）

**签名**（`c4_40x40`，装置侧逐列对账 `COLDBG`，1936 列 = Σ `tNRow·tNCol`）：

- **before**：`mismatches=1` —— 恰在 **`ty=1 tx=1 r=0 j=0`**（= 保留首像素 `(32,32)` 的**唯一**
  "上 halo 行 `r=0` ∧ 左 halo 列 `j=0`"交点列）；读到的是**相邻 tile 的 `(y=39,x=31)`**
  （残留 band `132640` 的第 23 字节），期望 `(y=31,x=31)=[-9,-4,12,2]`，实得 `[-3,-18,11,-20]`。
  `j=0` 在 `tx=0` 是 pad、`r=0` 在 `ty=0` 是 pad ⇒ 只有 `(ty>0 ∧ tx>0)` 的 tile 冒泡 ⇒ 装置侧"6/7 PASS
  但每 tile 首像素错"正是这个（每 tile 恰好 1 列 × 若干通道）。

**根因**（逐拍 `TRC` 抓死）：gather 的门是 `wxRun = (state===WIDERUN) && tilingW` —— **不含 `wSt`**。
于是 gather 在**载权/起趟/换趟**（`wSt∈{0,1,2,4}`）期间也在**空转**：`wxSt` 走 DECIDE/EMIT、`wCol/wRow`
被"**无 `x_valid` 的 EMIT**"一路推进到 **远超 `tNRow`**。下一趟 `wSt==2`（`start` 脉冲）那一拍，写在主
FSM **之后**（⇒ 覆盖）的 `switch(wxSt)` 用**上一趟的** `wRow`（越界 ⇒ `wxNeedB=0`）跑 DECIDE ⇒ 把 `wxSt`
置成 EMIT ⇒ **新一趟第一拍**（`wRow=0/wCol=0` 已刷新）**直接交付第 0 列**，而它的 band **从未取过**
（`wxBandV=0`）⇒ 交付 `xwBuf` 里上一趟的**残留字节**。
逐拍证据：`cyc=55740 wSt=2 wRow=39 wCol=2 wxSt=1 needB=0`（起趟拍，用旧 row 判"无需取 band"）
→ `cyc=55741 wSt=3 wRow=0 wCol=0 wxSt=3 bandV=0 BBR=132640 xv=1 x0=-3`（**第一拍就 EMIT**）。

**修法**：门加 `wSt===3`（只认"喂列相位"）。主 FSM 的 `wxSt:=1`（起趟那拍）不再被覆盖 ⇒ 第一拍一定是
**新鲜 `(0,0)` 上的 DECIDE**（该取 band 就取，`j=0` 是 pad 就直接给 `z_pad`）。
`rd_ready` 不受该门影响 ⇒ 冻结期间上一笔在飞 band RD 仍能排空（不挂主口）。
**副作用（正向）**：载权/换趟期间不再空转 ⇒ 不再发多余 band RD（`c4_40x40` AR 1126 → 1099）。

**证据（after）**：`COLDBG` 1936 列 **mismatches=0**（逐字节 == DDR 平面源）；`tile(1,1)` 第 0 列
`bandV=1 BB=132320`。

### 12.2 缺陷 2 根因：`s=2` 挂起 —— 出数**行数**没按步长相位算

**签名**（`s2_3x16`，C_in=3/C_out=16 64×64 `STRIDE=2`）：`wEmitCnt` **饱和在 561**(=33·17)，而
`wxPixTot` 是 **1105**(=65·17) ⇒ 喂列收工判据 `wEmitCnt === wxPixTot-1` **永不命中** ⇒ 喂列相位永不退出、
gather 一路空转把 `wRow` 推到 **1899+**（4M 拍超时）。

**根因**：`wxPixTot = (tNRow-1)·tOutPerRow` 里的 `tNRow-1` 是 `s=1` 口径。切片（`Conv3x3Slice` 文件头
C4b-D1："第 `r` 行流入 ⇒ 目标 `r ≡ 1 (mod s)`"）下，**出数行数 = `#(r≡1 mod s, 1≤r≤tNRow-1)`**；
代入 `tNRow = s·tTh+2` ⇒ **两种步长都是 `tTh+1`**（`s=1` ⇒ `≡ tNRow-1`，与旧式**逐字同值**；
`s=2` ⇒ `(tNRow-1)/2+1`，旧式**多算一倍**）。同口径在列方向早已对（`tOutPerRow` 就是 `Mux(s==1, tNCol, …)`）。

**修法**：`wxPixTot = if (TILING) ((tTh+1)·tOutPerRow) else <旧式逐字>`。
**证据（after）**：`s2_3x16` 真装置 `CYCLES=587054, RESULT: PASS`（< 4M）；逐趟 `ROW` 轨迹：每趟 66 行、
`emitCnt` 单调到 **561** 后 `wSt→5` 收工换趟；闸门判 **MISMATCH=0**。

### 12.3 硬约束：`TILING=false` 三份既有网表**逐字节不变**

上一稿的改法有两条**副作用**会把非 tiled 网表也改掉：

1. **SpinalHDL 把源码行号编进内部网名**（`_zz_when_UnitExec_l<line>`）⇒ **加/删注释行即平移全文网名**；
2. `wxRun` 是**寄存器门**（`tilingW` 是 `Reg`，`when(tilingW)` 分支**不被剪枝**）⇒ 表达式本身也进了
   `gen/UnitExec.v`（`assign wxRun = ((state == WIDERUN) && tilingW);`）。

**修法**：两处改动都做到 **① `if (TILING)` 常量分支（`else` 分支**逐字**复刻旧表达式）** +
**② 行号中立**（只改既有行，不增删行；`wc -l` = 2737 = 父提交 `42655a4` 的 2737）。
**证据**：父提交源码重生成 vs 本源码重生成，三份 `TILING=false` 网表 md5 **逐字节相同**：

| 网表 | md5（父 = 本） |
|:--|:--|
| `y1/gen/UnitExec.v` | `979129017535dc82ab9e6d89bea31080` |
| `y1/gen/UnitExec_w32.v` | `618af3381eadcb4d7c6964cd4338a825` |
| `y1/gen/UnitExec_w640.v` | `ddb9bb8addc01f94e2ea8ae8b6b898e6` |

（同源码连跑两次 `UnitExec_tiled.v` md5 相同 ⇒ 确定性 2×。）

### 12.4 闸门本体的两处**接线/坐标**缺陷（本步修，判据阈值与突变未动）

§11 的闸门**从未跑到**负对照（正对照红 ⇒ `exit 1`），故两处潜伏缺陷此前看不见：

1. **负对照用了错的内存镜像**：`genjob.py` 把 `mem.hex`/`pre.hex` 写在**共享 `$work`**、每作业覆写 ⇒
   循环结束后只剩**最后一个作业**（`s2_3x16`）的激活。正对照"生成后立刻跑"不受影响；负对照在循环
   **之后**跑 ⇒ 拿 `c4_40x40` 的 gold 配 `s2_3x16` 的激活（实测漏趟负对照 `MISMATCH=6358`、错列铺满
   `0..39`）⇒ 测的是"输入根本不对"。**改**：`$work/<name>/{mem,pre}.hex`。
2. **错配列号用了错的布局**：原式 `(k // Co) % W` 是**通道交错 `[y][x][co]`** 布局的列号，而黄金与网表
   写回都是 **NCHW 平面 `[co][y][x]`** ⇒ 改 `k % W`。原式把真被漏掉的列带 `x∈[32,39]` 映射成
   `{8,9,18,19,28,29,38,39}`（`XMIN=8`）⇒ `XMIN>=32` 断言**恒假**。

**负对照锚点**（`(tNtx - 16'h0001)` ×2、两条 `tWinLo`/`tWinHi` assign 串）在重生成网表里**逐字仍在**
（各 1 次命中）⇒ 脚本内的突变字符串**无需改**。

### 12.5 判据证据（`bash y1/tools/run_tiling2d_wide_ab.sh`，退 **0**）

```
正对照：真表宽几何（C=1/4/16/64 + depthwise + Conv_0 s=2），整层 tile 拼接 == 整层逐字节
   OK: c1_80x80 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: c4_40x40 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: c16_160x160 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: c64_40x40 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: dw16_80x80 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: dw64_40x40 DST == 整层黄金（MISMATCH=0，邻居未动）
   OK: s2_3x16 DST == 整层黄金（MISMATCH=0，邻居未动）
   正对照通过 7 例
   MUT_MISMATCH=1274 NBADX=8 XMIN=32 XMAX=39          <- 负①：错点全在被漏的 tx=1 列带
   NEG_OK: 漏一趟 ⇒ MISMATCH=1274（>0），错配 XMIN=32 ≥ 32 ⇒ 落在被漏掉的 tx=1 列带
   NH_MISMATCH=631 NBADX=4 XMIN=0 XMAX=32 XSORT=[0, 1, 31, 32]   <- 负②：接缝类（4 列）
   NEG2_OK: 不给 halo ⇒ MISMATCH=631（>0），错**列**仅 4 列（⇒ 接缝类）
RESULT: PASS
```

**负②的 4 个错列可手算对上**（"不给 halo = 每侧多啃 1 列真数据"）：`tile0`（`ox0=0`，`tFx=-1`）——
`tWinLo` 被夹到 `0` 后 `+1` ⇒ 真列 `g=0`（`j=1`）丢 ⇒ 首列 `X∈{0,1}`（3-tap 扩散 1 列）；`tWinHi`（`tFxEnd=33<40`
走第三支）`-1` ⇒ `g=32`（`j=33`）丢 ⇒ `X=31`。`tile1`（`ox0=32`，`tFx=31`）——`tWinLo+1` ⇒ 左 halo `g=31`（`j=0`）丢
⇒ `X=32`；`tFxEnd=65>40` 走**第一支**（`tWinHi=tInWi`）⇒ 该支**不在突变串里** ⇒ 右列不动。
⇒ 错列 = `{0,1,31,32}`（全是 tile 接缝列），**tile 内部全对**。

### 12.6 网表指纹（本片，`git` 不入库）

| 项 | 值 |
|:--|:--|
| `y1/gen/UnitExec_tiled.v`（`WIDTH=34 IMG_H_MAX=32 TILING=true`）md5 | `87418e514cfb383b9fe57e0654bf1f5f`（8,155,351 B） |
| `TILING=false` ×3 | **与父提交逐字节相同**（§12.3） |

### 12.7 我**能**证 / 我**不能**证

**能证**：① 宽路 tile 在真表宽几何（`C=1/4/16/64` + depthwise 对角趟 + **`s=2`**）上 **7/7 逐字节**；
② 两条负对照**发火且定位/分类正确**；③ `TILING=false` 三份网表**逐字节不变**；④ 两个缺陷的根因都有
**受控实验/逐拍证据**（§12.1 逐列 + 逐拍；§12.2 `wEmitCnt` 饱和值 vs 阈值）。

**不能证 / 仍是开口项**：① **流量 ~23×**（每趟重读整个窗口）—— 本步**未动**（S2b-ii）；
② `HW%32≠0` 的真层（真表 `20×20`）仍被 `tilingWideC` 响亮挡住（tile 不了）；
③ 闸门本体的两处修正（§12.4）属**判据接线**改动，虽阈值/突变未动、且修后负对照行为与脚本头
   写明的意图逐条吻合，但**不是**原脚本的原样运行 —— 已明写；
④ `dev_map`（§11.6）/ PnR / 板级 / 比特流（S3）。

### 12.8 判据清单（单行结论）

```
[T2b-i-1] 正对照 7/7（C=1/4/16/64 + dw16/dw64 + s2_3x16）逐字节 : PASS（MISMATCH=0，邻居未动）
[T2b-i-2] 负① 漏趟（tNtx-1->-2）                              : PASS（MUT_MISMATCH=1274，XMIN=32∈[32,39]）
[T2b-i-3] 负② 不给 halo（tWinLo+1/tWinHi-1）                   : PASS（NH_MISMATCH=631，错列 4 ⇒ 接缝类）
[T2b-i-4] TILING=false 三份网表                                 : PASS（与父提交逐字节相同）
[T2b-i-5] s=2 收工                                              : PASS（CYCLES=587054 < 4M）
RESULT: PASS
```

