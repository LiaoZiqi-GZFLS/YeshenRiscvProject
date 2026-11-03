# Y1-C3 结论报告 —— 描述符驱动的**层调度器**（S1–S6 逐条对上 + 复现指纹 + 缺口清单）

**Status: DONE_WITH_CONCERNS**

**一句话**：C3 把"一张冻结的描述符表 → 一个 FSM 走完一整帧"做通了，**S1–S6 六条判据全部有可跑的命令、
可复现的向量、逐字的绿/红证据**；面积（S5）也过闸（`DRM 7.5 ≥ 7`、集成 `DRM 24.5 ≤ 415`）。
**★ C3.16 补语**：原缺口清单第 3 条"**没有权重装载通路**"**已关闭** —— 权重现在走
**寄存器信箱**（`WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE`，`§8`），顶层 conv 能在**真数值**上逐字节对账
（原来只能算零张量）；"权重从 DDR 搬"（= 描述符里带权重指针 / 转换器搬权重）**仍是 C4/M2**。
**但**它离"能在板上跑完整网络"还差这几样**结构性**的东西，且**都如实记在 §4 的缺口清单里**：
**没有 `depthwise`/`concat` 单元**、**没有 `Add` 的双源表达**；
再加**无时序/无 PnR/无上板**（原"未定位的面积归因异常"已由 C3.14 + C3.16 定位并关闭，见 `c3_area.md` §5/§11）。

---

## 0) C3 交付物一览

| 类别 | 文件 |
|---|---|
| 冻结契约（C4/M2 的单一真源） | `y1/tools/desc_table.py`（位打包 + 六规则 `validate` + `--emit-hex/--emit-meta`）、`y1/reports/c3_descriptor_format.md` |
| RTL（`y1/rtl/`，生成物在 `y1/gen/`） | `DescDefs.scala` / `DescFetch.scala`（S1）、`UnitExec.scala`（S2/S3）、`LayerSched.scala`（S4/S6）、`FusionBuf.scala`、`BypassExec.scala` + `MaxPoolUnit`/`ResizeUnit`/`AddUnit`/`SigmoidUnit`、`HostRegs.scala`（+`DESC_ADDR`/`DESC_COUNT`，★C3.16 再 +`WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE` 权重信箱）、`NpuTop.scala`（集成）、`DdrMaster.scala`（C3.3 扩到 32 B 粒度 + RD/WR 流式） |
| 闸门 | `y1/tools/run_desc_ab.sh`、`run_unitexec_ab.sh`、`run_fuse_ab.sh`、`run_fuse_head_ab.sh`、`run_chain_ab.sh`、`run_sched_ab.sh`、`run_bypass_ab.sh`、`run_fusionbuf_ab.sh`、`run_nputop_sched_ab.sh`（★C3.16 起内含 **W1/W2 权重数值作业**）（+ C2 的 `run_nputop_ab.sh` / `run_hostregs_ab.sh` / `run_ddrcopy_ab.sh` / `run_ddrread_ab.sh` / `run_ddrwrite_ab.sh` / `run_ddrmaster32_ab.sh`） |
| 报告 | `c3_traffic_full.md`（C3.1）、`c3_bypass.md`、`c3_descriptor_format.md`（C3.2+C3.11a+A-2）、`c3_fusion_buffer.md`（C3.0）、`c3_fusion_chains.md`（C3.11b）、**`c3_area.md`（C3.13 / S5 + A-3 / §11 C3.16 板级面积更正）**、**本文件** |
| S5 面积闸门 | `y1/pds/devmap_c3.tcl` + `y1/pds/devmap_c3*.log`（★C3.16 起 + `devmap_c3_after_wgt.log` 等三份"修后"读数） |

**架构（一句话）**：主机写 `DESC_ADDR`(`0x…C008`)/`DESC_COUNT`，一拍 `CTRL.start` ⇒ `LayerSched` 从 DDR 逐项取
**8×32-bit = 32 B** 的描述符（S1），按 `FLAGS[1:0]` 把连续的 `head middle* tail` **塌缩成一次 `go`** 交给
`UnitExec`（S2/S3，`L_MAX=8` 片行锁步、片间零 DDR），旁路算子（MaxPool/Resize/Add/Sigmoid）走
`BypassExec`；非法表在**进表前**响亮 `err` 且零设备搬运（S6）；整帧**只在末单元 `frameDone` 抬一次中断**（S4）。
`NpuTop` 把 `LayerSched` 与 C2 的块拷贝 `DdrMaster` 合并到**一个对外 AXI 主口**（结构性 2:1 复用）;
★C3.16 起**权重**经 `HostRegs` 的**寄存器信箱**逐字节预载（`WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE`），
`UnitExec` 对每个切片做一个 `sel===i` 比较 ⇒ `L_MAX` 片**各自独立**可写（见 §8）。

---

## 1) S1–S6 逐条映射（闸门 / 向量 / **逐字**结果 / 负对照）

> 全部命令的退出码见 §3 的回归扫描。`RESULT: PASS` = exit 0；负对照若"没发火"则闸门自身报 exit 2。

### S1 —— 描述符**解析**（冻结位打包 + RTL 译码逐字段一致）

