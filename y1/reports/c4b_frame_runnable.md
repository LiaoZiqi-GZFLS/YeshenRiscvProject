# Y1 T-S3 —— **让真帧跑得完**（旁路算子 tiling + 宽路 gather per-plane band）收口

- 日期：2026-10-15
- spec：`docs/superpowers/specs/2026-10-14-y1-frame-runnable-design.md`（§3.1 旁路 / §3.1.1 列切 / §3.1.2 通道维 / §3.2 per-plane band / §4 判据）
- plan：`docs/superpowers/plans/2026-10-14-y1-frame-runnable.md`（T-S3a.1–4、T-S3b.1–2）
- 上游：T-S2/T-S2R/T-S2b（**conv 侧** tile 已逐字节证死）、T-S2b-i（宽路首像素 + `s=2` 挂起）

**Status: DONE（§5 的"能证"全部拿到；"不能证"明列 —— 未上板 ⇒ fps/G7 留给 S3）**

> ★★ **后续（T-S3c.1，2026-10-15）**：本报告 §5"不能证"第 2 条（整表几何预检）**已做**，
> 结果是**"整帧跑不完"**：`UNIT` 口径有 **1 个单元 err**（`Resize_43` 撞 `BypassExec.tileAliOk`），
> 忠实派发口径有 **54 条无通路**（宽层融合链 vs RTL 宽路的 `chain_len==1` 前提）。
> ⇒ 本报告 §6 的"下一步 = T-S3c ⇒ 零 err ⇒ 然后 S3"**被推翻**；详见
> `y1/reports/c4b_frame_preflight.md`（含修法建议）与 spec §9。**S3 现在不能开工。**

---

## 0. 一句话

真表 67 个单元此前有三处几何盲区会**响亮 err**（宁可红、不静默错值）；本片把三处**全部**补成"走 tile / 走分块 / 走布局折"的**逐字节正确**通路，并给出**面积/回归**账：

| # | 盲区 | 真表证据 | 处置 | 判据 |
|:--|:--|:--|:--|:--|
| 1 | 旁路算子的**通道维**（`geomOk` 要 `cIn==cOut==C==8`） | `MaxPool_5`=16、`MaxPool_18/25/32`+`Resize_43/49`=64、`Sigmoid_*`=1 | **通道分块** `cIn/8` + `C_in=1` 逐点**布局折** | `run_bypass_cblk_ab.sh` |
| 2 | 旁路算子的**空间维**（`outPix≤MAXPIX=1088`、`rowW≤WIDTH=34`） | `MaxPool_5` 160×160（`outPix=25600`、输入行宽 320） | **无 halo 的 2-D tile 循环**（复用 `outMem`） | `run_bypass_tile_ab.sh` |
| 3 | 宽 conv 的 `HW%32≠0` | 20×20 的 11 层（`400%32=16`） | **gather 的 per-plane band** | `run_tiling2d_wide_ab.sh` |

另有 2a 实测发现、本片一并修的**第四处**：`Add_44/Add_50`（`C=64`、`src2k=1`）——多块要求 planar，而 `planarOk` 原禁 Add 布局模式 ⇒ 给**第二源**做了同一套行跨步 planar gather（+2 趟 tile）。

---

## 1. 交付物

| 文件 | 动作 | 说明 |
|:--|:--|:--|
| `y1/rtl/BypassExec.scala` | 改 | 契约（文件头）+ 通道分块 + 2-D tile 循环 + `C_in=1` 布局折 + `Add` 第二源 planar（**复用 `outMem`，零新增宽存储**） |
| `y1/rtl/UnitExec.scala` | 改 | 宽路 gather 的 **per-plane band**（每平面各记 `(bandBase, idxW, idxB)`）；去掉 `tHW32%32==0` 前提 |
| `y1/rtl_test/BypassTb.v` | 改 | `+TILED_B` 模式；补 `+SRC2`/`+SRC2K`（E1）接线 |
| `y1/rtl_test/BypassExecGen.scala` | 改 | 出 `gen/BypassExec_w34.v`（`WIDTH=34/IMG_H_MAX=32`，与板级同参） |
| `y1/tools/run_bypass_tile_ab.sh` | 新 | 真表旁路形状（含 160×160/80×80/20×20、`Add` 两源）+ 3 条负对照 |
| `y1/tools/run_bypass_cblk_ab.sh` | 新 | 通道分块（C=8/16/64）+ `C_in=1` 折三档 + 2 条负对照 |
| `y1/tools/run_tiling2d_wide_ab.sh` | 改 | 加 `c64_20x20`/`dw10_20x20` 正对照 + per-plane 负对照（**两侧**） |

