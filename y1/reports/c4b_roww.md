# T-S1 判词 —— **运行期行宽 `rowW`**（一张网表重放真表 6 个输入行宽）

- 日期：2026-10-14
- spec：`docs/superpowers/specs/2026-10-13-y1-runtime-width-and-tiling-design.md`
  **§3.1**（`inWOk` 的修法）、**§5 T1**（判据 + 负对照）、**§7 S1**（本片范围：`W_MAX` 保持 **640**，无 tile 循环）
- 上游：`b87407f`（T-S1 RTL 起手）、`0b24bf0`（T-S0：`tiling_ref.py` 钉死 halo 规则）
- 闸门：**新** `y1/tools/run_roww_ab.sh`（T1）+ 回归 40 条 + 台账/悬空/重名
- 本片**未做**：PDS / PnR / 板级（spec §7：那是 S3）；`W_MAX` 收窄 + tile 循环（那是 S2）

---

## 0. 一句话结论

**T1 成立**：一张 `W_MAX=640` 的网表（`gen/UnitExec_w640.v`）**逐字节**重放了真表 `desc.bin` 的
**全部 6 个输入行宽 `{640,320,160,80,40,20}`**（`DST` 区 `MISMATCH=0` ×6，黄金互异 6/6，自报运行期行宽
`RTL_ROW_W` 互异 **6/6**）；**负对照**（把 `rowW` 钉死成 640）在 **5 个非 640 行宽上全部发火**
（`MISMATCH≈40800/40960` 且装置 FAIL），在 **640 上行宽上保持外科式绿**。既有作业**逐字节不变**；
回归 40 闸门 + 台账（17 站点）+ 悬空 + 重名全绿（唯一例外见 §7 的 `run_sched_ab`，**属上一片的既有红**）；
网表**确定性 2×**（两次全量重生成逐字节相同）。

> **收尾时发现并修掉的承重缺陷**：committed 的 T-S1 RTL（`b87407f`）**根本无法展开** —— `UnitExec.scala`
> 里 `slices(i).io.rowW := rowW` 出现在 `val rowW = Reg(...)` **之前**（Scala class 体顺序求值 ⇒ 取到 `null`，
> SpinalHDL 报 8 条 `:= null`），即便挪正，**位宽也不匹配**（20 位寄存器 → 16 位 additive 口；40 位乘积 → 20 位寄存器）。
> 本片把它修到能展开、能重生成、能过闸门（详见 §3）。

---

## 1. 本片做了什么（S1 的范围，一字不多）

**做什么**：只加**运行期行宽 `rowW`**（寻址/计数全走运行值，**分配仍按 `W_MAX=640`**）—— 解掉
"一张网表只服务一个输入行宽"（`c4b_frame.md` §9.5 的第二条结构性原因）。

**不做**：tile 循环 / halo 重读 / `W_MAX` 收窄（S2）；描述符格式（冻结）；帧率（C5）；相机（Y5）。

**为什么 S1 零面积收益**（spec §3.1）：所有存储**仍按 `WIDTH=640` 分配**（`PartialSumBuf`/`wOutMem`/`outMem`/
`FusionBuf`/`hat`/`accRow`/`rb` …）⇒ 本片**只把链走通**，"装得下"留 S2（§9）。

---

## 2. spec §3.1 的**逐点落实**（实际改到的点，file:line = 当前树）