| 项 | 内容 |
|---|---|
| 闸门 | `bash y1/tools/run_desc_ab.sh`（RTL 侧 `DescFetch` 交叉对账）+ `…/python.exe y1/tools/desc_table.py --selftest`（纯 Python 契约侧） |
| 向量 | **真实 YuNet 表**（`desc_table.py --emit-hex/--emit-meta` 产出）：**68 项 = 2176 B**；RTL 用例 `BASE=4096 (MEMSZ=8192, 表 2176 B)  idx ∈ {0 1 2 67}` |
| 逐字结果 | `TABLE_MD5（单一真源 desc_table.TABLE_MD5_FROZEN）=a45d0da0440a468f1b75788c9ad5bc14`<br>`EMIT_TABLE BYTES=2176 ITEMS=68 MD5=a45d0da0440a468f1b75788c9ad5bc14`<br>`LABEL 正对照 MODE pos IDX 0` / `FIELD_BAD 0（对照 17 个字段）`（idx 0/1/2/67 各一行）<br>`再取表 PASS：第二个 go 被受理、words_valid 先落后起、第二项 8 字 == 它自己的黄金、AR 两笔 32 B、RD_BEATS=8、busy 回 0`<br>`RESULT: PASS`（exit 0） |
| 负对照 | `负对照 A[位] / A2[字序] / A3[小端] / B[对齐] / C[越界] = OK`；`比较器自检 = OK（扰动一个期望字 ⇒ WORD_BAD=1）`；`网表突变 = OK（取字顺序突变 ⇒ 8 个字按预测对调被抓；STRIDE 切片突变 ⇒ 恰好 1 个字段被抓）`；`向量来源 = OK（…表指纹 a45d0da0440a468f1b75788c9ad5bc14 == 冻结值，未漂）` |
| Python 侧五判据 | `SELFTEST_ROUNDTRIP_OK=1`（往返 14 字段 + **第二遍按字节偏移直解**的 8 个字）、`SELFTEST_NEGCTL_BITFLIP_OK=1`、`SELFTEST_NEGCTL_BADTYPE_OK=1`、`SELFTEST_NEGCTL_COUNT_OK=1`、`SELFTEST_NEGCTL_RULES_OK=1`（`_rule_probe` **23 行**含 4 条正对照）⇒ `RESULT: PASS` |
| 红证据 | 删 `validate` 任一条规则 ⇒ 对应行 `MISMATCH` ⇒ `RESULT: FAIL`、exit 1（`c3_descriptor_format.md` §6.6 五组） |

### S2 —— **单单元数值**（`UnitExec` 一次 `go` 跑一个 3×3 卷积）

| 项 | 内容 |
|---|---|
| 闸门 | `bash y1/tools/run_unitexec_ab.sh` |
| 向量 | 几何 `C_IN=8 C_OUT=8 W=64 H=4 GROUP=1 SHIFT=6`；黄金由**独立** `y1/tools/conv_unit_ref.py` 算（不盲信装置自报） |
| 逐字结果 | `正对照 OK：dst 区逐字节 == 黄金（MISMATCH=0）；src 未改；邻居未动。`<br>`RESULT: PASS`（exit 0） |
| 负对照 | `负对照 A = OK（网表 shift 6->5 ⇒ 精确命中 >>5 预测 0 差、!= 黄金差 2009 字节；装置仍 PASS、计数一字不变）`<br>`负对照 B = OK（权重翻 1 字节 ⇒ 精确命中翻转权重预测 0 差、!= 黄金差 247 字节；计数一字不变）`<br>`QUANT_SHIFT 对账 = OK（描述符 +D7=5 != 网表 6 ⇒ RTL err 且零搬运）`<br>先红证据：`PASS  SHIFT 6->5 会让黄金变值（差 2009/2048 个字节）⇒ 负对照 A 有牙` |

### S3 —— **融合单元**（1×1 → 3×3，中间张量**零 DDR**）

| 项 | 内容 |
|---|---|
| 闸门 | `bash y1/tools/run_fuse_ab.sh`（相邻两片）+ `bash y1/tools/run_chain_ab.sh`（L 切片链）+ `bash y1/tools/run_fuse_head_ab.sh`（3×3→1×1 方向） |
| 向量 | `正对照[融合对 = 两个相邻条目 0b00+0b11；chainLen=2]：一个 go 跑两个切片，中间张量零 DDR`；链闸门 `+CHAINLEN=4`（`0b00,0b10,0b10,0b11`） |
| 逐字结果 | `判据 2(a) = OK（字节计数三方一致（正对照）：AR_BURSTS=16 AW_BURSTS=16 B_OK=16 / RD_BYTES_PEAK=2048 WR_BYTES=2048 / MEM rd=2048 wr=2048 bursts=32 maxburst=16；中间张量的 2x2048 两份都不在 DDR）`<br>`SELFTEST: PASS` / `RESULT: PASS`（exit 0） |
| 负对照 | **两面发火**：`负对照 = OK（bit0=1 ⇒ wr 2048->4096、MID_UNCHANGED_BAD=2043 ⇒ 两面发火）`（`run_fuse_ab` / `run_chain_ab` 各一条，链版为 `DEC1_UNCHANGED_BAD=2038`）<br>`CMP_SELFTEST_FUSED_DST_MISMATCH=1（期望恰好 1）` / `CHAIN_FIN_MISMATCH=1`（比较器自检） |

### S4 —— **帧内零中断**（单元序列 FSM 一整帧只抬一次 `frameDone`）

| 项 | 内容 |
|---|---|
| 闸门 | `bash y1/tools/run_sched_ab.sh`（主）+ `run_bypass_ab.sh`（4 档旁路链）+ `run_nputop_sched_ab.sh`（端到端，经 `NpuTop`/`HostRegs`） |
| 向量 | A 作业 **3 项**（`plain 0b01(A0->A1)` + `head 0b00(A1->片上)` + `tail 0b11(片上->A2)`）、B 作业 **4 项**（相邻项故意复用地址）；旁路 4 档链 |
| 逐字结果 | `★ IRQ 纪律 OK[A conv-only]：IRQ_RISES=1 IRQ_INTRA_FRAME=0 IRQ_AT_FRAME_END=1 IRQ_HELD_AFTER_50=1 UNIT_INDEX_FINAL=3`<br>`正对照 OK：ERR_SEEN=0（合法表（3 项、相邻项复用地址）不被字段规则/自环判据误报）`<br>`RESULT: PASS`（exit 0） |
| 负对照 | `负对照 A = OK（网表突变 ⇒ conv 作业 IRQ_INTRA_FRAME=1>0；旁路链 IRQ_INTRA_FRAME=2>0）` + 原始红证据 `RESULT: FAIL FRAMEDONE=1 ERR=0 UNIT_INDEX=3(期望 3) IRQ_RISES=2 IRQ_INTRA=1 IRQ_HELD=1`<br>`负对照 B = OK（descCount 少 1 ⇒ 响亮 err + 零单元搬运：MEM rd=32 wr=0 bursts=1 maxburst=4）`<br>`新负对照 = OK（middle 无前驱 / head 无 tail ⇒ 响亮 err + 零设备搬运）`<br>旁路：`负对照 A/B/C/D = OK`（MaxPool 恒取左上 / Resize 行手取反 / Add clamp 关掉 ⇒ 回绕 / Sigmoid 查表地址取反 ⇒ 254/256 码点变值），`装置自检 = OK` |

