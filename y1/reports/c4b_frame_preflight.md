# Y1 **T-S3c.1** 收口 —— 整表几何预检（判据 C 的 **Python 快门**）

- 日期：2026-10-15
- spec：`docs/superpowers/specs/2026-10-14-y1-frame-runnable-design.md` **§4-C**（判据 C：整表预检）
- plan：`docs/superpowers/plans/2026-10-14-y1-frame-runnable.md` **Task T-S3c.1**（Step 1–4）
- 上游：`y1/reports/c4b_frame_runnable.md`（T-S3 收口；其 §5"不能证"第 2 条 = **本任务**）
- 交付物：`y1/tools/frame_preflight.py`（预检）+ `y1/tools/run_preflight_ab.sh`（闸门）

**Status: DONE_WITH_CONCERNS** —— 预检**跑起来了、有牙、可复现**，但它**没有**给出"67 个单元零 err"
的干净证书：**真表里有 1 个单元（`Resize_43`）在 RTL 上无合法通路**（响亮 err + 零搬运），
另有一整类（**宽层的融合链**，54/67 条）在**忠实派发**口径下无通路。两条都按纪律**上报为发现**，
不粉饰、不改口径去凑绿。

---

## 0. 一句话

按 spec §4-C 把真表 **67 个单元逐条喂进 RTL 在 `go` 那一刻的几何判据**（Python 侧第二实现，
每条判据注明 RTL 行号）：

| 口径 | 结果 | 含义 |
|:--|:--|:--|
| `UNIT`（每单元各一条，`chain_len=1`，编程 = 既有闸门那一档 `XDMA_EN=1` / 权重按层预载） | **PREFLIGHT_ERR = 1** | **`Resize_43` 没有合法通路** ⇒ "67 个全过"**不成立** |
| `DISPATCH`（忠实派发：`LayerSched` 把 `head middle* tail` 链**塌缩成一次 `go`** ⇒ `chain_len` = run 长；编程 = 真帧驱动 `XDMA_EN=1` + DDR blob） | **DISPATCH_ERR = 54** | **宽层的链在 RTL 上没有任何通路**（RTL 的宽路判据都带 `chain_len == 1`）⇒ **整帧跑不完** |

⇒ **FRAME-RUNNABLE: NO**。S3（PnR → 比特流 → 板 → 12 路 + G7）**现在做不了**；
`c4b_frame_runnable.md` §6 的"下一步 = T-S3c ⇒ 零 err"这一条**被本任务否掉**。

---

## 1. 交付物

| 文件 | 动作 | 说明 |
|:--|:--|:--|
| `y1/tools/frame_preflight.py` | 新 | 整表几何预检（两种口径；每条判据注明 RTL 行号；`--inject` 负对照注入；`--layout derived\|zero`；`--xdma/--blob/--unit-flags`） |
| `y1/tools/run_preflight_ab.sh` | 新 | 闸门：正对照（**冻结**的 ERR 集合）+ 确定性 2× + **2 条能发火的负对照** + DISPATCH 口径的开口项锚；退出码 `0/1/2/3` |

**未改**（`git status` 可核）：冻结工具（`bypass_ref.py` / `bypass_traffic.py` / `tiling_ref.py` /
`multipass_ref.py` / `conv_unit_ref.py` / `desc_table.py` / `ddr_traffic.py` / `fusion_buffer.py` /
`mac_ref.py`）、`third_party/**`、**任何 RTL**、**描述符格式**、`gen/` 产物（`gen/desc.bin`
`md5=fec587a13fb51ed00914e5ce9c04db02`，与 T-S3 收口时逐字节同源）。

---

## 2. 逐单元证书（`UNIT` 口径；真表 67 条）

