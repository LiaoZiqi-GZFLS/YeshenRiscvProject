# Y1-NPU 性能 B1：宽层输入 tile 跨 co-block 复用（设计）

**状态**：设计（待实现）　**日期**：2026-10-20　**目标**：检测帧率 0.215 fps → ≥0.5 fps（第一刀）

## 1. 实测归因（冻结口径，`y1/reports/npu_v2_board_frame.md` §14.5）
- 4.66 s/帧；conv1x1 61%、depthwise 21%；成本与激活 inB 强相关（0.30 µs/B），
  真实 DDR 读 ≈75 MB/s（桥可达 275.9 MB/s）⇒ 帧被**读放大**限住，不是 MAC 阵列。
- 宽层（C_in>8 或 C_out>8）的激活按 `co-block 外、ci-block 内` 的趟序流式喂入
  （`UnitExec.scala` 文件头 C4a.5b）；每个 co-block 都重读同一 ci-block 的输入。
- 按 53 个 conv/dw 单元算（B1-T0 实测，见 §5）：输入名义 15.24 MB（14.53 MiB），当前按 co-block
  重读 68.65 MB（65.47 MiB，**4.505×**）。复用后输入读回到 14.53 MiB；按输入读占帧 70–82% 估算：
  **4.66 s → 1.7–2.1 s（0.47–0.60 fps）**。
  （早期"67 单元 / 15,021 KiB / 67 MB / 4.58×"是整文件行扫把 `issued Top-12` 排行表也计入的错误口径，
  见 §5 的差异说明。）

## 2. B1 方案
对每个 ci-block：输入 tile **只从 DDR 读一次**，在片上 tileBuf 中驻留，
依次跑该 ci-block 的所有 co-block（权重已在 `wRam` 全趟常驻；部分和按 `cob`
分段已在 `PartialSumBuf` 的 `NCOB=8` 段内，天然容纳全部 co-block）。

```
for cib in 0..nCi-1:
    gather(input tile of cib, 8 ch) -> tileBuf        # 1 次 DDR 读
    for cob in 0..nCo-1:
        for pix in tile:
            x = tileBuf[pix]
            acc = PSB[cob][pix] + conv(x, wRam[cib][cob])
            PSB[cob][pix] = acc
```
- `tileBuf`：8 ch × (tileW+2) × (tileH+2) B；32×32 tile 约 9 KB（BRAM）。
- 保持 `wide_x` 对外契约不变；只改 `UnitExec` 的宽层编排与 gather 次数。
- 窄层/旁路算子路径不动；TILING=false 冻结网表不动（wide 通路是产品路径）。

## 3. 判据（先红后绿）
1. **读计数**：同一层在 B1 前后的 DDR 读字节数 = `nominal` vs `nominal×nCo`（新增计数器/TB）。
2. **数值**：全部宽层端到端逐字节 == 冻结黄金（`run_multipass_ab.sh`/`run_dw_wide_ab.sh` 等的现有判据）。
3. **负对照**：故意让 tileBuf 在 co-block 间不刷新（或按 cob 重读）⇒ 读计数判据必红。
4. **面积/时序**：dev_map DRM 增量与 LUT 增量记录；PnR `All Constraints Met`（speed）。
5. **上板**：`y1cam --once` 的 `npu_ms` 与 12/12 输出 CRC 对账；A/B 同 C runner。

## 4. 后续（B1 之后）
- B2：tile halo 复用（相邻 tile 的 2 行 halo 不重复 gather）+ dw 对角趟输入复用。
- B3：更宽 DDR gather（多请求在飞 / 128 B）。
- 目标阶梯：0.5 → 0.8 → ≥1 fps；10 fps 仍需阵列/存储架构级改造（另立 spec）。

## 5. B1-T0 实测：DDR 输入读账（追加，2026-10-20）

**工具** `y1/tools/read_account.py`（只读 `y1/reports/npu_v2_mac_table.txt`、`y1/gen/wgt_index.json`、
`y1/gen/desc.bin`）；**闸门** `bash y1/tools/run_read_account_ab.sh` ⇒ `RESULT: PASS`（exit 0）。