### S5 —— **面积闸门**（`DRM ≥ 7` + 缓冲真落 DRM + 全表 + Δ）

| 项 | 内容 |
|---|---|
| 闸门 | `y1/pds/devmap_c3.tcl` + `y1/pds/devmap_c3*.log`（四次 `dev_map`）；完整报告 `y1/reports/c3_area.md` |
| 向量（最坏形状） | `FusionBuf(C=64, WIDTH=160)` ⇒ 3 行 = `3×64×160 = 30,720 B`（= 7 个 DRM36K） |
| 逐字结果（判据 1 & 2） | `Total DRMs = 7.5 of 415 (1.81%)`；`GTP_DRM36K_E1 7 uses` + `GTP_DRM18K_E1 1 use`；`LUTs as dram: 0 of 39500 (0.00%)`；`Adm-4088 = 0` 条；`Total Registers: 2` ⇒ **`DRM 7.5 ≥ 7` + "真的落 DRM"PASS** |
| 逐字结果（判据 3） | 集成（板级 SoC+NPU）：`APM 4 / FF 17187 / LUT 14383.5 / DRAM 231 / DRM 24.5 / IO 99`，exit **0**，**打印了** `Device Utilization Summary`，`DRC-0018 = 0`；Δ vs C2 基线（14370.5/17187/4/24.5）= **+13.0 LUT / +0 FF / +0 APM / +0 DRM**（**但该 Δ 不可信**，见下） |
| 补充读数 | 独立 `LayerSched`（权重口自由 ⇒ 不折叠）：`LUT 33979 / FF 48143 / APM 163 / DRM 4.0`（`L_MAX=4`，C3.13）；★ **A-3 起默认 `L_MAX=8` ⇒ `LUT 58788 / FF 68203 / APM 323 / DRM 8.0`**（占器件 36.8% / 21.3% / 43.7% / 1.9% ⇒ 装得下；`c3_area.md` §10）（`Mapping Summary`，裸探针 IO 超限 ⇒ **无** `Device Utilization Summary`，M0 教训） |
| 负对照 / 异常 | **`PDS 忽略 ram_style`**（M0 教训仍成立）：落 DRM 靠**结构**；`Adm-4088 = 0` 证明没有 DRM→LUTRAM 降级。**异常 → ★ 已定位并关闭（C3.14 + C3.16）**：板级 Δ≈0 的原根因是 ① 地址基址未剥（C3.14 修 `YeshenSocGlue` 的 `pW/pR`）+ ② 权重口钉 0 ⇒ conv 通路被**常量折叠**（C3.16 补**寄存器信箱**后消除）。更正后的板级读数见 `c3_area.md` §5/§11 |

### S6 —— **非法表响亮拒绝**（字段规则 + 零设备搬运）

| 项 | 内容 |
|---|---|
| 闸门 | `bash y1/tools/run_sched_ab.sh` 的 C3.11b 段（RTL）+ `desc_table.py --selftest` 的 `_rule_probe`（Python） |
| 向量 | RTL：**6 张故意非法的表**，每张只违反**一条**规则（`neg_alignsrc neg_oobdst neg_loop neg_inbytes neg_type neg_alignhead`）；Python：22 行变异/正对照表 |
| 逐字结果 | `C3.11b 负作业向量 OK（6 张故意非法的表，每张只违反一条规则）`<br>`C3.11b 字段规则 = OK（6 道负作业：[neg_alignsrc neg_oobdst neg_loop neg_inbytes neg_type neg_alignhead] —— 每道 ERR_SEEN=1 + AW_BURSTS total=0 + MEM rd=64（表探测 2 笔））`<br>`C3.11b 突变控制 = OK（逐条摘掉预检 ⇒ 对应负作业不再绿：align/window/loop/inbytes/type 五条都有原始红证据）`<br>`SELFTEST_NEGCTL_RULES ... cases=22 mismatch=0` ⇒ `SELFTEST_NEGCTL_RULES_OK=1` |
| 负对照 | **六规则逐条"摘掉即红"**（`c3_descriptor_format.md` §6.6 五组：删 `chain too long` / 删无前驱 / 删 `chain geom mismatch` / 换回 C3.11a 旧规则 / 塞回旧"两项一对"规则）；端到端经 `NpuTop` 也验过：`非法表负对照：COUNT 与哨兵不符 / 未知 TYPE ⇒ 都发火（主机经 STATUS 看到 err；零设备搬运）`（`run_nputop_sched_ab.sh` 作业 3/4） |

---

## 2) 复现命令 + 产物指纹

### 2.1 一键回归（全部 exit 0）