```
  idx type         chain     shape(WxHxCin>Cout) flags    UNIT path    verdict
  0   conv3x3   plain         320x320:3>16     0b01    wide-tile    OK
  1   conv1x1   run@1 L=2     320x320:16>16    0b00    wide-tile    OK
  2   depthwise run@1 L=2     320x320:16>16    0b11    wide-tile    OK
  3   maxpool   plain         160x160:16>16    0b01    bypass-tile  OK
  4   conv1x1   run@4 L=8     160x160:16>16    0b00    wide-tile    OK
  5   depthwise run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  6   conv1x1   run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  7   depthwise run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  8   conv1x1   run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  9   depthwise run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  10  conv1x1   run@4 L=8     160x160:16>16    0b10    wide-tile    OK
  11  depthwise run@4 L=8     160x160:16>16    0b11    wide-tile    OK
  12  maxpool   plain         80x80:64>64      0b01    bypass-tile  OK
  13  conv1x1   run@13 L=4    80x80:64>64      0b00    wide-tile    OK
  14  depthwise run@13 L=4    80x80:64>64      0b10    wide-tile    OK
  15  conv1x1   run@13 L=4    80x80:64>64      0b10    wide-tile    OK
  16  depthwise run@13 L=4    80x80:64>64      0b11    wide-tile    OK
  17  maxpool   plain         40x40:64>64      0b01    bypass-tile  OK
  18  conv1x1   run@18 L=4    40x40:64>64      0b00    wide-tile    OK
  19  depthwise run@18 L=4    40x40:64>64      0b10    wide-tile    OK
  20  conv1x1   run@18 L=4    40x40:64>64      0b10    wide-tile    OK
  21  depthwise run@18 L=4    40x40:64>64      0b11    wide-tile    OK
  22  maxpool   plain         20x20:64>64      0b01    bypass-tile  OK
  23  conv1x1   run@23 L=6    20x20:64>64      0b00    wide-tile    OK
  24  depthwise run@23 L=6    20x20:64>64      0b10    wide-tile    OK
  25  conv1x1   run@23 L=6    20x20:64>64      0b10    wide-tile    OK
  26  depthwise run@23 L=6    20x20:64>64      0b10    wide-tile    OK
  27  conv1x1   run@23 L=6    20x20:64>64      0b10    wide-tile    OK
  28  depthwise run@23 L=6    20x20:64>64      0b11    wide-tile    OK
  29  resize    plain         40x40:64>64      0b01    -            ERR(geomOk（:558）：outPix(1600)>MAXPIX(1088) + planarOk（:573）：inCols(400)%32!=0 + tileOk（:610）：tileAliOk（:607，inCols=400 % 32 = 16）)
  30  add       plain         40x40:64>64      0b01    bypass-tile  OK
  31  conv1x1   run@31 L=2    40x40:64>64      0b00    wide-tile    OK
  32  depthwise run@31 L=2    40x40:64>64      0b11    wide-tile    OK
  33  resize    plain         80x80:64>64      0b01    bypass-tile  OK
  34  add       plain         80x80:64>64      0b01    bypass-tile  OK
  35  conv1x1   run@35 L=2    80x80:64>64      0b00    wide-tile    OK
  36  depthwise run@35 L=2    80x80:64>64      0b11    wide-tile    OK
  37  conv1x1   run@37 L=2    80x80:64>1       0b00    wide-tile    OK
  38  conv3x3   run@37 L=2    80x80:64>1       0b11    wide-tile    OK
  39  conv1x1   run@39 L=2    40x40:64>1       0b00    wide-tile    OK
  40  conv3x3   run@39 L=2    40x40:64>1       0b11    wide-tile    OK
  41  conv1x1   run@41 L=2    20x20:64>1       0b00    wide-tile    OK
  42  conv3x3   run@41 L=2    20x20:64>1       0b11    wide-tile    OK
  43  conv1x1   run@43 L=2    80x80:64>4       0b00    wide-tile    OK
  44  depthwise run@43 L=2    80x80:64>4       0b11    wide-tile    OK
  45  conv1x1   run@45 L=2    40x40:64>4       0b00    wide-tile    OK
  46  depthwise run@45 L=2    40x40:64>4       0b11    wide-tile    OK
  47  conv1x1   run@47 L=2    20x20:64>4       0b00    wide-tile    OK
  48  depthwise run@47 L=2    20x20:64>4       0b11    wide-tile    OK
  49  conv1x1   run@49 L=2    80x80:64>1       0b00    wide-tile    OK
  50  conv3x3   run@49 L=2    80x80:64>1       0b11    wide-tile    OK
  51  conv1x1   run@51 L=2    40x40:64>1       0b00    wide-tile    OK
  52  conv3x3   run@51 L=2    40x40:64>1       0b11    wide-tile    OK
  53  conv1x1   run@53 L=2    20x20:64>1       0b00    wide-tile    OK
  54  conv3x3   run@53 L=2    20x20:64>1       0b11    wide-tile    OK
  55  conv1x1   run@55 L=2    80x80:64>10      0b00    wide-tile    OK
  56  depthwise run@55 L=2    80x80:64>10      0b11    wide-tile    OK
  57  conv1x1   run@57 L=2    40x40:64>10      0b00    wide-tile    OK
  58  depthwise run@57 L=2    40x40:64>10      0b11    wide-tile    OK
  59  conv1x1   run@59 L=2    20x20:64>10      0b00    wide-tile    OK
  60  depthwise run@59 L=2    20x20:64>10      0b11    wide-tile    OK
  61  sigmoid   plain         6400x1:1>1       0b01    fold         OK
  62  sigmoid   plain         1600x1:1>1       0b01    fold         OK
  63  sigmoid   plain         400x1:1>1        0b01    fold         OK
  64  sigmoid   plain         6400x1:1>1       0b01    fold         OK
  65  sigmoid   plain         1600x1:1>1       0b01    fold         OK
  66  sigmoid   plain         400x1:1>1        0b01    fold         OK
```