| spec §3.1 点 | 模块 / 位置 | 改动 | 本片是否触到 |
|---|---|---|---|
| `inWOk` 编译期等式 → 运行期界限 | `UnitExec.scala:733` `val inWOk = (inWMax >= 1) && (inWMax <= U(WIDTH,20b))` | 等式 `WIDTH ∈ [IMG_W·s-s+1, IMG_W·s]` → 界限 `1 ≤ rowW ≤ W_MAX` | ✔ |
| `rowW` 在 `go` 拍**闩存** | `UnitExec.scala`（IDLE 态）`rowW := inWMax.resize(20)` + 观察口 `io.row_w` | 新增 20 位寄存器 + 唯一闩存点 | ✔ **修**（§3） |
| `LineBuffer` 列回绕 / hist 深度 | `LineBuffer.scala:67`（口）/`:82`（`rowWm1`）/`:113`（回绕） | `col === WIDTH-1` → `col === rowW-1` | ✔ |
| `Conv3x3Slice` `cw`/`colLast`/幻影列 | `Conv3x3Slice.scala:224`（口）/`:269`（`rowWm1`）/`:531,545,549,554` | 列回绕/行末列号/幻影列改用运行值 | ✔ |
| `FusionBuf` 行槽步长 | `FusionBuf.scala:132`（口）/`:171,175,180,195` | 字址 `行槽*WIDTH+列` → `行槽*rowW+列` | ✔ |
| `UnitExec` `cw`/`inPix`/喂流/gather | `UnitExec.scala`：`inPix = inRows·rowWUse`；`wCol`/`pcol`/`cCol`/`ocol`/`padCol` 回绕；`slices(i)/mpu/bufs(i)/bufs(L_MAX).io.rowW` | 计数/寻址常量 → 运行值（**分配不动**） | ✔ |
| `MaxPoolUnit` | `MaxPoolUnit.scala:84`（口）/`:96`（`rowWm1`）/`:144` | 列回绕即换行改 `rowW-1` | ✔ |
| `ResizeUnit` | `ResizeUnit.scala:86`（口）/`:98,99`（`rowWm1`/`ocWm1`）/`:145` | 输入列 + 行内输出列回绕改运行值 | ✔ |
| `BypassExec` 第二处钉子 | `BypassExec.scala:269`（`rowW = inW32`）/`:272`（`rowWParOk`）/`:274`（`rowWOk`） | 带行宽状态的单元 + maxpool 偶数；逐点算子只要求非 0 | ✔（`b87407f`） |
| **（spec 未列，但必须）** `MultiPassUnit` 直通 | `MultiPassUnit.scala:101`（口）/`:150` `sl.io.rowW := io.rowW` | 宽层多趟把 rowW 直通它自己的切片 | ✔ |

**分配一字未动**：`WIDTH` 仍是 `UnitExec`/`4 个旁路单元` 的**分配口径**（= `W_MAX`）；`rowW` 只影响
**计数/寻址**。⇒ `rowW == WIDTH` 时与"没有这个口"**逐拍/逐字节同形**（既有闸门据此零改动成立，§7 实证）。

---

## 3. ★ 承重修复：committed T-S1 RTL **展开不过**（本片修掉）

`b87407f` 提交后**从未重生成网表**，所以这个缺陷藏到了本片才现形（`gen/UnitExec*.v` mtime 仍是上一片
（`10-13 05:19`），两处问题在 `Test/runMain UnitExecGen` 上**当场**报出）：

1. **Scala 前置引用 ⇒ `:= null`**（8 条）：
   `(toplevel/sliceRest_*/rowW : in UInt[16 bits]) := null`。
   根因：`slices(i).io.rowW := rowW`（切片接线循环）在 `val rowW = Reg(UInt(20 bits))` **之前** ——
   `UnitExec` 的 class 体是**顺序求值**，前置引用取到 `null`。
   **修**：把 `val rowW`（连同注释）**移到切片接线之前**（放在 `mR/zpadR/zyR/biasReg` 那批寄存器之后，
   `UnitExec.scala` 的 `biasReg` 块末尾），并明写"必须在切片接线前声明"。
2. **位宽不匹配**（20 条）：`WIDTH MISMATCH (16 bits <- 20 bits)`（8 切片 + `mpu` + 9 `bufs`）与
   `(rowW[20] := inWMax[40])`。
   **修**：`rowW` 保持 20 位（与 40 位乘积、观察口 20 位一致），**驱动 16 位 additive 口时显式
   `rowW.resize(16)`**（8 切片 + `mpu` + 9 `bufs`），**闩存改 `rowW := inWMax.resize(20)`**。
   语义不变：`inWOk` 已保证 `rowW ≤ W_MAX ≤ 640 < 2^16`，16 位口足够。