```bash
cd /d/code/PDS/VexiiYeshenLinux
for g in run_ddrmaster32_ab run_desc_ab run_fusionbuf_ab run_bypass_ab run_unitexec_ab \
         run_fuse_head_ab run_fuse_ab run_chain_ab run_sched_ab run_nputop_ab \
         run_nputop_sched_ab run_hostregs_ab run_ddrcopy_ab run_ddrread_ab run_ddrwrite_ab; do
  bash y1/tools/$g.sh >/dev/null 2>&1; echo "$g=$?"
done
python scripts/check_addr_map.py                       # PASS: address ledger consistent (16 sites reconciled)
python y1/tools/check_dangling.py y1/gen/NpuTop.v      # RESULT: PASS
python y1/tools/check_dangling.py y1/gen/LayerSched.v  # RESULT: PASS
python y1/tools/check_dangling.py y1/gen/worst/FusionBuf.v   # RESULT: PASS
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v  # RESULT: PASS
bash y1/tools/check_no_xilinx.sh rtl                   # xilinx-residual hits: 0 / RESULT: PASS
```

### 2.2 离线分析（C3.0/C3.1/C3.2/C3.11b）

```bash
cd /d/code/PDS/VexiiYeshenLinux/y1
PY=/d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' $PY tools/desc_table.py --selftest
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' $PY tools/fusion_buffer.py ../third_party/yunet/yunet.onnx
PYTHONIOENCODING=utf-8 PYTHONPATH='../third_party/yunet/deps' $PY tools/fusion_chains.py ../third_party/yunet/yunet.onnx
```

### 2.3 产物指纹（**冻结物**）

| 产物 | 指纹 | 备注 |
|---|---|---|
| 描述符表（`desc_table.TABLE_MD5_FROZEN`） | **`a45d0da0440a468f1b75788c9ad5bc14`**（2176 B，68 项） | **A-3b 重生成**（`CHAIN_L_MAX` 4→8，最长链不再拆）；A-2 的 `ed00cad7…`(2176 B)、C3.11a 的 `4908613b…`(1344 B) 与 C3.2 的 `374121088f…`(2176 B) 均已作废 |
| 描述符位打包 | 8×32-bit 小端 = 32 B/项；`w0..w7` 布局见 `c3_descriptor_format.md` §1 | 线格式自 C3.2 起未变（A-2 改 FLAGS 语义/规则；A-3b 只改表内容与 `CHAIN_L_MAX`） |
| 网表 `y1/gen/NpuTop.v` | **`c9c801b0b488600c804c59a1590443e1`**（★C3.16） | C3.13 为 `ac883dc6738149502ad05740cf05f003` ⇒ **已变**（权重信箱接线；对外端口集不变） |
| 网表 `y1/gen/LayerSched.v` | **`a39d640761826187fb75fe0255c04eb5`**（★C3.16） | C3.13 为 `5228254661a6162a6a25f25c2ce92f46` ⇒ **已变**（4 套装载口 → 1 套信箱，扇出在 `UnitExec`） |
| 网表 `y1/gen/UnitExec.v` | **`87c1991dc0a0789fa062a80354b935c3`**（★C3.16） | C3.13 为 `846fdc4fd3e52470641a2b5985a5bb2c` ⇒ **已变**（同上；另见 `UnitExec_w32.v` = `ba4b46898bdf11ce9227000b28836ef5`） |
| 网表 `y1/gen/DdrMaster.v` | **`e69e3853b4a140a30a17a7bd90436e62`** | C3 基线为 `e1871260a5509c95bea0f0fd8be3bf61` ⇒ **已变**（C3.3 的 32 B 粒度） |
| 网表 `y1/gen/HostRegs.v` | **`040716cd44ca5b47e5c55ff8a040f83d`**（★C3.16） | C3.13 为 `492f84cbd98b17f1b2e2610fe6a638a6` ⇒ **已变**（+`WGT_SEL/WGT_ADDR/WGT_DATA/WGT_WE`；寄存器表 15 → 19 格） |
| 网表 `y1/gen/DescFetch.v` | `4afb960fe55e71c9787b5ae9e2981922` | S1 |
| 网表 `y1/gen/worst/FusionBuf.v` | `436f630243be19c1833746a923b4fa55` | 最坏形状 C=64,W=160（`imgC=0x40 / imgW=0x00a0`） |
| 网表 `y1/gen/FusionBuf.v` | `f2bacef4546e84337ef427e89244117c` | 功能形状 C=2,W=4 |
| **Sigmoid 查表**（LUT） | `y1/gen/sigmoid_lut.hex` = **`1b5866866686a1d2c81c98ac1ded4d4a`**<br>`y1/gen/SigmoidUnit.v_toplevel_lut.bin` = `f1cb125c7398baf4de775b1196038e3e` | 见 §4 的 sidecar 口径 |
| 胶合 `rtl/YeshenSocGlue.v` | **`72bec1f30d2c507669028e2470df492a`** | C3.13 为 `76f70e7ab013a23b47ae464f3fe9beab` ⇒ **已变**（C3.14 修「地址基址未剥」：`pW/pR` → `pW(13,0)/pR(13,0)`）；★ **C3.16 零改动**（权重信箱整个在 NPU 内部，对外端口集不变） |
| 核 `rtl/vexiiriscv/VexiiRiscv.v` | `562aa39adbd55bb0f6b24088e87fdea8` | 本步零改动 |
| 生成器确定性 | 所有 `*Gen.scala` 均 `headerWithDate=false` + `headerWithRepoHash=false` | 连跑两次 `md5sum` 一致 |

---

## 3) 回归扫描（**逐条 exit 码**，C3.13 本步实测）

