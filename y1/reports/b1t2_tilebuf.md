# Y1-NPU B1-T2：宽层 tile 输入跨 co-block 复用（`tileBuf`）—— RTL + 单元闸门

- 日期：2026-10-20
- 上游：`docs/superpowers/specs/2026-10-20-y1-npu-b-input-reuse-design.md` §2/§5、
  `docs/superpowers/plans/2026-10-20-y1-npu-b1-input-reuse.md` B1-T1/T2/T3、
  `y1/reports/b1t1_map.md`（§2 趟循环、§3.3 tileBuf 尺寸、§4 部分和、§6.3 最小编辑集、§6.2 风险 2 行号冻结）
- 本片边界：**RTL + TB + 闸门 + 网表**。不碰 PnR / 板级 / 驱动 / 描述符格式 / 冻结工具。

---

## 1. 一句话结论

宽层 dense 的输入读从 **每 co-block 读一遍** 改成 **每 ci-block 读一遍**（ci 外 / co 内 +
9,248 B `tileBuf` 填充/重放 + 重放期零 AR）：`Conv_15`（32→64、160²、1×1）上
**输入读 = 924,800 B = nominal×1.1289**（tile halo），旧行为 **7,398,400 B = ×9.03**；
数值**逐字节不变**（两条独立冻结参考互证），`TILING=false` 三份网表**逐字节不变**。

---

## 2. 改了什么（`y1/rtl/UnitExec.scala`，类体**末尾**新增一节，`if (TILING)`）

| # | 落点 | 内容 |
|:--|:--|:--|
| ① | 新增节「B1」 | **趟序重排**：dense 换趟（`wSt==4`）改成 **ci-block 外、co-block 内**（对该分支后写覆盖） |
| ② | 同上 | **`tileBuf`** `Mem(Bits(64), 1156)` = **9,248 B**：填充趟写、重放趟读 |
| ③ | 同上 | **AR 抑制**：重放趟把 gather 的 DECIDE 直接改判到 EMIT（`wxSt: 1→3`）⇒ 该趟 `wxSt` 永不为 2 ⇒ `start`/`rd_ready` 的 gather 支恒 0 |
| ④ | 同上 | 观察口 **`gather_bytes`**（`TILING=true` 才有的输出端口，与 `x1_beats`/`chain_rep_*` 同一手法） |

**为什么行数中性**：SpinalHDL 把源码行号编进网名（`_zz_when_UnitExec_l####`）与 `// @[...]` 注释 ⇒
任何**既有行**的增删都会改 `TILING=false` 网表。本节**只追加在类体最后一条语句之后**、且全部包在
`if (TILING)` 里 ⇒ `TILING=false` 连一根线都不加（§5 逐字节证据）。

### 2.1 为什么"数值不变"是可推的（不是"应该没事"）

- 每个 co-block 的累加**仍按 ci 升序**（cib = 0 → nCi−1）：ci-outer 只是把**别的 cob** 的趟插在中间，
  同一个 `cob` 的加数顺序一字未变；
- 部分和按 `cob` 分段（`PartialSumBuf` 的 `cob*PIXMAX`，`NCOB=8` 段地址互不重叠）⇒ 插入的其它
  co-block 的趟**写的是别的段**，不会清/踩本段；
- `ps_clr = tilingW && (wCi==0)`：ci-outer 下 `wCi==0` **正好是每个 co-block 的第 1 趟** ⇒ "每段清零
  一次、其余趟读回累加"的语义不变；`wCollectCiOk = (wCi==nCi-1)` 同理 = 每个 co-block 的成品趟；
- `wBiasR` 的 `(wCi==0)||isDwW` 门 ⇒ 每个 co-block 的第 1 趟带本块 bias，一次不差。

### 2.2 重放为什么复用 gather 的位置推进（第一版踩过的坑，写进账）