**读法**：`chain` 列 = 本条目在**真表**里的角色（`plain` = 自成一段；`run@k L=n` = 属于 `k..k+n-1`
这一段融合链，链长 `n`）；`UNIT path` = 把它当**单个 plain 单元**跑时 RTL 会走的通路
（`narrow-tile` / `narrow-whole` / `wide-tile` / `wide-whole` / `bypass-whole` / `bypass-tile` / `fold`）。

**汇总**：`OK = 66`、**`ERR = 1`（unit 29 `Resize_43`）**。
即：**T-S3a/T-S3b 修的三处盲区（旁路 C≠8 / `Add` 多源 / 20×20 的 `HW%32≠0`）在真表上确实全过**，
但整表**不是零 err**。

### 2.1 与既有闸门的交叉对账（预检 vs. 已被逐字节证过的形状）

| 既有闸门 | 跑过的形状 | 预检是否同意 |
|:--|:--|:--|
| `run_bypass_tile_ab.sh` | `maxpool` C=16 160×160；C=64 80×80 / 40×40 / 20×20；`resize` C=64 **80×80**；`add` C=64 40×40 / 80×80 | **全部一致**（对应 unit 3 / 12 / 17 / 22 / 33 / 30 / 34，全 `OK`） |
| `run_bypass_cblk_ab.sh` | `sigmoid` C=1 W=6400 / 1600 / 400 | **一致**（unit 61–66 走 `fold`） |
| `run_tiling2d_wide_ab.sh` | `c64_40x40` / `c64_20x20` / `dw10_20x20` 等 9 档 | **一致**（对应 unit 18–21 / 23–28 / 59–60 走 `wide-tile`） |

⇒ 预检**没有**推翻任何既有绿档；它多覆盖的是**闸门没跑过的 59 个形状** —— 缺口正在其中。

**本次实测复跑**（确认预检与闸门同源、且本片没有碰任何 RTL/参考）：
`bash y1/tools/run_bypass_tile_ab.sh` ⇒ `RESULT: PASS`（exit 0）；
`bash y1/tools/run_bypass_cblk_ab.sh` ⇒ `RESULT: PASS`（exit 0）；
`bash y1/tools/run_tiling2d_wide_ab.sh` ⇒ `RESULT: PASS`（exit 0，含 `c16_160x160`/`c64_40x40`/`c64_20x20`/`dw10_20x20` 等 9 档 + 3 条负对照）。

---

## 3. 发现（**真开口项**，这是本任务的价值）
### 3.1 `Resize_43`（unit 29）：**`BypassExec.tileAliOk` 仍要求整层的 `inCols % 32 == 0`**