```
run_ddrmaster32_ab=0
run_desc_ab=0
run_fusionbuf_ab=0
run_bypass_ab=0
run_unitexec_ab=0
run_fuse_head_ab=0
run_fuse_ab=0
run_chain_ab=0
run_sched_ab=0
run_nputop_ab=0
run_nputop_sched_ab=0
run_hostregs_ab=0
run_ddrcopy_ab=0
run_ddrread_ab=0
run_ddrwrite_ab=0

python scripts/check_addr_map.py                          -> PASS (16 sites reconciled)  exit 0
python y1/tools/check_dangling.py y1/gen/NpuTop.v         -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/LayerSched.v     -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/UnitExec.v       -> RESULT: PASS  exit 0
python y1/tools/check_dangling.py y1/gen/worst/FusionBuf.v-> RESULT: PASS  exit 0
python y1/tools/check_dangling.py rtl/YeshenSocGlue.v     -> RESULT: PASS  exit 0
bash y1/tools/check_no_xilinx.sh rtl                      -> xilinx-residual hits: 0 / RESULT: PASS  exit 0

dev_map（y1/pds/devmap_c3.tcl）
  integrated (SoC+NpuTop)   exit 0   —— 打印 Device Utilization Summary；DRC-0018 = 0
  nputop                    exit 0   —— 打印 Device Utilization Summary；DRC-0018 = 0
  layersched                exit 1   —— DeviceMap-2003/DRC-0018 **仅因裸探针 IO 超限**；资源取 Mapping Summary
  fusionbuf (worst)         exit 1   —— 同上（IO 1078 > 400）；资源取 Mapping Summary
```

**15 道功能闸门 + 3 类结构检查全绿** ⇒ C3 的改动**没有回归** C2 的字节级判据。

### 3.1 ★ C3.16（权重信箱）后的**重跑**（全 0 / PASS）

权重信箱动了 `HostRegs` 的寄存器表（15 → 19 格，表尾 `0x38 → 0x48`）⇒ 台账与**每道闸门的判据前提**
都得重跑确认。**实测**（全部 exit **0**）：

```
run_hostregs_ab=0   run_nputop_ab=0      run_nputop_sched_ab=0   run_sched_ab=0
run_chain_ab=0      run_fuse_ab=0        run_fuse_head_ab=0      run_unitexec_ab=0
run_desc_ab=0       run_bypass_ab=0      run_fusionbuf_ab=0      run_ddrmaster32_ab=0
run_ddrread_ab=0    run_ddrwrite_ab=0    run_ddrcopy_ab=0

python scripts/check_addr_map.py                     -> PASS: address ledger consistent (16 sites reconciled)  exit 0
python y1/tools/check_dangling.py y1/gen/NpuTop.v    -> RESULT: PASS / total dangling instances: 0  exit 0
bash y1/tools/check_no_xilinx.sh rtl                 -> xilinx-residual hits: 0 / RESULT: PASS  exit 0
```

**唯一一处"闸门前提"的显式改动**（**不是放宽判据**，是常数移动）：
`run_hostregs_ab.sh` 里"未映射地址探针"从 **`0x3C`** 挪到 **`0x4C`** —— 因为 `0x3C/0x40/0x44` 现在
**已映射**成 `WGT_SEL/WGT_ADDR/WGT_DATA`（表尾是 `WGT_WE(0x48)`）。该脚本**自带**三条新自检把这件事
钉住（见文件头 + `cmp.py` 的 `wo` 档 + `assert (pattern(0x48) & 1) == 0`），并新增四道 grep 判据
（`WGT_OK` / `WGT_WE_PULSES 1` / `WGT_WE_NOW 0` / `WGT_RB_WE 00000000`）。台账 `check_addr_map.py`
**无需改动**（四个新档仍落在既有 16 KiB NPU 窗内）。

```text
WGT_EXPORT_SEL 00000005    WGT_EXPORT_ADDR 00000123    WGT_EXPORT_DATA 9c
WGT_WE_PULSES 1            WGT_WE_NOW 0                WGT_RB_WE 00000000
WGT_OK                     RESULT: PASS
```

---

## 4) **缺口 / 已知问题**（如实列，按影响排序）

1. **无时序、无 PnR、无上板**：本步只跑了 `dev_map`（综合 + 器件映射）。
   S5 的"装得下"只是**资源算术**；`soc_clk`/`cpu_clk` 100 MHz 能否收敛、DDR 通路是否满足
   建立/保持，**全部未测**（C2.4 的"两时钟 + 行为级桥模型"仍挂着）。
2. **`depthwise`(`0x03`) 与 `concat`(`0x12`) 单元缺席** ⇒ **冻结的 67 项表跑不了端到端**：
   `desc_table.py` 的 `VALID_TYPES` **认** `0x03`（表里有 **20** 个 depthwise 项）与 `0x12`，
   而 `LayerSched` 的**分派只有 conv3x3/conv1x1/旁路四类**，遇到它们**响亮 `err`**（比
   `VALID_TYPES` **更严**，这是有意的：宁可报错也不静默算错）。
   ⇒ 真实 YuNet 表要跑通，**必须等 C4/M2 补 depthwise 单元**（20 项，占 payload 的 30%）。
3. ~~**没有权重装载通路**~~ → **★ C3.16 已关闭（"寄存器信箱"这条路）**：`HostRegs` 新增
   `WGT_SEL(0x3C)/WGT_ADDR(0x40)/WGT_DATA(0x44)/WGT_WE(0x48，自清单拍)`，`NpuTop` 把它直连
   `LayerSched` 的信箱口，`UnitExec` 对 `L_MAX` 个切片各做一个 `sel===i` 比较 ⇒ **每片各自的
   `WeightStore` 独立可写**（旧的 4 套装载口在 `L_MAX>4` 时会把切片 4..7 折叠到第 4 套 —— 已消除）。
   ⇒ 顶层 conv 现在能在**真数值**上逐字节对账（`run_nputop_sched_ab.sh` 的 **W1/W2** 作业，见 §8），
   板级 `dev_map` 也**不再**把卷积通路常量折叠（`c3_area.md` §11）。
   **仍然残留（C4/M2）**：**权重从 DDR 搬进片上**这条路 —— 描述符格式里**没有**权重指针
   （`DescDefs`/`desc_table` 冻结口径），所以现在只能由**主机**逐字节写寄存器；真实网络需要
   "转换器 + DMA 把权重搬进去"（或给描述符补权重指针字段）。**这才是 C4/M2 的那一条**。