修完：`UnitExecGen` / `LayerSchedGen` / `NpuTopGen` **全部展开成功**并重生成（§8 指纹）。
> 这是"**verify 发现 committed RTL 不成立**"的一处，**非设计改动** —— 只把作者的**意图**（运行期行宽、
> 分配按 W_MAX）落到能展开的写法上，判据与既有逐字节口径一字未改。

---

## 4. TB 收尾（上一片在飞的活）

| TB | 上一片状态 | 本片动作 |
|---|---|---|
| `LineBufferTb.v` | 改过，但口值写错 `16'dNW`（**非法 SV**，iverilog 语法错） | 修成 `16'(NW)` |
| `FusionBufTb.v` | 同上 `16'dNW` | 修成 `16'(NW)` |
| `Conv3x3Tb.v` / `MultiPassTb.v` | `16'(IW)`（合法） | 保持；已编译过 |
| `UnitExecWideTb.v` | 新增 `.row_w(row_w)` 观察口 | 保持；已编译过 |
| `BypassTb.v` | `\`ifdef BP_ROW` 连 `MaxPoolUnit`/`ResizeUnit` 的 `rowW` | 保持；`run_bypass_ab.sh` 已带 `-DBP_ROW` |
| **`DwTb.v`（上一片漏了）** | **实例化 `MultiPassUnit` 但没连 `rowW`**（悬空 ⇒ z ⇒ 列回绕变 x） | **补 `.rowW(16'(IW))`**（该闸门已对账 `+IW == imgW` ⇒ 与"没有这个口"逐字节同形） |

**口径**：所有 TB 都把 `rowW` 喂**该网表的编译期 `WIDTH`**（`NW`/`IW`）⇒ **既有作业逐字节不变**
（§7 用 40 闸门实证）。**6 个受影响 TB 逐个 iverilog `-g2012` 编译通过**（含 `UnitExecTb`/`UnitExecWideTb`
对 `UnitExec*.v`、`BypassTb` 对 `MaxPoolUnit.v`/`ResizeUnit.v`）。

---

## 5. T1 判据：**一张网表 × 6 个真行宽，逐字节**

闸门 `y1/tools/run_roww_ab.sh`（**不写第三条参考**：供料复用冻结 `tools/stride_ref.py --emit`，与 D1/D1b 同一份）。
真表 6 个输入行宽 = `desc.bin` 的 conv/池化类 `IMG_W·STRIDE` ∈ `{640,320,160,80,40,20}`（本片**实测枚举**：
直方图 `{20:14, 40:16, 80:17, 160:10, 320:3, 640:1, …}`；如 `idx0 Conv_0 = 320×2 → 640`、`idx1 = 320×1 → 320`）。
作业几何（等价行宽作业）：真 `Conv_0` 权重/参数（`--lid 0`）、`s=1`、`W = 行宽`、`H = 2560/W`（取满该网表
输出上限 `PIXW = WIDTH·IMG_H_MAX = 2560`）。

**一张网表** = `gen/UnitExec_w640.v`（`W_MAX=640`，md5 `c7ddcb19bb9356903d51254a6c0f9734`）。结果：

| 行宽 `W` | `H` | `DST` 逐字节 | 黄金 `distinct` | 自报 `RTL_ROW_W` | `WIDE_ON` | `RTL_MAXPIX` |
|---|---|---|---|---|---|---|
| 640 | 4   | **MISMATCH=0** | 27 | **640** | 1 | 2560 |
| 320 | 8   | **MISMATCH=0** | 26 | **320** | 1 | 2560 |
| 160 | 16  | **MISMATCH=0** | 27 | **160** | 1 | 2560 |
| 80  | 32  | **MISMATCH=0** | 27 | **80**  | 1 | 2560 |
| 40  | 64  | **MISMATCH=0** | 24 | **40**  | 1 | 2560 |
| 20  | 128 | **MISMATCH=0** | 25 | **20**  | 1 | 2560 |