第一版给重放另立了一个"SETTLE→PRESENT"喂列 FSM，实测**挂死**（`Conv_*` 8×8 冒烟里 `wRow` 无限自增）：
`wRow/wCol` 的推进在 gather 的 EMIT 分支里（`when(wxRun){ switch(wxSt){ is(3){ when(mpu.io.x_ready){…} }}}`），
它**在 `x_ready` 上推进、不看 `x_valid`** ⇒ 两套推进消费同一个 `x_ready`（列号走得比数据快一倍）；
而且 `wxSt=0` 在 gather 的 FSM 里只是过路态（`is(0){wxSt:=1}`），压不住。
现实现只做两件事：**DECIDE 的后继改判 EMIT**（不 fetch、不写 `xwBuf`）+ **列数据换成 tileBuf 读出**；
位置推进/握手/趟收工全部沿用既有那一条路（每 2 拍一列，切片 `x_ready` 最快 1/3 ⇒ 不降吞吐）。

---

## 3. `gather_bytes` 的口径（明写；与 map §3.4 的三条放大对齐）

`gather_bytes` = 本次 run 里 gather **首次交付**的输入字节数 = Σ(填充趟交付的列数 × 本 ci-block 的
有效平面数 `wxNPl`)。口径边界：

| 项 | 在不在计数里 | 归属 |
|:--|:--|:--|
| 同一 ci-block 的第 2..nCo 个 co-block 的重读 | **不在**（重放趟不数） | ← **B1 消掉的就是这一项** |
| tile halo（相邻 tile 的 2 行/列重复列） | **在**（1.129× @32×32 tile） | B2 |
| 32 B band 的重取放大（一行 34 列跨 2–3 个 band） | **不在**（数唯一列字节，不数 AR 字节） | B3 |
| `C_in%8!=0` 的跳过通道 | **不在**（`wxNPl = min(8, C_in-8·cib)`） | — |

`Conv_15` 预测：25 tile × 34×34 列 × Σ`wxNPl`(4×8=32) = **924,800 B**；nominal = 32·160·160 =
**819,200 B** ⇒ **×1.1289**（= 34²·25/160²）。旧行为 ×8 = **7,398,400 B**（= nominal × 9.03）。

---

## 4. 闸门 `tools/run_b1_tilebuf_ab.sh`

被测网表 `gen/UnitExec_tiled.v`（`WIDTH=34 / IMG_H_MAX=32 / TILING=true`），装置
`rtl_test/UnitExecWideTb.v`（`-DUE_CGEOM -DUE_GBYTE`）+ `AxiMemModel.v`。作业两份：

| 作业 | 形状 | 目的 |
|:--|:--|:--|
| `conv15` | C_in=32、C_out=64、160×160、**conv1×1（TYPE 2）** | 任务要求的 `Conv_15` 形状；4 ci × 8 co = 32 趟、5×5 tile |
| `c64_40` | C_in=64、C_out=64、40×40、3×3（TYPE 1） | 9 抽头档 + 两种 tile 尺寸（34 / 10 行） |

判据：① `DST` 与**冻结黄金**逐字节同（`tiling_ref.conv_tiled` + `quant_ref.conv_vec` 两条互证；
1×1 用 S4-C 的**居中**口径：参考核抽头在 (1,1)、DUT blob 在槽 0）；② `gather_bytes == 唯一列字节`
（=`GEXP`）；③ 负对照（`assign b1_play = 1'b0;` ⇒ 旧行为每 co-block 重读）：**数值仍逐字节对**
（`MISMATCH=0`）而**计数翻 nCo 倍** ⇒ `+GEXP` 判据**必红** ⇒ 红点唯一可归因。

（闸门输出见 §7。）

---

## 5. `TILING=false` 冻结证据（约束 1）

三条互相独立的证据：

1. **文件 md5（已知三元组，逐字节不变）**：
   `gen/UnitExec.v dd9ee31e65017427d05d8f8272b501be`、
   `gen/UnitExec_w32.v af5090713ecef3d3d9415453c22da067`、
   `gen/UnitExec_w640.v 781bb0fd6e029e2fac5d8b95ca7abc16`。
2. **源码中性（本改动的直接判据）**：同一份源码**改动前 / 改动后**各生成一次 `TILING=false` 三份
   ⇒ 逐字节相同：`2aa33f68098e0fb82235856f80c177c4` / `0347a2efa5fbeb1765d0246c3e2cd5f5` /
   `aa1d8094498b32037467c92b940b45ff`（两份产物留在 `build/b1_slice/{base,new}_tfalse/`，闸门 [0] 现场复核）。