4. **O1：描述符只有一个 `SRC_ADDR`，`Add` 需要两个操作数**。当前靠"设备侧交错约定"
   （`IN_FROM_PREV` 取片上 + `SRC_ADDR` 取 DDR）；本网两个 `Add` 的两路**都来自 DDR**，
   格式表达不了第二路 ⇒ **C4/M2 的 spec 项**（`c3_descriptor_format.md` §7 O1）。
5. **O2：`IN_BYTES` 是上界**（`align32(max(Σread, write))`），对 maxpool/resize/add 以及
   变通道 1×1 都不是精确 DMA 长度；RTL 必须**自行按 `IMG_W/IMG_H/C_IN/C_OUT` 算真实长度**，
   `IN_BYTES` 只用于规则 (3) 与 32 B 粒度检查（§7 O2）。
6. **Sigmoid 的 Q3.4→Q0.7 定点刻度是"计划冻结"的选择，不是 YuNet 的真实刻度**：
   真值由 **C4/M2 的量化器**决定（`c3_descriptor_format.md` §0.6 / C3.7 报告同款声明）。
   同理 `QUANT_SHIFT` 的 6/4/0 是**占位**口径（O4），且**在 run 内必须一致**（规则 (5)）。
7. **`\`$readmemb\`` 式的 LUT sidecar 要求（**只对独立网表**）**：`gen/SigmoidUnit.v`
   （以及任何单独生成的含 `Mem` 初值的网表）会外链一份 `.bin`（如
   `SigmoidUnit.v_toplevel_lut.bin`，md5 `f1cb125c…`），iverilog/别的工具在**任意 cwd** 下
   要能找到它。**集成的 `LayerSched`/`NpuTop` 没有这个问题**：它们的生成器用
   `inlineRom = true` 把初值**内联成 `initial` 块**（`grep -c readmemb gen/NpuTop.v = 0`），
   ⇒ **集成流程自包含、不受影响**；只有"单独喂 `gen/SigmoidUnit.v` 给 iverilog"这一类用法
   需要 sidecar。
8. **`>2` 切片链 vs `L_MAX` 的取舍（面积/实例问题，不是编码问题）** —— ★ **A-3 已定案：默认改成 `L_MAX = 8`**：
   - **编码层能表达全部 33 条融合边**（任意长链 `0b00 (0b10)* 0b11`）⇒ `12,576,000 B/帧` 可达；
   - ~~**本代 `L_MAX = 4`** ⇒ 长 6 / 长 8 的两条极大链**必须在表里拆开**~~（旧默认，拆点
     `Conv_10→Conv_12` = 819,200 B、`Conv_34→Conv_36` = 25,600 B ⇒ 覆盖 **31/33**、
     conv-only `14,265,600 B/帧`、含旁路 `21,211,200 B/帧 ⇒ ≈13.01 fps`）；
   - ★ **A-3 实测（`c3_area.md` §10）**：`L_MAX=8` 单独综合 = `LUT 58,788 / FF 68,203 / APM 323 /
     DRM 8.0`（占器件 **36.8% / 21.3% / 43.7% / 1.9%**）⇒ **装得下（余量宽裕）** ⇒ **提交默认值 8**
     ⇒ 覆盖 **33/33**、conv-only **`12,576,000 B/帧`**、含旁路 **`19,521,600 B/帧 ⇒ ≈14.13 fps`**
     （**下界**），**两个拆点消失、省 `1,689,600 B/帧（−8.0%）`**；
   - ★ 这里的"fps"全部是**由下界流量导出的上界**（见 §5）。
9. **两趟"先校验后执行"是开口项**：本代 `LayerSched` 是**边扫链边执行**，
   S6 能给"**字面上的零搬运**"的只有**第一个非法项**（`err` 在扫链途中发现 ⇒ 已取过的
   描述符字节是既成事实；**设备级**一个激活字节都不搬、一个 AW/W 都不发）。
   若要"全表校验通过后才动第一个字节"，需**两趟**（先扫全表再执行）—— C4/M2 决定。
10. **C5（CPU 争用份额）与真实 fps 未测**：NPU 与 RV32 共用一个 memory-master merger，
    真实帧率取决于 DDR 争用与 12 个头张量的后处理（decode/NMS，本步完全没算）。
11. ~~**S5 的一处未定位异常**（`c3_area.md` §5）：板级 `synthesize -ads` 比"`NpuTop`/`LayerSched`
    单独综合"**多消掉** ~7.5k LUT 的 NPU 逻辑（Δ vs C2 只有 +13 LUT）。**在修好权重装载口
    之前，"板级面积"不可用作数据通路面积依据。**~~ → **★ 已定位并关闭（C3.14 + C3.16）**：
    ① C3.14 定位的是**地址基址未剥**的真集成 bug（`YeshenSocGlue` 的 `pW/pR` 改成窗内相对偏移）；
    ② C3.16 补上**权重通路**后，板级 `dev_map` 的卷积通路**不再**被常量折叠
    （`unitExec_1/conv/arr/arr/acc*` 的 `stuck at constant 0`：**26 → 0**），
    板级 Δ vs SoC-only 从 **+8,604.5 LUT** 跳到 **+58,155.5 LUT**（`c3_area.md` §11）。
    ⇒ **板级面积现在与独立探针同量级**，不再是"被剪过的数"。
12. **`C=64` 那一档 FusionBuf 只证了"结构落 DRM"，没证功能**：`FusionBufTb` 的端口名
    `rd_data_0/1` 不可参数化 ⇒ **C 只能 2**；功能闸门只覆盖 `C=2/W=4` 与 `C=2/W=5`
    （`rtl_test/FusionBufTb.v` 头部已写明这一残留风险）。
13. **`LayerSched` 的 `L_MAX`/几何**：★ **A-3 起 `L_MAX` 已改成构造参数**（`rtl/LayerSched.scala:175`
    `class LayerSched(..., val L_MAX: Int = 8)`），默认值 = **8**（见 `c3_area.md` §10 的实测）。
    ⇒ 想扫 `L_MAX ∈ {2,4,6,8}` 的面积**现在只需换一个生成期参数**（`LayerSchedGen` 里显式给值）。