| 项 | 值 |
|:--|:--|
| 描述符 | idx 29，`TYPE=0x11`（resize），`IMG_W=IMG_H=40`、`C_IN=C_OUT=64`、`FLAGS=0b01`（plain） |
| 输入几何（算子反推） | `20×20` ⇒ `inCols = 400`；`rowW = 20 ≤ WIDTH(34)` ✓ |
| 输出像素 | `outPix = 1600` |
| **撞的判据①** | `geomOk`（`rtl/BypassExec.scala:558-564`）的 `outPix <= MAXPIX`：`1600 > 34·32 = 1088` ⇒ **整层路径不可用**（这正是 T-S3a 的 tile 循环要解决的那一类） |
| **撞的判据②** | `tileOk`（`:610`）里的 **`tileAliOk`（`:607`）**：`inCols % 32 == 0` ⇒ `400 % 32 = 16` ⇒ **tile 路径也不可用** |
| 结果 | 两条路都不通 ⇒ `BypassExec.scala:1062-1064` 走 `otherwise` ⇒ **响亮 err + 零搬运**（整帧在 unit 29 死） |

**根因**（一句话）：`tileAliOk` 的注释自己写着前提 ——"8 个平面**共用**同一个 band 内偏移 `tOff`
（同一次转置）⇒ 平面基址必须同余" ⇒ 要求**整层** `inCols % 32 == 0`；**T-S3b 已经把这个前提从
`UnitExec` 的宽路 gather 上摘掉了**（改成"每平面各记 `(bandBase, idxW, idxB)`"，
`rtl/UnitExec.scala:1636-1650`），但 **`BypassExec` 的 tile 通路还带着同一个前提** ——
同一类"口径没搬"，只是落点换到了旁路侧。`Resize_43` 恰好是**真表里唯一**一个
"输出 > MAXPIX（必须 tile）∧ 输入像素数 `% 32 != 0`（tile 却进不去）"的形状。