3. **确定性 2×**：连续两次生成，四份 `UnitExec*.v` 的 md5 逐字节相同（`DET2X_OK`，§7）。

★ **必须记录的既有漂移（与本改动无关，但会咬人）**：`y1/gen/` 是**未入版本库**的构建产物，而
`gen/UnitExec*.v` 的时间戳早于 `bf91fee`（10-18 03:08，改 `wxPixTot→wxPixTotG`）与 `b20dbb1`
（10-18 09:33，`DdrMaster` Q=4 块槽预取）⇒ **从 HEAD 源码现生成**的 `TILING=false` 三份 ≠ 上面第 1 条的
三元组（差的就是这两笔，证据：在 `f848e01` 的 worktree 里对同一 `UnitExecGen` 现生成 ⇒ 逐字节回到
`dd9ee…/af509…/781bb…`）。因此本片**把三份冻结文件按原字节恢复**（provenance = `f848e01`，md5 逐字节
对上），并把"HEAD 源码版"存到 `build/b1_slice/headsrc_tfalse/` 备查；**判"本改动没动 `TILING=false`"
用的是第 2 条**（同一棵树、只差本改动）。
★ 未做（开口项）：`LayerSched.v`/`NpuTop.v` 等其余 43 份网表**未重生成**（它们内嵌的 `UnitExec` 仍是
L2b 之前的版本）—— 全量重生成属 L2b 的既有债，应与板级 `TILING=true` 面一起做（B1-T4）。

---

## 6. 回归清单

| 闸门 | 结果 |
|:--|:--|
| `run_b1_tilebuf_ab.sh`（B1 直接闸门） | **PASS**（§7.2） |
| `run_multipass_ab.sh` | **PASS**（§7.3） |
| `run_dw_wide_ab.sh` | **PASS**（§7.3） |
| `run_chain_wide_ab.sh` | **FAIL / 既有红（与本片无关）**：同一条闸门换成本片之前的 `build/b1_slice/nob1/UnitExec_tiled.v` 也是 4/4 POS_RED、同一段说明（§7.4） |
| `run_unitexec_ab.sh` | **PASS**（§7.5） |
| `run_sched_ab.sh` | **PASS**（§7.5） |
| `run_wgtblob_tiled_ab.sh` | **FAIL / 既有红（与本片无关）**：负对照② 的 `MEM rd=128` 锚早于 `b20dbb1` 的 `DdrMaster` `rqDepth=4` 预取（实测恒 512）；pre-B1 网表逐字复现（§7.6） |
| `run_tiling2d_wide_ab.sh`（**额外**，B1 的直接回归面：9 个宽 tile 作业 + 3 条突变） | **PASS**（§7.7） |

---

## 7. 实测输出

> 现场：2026-10-20，`cd /d/code/PDS/VexiiYeshenLinux/y1` 下逐条 `bash tools/<gate>.sh`（Git Bash，
> iverilog 13，python = `…/sim/reglogs/lxvenv/Scripts/python.exe`）。逐闸门原始日志留在
> `y1/build/b1_gate_logs/`（**未入版本库**：`y1/.gitignore` 已 ignore `build/`）。
> 本节的 tail 逐字复制自这些日志。

### 7.1 汇总（8 条）

| # | 闸门 | 命令 | 结论 | exit |
|:--|:--|:--|:--|:--|
| 0 | **B1 直接闸门** | `bash tools/run_b1_tilebuf_ab.sh` | **PASS**：`Conv_15` 逐字节 + `gather_bytes` **924,800** == `GEXP` + 负对照**翻 8 倍必红** | 0 |
| 1 | 多趟回归 | `bash tools/run_multipass_ab.sh` | **PASS** | 0 |
| 2 | depthwise 宽路 | `bash tools/run_dw_wide_ab.sh` | **PASS** | 0 |
| 3 | 宽链 | `bash tools/run_chain_wide_ab.sh` | **FAIL（既有红，非本片）** §7.4 | 1 |
| 4 | 窄路 UnitExec | `bash tools/run_unitexec_ab.sh` | **PASS** | 0 |
| 5 | 调度器 | `bash tools/run_sched_ab.sh` | **PASS** | 0 |
| 6 | 权重 blob × tiled | `bash tools/run_wgtblob_tiled_ab.sh` | **FAIL（既有红，非本片）** §7.6 | 2 |
| 7 | tiled 二维（B1 回归面） | `bash tools/run_tiling2d_wide_ab.sh` | **PASS** | 0 |