**未改**（`git status` 可核）：冻结工具（`tiling_ref.py`/`multipass_ref.py`/`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`/`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`）、`third_party/**`、**描述符格式（8 字）**、数值口径（PTQ/requant/`z_pad`）。

---

## 2. 判据证据（19 个闸门 + 3 检查器，全绿）

**旁路（T-S3a）**
| 闸门 | 结果 |
|:--|:--|
| `run_bypass_ab.sh`（旧整层路径回归） | PASS（未改其判据/文件） |
| `run_bypass_cblk_ab.sh` | **8 作业逐字节**（C=8/16/64 + `Sigmoid` 6400/1600/400）× 2 负对照（漏块 / 折分母加倍）+ 两条外科式对照 |
| `run_bypass_tile_ab.sh` | **8 作业逐字节**（`maxpool` C=16 160×160、C=64 80×80/40×40/20×20；`resize` 80×80；`Add` C=64 40×40/80×80）× **3 负对照**（漏 tile 行 / 窗口错一格 / 漏块偏移）+ 外科式对照 |

**宽 conv（T-S3b）**
| 闸门 | 结果 |
|:--|:--|
| `run_tiling2d_wide_ab.sh` | **9 作业逐字节**（含新增 `c64_20x20`、`dw10_20x20`）× 3 负对照；per-plane 负对照**两侧**：20×20 红（`MISMATCH=20582`）、40×40 绿（`HW%32==0` 不提） |
| `run_tiling2d_rtl_ab.sh` | PASS（窄路共用同一 `UnitExec_tiled.v`） |

**回归（17 个非慢闸门）**：`run_unitexec_ab` / `unitexec_wide` / `nonwide_wide` / `dw_wide` / `wide_tail` / `wgtdma`×3 / `dw` / `sched` / `nputop_sched` / `roww` / `bypass` / `bypass_cblk` / `bypass_tile` / `addsrc2` / `layoutadapt` —— **17/17 PASS**。

**结构检查器**：`check_dangling.py`（0 dangling）/ `check_dup_modules.py`（0 dup）/ `check_no_xilinx.sh`（0 残留）—— 全 PASS。

**不变量**：三份 `TILING=false` 网表**逐字节未变**（全量重生成后复核）：
`UnitExec.v 979129017535dc82ab9e6d89bea31080`、`UnitExec_w32.v 618af3381eadcb4d7c6964cd4338a825`、`UnitExec_w640.v ddb9bb8addc01f94e2ea8ae8b6b898e6`。

---

## 3. 面积账（板级集成 `dev_map`，`y1/pds/devmap_c4a.log`）

| 量 | T-S3 前（S2b-i 后） | **T-S3 后** | Δ |
|:--|--:|--:|--:|
| `Adm-4088` | 0 | **0** | 0 |
| LUT | 122,770（76.83%） | **127,338（79.69%）** | **+4,568（+2.86 pp）** |
| `LUTs as dram` | 6,784（17.17%） | **7,872（19.93%）** | +1,088 |
| **DRM** | 375.5 / 415（90.48%） | **375.5 / 415（90.48%）** | **±0** |
| APM | 556（75.14%） | **558（75.41%）** | +2 |

★ **DRM 一位没动** ⇒ spec §5-R1 的"**零新增宽存储**"（旁路 tile 复用 `outMem`、per-plane band 只用寄存器）**实测成立**。余量：LUT 20%、DRM 9.5%（~39 块）。