- `DST_NEIGHBOR32_BAD=0`（6/6，写区外一字未动）；`WR_BYTES=COUT·H·W`（40960，6/6）。
- **运行期行宽自报互异 6/6** = `[640 320 160 80 40 20]` ⇒ "闩存真在跑"的**直接证据**。
- **黄金互异 6/6**（值 md5：`fdf9c6d2…/2e18fcc7…/174eabe1…/f50343ef…/276c0ef1…/291c5a48…`）⇒ 行宽**确实**改了输出。
- 退出码 **0**（`ROW W RESULT: PASS`）。
- ★ 运行时长约 **30 min**（负对照里"钉成常量的 DUT 收不到足够列"会跑到 TB 超时 4M 拍；属预期）。

---

## 6. 负对照（**必须发火**）：把 `rowW` **钉死成 640**

**外科式网表突变**（一刀，靶点唯一）：`gen/UnitExec_w640.v` 的
`rowW <= inWMax[19:0];` → `rowW <= 20'h00280;`（`= 640`，忽略 latch）。

| 行宽 | 期望 | 实测 `DST MISMATCH` | 装置 | 判 |
|---|---|---|---|---|
| **640** | 绿（外科式：640 层本就该 640） | **0** | PASS | **NEG-OK** |
| 320 | 红 | **40800** / 40960 | FAIL | **NEG-FIRE** |
| 160 | 红 | **40798** | FAIL | **NEG-FIRE** |
| 80  | 红 | **40798** | FAIL | **NEG-FIRE** |
| 40  | 红 | **40799** | FAIL | **NEG-FIRE** |
| 20  | 红 | **40797** | FAIL | **NEG-FIRE** |

⇒ **5 个非 640 行宽全部发火、640 保持外科式绿**，`NEG_NOFIRE=0`。**这条负对照有牙**（"把运行期行宽当常量"
必被打红）。另外：闸门自己也拒收"网表缺 `rowW` 口/闩存不唯一"的情形（退出 3）。

---

## 7. 回归总账（**git-bash / iverilog**；本片脚本 grade **本树**）

**40 条闸门**（顺序跑，逐条记 `rc`）：

- **39 条绿**：`desc / unitexec / unitexec_wide / fuse / fuse_head / chain / bypass / fusionbuf / multipass /
  dw / stride / stride_exec / nputop / nputop_sched / hostregs / ddrcopy / ddrread / ddrwrite / ddrmaster32 /
  wgtdma / wgtdma_geom / wide_tail / nonwide_wide / layoutadapt / inlayout / addsrc2 / paramdel / convert /
  quant / tiling / tiling2d / frame / axilite_cdc / mem_cdc / irqrst_cdc / twoclock / macarray / grouped /
  weightstore`（全部 `RESULT: PASS` / `rc=0`）。
  （spec §5 T3 点名的 9 条 + `unitexec_wide/stride_exec/wgtdma_geom/wide` 全在此列。）
- **1 条红（★ 既有、非本片）**：**`run_sched_ab.sh`** —— TB time-0 报
  `desc0(conv) IMG_W=32 != 网表自报 imgW=640（该网表按 WIDTH=640 生成）`。
  **根因**：`LayerSchedGen.scala` 自 **`800921f`（Y1-frame 真几何）**起把 `WIDTH` **硬钉成 640**（**无形状参数**），
  而 `run_sched_ab.sh`/`LayerSchedTb.v` 仍是 C3 期的 `W=32` 口径。两者在 `800921f` 之后**必然**对不上
  ⇒ 该闸门**自 `800921f` 起就是红的**，与 T-S1 无关（本片**未改** `LayerSchedGen`/`LayerSchedTb`/`run_sched_ab`，
  `git diff` 可核）。**处置**：本片**不**动它（改它＝把 C3 用例几何整体搬到 640，属 S2/单独一件）；如实记账。