★ 闸门脚本本片内修了一处**纯顺序** bug（不动任何判据）：`run_b1_tilebuf_ab.sh` 原来在 `[2]` 结尾
就用 `$(( G2_GEXP * 8 ))` 算"旧行为口径"的显示值，而 `G2_GEXP` 要到 `[3]` 才定义 ⇒ `set -u` 下
`G2_GEXP: unbound variable` 当场退出（判据一行都没跑到）。现挪到 `[3]` 之后取值（两个变量只用于末尾
两行汇总显示）。

### 7.2 `tools/run_b1_tilebuf_ab.sh`（B1 直接闸门）—— **PASS**

```text
---- [0] 前置：参考自检 + TILING=false 三网表 md5 + 源码中性证据 ----
   参考自检 OK（tiling_ref.py --selftest2d）
   TILING=false 三网表 md5 不变（dd9ee31e65017427d05d8f8272b501be / af5090713ecef3d3d9415453c22da067 / 781bb0fd6e029e2fac5d8b95ca7abc16）
   NEUTRAL UnitExec.v base=2aa33f68098e0fb82235856f80c177c4 new=2aa33f68098e0fb82235856f80c177c4 IDENTICAL
   NEUTRAL UnitExec_w32.v base=0347a2efa5fbeb1765d0246c3e2cd5f5 new=0347a2efa5fbeb1765d0246c3e2cd5f5 IDENTICAL
   NEUTRAL UnitExec_w640.v base=aa1d8094498b32037467c92b940b45ff new=aa1d8094498b32037467c92b940b45ff IDENTICAL
   TILED_NL_MD5=1ecd6ba0c5fc64f90b1aee14433416e6（gen/UnitExec_tiled.v，只记账）
---- [1] iverilog 编译（UnitExecWideTb + AxiMemModel + gen/UnitExec_tiled.v；-DUE_CGEOM -DUE_GBYTE）----
   编译 OK
---- [2] 正对照①：Conv_15 形状（C_in=32 C_out=64 160×160 conv1x1）----
   预测：GEXP=924800 NOMINAL=819200 COLUMNS=28900 PLANES=32 NTX=5 NTY=5
   JOBGEN conv15 kind=x1 CIN=32 COUT=64 160x160 n_ci=4 n_co=8 M=53687091 len=1638400 in=819200
   [conv15/pos] MISMATCH=0 NEIGHBOR_BAD=0  GATHER_BYTES=924800 GEXP=924800 GB_OK=1
   OK: conv15/pos 逐字节 == 冻结黄金 + gather_bytes == 唯一列字节
---- [3] 正对照②：dense 3×3（C_in=64 C_out=64 40×40）----
   预测：GEXP=123904 NOMINAL=102400 COLUMNS=1936 PLANES=64 NTX=2 NTY=2
   JOBGEN c64_40 kind=k3 CIN=64 COUT=64 40x40 n_ci=8 n_co=8 M=53687091 len=102400 in=102400
   [c64_40/pos] MISMATCH=0 NEIGHBOR_BAD=0  GATHER_BYTES=123904 GEXP=123904 GB_OK=1
   OK: c64_40/pos 逐字节 == 冻结黄金 + gather_bytes == 唯一列字节
---- [4] 负对照：assign b1_play = 1'b0（旧行为：每 co-block 重读）----
MUTGEN_HITS=1 (期望 1)
   [mut] GATHER_BYTES=991232 GEXP=123904 GB_OK=0
   [mut] RESULT: FAIL tiled_w=1 done=1 err=0 busy=0 nfed=0/1 wr=32(期望 102400) aw=5120 b=5120 rd_peak=32(期望 0)
   [mut] MISMATCH=0 NEIGHBOR_BAD=0  GATHER_BYTES=991232（期望 991232）GEXP=123904 GB_OK=0（期望 0）
   NEG_OK: 数值逐字节对（MISMATCH=0），只有计数翻 8 倍（123904 → 991232）⇒ 红点唯一且可归因
--------------------------------------------------------------------------
  gather_bytes（Conv_15，唯一列字节）=924800  = nominal 819200 × 1.1289（tile halo）
  gather_bytes 旧行为（每 co-block 重读）  =7398400 = nominal × 9.03（Conv_15 口径；负对照实测在 c64_40 作业上：991232）
  结论：B1 把**每帧输入读**从 nominal×9.03 收回到 nominal×1.13（DDR 侧；band 重取放大属 B3、halo 属 B2）
RESULT: PASS
```