**网表指纹**（`gen/` 在 `.gitignore` 里，不进库）：`BypassExec.v 50eedf28…`、`BypassExec_w34.v 36069896…`、`UnitExec_tiled.v 3e1fb1fb…`、`LayerSched.v f6692d69…`、`NpuTop.v b3a47372…`；同源连跑两次 md5 相同（确定性）。

---

## 4. 实现中抓死的真坑（留档，避免复发）

1. **`MaxPool` 的 tile 输入行宽会超 `WIDTH`**：pool 输出 tile 宽必须再切 `WIDTH/2`（spec §3.1.1）。
2. **段内字节序判定必须无符号**：`tBoff.asSInt.resize(9)` 把 16..31 当负数 ⇒ `off≥16` 的输出行**整段被掩掉**（一个字节都没写）。
3. **burst 长度必须用组合切片算**：与 `tBoff` 同拍赋值的寄存器会读到**上一笔**的偏移 ⇒ 长度整笔错位、`wstrb` 写进邻居。
4. **`DdrMaster` 要 `len%32==0`** ⇒ `C_in=1` 的折档有效像素数**向上取 4 的倍数**，多出的 pad 像素用 **`wstrb=0`** 落（真表 `Sigmoid_400` 的 `IN_BYTES=416=align32(400)` 与此一致）。
5. **TB 潜伏洞**：`+SRC2` 一直被解析但**从未驱动** `io.src2`（E1 的第二源此前没被真跑过）。

---

## 5. 我**能**证 / 我**不能**证

**能证**
1. 真表**旁路**的每一种形状（`maxpool` 16/64ch、`resize`、`add` 两源、`sigmoid` `C=1` `W∈{400,1600,6400}`）在 `WIDTH=34/H_TILE=32` 的网表上**逐字节**正确，且每条判据都有**能发火的负对照 + 外科式对照**。
2. 真表**宽 conv 20×20**（`HW%32≠0`）逐字节正确；`40×40` 等 `HW%32==0` 的层不受影响（负对照两侧）。
3. **19 闸门 + 3 检查器全绿**；`TILING=false` 三网表**逐字节不变**。
4. 板级 `dev_map`：`Adm-4088=0`；**DRM 零增长**（"零新增宽存储"实测成立）。

**不能证（开口项）**
1. **没有上板、没有整帧** ⇒ 12 路输出与 G7 容差 = n/a（**S3**）。
2. **T-S3c（整表几何预检）未做**：上面是按"每个盲区各立一条真表形状的正对照"证的，**还不是**"67 个单元逐条走 RTL 对账 ⇒ 零 err"的**整表**证书。spec §4-C 要求它（Python 快门 + 模拟真 `desc` 终证）。
3. **流量未更新**：旁路 tile 与 `Add` 两趟都会放大读（实测 `Add` 2 趟读 450,560 B / 102,400 B 的 A 张量），逐帧流量模型（`bypass_traffic.py` 冻结）**未重算**。
4. **fps**：S2b-ii（宽路 tile 的 23× 重取）仍未做 ⇒ fps 预算未闭合（**不挡 G7**）。

---

## 6. 下一步

- **T-S3c**：整表几何预检（判据 C）—— 对真表 67 条逐条走 `inWOk`/`wideGeomOk`/`tilingWideC`/`tilingOkC`/`BypassExec.geomOk` ⇒ **零 err**；Python 快门 + **模拟真 `desc` 序列**终证。
- **S3**：PnR（`YESHENMINI_SYNTH_MODE=speed`）→ 比特流 → 板 → 12 路 + G7（IoU ≥ 0.5 / 关键点平均 L2 ≤ 2 px / |Δconf| ≤ 0.1 / 检出数差 ≤ 1）。**上板时机由用户给**（板占用纪律）。
- **S2b-ii**（可选，fps）：宽路 tile 的窗口片上跨趟留住。