14. **表里的地址值是"一次性 bump 布局"**（O6），只为判据确定性；真实转换器要做内存复用
    （只要满足六规则即可）。**位打包是冻结物，地址值不是。**

---

## 5) DDR 流量（C3.1 / A-2 重算；**下界**；fps 是**由下界导出的上界**）

**口径**：只计**激活 IO**（`ddr_traffic.py` 文件头口径）。**不含**：12 个头张量的后处理
（decode/NMS）、突发对齐/填充浪费、**权重装载**、CPU 争用。
⇒ **字节数是下界 ⇒ fps 是上界**（真实只会更低）。

| 口径 | conv-only | +旁路（`6,945,600`） | fps 上界 @275.9 MB/s |
|---|---|---|---|
| `baseline`（不融合，C0.1 复现） | `31,942,400` | — | — |
| ★ **`L_MAX = 8`（提交默认，A-3 起）**（逐边全融合，33/33，= `fuse_both` 下界） | **`12,576,000`** | **`19,521,600`** | **≈ 14.13** |
| （旧默认）`L_MAX = 4`（31/33，拆点 2 处 +`1,689,600`） | `14,265,600` | `21,211,200` | ≈ 13.01 |
| （历史对照）`L_MAX = 2`（C3.11a 的塌缩编码曾等价于这一行） | `17,798,400` | `24,744,000` | ≈ 11.15 |

**拆点代价** = `2 × (819,200 + 25,600) = 1,689,600 B/帧`（`+13.4%`），**全部是 `L_MAX=4` 的代价，
不是编码代价**；★ **A-3 把默认改成 `L_MAX = 8`（实测装得下，`c3_area.md` §10）⇒ 这笔代价归零**。
旁路那 `6,945,600 B`（maxpool `4,736,000` / resize `640,000` / add `1,536,000` /
sigmoid `33,600`）是**单独的、可加的**，任何 `L` 都消不掉。
（`ddr_traffic_budget.md` 的 15 fps 档 = `458 MB/s` 需求对应的口径另算；本表的 275.9 MB/s
是 C0 系列冻结的 DDR 下限，**不是实测可达带宽** —— 可达带宽的板端实测属 A2，见缺口 1。）

---

## 6) 关于产物入库（**如实说明**）

- `y1/.gitignore` 有 `*.log`，`.gitignore` 有 `sim/reglogs/` 与 `y1/pds/pds_*.000/`：
  所以**日志与工程目录默认不入库**（本步的 `y1/pds/devmap_c3*.log` 与
  `y1/pds/pds_c3_*` 都命中忽略规则）。C3.13 的提交**按任务书**把 `y1/pds/devmap_c3*.log`
  **显式 `-f` 入库**（否则证据链只剩报告里的引用）；这与既有报告里"已提交的 `devmap_slice.log`"
  这类说法**此前并不成立**（`git ls-files` 里其实没有 `*.log`）—— 此处一并记下。
- 所有判据的**机器可读真源**都在**代码/报告**里（`desc_table.py` 的 `TABLE_MD5_FROZEN`、
  各闸门的 `RESULT: PASS`/exit 码、本文件的 §2.3 指纹表），**不依赖日志是否入库**。

---

## 7) C3 的结论

**C3 = 完成（带缺口）**：冻结描述符格式（S1）→ 单单元数值（S2）→ 片上融合链（S3）→
帧内零中断调度（S4）→ 面积闸门（S5）→ 非法表拒绝（S6）**六条判据逐条成立且可复现**，
且**没有回归** C2（15 道闸门全绿，C3.16 后重跑仍全 0，见 §3.1）。
**离"板上跑完整 YuNet"还差的主要是"单元补齐"而不是"框架"**：`depthwise` 单元（20 项）、
`concat`、`Add` 的第二源 —— 三条都是 **C4/M2** 的范围；**权重装载通路在 C3.16 已用「寄存器信箱」
补上**（§8：`HostRegs` 4 档 + `UnitExec` 的 `sel===i` 扇出 ⇒ `L_MAX` 片各自独立可写，顶层 conv 有
**真数值**证据），**残留的只有「权重从 DDR 搬」**（描述符里没有权重指针 ⇒ 需转换器 + DMA，C4/M2）。
⇒ **C3.13 的"本步不改任何 RTL"这句话在 C3.16 不再成立**：C3.16 动了 `HostRegs.scala` /
`LayerSched.scala` / `UnitExec.scala` / `NpuTop.scala`（**对外端口集不变**，`scripts/check_addr_map.py`
期望不变）；把这些**如实锁在缺口清单**里，不做"静默降级"来假装能跑。

---

## 8) ★ C3.16 —— **寄存器信箱**权重装载（把"没有权重通路"这条缺口关掉）

**要解决的问题**：C3.12 起 `NpuTop` 把 `LayerSched` 的**四套权重装载口全钉 0**（旧口径"对外端口集
不含权重口"）⇒ 顶层 conv 只能跑**零张量**，板级 `dev_map` 还会把整条卷积数据通路**常量折叠**。
C3.16 在**同一条 AxiLite 寄存器窗内**补一条**主机可写**的权重通路，**对外端口集一字不改**。

### 8.1 信箱契约（寄存器映射；`rtl/HostRegs.scala` → `rtl/NpuTop.scala` → `rtl/LayerSched.scala` → `rtl/UnitExec.scala`）