三条判据逐条落地：① `Conv_15` 形状 `MISMATCH=0 / NEIGHBOR_BAD=0`（`tiling_ref.conv_tiled` +
`quant_ref.conv_vec` 两条冻结参考互证）；② `gather_bytes = 924,800 = 唯一列字节`（= `GEXP`，
nominal×1.1289）；③ 负对照 `b1_play` 打平 ⇒ **数值仍逐字节对**、`gather_bytes` **恰 ×8**（991,232）、
`+GEXP` 判据发火（`GB_OK=0` / `RESULT: FAIL`）⇒ 红点唯一可归因。

### 7.3 `tools/run_multipass_ab.sh`、`tools/run_dw_wide_ab.sh` —— **PASS**

```text
$ bash tools/run_multipass_ab.sh
负对照 A2= OK（网表突变：PartialSumBuf 写口关掉 ⇒ 精确命中'只 requant 末趟 partial'、且 != 黄金）
负对照 B = OK（网表突变：部分和缓冲初值非 0 ⇒ 精确命中 requant(acc+K)、且 != 黄金 ⇒ '第 1 趟清零'是承重项）
RESULT: PASS

$ bash tools/run_dw_wide_ab.sh
负对照   = OK（收料门退回 'wCi==nCi-1' ⇒ 对角循环下前 nCo-1 个 co-block 收不到料 ⇒ 红且定位到末 co-block 之前）
边界     = OK（GROUP ∉ {1,depthwise} / C_in==0 ⇒ ERR_SEEN=1、零搬运）
整帧可跑 = 宽层 conv 44/53 端到端逐字节（其中 depthwise 17 **本任务证死**）；剩余 9 个非宽层（C∈{1,4}）走窄通路装不了
RESULT: PASS
```

> 这两条正对 `st==4` 换趟（`run_multipass_ab.sh` 的趟序账、`run_dw_wide_ab.sh` 的 depthwise 对角趟）——
> 本片**后写覆盖只对 dense 生效**（`b1Use` 里有 `!isDwW`），depthwise 原样，实测逐字节不变。

### 7.4 `tools/run_chain_wide_ab.sh` —— **FAIL（既有红，非本片）**

```text
$ bash tools/run_chain_wide_ab.sh
作业集合： c16_L2 c64_L4 c64_10_L2 c64_1_L2
正对照: 绿 0 / 红(POS_RED) 4
JUDGE-RED: 宽链（chain_len ≥ 2 的宽路）在当前网表上没有通路 ——
  宽路的四条判据（wideGeomOk :1428 / wgtLoadOk :1451 / tilingWideC :1650 / LayerSched 派发）
  都要求 chain_len == 1 ⇒ go 那一刻响亮 err + 零搬运（本闸门 = 先红证据）。
  绿需要实现 plan T-S3f（宽路支持整链）；设计约束与取舍见 rtl/UnitExec.scala 文件尾「T-S3f」一节。
RESULT: FAIL          （exit 1）
```

**归因证据（把本片摘掉即复现）**：同一条闸门、把被测网表换成**本片之前的** tiled 网表
`build/b1_slice/nob1/UnitExec_tiled.v`（无 `b1_play`/`gather_bytes`，7,087,098 B）⇒ **一字不差**：