- **1 条前提重锚（★ 本片）**：**`run_wide_tail_ab.sh`** 的边界用例 `bw` 断言"`IMG_W != WIDTH` ⇒ 响亮 err"，
  而 **T-S1 的**正是"运行期行宽"：`IMG_W < WIDTH`（`s=1`）**现在合法**（`rowW = IMG_W ≤ W_MAX`）。
  ⇒ 把该用例**重锚**为 `IMG_W > WIDTH`（`W=128 > 64`，即 `rowW > W_MAX`）后**全绿**（`[1][2][3]` 一字未改，
  12 个真 dense 尾块仍 `MISMATCH=0`、突变体仍发火）。**"`IMG_W < WIDTH` 合法"这件事本身由 §5 的 6 行宽闸门证死**
  （5 个亚 640 行宽在 `W_MAX=640` 网表上逐字节正确）。

**结构判据**：`scripts/check_addr_map.py` → **PASS（17 站点 reconciled）**；
`tools/check_dangling.py` → 逐网表 **PASS**（`UnitExec/UnitExec_w640/LayerSched/NpuTop/BypassExec/LineBuffer/
FusionBuf/MultiPassUnit/DwUnit` 零悬空）；`tools/check_dup_modules.py` → **PASS（77 源 / 81 module / 0 重名）**。