| 偏移 | 名字 | 类型 | 语义 |
|---|---|---|---|
| `0x3C` | `WGT_SEL` | RW（整 32 位存储） | 目标**切片下标**（`0..L_MAX-1`；本代 `L_MAX=8` ⇒ `0..7`）。位宽裁剪在 `NpuTop`（`log2Up(L_MAX)`） |
| `0x40` | `WGT_ADDR` | RW（整 32 位存储） | 该切片 `WeightStore` 内的**条目下标**（`0..NENTRY-1`；dense 时 576） |
| `0x44` | `WGT_DATA` | RW（整 32 位存储） | **载荷 = 低 8 位**（int8 权重；上 24 位照存不参与） |
| `0x48` | `WGT_WE` | **WO，自清单拍** | 写 `1` 起效、**下一拍自动落 0**（同 `CTRL.start`）；回读恒 `0` |

**装载序列**（**必须在 `CTRL.start` 之前**做完 —— 权重带外预载）：`WGT_SEL:=s` → 循环
{`WGT_ADDR:=k`；`WGT_DATA:=byte`；`WGT_WE:=1`}。**一次一个 int8**（`WeightStore` 的装载口就是 `SInt(8)`
的冻结口径 ⇒ 本档只做最薄的一层"主机可写"包装，不另造打包格式）。

**扇出（本档的承重点）**：`LayerSched` 引出**一套**信箱口，`UnitExec` 把 `wgt_addr/wgt_data` **广播**
到全部 `L_MAX` 个切片，每片各做一个比较

```scala
slices(i).io.we := io.wgt_we && (io.wgt_sel === U(i, selBits bits))
```

⇒ 任一时刻**最多一个**切片的 `WeightStore` 被写、**`L_MAX` 个 WeightStore 各自独立可写**
（**删除了**旧"A-3 四套口在 `L_MAX>4` 时把切片 4..7 alias 到第 4 套"那条限制 —— 它曾让 `L=8` 链
的"每片一份独立权重"无法由硬件表达）。端口从 12 根降到 4 根，只多 `L_MAX` 个比较器。

### 8.2 判决装置 A —— 寄存器语义（`run_hostregs_ab.sh`，exit 0）

19 格穷举写-回读（三个新 RW 档参与 `MISMATCH=0` 的逐字回读）；`WGT_WE` 的**只写 + 自清单拍**语义由
装置 4d) 段**显式**判：写 1 后导出端口**恰好高 1 拍**（`WGT_WE_PULSES 1`）、随后自清（`WGT_WE_NOW 0`）、
回读恒 0（`WGT_RB_WE 00000000`）。未映射探针挪到 `0x4C`（表尾下一个字）仍读 0 / 写被忽略。

### 8.3 判决装置 B —— **顶层数值**（`run_nputop_sched_ab.sh` 的 W1/W2，exit 0）

主机经 AxiLite 写信箱 → `NpuTop` → `LayerSched` → `UnitExec` 扇出 → 切片 `WeightStore` → conv → DDR，
转储镜像与 Python 黄金（`conv_unit_ref` / `mac_ref` 两条独立实现）**逐字节**对账：

| 作业 | 内容 | 判据（逐字） |
|---|---|---|
| 作业 1（旧正对照，**免费负对照**） | 3 条目表（conv3x3 + conv1x1 + maxpool），**一个字节权重都不写** | `MISMATCH=0`；`DST0/DST1 = 零张量`（信箱复位值 0）；说明"权重通路存在但主机没写"与"通路不存在/被折叠"是两档 |
| **W1 正** | 2 条目表（conv3x3 plain + maxpool），切片 0 装 **576 B** 真权重 | `MISMATCH=0`；`WGT_LOADED slices=1 entries=576 bytes=576`；`MEM rd=4192 wr=2560` |
| **W1 负 C**（**权重错 1 字节**） | 同一表/输入，只扰动切片 0 的一个权重字节（下标 192） | 与正确黄金 `MISMATCH=229`（**>0，判据有牙**）；与被扰动权重的黄金 `MISMATCH=0`（**输出跟着装载的权重走**） |
| **W2 正** | **8 片链**（head+6 middle+tail，一次 `go`，`chainLen=8`）；切片 0..3 = 恒等权重（`(64*x)>>6=x` 精确）、切片 4..7 = 四份互不相同的非平凡权重 | `MISMATCH=0`；`WGT_LOADED slices=8 entries=576 bytes=4608`；`MEM rd=2336 wr=2048`（中间张量**零 DDR**） |
| **W2 负 D**（**别名折叠**） | "切片 4..7 共用一份权重"的四种折叠假设 + "全零权重"一档，各算一份黄金 | 实测输出与**每一个**假设都不同：`ID=2042 / W4=1838 / W5=1922 / W6=1995 / W7=1984`（**全 >0**）⇒ **8 个 `WeightStore` 各自独立可写**由**数值**钉死 |

> **口径已对齐（原"口径差"记录，A-3b 收口）**：RTL 的 A-3 把 `L_MAX` 提到 **8** 之后，
> 冻结 Python 模型的 `desc_table.CHAIN_L_MAX` 也跟到 **8**（**A-3b**）⇒ W2 的 8 片链**不再**被判
> `chain too long`：本闸门现在**显式调** `desc_table.validate` 并**断言它接受**（`PYLIST_VALIDATE ok
> （冻结模型 CHAIN_L_MAX=8 接受 8 片链，与 RTL 的 L_MAX=8 同口径）`）⇒ 原来的
> `PYLIST_VALIDATE reject(chain too long @4)` 已消失、模型/RTL 链长上限**同口径**。逐项位打包仍走
> **冻结真源**（`DT.reference_words` / `DT.pack_table`）并与之逐字对账。

### 8.4 板级后果

权重可装载 ⇒ conv 数据通路在网表里**留得住**。板级 `dev_map` 实测：`unitExec_1/conv/arr/arr/acc*`
的 `stuck at constant 0` **26 → 0**，板级 Δ vs SoC-only 从 **+8,604.5 LUT** 跳到 **+58,155.5 LUT**
（`c3_area.md` §11）。⇒ **"板级面积不能当数据通路面积用"这条从 C3.13 起挂着的顾虑，到此关闭。**

---