```text
正对照: 绿 0 / 红(POS_RED) 4
JUDGE-RED: 宽链（chain_len ≥ 2 的宽路）在当前网表上没有通路 ——…（同上）
RESULT: FAIL          （exit 1）
```

⇒ 这是 T-S3f（宽路整链）**尚未实现**时该闸门的**先红证据**，与 B1 无关；本片不修。

### 7.5 `tools/run_unitexec_ab.sh`、`tools/run_sched_ab.sh` —— **PASS**

```text
$ bash tools/run_unitexec_ab.sh
比较器   = OK（扰动 1 个黄金字节 ⇒ MISMATCH 恰为 1）
结构     = OK（check_dangling.py：gen/UnitExec.v 零悬空）
RESULT: PASS
EXIT=0

$ bash tools/run_sched_ab.sh
链塌缩         = OK（head 0b00 + tail 0b11 两个相邻条目 ⇒ **一次 go**（chainLen=2）；中间张量零 DDR）
非退化         = OK（各档黄金非常数/非全 0；maxpool 黄金 != 四个整块平移；add SAT>0；防混叠三区预载与黄金 >=1900 不同）
RESULT: PASS
EXIT=0
```

### 7.6 `tools/run_wgtblob_tiled_ab.sh` —— **FAIL（既有红，非本片）**

```text
$ bash tools/run_wgtblob_tiled_ab.sh
[0] 前置：参考自检 + TILING=false 三网表 md5 不变 + blob→wRam 映射 == weight_tiles()（互证） : OK
[1] 正对照（tiled 宽 + blob(DDR)，真表几何 ×3）                                       : 3/3（PASS + DST 逐字节 + wRam 逐字节）
[2] 负对照① blob 少一个趟瓦片（定位到 co-block 带）                                   : MISMATCH=8334（outside=0）
[3] 负对照② 退回修复-①（rd_ready 漏 wlTake）⇒ 挂住                                   : rd_ready=0 MEM rd=512 timeout=1
[4] 负对照③ 退回修复-②（WGTRUN 漏 !tilingW）⇒ 40×40 err / 8×32 不提                  : ERR=1/0 PASS=1
NEGCTL-FAIL: 1 条负对照没发火 ⇒ 闸门自身不可信
RESULT: FAIL          （exit 2）
```

**根因（与本片无关）**：负对照② 的"发火"判据里写死了 `MEM rd == 128`（"恰一块"）：
`tools/run_wgtblob_tiled_ab.sh:401` `[ "${MEMRB:-x}" = "128" ]`。但 `DdrMaster` 在 `b20dbb1`
（10-18，"Q=4 块槽预取"，`rtl/DdrMaster.scala:171` `rqDepth: Int = 4`）之后**一次会发 4 块**
⇒ 突变网表挂住前必然读到 `MEM rd=512` ⇒ 该条负对照**永远**判成"没发火"。挂住本身是**对的**
（`timeout=1`、`DBG-PHASE` 里 `rd_ready=0`、`MEM rd=512 bursts=4`），坏的只是那个常量。

**归因证据（把本片摘掉即复现）**：同一条闸门、被测网表换成**本片之前的** tiled 网表
`build/b1_slice/nob1/UnitExec_tiled.v` ⇒ 同样的 `MEM rd=512`、同样的 `NEGCTL-FAIL`、同样 `exit 2`
（日志 `build/b1_gate_logs/wgtblob_nob1.log`），且正对照 3/3 仍全绿。

⇒ 结论：**本片不引入该红**，也不在本片改这个常量（属 `b20dbb1` 的收尾债，应单独一笔把
`128 → 512`（或 `= rqDepth*128`）连同注释一起改，并保持"挂住 + `rd_ready=0`"两条断言不动）。
本片对它的**正向覆盖**是：同一条闸门的正对照 3/3（tiled 宽路 + blob）在本网表上仍全绿。

### 7.7 `tools/run_tiling2d_wide_ab.sh`（B1 的直接回归面）—— **PASS**