口径（逐单元，可复算）：`nCi=ceil(C_in/8)`、`nCo=ceil(C_out/8)`、`passes=nCi·nCo`；
`nominal_in=C_in·H·W`（Q8 1 B/元素，H/W = 单元输出栅格）；`current_read=nominal_in·nCo`
（趟序 co-block 外、ci-block 内 ⇒ 每个 co-block 重读全部输入，`UnitExec.scala:1368-1369`）；
`reuse_read=nominal_in`（B1 目标）。只计 conv1x1/conv3x3/depthwise **53** 个单元
（maxpool/resize/add/sigmoid 属旁路，走冻结 `bypass_traffic.py` 口径，不并入）。

| 项 | 字节 | MiB | MB (1e6) |
|:--|--:|--:|--:|
| nominal（= B1 复用后 reuse） | 15,238,400 | 14.5325 | 15.2384 |
| current（co-block 重读） | 68,647,200 | 65.4671 | 68.6472 |
| B1 可消掉 | 53,408,800 | 50.9346 | 53.4088 |
| **amplification** | **4.5049×** | — | — |

**Top-3 by current_read**：`Conv_16` dw 64→64 160² = 13,107,200 B（nCi=nCo=8）；`Conv_15` 1×1 32→64
160² = 6,553,600 B（nCi=4、nCo=8）；第三名 **3,276,800 B 一档 11 个单元并列**（`Conv_2`/`Conv_3`/
`Conv_10`/`Conv_12`/`Conv_13`/`Conv_19`/`Conv_20`/`Conv_22`/`Conv_23`/`Conv_51`/`Conv_52`，
按 idx 稳定排序取 `Conv_2`）。

**与 §1 早期快速模型的差异（已查明）**：那张表是**整文件行扫**——`npu_v2_mac_table.txt` 在第一张
逐单元表（53 行）之后还有一张 `issued Top-12` 排行表，列序不同（无 `flags` 列），同一行正则把它也
当成单元 ⇒ 12 个单元被重复计入、列错位（共 65 行）⇒ 15,021.3 KiB / 67.17 MiB / 4.579×。
正确口径（第一张表 53 行）：15,238,400 B / 68,647,200 B / **4.5049×**。工具用 `NAIVE_RAW_SCAN_*`
把旧口径原样复现出来，闸门要求它与正对照**必须不同**（口径防回归）。

**敏感性**（结论不变）：A) 把 nominal 换成 `wgt_index.in_bytes` 真输入字节（`Conv_0` s=2 ⇒ 输入
640×640×3 = 4×H·W；两个 20×20 C_in=1 折档平面 +32 B 补位）⇒ 16,160,032 / 70,490,432 B / 4.3620×；
B) 剔掉 6 个 conv3x3 小尾 ⇒ 47 单元 15,221,600 / 68,630,400 B / 4.5088×。

**闸门（正/负对照都真跑；负对照是判据不是打印）**——输出摘录（省略部分 PASS 行）：

```
$ bash y1/tools/run_read_account_ab.sh
[PASS] Σnominal awk == tool（15238400 B）
[PASS] Σcurrent awk == tool（68647200 B）
[PASS] current = 65.467072 MiB ∈ [65,69]（67±2）
[PASS] nominal/reuse = 14.532471 MiB ∈ [14,15]
[PASS] amplification = 4.504882 ∈ [4.5,4.7]
[PASS] 负对照总数 15238400 != 正对照 68647200（开关真的生效）
[PASS] 负对照 current == 正对照 nominal（15238400 B；nCo=1 ⇒ 只读一次）
[PASS] 负对照 amplification = 1.000000
RESULT: PASS
$ echo $?
0
```

负对照 = `read_account.py --force-nco1`（nCo 强制 1）：`TOTAL_CURRENT_BYTES` 塌回 15,238,400 B、
amp=1.000000；若两者相等 ⇒ 闸门 **exit 2**。红证据（受控注入后已还原）：① 把 `--force-nco1` 改成
空操作 ⇒ `RESULT: FAIL (negative control did not fire)`、exit 2；② 默认 nCo 多算一个 co-block ⇒
`[FAIL] Σcurrent awk=68647200 != tool=83885600`、exit 1。