**为什么既有闸门没抓到**：`run_bypass_tile_ab.sh` 的 `resize` 档**只落了 80×80**
（`c64_resize_80x80` ⇒ `inCols = 40·40 = 1600`，`1600 % 32 = 0` ✓ 恰好过）——
**plan T-S3a.3 Step 1 点名过 `resize` C=64 80×80 **/** 40×40**，但 40×40 那一档**没有落地**；
`run_bypass_cblk_ab.sh` 的 resize 是 `32×32`（`inCols = 256` ✓）。⇒ 这个缺口**从未被任何判据碰到**。

**建议修法（最小、与 T-S3b 同 idiom）**：把旁路 tile 通路的 band 相位从"8 平面共用"改成
"**每平面各记**"（`inCols % 32` 的相位 `(p · inCols) % 32` 因平面而异），或退一步把
`tileAliOk` 的界从"整层 `inCols`"改判"**该平面 stride 的 32 B 对齐可由 per-plane base 兜住**"。
两种都只动寻址、**不动数值口径**。修完必须**重新锚定**本闸门的 `EXPECT_UNIT_ERR_UNITS`。

### 3.2 宽层的**融合链**没有通路（`DISPATCH` 口径 54/67）

| 项 | 值 |
|:--|:--|
| 真表事实 | 53 个 conv 条目里**没有一个是窄层**（`C_IN/C_OUT ∈ {3→16, 16, 64, 1, 4, 10}`、`GROUP=1`、`tpe∈{1,2,3}`）⇒ `narrowShape`（`UnitExec.scala:1384`）对**全部** conv 恒假 ⇒ **全部走宽通路**；其中 **52 个**在 `head middle* tail` 的链上（链长 2/4/6/8），只有 `Conv_0` 是 `plain` |
| RTL 事实 | 宽路的四条判据**都带 `chain_len == 1`**：`tilingOkC`（`:1236`）、`wideGeomOk`（`:1426`）、`wgtLoadOk`（`:1451`）、`tilingWideC`（`:1650`）；文件头也把这条写成前提（`:942`"**宽层恒 `chainLen==1`** ⇒ 不乘链长"），`WGTRUN` 收口那一拍还把"链长≠1"列进"真不支持"（`:2075`） |
| 派发事实 | `LayerSched` 的 CHAINSCAN/CHAINSCANW 把一段 run **塌缩成一次 `go`**，并把**链长**（= run 长度 ≥2）作为 `io.chain_len` 交给 `UnitExec`（`LayerSched.scala:473`） |
| ⇒ 结论 | `chain_len ≥ 2 ∧ isWide` 时：`tilingWideC` 假、`tilingOkC` 假、`wgtLoadOk` 假（`chain_len==1` 那一项）、`wideGeomOk` 假 ⇒ **四条宽路分支全落空** ⇒ `UnitExec.scala:2033-2037` 的 `otherwise` ⇒ **响亮 err + 零搬运**（与权重来源无关：`dmaEn` 开/关都如此） |
| 逐个 run 的证词 | 见 §4 的闸门输出（`run@1 L=2` / `run@4 L=8` / …全部 ERR） |

⇒ **真表 52 条链上 conv（+ `Conv_0` 那一条在 blob 编程下的 `WGTRUN` 收口 err）= 54 条**在
"真派发 + 真帧编程"下没有任何通路。**这不是"某处几何算错"，是表与 RTL 的前提不兼容**：
真表的融合链是**按通道数无关**的方式建的（`desc_table` 的 `fuse_both` 链），而本代 RTL 的宽路
**只支持 `chain_len == 1`**（窄路才支持链）。**冻结的 C3.2 表同样如此**（我复算过：
`desc_table.build_table` 出来的 19 条链全是 C=16/64）⇒ 这是**从 C3 起就存在**、只是**从未有闸门碰过**
的空白（既有链闸门 `run_chain_ab.sh` 用的是 **C=8** 的窄链，宽闸门用的是 **`FLAGS=1` 的单单元**）。

**建议修法（两条路，都要走 spec 修订）**：
1. **表侧**：把宽层的融合链**拆成 `plain`**（每条边重走一趟 DDR ⇒ 流量涨，与"fuse_both 下界"冲突），
   或在链上**只允许窄层**（等于放弃真表的全部 conv 融合 ⇒ 流量账要重算）；
2. **RTL 侧**：给宽路加"链"支持（`L_MAX` 片宽层串片：趟瓦片按片寻址 + 中间张量片上留）
   —— 这是**面积/存储**量级的新功能（`outMem`/`wram` 都要按链展开），不是"补一条判据"。
   ⚠ 与 DRM 余量（`c4b_frame_runnable.md` §3：`DRM 375.5/415 = 90.48%`）冲突，需先算面积。

### 3.3 另外两档**编程**下的预检（说明"整帧可跑"还缺什么）

同一张表、同一个口径，只换**主机编程**（运行时开关不在描述符里）：

| 档 | `PREFLIGHT_ERR`（UNIT） | ERR 的单元 | 说明 |
|:--|:--|:--|:--|
| 默认闸门档（`XDMA_EN=1` + 权重**按层预载** + `layout=derived`） | **1** | 29 | §2 的证书 |
| `--layout zero`（**= 当前驱动的实况**：区域 7 道 2 那两位**没人投递**） | **8** | 3, 12, 17, 22, 29, 30, 33, 34 | 多块旁路层（C=16/64 的 `maxpool`/`add`/`resize`）要**平面通路**（`blkPlanarOk`，`BypassExec.scala:580`），而 `src_planar/dst_planar` 上电为 0 ⇒ **就算修好 `Resize_43`，驱动侧还得补投这两位**（`tools/npu_frame_run.py:346-348` 自己就写着这是开口项） |
| `--blob 1`（**= 真帧的权重编程**：DDR blob） | **40** | 0,1,2,4,5,…,58（全部非 plain 的宽层） | 宽层非 `plain` 的单元在 `WGTRUN` 收口那一拍撞 `wideGeomOk` 的 `inWOk`（`inWMax > WIDTH=34`）——见 §3.2；`plain` 的宽层走 `tilingWideC` 也撞同一拍 |

⇒ **"整帧跑得完"至少还差三件**：① `Resize_43` 那一类的 per-plane band（§3.1）；
② 驱动投递布局两位（`--layout zero` 档的 8 个 ERR）；③ 宽层链的裁决（§3.2）。

---

## 4. 闸门证据（`bash y1/tools/run_preflight_ab.sh`）

```
== run_preflight_ab: 整表几何预检（67 单元逐条走 RTL 的 go 判据）==
   tool=tools/frame_preflight.py  desc=gen/desc.bin  py=/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe
---- [1] 正对照：真表 67 单元（UNIT 口径；编程 = 既有闸门档 XDMA_EN=1 / blob=0）----
    frame_preflight —— 整表几何预检（spec §4-C 判据 C 的 Python 快门）
      table = D:\code\PDS\VexiiYeshenLinux\y1\gen\desc.bin
      md5=fec587a13fb51ed00914e5ce9c04db02  payload=67  sentinel@67（+1 = 68 条）
      网表参数 C=8 WIDTH=34 IMG_H_MAX=32 L_MAX=8 TILING=True MAXPIX=1088
      运行时开关（UNIT 口径）XDMA_EN=1 dmaEn(blob)=0 unit_flags=plain layout=derived
      运行时开关（DISPATCH 口径）XDMA_EN=1 dmaEn(blob)=1（= 真帧驱动 tools/npu_frame_run.py）
    
      idx type         chain     shape(WxHxCin>Cout) flags    UNIT path    verdict
    PREFLIGHT_ERR=1
    PREFLIGHT_ERR_UNITS=29
    DISPATCH_ERR=54
    DISPATCH_ERR_RUNS=0,1,4,13,18,23,29,31,35,37,39,41,43,45,47,49,51,53,55,57,59
    RESULT: FAIL
    正对照 OK：唯一 ERR = unit 29（tileAliOk；见报告 = 真开口项）
---- [2] 确定性：同源连跑两次必须逐字节相同 ----
    DETERMINISM_2X_OK md5=7c73a8bcea09b103d3c79d5edd1eefc6
---- [3] 负对照①：Resize_49（idx 33）IMG_W 80 -> 82 ⇒ 必须翻成 ERR ----
    INJECT unit=33 IMG_W 80 -> 82
    PREFLIGHT_ERR=2
    PREFLIGHT_ERR_UNITS=29,33
    负对照① 发火：ERR 集合 {29} -> {29,33}（外科式：恰好 +33）
---- [4] 负对照②：MaxPool_5（idx 3）C_IN 16 -> 17 ⇒ 必须翻成 ERR ----
    INJECT unit=3 C_IN 16 -> 17
    PREFLIGHT_ERR=2
    PREFLIGHT_ERR_UNITS=3,29
    负对照② 发火：ERR 集合 {29} -> {3,29}（外科式：恰好 +3）
---- [5] DISPATCH 口径（真派发：链塌缩 + 真帧编程 XDMA_EN=1/blob=1）的开口项锚 ----
    DISPATCH_ERR=54（冻结 54）
      run@0   L=1  单元 0..0 -> ERR(wide-tile: WGTRUN-end wideGeomOk/inWOk（:2079，inWMax=640>34）)
      run@1   L=2  单元 1..2 -> ERR(wide-whole: wgtLoadOk(chain_len==1, :1451))
      run@4   L=8  单元 4..11 -> ERR(wide-whole: wgtLoadOk(chain_len==1, :1451))
      run@13  L=4  单元 13..16 -> ERR(wide-whole: wgtLoadOk(chain_len==1, :1451))

== 结论 ==
  PREFLIGHT_ERR=1（UNIT 口径）：unit 29 Resize_43 —— tileAliOk（真开口项）
  DISPATCH_ERR=54（真派发口径）：宽层的融合链无合法通路（chain_len==1 前提）
  ⇒ FRAME-RUNNABLE: NO（整帧在 tiled 网表 + 真表上跑不完；见 reports/c4b_frame_preflight.md）
  闸门本身：正对照（冻结 ERR 集合）+ 2 条能发火的负对照 + 确定性 ⇒ 全部成立
RESULT: PASS
```

- **正对照**：真表 `UNIT` 口径的 ERR 集合**恰好** `{29}`（判据 = 冻结常量 `EXPECT_UNIT_ERR_UNITS=29`
  **且**该条的错误理由里必须含 `tileAliOk`）⇒ 既抓"又多了缺口"，也抓"缺口被修好却没重新锚定"。
- **确定性**：同源连跑两次逐字节相同（`DETERMINISM_2X_OK`）。
- **负对照①（有牙）**：`Resize_49`（idx 33）`IMG_W 80 → 82` ⇒ `{29} → {29,33}`（**外科式**：
  恰好 +1，且正是被改的那一条）。
- **负对照②（有牙）**：`MaxPool_5`（idx 3）`C_IN 16 → 17` ⇒ `{29} → {3,29}`（`cBlkOk` 发火）。
- **DISPATCH 锚**：`54`（冻结；变小 = 开口项被修 ⇒ 重新锚定，变大 = 新缺口）。
- 退出码：`0` 全过 / `1` 正对照或锚不符 / `2` 负对照没发火 / `3` 前置缺失。

---

## 5. spec §4-C 的**终证**（模拟里跑真 `desc` 序列）：**尽力了，但要如实说**

### 5.1 做到哪一步

spec §4-C 的**权威**证书是"把真 `desc` 序列喂进模拟、`errSticky` 恒 0"。我**没有**做整表 67 条
的模拟（理由见 5.3），但做了一条**判决性的子实验**（**只用既有装置**，不新建基础设施）：

| 实验 | 装置/网表 | 结果 |
|:--|:--|:--|
| A 宽层 tile + **邮箱权重**（= 既有 `run_tiling2d_wide_ab.sh` 的编程） | `rtl_test/UnitExecWideTb.v` + `gen/UnitExec_tiled.v`， `+TILED_W`，`64→64 40×40 s=1` | **`RESULT: PASS`**（done、无 err、busy 落 0；`AR=54912`） |
| B 同上 + **权重 blob DMA**（`+WBASE=262144`，= 真帧的编程；内存镜像里那一段权重由**冻结参考**的同一 `wq` 摆好） | 同上 | **不完成**：`RESULT: FAIL timeout(… 超 4000000 拍)`；`MEM rd=128 wr=0 bursts=1` ⇒ 权重 RD **只发了 128 B 一笔就停住**，既无 done 也无 err |
| C 对照（把形状换成 `inWMax ≤ WIDTH` 的 `64→16 8×32`） | 同上 + `+WBASE` | **同 B**（`rd=128/bursts=1` 后挂住）⇒ **不是** `inWOk` 引起的，是 **(tile 网表 + 权重 blob)** 这个**组合**本身 |

**A/B 的差只有一个开关**（`+WBASE`），而 **`run_tiling2d_wide_ab.sh` 从不传 `+WBASE`**
（`+TILED_W` 只在那一份闸门里出现；`+WBASE` 只在 `run_wgtdma_*` / `run_paramdel_ab.sh` 的
**非 tile** 作业里出现）⇒ **(tile 网表 × 权重 blob) 这个组合没有任何闸门覆盖**，
而**真帧驱动恰好用的就是它**（`tools/npu_frame_run.py`：区域 6 投递 `WGT_BLOB_BASE` + `--xdma-en`）。

### 5.2 这条子实验**能**说什么 / **不能**说什么

- **能**说：真帧的那一档编程（blob + XDMA）在 tiled 网表上**跑不完**（B/C 两档都挂），
  且这一档**从未被证过**；这与 §3.1/§3.2 的结论**方向一致**（整帧现在跑不完）。
- **不能**说：**挂住的机理**。§3.2 的 Python 模型预测的是"`WGTRUN` 收口那一拍 `wideGeomOk` 假 ⇒ err"，
  而实测是**挂住（无 done 无 err）**。⇒ **Python 预检与 RTL 在这一条上口径不一致**
  （要么模型少了一个前提，要么装置里还有一处我没看出来的差异）。**这正是 §4-C 要求"模拟终证"的原因**，
  也说明**本报告的 §3.2 应以"RTL 判据链的读码 + 该档跑不完的实测"合起来读，而不是以 Python 模型单独结论**。

### 5.3 整表 67 条序列为什么**defer**

要跑真序列需要：① 给 67 条描述符各准备**真张量**（输入 1.2 MB + 66 张中间张量，`arena ≈ 5 MB`）；
② 逐层权重 blob（404 KB）与 `M/z_pad/z_y/bias_adj` 信箱投递；③ 把 `NpuTopSchedTb.v` 的内存模型
从 64 KiB 扩到 ≥ 8 MiB 并**给整帧落盘对账**；④ 真帧的 `XDMA`/布局位/… 一整套主机编程序列。
现有装置（`NpuTopSchedTb.v` 64 KiB、3 条目小表；`LayerSchedTb.v` 小几何）**不支持**这一档，
改造量 ≥ 新建一套"整帧装置"（不是"适配参数"）⇒ **按任务约定不做假证，明确记为 defer**。

**⇒ 由此产生的口径漂移风险（明写、开口项）**：
`frame_preflight.py` 是 RTL 判据的**第二实现**（Python 侧），与 RTL 之间**没有自动对账**。
本报告里凡是"Python 说"的（尤其 §3.2 的 54 条），**都必须以"读 RTL 代码 + §5.1 的实测"为真源**；
一旦补上"整帧装置"，**第一件事是用它把 `PREFLIGHT_ERR` / `DISPATCH_ERR` 逐条对账**。

---

## 6. 我**能**证 / 我**不能**证

**能证**
1. 真表 67 条**逐条**走完 RTL 的 `go` 判据（Python 第二实现，每条注明 RTL 行号）⇒
   **66 条有合法通路、1 条（`Resize_43`）没有**；判据（`tileAliOk`，`BypassExec.scala:607`）
   与根因（整层 `inCols%32` 前提没搬到 tile）都点到了行。
2. 预检**有牙**：两条负对照把**指定**单元翻成 ERR、且是**外科式**（ERR 集合恰好 +1）；
   同源连跑两次逐字节相同。
3. 预检与既有三道闸门证过的形状**逐一一致**（§2.1）⇒ 它没有推翻任何既有绿档，只是**多覆盖 59 个形状**。
4. 真表**52 条链上 conv 全是宽层**、而 RTL 宽路四条判据全带 `chain_len == 1`（`UnitExec.scala:1236/1426/1451/1650`）
   ⇒ **宽层融合链无通路**（读码级；并且 (tile × blob) 档在模拟里实测**跑不完**）。
5. 冻结的 C3.2 表**同样**带这个不兼容（我复算了它的 19 条链：全是 C=16/64）⇒ 这是 C3 起的空白，
   不是本片引入的。

**不能证（开口项）**
1. **整帧跑不完的"机理"**：模拟只证到"该档不完成"，没定出"err 还是挂、挂在哪一拍"。
2. **§3.2 的逐条模型**：`DISPATCH_ERR=54` 是 Python 侧的数，**没有**用真序列在模拟里复核（§5.3）。
3. **没上板**：12 路输出与 G7 容差仍是 n/a（本来归 S3，而 S3 现在被本任务挡在门外）。
4. 修完 §3.1/§3.2 之后的**流量/面积**账（宽层链的支持要动 `wram`/`outMem` 规模）尚未算。

---

## 7. 下一步（把"真帧可跑"变成真的）

1. **修 `Resize_43` 那一类（小、同 idiom）**：`BypassExec` 旁路 tile 的 band 相位改 per-plane
   ⇒ 让 `tileAliOk` 不再要求整层 `inCols%32==0`；闸门加 `resize 40×40`（**先红后绿**）+ 负对照
   （退回共享相位 ⇒ 必红）；修完**重新锚定** `EXPECT_UNIT_ERR_UNITS`。
2. **裁决宽层链（大，先 spec 修订）**：表侧"宽层不融合"（重算流量）**或** RTL 侧"宽层支持链"
   （面积/DRM 先算）；两条都要在 spec §4-C 里写死新的判据。
3. **补 (tile × blob) 档的闸门**：现在这个组合**零覆盖**，而真帧非它不可（§5.1）。
4. **整帧装置**（§5.3）：把 `PREFLIGHT_ERR`/`DISPATCH_ERR` 在模拟里逐条对账 —— 这是 §4-C 的**终证**。
5. 之后才是 **S3**（PnR → 比特流 → 板 → 12 路 + G7）。