```text
$ bash tools/run_tiling2d_wide_ab.sh
[1] 正对照 真表宽几何（C=1/4/16/64 + depthwise + Conv_0 s=2）整层逐字节 : PASS（MISMATCH=0）
[2] 负对照① 漏一趟（tNtx-1->tNtx-2）        : PASS（MISMATCH=1274>0，定位 XMIN=32）
[3] 负对照② 不给 halo（tWinLo+1/tWinHi-1）   : PASS（MISMATCH=631>0，错列 4 ⇒ 接缝类）
[4] 负对照③ 共享 plane-0 索引（T-S3b）        : PASS（20×20 MISMATCH=20582>0；40×40 MISMATCH=0 不提）
RESULT: PASS
EXIT=0
```

> 9 个宽 tile 作业（含 `c16_160x160`、`c64_40x40`、`dw16_80x80`、`Conv_0 s=2`）整层逐字节全绿
> ⇒ B1 的趟序重排没有碰 `s=2`（`b1Use` 的 `tS==1` 门）与 depthwise（`!isDwW`）这两档。

### 7.8 `TILING=false` 冻结三证据（复核）

| 证据 | 命令 | 结果 |
|:--|:--|:--|
| ① 文件 md5 | `md5sum y1/gen/UnitExec.v y1/gen/UnitExec_w32.v y1/gen/UnitExec_w640.v` | `dd9ee31e65017427d05d8f8272b501be` / `af5090713ecef3d3d9415453c22da067` / `781bb0fd6e029e2fac5d8b95ca7abc16` — **逐字节对上** |
| ② 源码中性（同源 before/after） | `md5sum build/b1_slice/{base,new}_tfalse/*.v` | base == new：`2aa33f68098e0fb82235856f80c177c4` / `0347a2efa5fbeb1765d0246c3e2cd5f5` / `aa1d8094498b32037467c92b940b45ff` — **IDENTICAL** |
| ③ 确定性 2× | `md5sum build/b1_slice/{det1,det2}/*.v` | 四份（含 `UnitExec_tiled.v` `1ecd6ba0c5fc64f90b1aee14433416e6`）det1 == det2 — **IDENTICAL** |

（② 的 `build/b1_slice/{base,new}_tfalse/` 是同一棵树各生成一次；`headsrc_tfalse/` 与 `base_tfalse/`
同 md5 ⇒ 印证 §5 的漂移说明：`gen/` 里那三份冻结文件来自 `f848e01`，不是 HEAD 源码。）

---

## 8. 上板 A/B（2026-10-20，`video1b1r`）

**构建**：产品网表全量重生成（28 生成器/48 文件；5 份变化：`NpuTop.v` +1278 行含
`b1_use/b1_play/gather_bytes`、`LayerSched.v`、`BypassExec*.v`、`DescFetch.v`），确定性 2×
全等；TILING=false 三份 pinned md5 保真。PnR **All Constraints Met**，比特流 9,188,552 B。
本版同时带相机 **AGC 2× 封顶**（`0x3A19=0x20`，commit `1e597a1`）。

**启动**：首次烧写未起（瞬时），重烧后 SD/Linux/LiteEth/dropbear 全 PASS。

**帧时间（两个独立量具互证）**
| 量具 | B1 前 | B1 后 | 变化 |
|:--|--:|--:|--:|
| `y1cam --once` `NPU_MS` | 4663 ms | **3147 ms**（3147/3147/3148，3 次） | **−32.5%，1.482×** |
| `y1run --frames 1` `RUN ns` | 4,509,621,710 | **3,147,500,340** | **−30.2%，1.432×** |
| 检测帧率 | 0.215 fps | **0.318 fps** | +48% |

**数值**：`y1run --frames 1` → `outputs=12/12`，obj/bbox/kps 三组 12 路 CRC 全 `OK`，
`Y1RUN: PASS frames=1 pass=1 fail=0` ⇒ B1 未改变数值口径。

**备注**：`y1run` 直跑时 ssh 大输出会断，改用板内后台 + 落盘取尾（`> /tmp/yr.log & sleep 25; tail`）。
下一步：B2（tile halo 复用）/B3（更宽 gather），目标继续向 1 fps 推进；10 fps 仍需阵列/存储架构改造。