**结论**：B1 的价值 = 每帧消掉 **53,408,800 B（50.93 MiB）** 的 DDR 输入读（68.65 → 15.24 MB，
−77.8%）；即 §2 的 tileBuf 复用落地后，输入读倍率 **4.505× → 1×**。


## 5. B1-T0/T1 测绘后的口径修正（2026-10-20，`bdeecbb`）
- **RTL 实口径**：depthwise 20 个单元已走对角趟（`UnitExec.scala:1406,2157-2159`），
  并非 `nominal*nCo`；B1-T0 的工具对它们多算了。按 RTL 计，当前输入读 **38.84 MB / 2.55×**
  （真 `in_bytes` 40.68 MB / 2.52×），B1 可省 **~23.6–24.5 MB**，不是 53.4 MB。
- **输入 gather 的真实位置**：`UnitExec` 自己的 DdrMaster 32 B plane 突发
  （`UnitExec.scala:1529-1532, 2304-2311`）；`wide_x` 在集成层被 **tie 0**
  （`LayerSched.scala:674-675`）⇒ B1 必须落在 `XDMA_EN=1` 的 dense 通路上，且
  `wide_x` 是单次背压流、不可重放。
- **tileBuf 尺寸**：8 ch × 34 × 34 = **9,248 B**（9 KB 级），不是 8,000 B。
- **最小改动集**：`UnitExec.scala:2304-2360`（tileBuf 填充/重放）、`2154-2168`（dense 趟序
  cob 内移）、`2436-2437`（重放期 AR 抑制）、`2721`（`gather_bytes` 计数）；TILING=false
  冻结网表保持行数中性（md5 不变）。
- **修正后的预期**：输入读项降 ~62%；若输入读占帧 70–80%，4.66 s → **~2.5–2.6 s
  （0.38–0.40 fps）**，约 1.8×。B2/B3 后再评估。

## 6. B1-T2 落地（2026-10-20）：`tileBuf` 已在 RTL 里跑通，实测口径见 `y1/reports/b1t2_tilebuf.md`

- 落点：`y1/rtl/UnitExec.scala` **类体末尾**新增「B1」一节（`if (TILING)`；行数中性 ⇒
  `TILING=false` 三份冻结网表逐字节不变）：dense 换趟改 ci 外/co 内 + `tileBuf` 9,248 B
  填充/重放 + 重放趟把 gather 的 DECIDE 改判 EMIT（**零 AR**）+ 观察口 `gather_bytes`。
- 档位：**宽路 tile ∧ dense ∧ s=1 ∧ XDMA_EN=1**。depthwise（对角趟）、`s=2`（窗口 34×66 >
  9,248 B，真表只有 `Conv_0`）、非 tile 宽路、窄路、`wide_x` 外部流**全部原样**。
- 实测（`Conv_15` 形状 32→64、160²、1×1）：输入读 **924,800 B**（= nominal×1.1289，halo），
  旧行为 **7,398,400 B**（×9.03）；数值与冻结黄金**逐字节相同**；负对照（强制每 co-block 重读）
  只让计数翻 8 倍、数值不变 ⇒ 判据可归因。
- 尚未做：`s=2`（`Conv_0`）的缓冲扩展（17,952 B）、band 重取（B3）、halo 去重（B2）、
  `LayerSched`/`NpuTop` 全量重生成 + PnR（B1-T4）。


## 6. B1 上板结果（2026-10-20）
- `video1b1r`（B1 + AGC 2×）PnR All Constraints Met；`y1cam NPU_MS=3147`（3 次一致），
  `y1run RUN=3.1475 s`、**12/12 CRC OK**；对比 B1 前 4.663 s / 4.5096 s ⇒ **1.48× / 1.43×**，
  检测帧率 0.215→0.318 fps。详见 `y1/reports/b1t2_tilebuf.md` §8。
- 首次烧写未启动为瞬时；重烧 PASS。产品网表全量重生成后 B1 才真正进入比特流（此前只重生成了测试网表）。