**冻结面**：`third_party/**` + 冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/
`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**零改动**（`git status` 可核）。

---

## 8. 网表确定性 2×（全量重生成）

**一次全量重生成**（22 个 `*Gen` main）⇒ 再**重跑一次**，两次 `gen/*.v` + `gen/_w640/*.v` 的 **md5 逐字节相同**
（`DETERMINISM: IDENTICAL`；两次会话均 **0 个 `[error]`**）。且与"重生成前的磁盘网表"**也相同**
（`NO-CHANGE vs before`）⇒ 网表可复现。

**关键网表指纹（md5）**：

| 网表 | md5 | 备注 |
|---|---|---|
| `UnitExec.v`（WIDTH=64） | `1a9210a2e23ff9193308b77e7b2c177a` | 含 `assign row_w = rowW;` + `rowW <= inWMax[19:0];` |
| `UnitExec_w32.v` | `f1d0ae3d97975e3a383681b7a37eca02` | |
| **`UnitExec_w640.v`** | **`c7ddcb19bb9356903d51254a6c0f9734`** | **T1 用的那一张网表** |
| `LayerSched.v`（WIDTH=640/IMG_H_MAX=8） | `fa3d75919b77080b91df08dd66df9c5f` | 内联 UnitExec |
| `NpuTop.v` | `efc8bc3016f07df5b8ebd6c5cd5630e1` | 真几何整网 |
| `LineBuffer.v` / `FusionBuf.v` / `FusionBuf_w5.v` | `633414b5…` / `6de7a921…` / `1e2ea35d…` | |
| `Conv3x3Slice.v` / `MultiPassUnit.v` / `DwUnit.v` | `131a6594…` / `5f2a62d5…` / `5f2a62d5…` | `DwUnit.v == MultiPassUnit.v`（同源，闸门据此对账） |
| `BypassExec.v` / `MaxPoolUnit.v` / `ResizeUnit.v` | `906e9014…` / `1f65ae01…` / `36450361…` | |

---

## 9. 面积 Δ（**网表级**，无 PDS —— spec §7：S1 **零面积收益**）

**S1 的存储分配一字未动**（`W_MAX=640`：`PartialSumBuf`、`wOutMem`、`outMem`+`outMemT`、`BypassExec.outMem`、
`FusionBuf×9`、`LineBuffer.hist`/`MaxPoolUnit.accRow`/`ResizeUnit.rb` 全部按 `WIDTH` 不变）⇒ **不省面积**，
这正是 spec 说的"先把链走通"。

**新增的结构（网表级，可数）**：每个 `UnitExec` 实例 **+1 个 20 位寄存器 `rowW`**（+ 复位初值 1）、
`rowWUse` 的 1 个二选一、`rowWm1` 的 1 个 20→`cw` 位减法、以及**把若干编译期常量比较（`=== WIDTH-1`）
换成对 `rowWm1` 的比较**（LUT 持平）；4 个叶子 + `MultiPassUnit` 各 **+1 个 16 位 additive 输入口**
（**无新存储**，只把常量换成线网）。⇒ 净增约 **20 FF + 数十 LUT**，**DRAM 0**。
**PDS/dev_map 未跑**（本片范围外；`NpuTop.v` 仍含 `Adm-4088`，那是 S2 的判据，见 §10）。

---

## 10. S2 必须做什么（spec §7 S2 + §5 T2）

1. **收窄 `W_MAX` 640 → 66**（= 64 tile 宽 + 2 halo 列）：`LayerSchedGen`/`UnitExecGen` 的 `WIDTH` 与
   真几何下的 `IMG_H_MAX` 改为 **`H_TILE=32`**（推荐值；见 spec §4.1）。运行期 `rowW ≤ 66` 由现有
   `inWOk` 界限**自动**把住（**S1 已经把这条界限建好了**）。
2. **tile 循环 + halo 重读**（**新 RTL**）：`UnitExec`/`BypassExec` **内部**按 64×32 走 tile；**halo 按
   "行跨步窗口读"**（`w+2` 列、pitch `IMG_W·C`）—— spec §4.2 明写这是新 RTL（今天的 gather 是线性平面，
   `UnitExec.scala:1300-1362`）。**halo 规则已由 T-S0 离线钉死**（`tools/tiling_ref.py --gate2d`，
   `reports/c4b_tiling2d.md`：27 halo 项 + 旁路族 `tile(+halo) == 整层`，负对照发火）。
3. **判据（§5 T2）**：整层 tile 拼接 == 整层（逐字节）；`dev_map` **零 `Adm-4088`**；
   **负对照**：tile 循环漏一趟 ⇒ 必红（`tiling_ref --inject2d tile-drop` 已备）。
4. **记账**：`halo` 只对有 halo 的 27/68 项付（`desc.bin` idx 见 spec §3）；流量按 `tiling_ref` 的
   `TRAFFIC2D`（≈ +6.3%）与原件合账。
5. **`R3`（未决）**：`Add`（`SRC2`）第二源在 tile 下可寻址**未证** —— S2 之前先查/先证（spec §6 R3）。

---

## 11. 我能证 / 我不能证（诚实边界）

**能证**：① 一张 `W_MAX=640` 网表**逐字节**重放真表 6 个输入行宽（§5）；② 运行期闩存**真在跑**
（`RTL_ROW_W` 互异 6/6）；③ 负对照（钉成常量）在**非 640 全部发火**、640 外科式绿（§6）；
④ 既有 39 闸门 + 台账 17 站点 + 悬空 + 重名**逐字节不变**（§7）；⑤ 网表确定性 2×（§8）；
⑥ `third_party`/冻结工具零改动。

**不能证（本片边界）**：① **没跑 PDS/dev_map/PnR** ⇒ **没有**"装得下器件"的证据（S1 本就零面积收益，§9）；
② **没上板** ⇒ 12 路输出 / G7 / 帧时 **n/a**（S3）；③ `run_sched_ab.sh` 是**既有红**（`800921f` 的几何切换），
本片**未修**（改它＝搬 C3 用例几何，属 S2/单独一件）；④ 真表**每一层**的端到端（不是等价行宽作业）留 S2
（那需要 tile 循环把整图跑完）。
