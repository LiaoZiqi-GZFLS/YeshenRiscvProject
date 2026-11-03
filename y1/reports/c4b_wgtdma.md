# Y1-C4b 报告 —— 任务 B1 / B1b：**权重 blob 从 DDR 批量装载**（G6 的装载半，DMA 主路径）
> 下方 §1–§8 = **B1（窄层）** 的原报告（`29f95a7`，逐字保留）；**§9 = B1b（宽层，本任务）**。

> **本任务（B1）只做一件事**：让 NPU **用自己的 `DdrMaster`** 在**每个单元开跑之前**把该单元的权重段
> 从 DDR 读进该切片的 `WeightStore`（不再由 host 逐字节推信箱）。判据 `y1/tools/run_wgtdma_ab.sh`
> （逐单元逐字节 + 装载字节数 + 定位负对照）。
>
> **明确不做（控制器做）**：跑 `dev_map` / PnR、填面积/时序占位（**RTL 改过 ⇒ 必须重跑 PnR**，见 §6）。
> **明确不做（B2 做）**：`M`/`z_pad`/`bias_adj` 的随 blob 投递、装载与计算的**重叠纪律**。

**Status: DONE**（`run_wgtdma_ab.sh` 全绿 + 负对照发火；全回归见 §5；PnR 待控制器重跑）。日期 2026-10-11。

---

## 1) 装载路径设计（触发 / 地址推导 / `WGT_BLOB_BASE` 落点）

| 项 | 落点 | 说明 |
|:--|:--|:--|
| **触发** | `UnitExec.scala` 主 FSM：`IDLE` 里 `io.go` 那一拍 | `dmaEn`（=段基址非 0）为真 ⇒ 先 `WGTLD -> WGTRUN` 装载本单元权重段，**装载收工后**才进 `RDSTART` 读激活。与"每个单元开跑之前先装自己的权重"逐字对应。 |
| **段起点（地址推导）** | `LayerSched.scala`：`wgtPtrR`（表序前缀和） | 帧首 `wgtPtrR := WGT_BLOB_BASE`；每跑完一个单元 `wgtPtrR += chainLen * N_i`。`N_i = C_out*(C_in/GROUP)*9`（**从几何导出**，不查表）；旁路项 `+0`。作为**独立入参** `wgt_dma_addr` 送进 `UnitExec`。 |
| **基址 `WGT_BLOB_BASE`** | `LayerSched.scala`：`wgtBlobBaseR`（**复用既有权重信箱**） | 经信箱**区域 6**（`RGN_WBASE=0x6`、地址 `0x600000`+道，`MAILBOX_AW=24` ⇒ 区域位 `[23:20]`）、4 个字节道**小端**写入。**`HostRegs`/`NpuTop`/描述符格式一字未动**（零寄存器契约变更）。`WGT_BLOB_BASE == 0` ⇒ `UnitExec.dmaEn` 为假 ⇒ **整条 DMA 不动** ⇒ 与 C3/C4a"信箱带外预载"逐字节同形。 |
| **段长** | `UnitExec.scala`：`wgtLenR = chainLen * NENTRY` | `NENTRY = C*(C/GROUP)*9`（dense 8×8 = **576**，**展开期常量**）。要求描述符几何与展开期几何**逐项相等**（`dmaGeomOk`：`C_in==C && C_out==C && GROUP==group && !depthwise`）⇒ 段长 == 片内条目数。另要求 `NENTRY%8==0`（一拍 8 B ⇒ 整拍收尾）且 `NENTRY%32==0`（DdrMaster RD 粒度 32 B）。 |
| **片内分配** | `UnitExec.scala`：`wlSlice`/`wlAddr` | **一笔连续 RD**（`mLen = chainLen*NENTRY`）读回，按 `wlSlice/wlAddr` 逐字节灌：前 `NENTRY` 字节→切片 0、再 `NENTRY`→切片 1 …… ⇒ 链上第 k 片拿到 blob 里第 k 段（"表序 == blob 序"，spec §4.2 裁决 (a)）。 |
| **与激活相位复用** | 同一个 `DdrMaster` | 权重 RD（`WGTLD/WGTRUN`）与激活 RD（`RDSTART/RDRUN`）、输出 WR 在时间上**串行**（一个主口）。`rd_ready = wlTake || (激活读)`。 |
| **自报口** | `UnitExec.wgt_bytes` → `LayerSched.wgt_bytes` | 本次 `go` **真正写进 `WeightStore` 的字节数**（装载器逐字节计数；未走 DMA 恒 0）。与"内存模型数出来的读字节"是**两处独立计数**。 |

**边界（本版只做窄通路，其余响亮拦住）**：宽层（`C_in>8 || C_out>8`）、`GROUP` 不符、depthwise、
段尾越 28 bit DDR 窗 ⇒ `dmaEn` 为真时**响亮 `err` + 零搬运**（绝不静默落到"权重还是信箱里的旧值"）。
⚠ **因此 C4b 的真表（53 个 conv 单元 `C_in`/`C_out` 全 > 8，宽层）在本版还不能整帧走 DMA 主路径**（归 B2+）；
B1 的逐单元逐字节判据用 **reduced blob（4 段 × 576 B）** 与 **大作业（真 blob 403,776 B，窄几何 8 片链）** 证死。

---

## 2) 上一轮遗留的**关键 bug**：装载器跨拍写口的**漏道**（lane 0 of a beat dropped）

**站点**（`y1/rtl/UnitExec.scala:711`，对应网表 `gen/LayerSched.v:53560`）：

```scala
// WGTRUN 里接新拍：
when(wlTake) {
  ... wlHold <= 新拍; wlV := True
  wlIdx := Mux(wlV, U(0, 3 bits), U(1, 3 bits))   // ← 修好的那一行
}
```

**病因**：装载器**一拍 8 道逐拍吃掉**。当"新拍在**正写上一拍的第 7 道**那一刻被接收"（`wlV` 为真、`wlIdx==7`）
时，**下一道必须回到新拍的第 0 道（= 0）**。上一轮把它写成了 **1** ⇒ **每一拍的第 0 道被整拍跳过**
（每拍只写 7 字节）。表现：装载越攒越少、`wlCnt` 永远到不了 576 ⇒ 主 FSM **卡在 `WGTRUN`、帧不结束**。

**受控实验**（把该行在网表里**还原**成 `3'b001 : 3'b001`，其余一字不动，跑闸门同一套装置）：

| 变体 | 配置 | 结果 |
|:--|:--|:--|
| **修好**（现状） | J2 单单元、DMA 开 | `WGT_BYTES=576`、`STORE_MISMATCH0=0`、`RESULT: PASS` |
| **还原 bug**（只动 `wlIdx`） | 同上 | **挂住**：帧不结束 ⇒ TB `RESULT: FAIL timeout`（装载器到不了 576） |
| **还原 bug + RD 加长到 672 B**（让装载器能跑完，把 bug 单独暴露给逐字节判据） | 同上 | **逐字节判据发火**：`STORE_MISMATCH0=508/576`、`STORE_FIRST slice=0 addr=8 dut=02 exp=00` |

**读法**：`addr=8` 处 `dut=0x02` 正是 **blob 第 9 字节**（`X[9]`），而期望 `exp=0x00` 是 **blob 第 8 字节**（`X[8]`）
—— **每拍的 0 号道被丢、其后整体左移一道**的**逐字节指纹**，一目了然。修好后同一判据 `576/576`、`0` 差。

> 附一条方法论（本任务实测的坑）：**信箱"覆盖"作业（J2，帧后把整片 0 重写一遍）会掩盖装载器的坏数据**
> —— 覆盖把第 0 片 576 字节**整片盖掉**，于是坏数据看不见。所以"装载内容"的逐字节判据**必须跑在
> 无覆盖的作业**上（闸门里是 J1/J5/J6/J7/J9；J2 只用来证"装载之后信箱仍可改"）。

---

## 3) 判据① —— **逐单元、逐字节**（不是校验和）

`run_wgtdma_ab.sh` 帧末把**每片 `WeightStore` 的全部 576 个条目**用其**既有 `tile` 端**读回（白盒观察，
零面积），与按 blob 布局算术（段起点 = 前缀和、段长 = 576）算出的那一段**逐字节对账**：

| 作业 | 表序 | 期望（按 blob 布局） | 结果 |
|:--|:--|:--|:--|
| **J1** | `[X(conv), P(maxpool), A(head), B(mid), C(tail)]` | 片 0/1/2 = `A`/`B`/`C`（**前缀和 0 / 576 / 1152**，旁路项 `P` 贡献 **0**）＋片 3..7 全 0 | `STORE_MISMATCHi=0`（i=0..7） |
| **J1b** | 同 J1 表，**DMA 关**（`WBASE=0`） | 八片全 0 | `STORE_MISMATCHi=0` |
| **J2** | 单单元，DMA 开 + 帧后信箱**覆盖**片 0 | 片 0 = X 段 + 覆盖 1 字节 | `STORE_MISMATCH0=0` |
| **J3** | 单单元，DMA **关** + 帧前信箱预载（C3/C4a 旧通路） | 片 0 = 预载向量 | `STORE_MISMATCH0=0` |
| **J5** | 单单元，DMA 开，**blob 镜像改 1 字节** | 见判据③ | `STORE_MISMATCH0=1` |
| **J6**（大作业） | `701` 项 = 87×8 片链 + 1×5 片链（**整份真 blob `wgt_blob.bin` 403,776 B**） | 末链 5 片 = `blob[400896:403776]` | `STORE_MISMATCH0..4=0` |

**真 blob 指纹锚**（闸门开跑前的离线自检）：`wgt_index.json` 的 53 段**密集拼接**（`offset == Σ_{j<i} N_j`），
`Σ N_i = 403,776 == len(wgt_blob.bin)`，md5 = `2270b6795d46cf551c140164ef862310`。

---

## 4) 判据② —— **装载字节数 == blob 大小**（三方独立对账）

| 口径 | 期望 | 实测 |
|:--|:--|:--|
| **设备侧自报** `LayerSched.wgt_bytes`（Σ 各单元 `UnitExec.wgt_bytes`） | J1=4×576=**2304**；J2=**576**；J3=**0**；J6=**403776** | 2304 / 576 / 0 / 403776 ✓ |
| **内存模型差值**（同一张表，DMA 开/关两跑的 `MEM rd` 之差） | **2304**（4 段） | `8640 - 6336 = 2304` ✓ |
| **大作业总量**（8 片网表展开后的读字节） | 权重 `403776` + 激活 `88×2048` + 取表 `702×32` = **606464** | `MEM rd=606464` ✓ |

**判据③（负对照，必须发火且能定位）**：

| 作业 | 突变 | 必须发生 | 实测 |
|:--|:--|:--|:--|
| **J5** | blob 镜像改**一个字节**（偏移 7） | 红 + **定位到单元** | `RESULT: FAIL store 对账不符（1 字节）`；`STORE_MISMATCH0=1`、`STORE_FIRST slice=0 addr=7 dut=01 exp=fe` ⇒ 定位 **单元 X0 / blob 偏移 7** |
| **J7** | 网表突变：装载 RD 段长 **+32 B** | **多读**：`MEM rd` 恰 +32，而 store 仍逐字节相等、设备侧计数仍 576 | `MEM rd=2720`（=2688+32）、`STORE_MISMATCH0=0`、`WGT_BYTES=576` |
| **J9** | 网表突变：段长 **−32 B**（收尾条件同步改小） | **少读**：`MEM rd`/`wgt_bytes` 各 −32，且**判据① 一起发火**（尾 32 字节为 0） | `MEM rd=2656`、`WGT_BYTES=544`、`STORE_MISMATCH0=27`（= 尾 32 字节里非 0 的个数）、`STORE_FIRST slice=0 addr=544 dut=00 exp=ff` |

**另附**（能力边界，非判据）：J4（描述符 `GROUP=4` 几何不符）⇒ **响亮 `err` + 零设备搬运**（`MEM rd=64` = 只取了两次表）；
J1 数值附判：X（plain conv，用 DMA 装进来的权重）的输出**逐字节 == `conv_unit_ref` 黄金**（`J1_X_OUT_MISMATCH=0`）。

---

## 5) 全回归（非 PDS）

`y1/tools/run_*_ab.sh`（全部）+ `scripts/check_addr_map.py` + `y1/tools/check_dangling.py`：

**31 个自包含闸门全部 `rc=0`**（`run_axilite_cdc / run_bypass / run_chain / run_convert /
run_ddrcopy / run_ddrmaster32 / run_ddrread / run_ddrwrite / run_desc / run_dw / run_fuse /
run_fuse_head / run_fusionbuf / run_grouped / run_hostregs / run_irqrst_cdc / run_layout /
run_linebuffer / run_macarray / run_mem_cdc / run_multipass / run_nputop / run_nputop_sched /
run_quant / run_sched / run_tiling / run_twoclock / run_unitexec / run_unitexec_wide /
run_weightstore / run_wgtdma`），其中代表性命中行：

| 闸门 | 结果 |
|:--|:--|
| `run_wgtdma_ab.sh`（本任务） | `RESULT: PASS`（exit 0） |
| `run_sched_ab.sh` / `run_nputop_sched_ab.sh` | `RESULT: PASS`（LayerSched/NpuTop 回归） |
| `run_unitexec_ab.sh` / `run_unitexec_wide_ab.sh` | `RESULT: PASS`（UnitExec 两份网表回归） |
| `run_chain_ab.sh` / `run_fuse_ab.sh` / `run_fuse_head_ab.sh` | `RESULT: PASS` |
| `run_twoclock_ab.sh` | 负对照（两时钟 + AR 跨域掐断）**发火** ⇒ 闸门能检出被破坏的 CDC |
| `run_grouped_ab.sh` / `run_weightstore_ab.sh` / `run_linebuffer_ab.sh` / `run_macarray_ab.sh` | `JUDGE-GREEN`（逐字节全中） |

> **`run_numeric_ab.sh rc=1` 不是回归**：它是**带参助手**（`<mode> <cin> <cout> <H> <W> <seed>`，
> 文件头明写"数值对账判据"，被 `run_macarray_ab.sh`/`run_linebuffer_ab.sh` 同风格引用），无参调用
> 只打印 `usage:` 并 `exit 1` —— 不是自包含闸门。仓库里**没有**任何脚本把它当顶层闸门调用。

**台账 / 结构判据**：

| 检查 | 结果 |
|:--|:--|
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/LayerSched.v` | 零悬空（rc=0） |
| `check_dangling.py gen/NpuTop.v` | 零悬空（rc=0） |
| `check_dangling.py gen/UnitExec.v` | 零悬空（rc=0） |
| `check_dangling.py gen/UnitExec_w32.v` | 零悬空（rc=0） |

**网表确定性 2×**（连续生成两次，md5 逐字节相同）：

| 网表 | md5（2 次一致） |
|:--|:--|
| `gen/UnitExec.v` | `aeb1bd12b50388cf258a8d8f23c5a423` |
| `gen/UnitExec_w32.v` | `e8922f8439d2a8a2bfbb014a10c4032c` |
| `gen/LayerSched.v` | `160995ae9890a731bf2b56127f739a6e` |
| `gen/NpuTop.v` | `3d42e5c007493d056b5a23d54effef16` |

`third_party/**` 与冻结工具（`ddr_traffic.py`/`fusion_buffer.py`/`bypass_traffic.py`/`mac_ref.py`/
`bypass_ref.py`/`conv_unit_ref.py`/`desc_table.py`）**未改动**（`git status` 无变化）。

---

## 6) 本轮收口时修掉的**闸门/装置缺陷**（不改判据语义）

| 缺陷 | 现象 | 修法 |
|:--|:--|:--|
| `gen/LayerSched.v` 里锚不唯一 | `UnitExec.scala` 的死代码 `val wlRemain`（从未被引用，且注释引用了不存在的 `wlDrain`）使 `(wlCnt < wgtLenR)` 在网表里出现 **2** 次，闸门突变锚断言 `1/1` 失败 exit 2 | **删掉死代码 `wlRemain`**（零行为变更；恢复突变锚唯一） |
| 装置 `STORE_FIRST` 位数 | TB 用 32 bit `integer` 打印 `%02x` ⇒ 打 **8** 位十六进制；闸门 J9 模式串期待 **2** 位 | 装置改打**低 8 位**（`dv[7:0]`/`ev[7:0]`）|
| 闸门 `getv` 锚行首 | `WGT_BYTES` 与 `FRAME_DONE/...` **同行**（装置契约），`getv` 锚行首取到空串 ⇒ 判据② 静默判成不符 | `getv` 改成取 **`<name>=<num>` 词**（不锚行首） |
| J9 期望值写死 | "尾 32 字节为 0"的不符字节数**数据相关**（X 段尾部 32 字节里有 5 个本就是 0 ⇒ 期望 **27** 不是 32） | 造向量时**算出**尾部非 0 个数写入 `wgtnum.txt`，闸门照它对 |

---

## 7) 控制器还要做什么（本任务**未做**、明写）

1. **重跑 PnR**（`dev_map` + `pnr`）：本轮**改了 RTL**（`UnitExec`/`LayerSched`）⇒ 需重出
   `All Constraints Met` + 面积 Δ 表。**本任务不跑 PDS。**
2. **B2**：`M`（§4.4 requant 乘子）/`z_pad`/`bias_adj`（§4.5）随 blob 同序投递 + **装载/计算重叠纪律**与判据。
3. **宽层整帧 DMA**：B1 只覆盖"段长能装进切片 `WeightStore`"的**窄单元**；真表宽层的"趟瓦片展开"
   归 B2+（本版对宽层在 `dmaEn` 下**响亮 err**，不静默错值）。
4. **上板**（B6）：大 blob 走网络（R5），整帧端到端与 float ORT 容差对账（G7）。

---

## 8) 附：指纹

| 文件 | md5 |
|:--|:--|
| `y1/gen/wgt_blob.bin`（403,776 B） | `2270b6795d46cf551c140164ef862310` |
| `y1/rtl/UnitExec.scala` | `a13474c6c2c9e8a42880fabfd1fa9988` |
| `y1/rtl/LayerSched.scala` | `f7e6a74d900f286122bc9b59de08b948` |
| `y1/rtl_test/WgtDmaTb.v` | `6fa622dabbe71682bdc76385d95ff8cc` |
| `y1/tools/run_wgtdma_ab.sh` | `060a5a36673e20dbb2ec5d5afb9f978e` |

---

## 9) ★★ B1b（本任务）：**宽层**走同一条 DMA 装载（落点换到趟瓦片 `wRam`）

**Status: DONE**（`run_wgtdma_wide_ab.sh` 全绿 + 三条负对照全部发火；全回归见 §9.4；PnR 待控制器重跑）
提交：`85c698b`（主体）+ `65dd056`（回归修复，见 §9.5）。日期 2026-10-12。

### 9.1 为什么必须做、改了什么

B1 只覆盖**窄层**（段长 == 切片 `WeightStore` 的条目数 576）。真表 53 个 conv 单元的 `C_in`/`C_out`
基本全 > 8（宽层）⇒ B1 的 `dmaEn` 下它们**响亮 err**（不静默，但真帧还是装不进权重 —— G6 的装载半在真表上
等于零覆盖）。本任务把**同一条装载器**（`WGTLD -> WGTRUN`，同一个 `DdrMaster` RD 流、同一套收拍纪律）
的**落点参数化**：`wlWideR` 选路 —— 窄层落各切片 `WeightStore`（B1 原样），宽层落**趟瓦片 RAM `wRam`**
（36,864 B，`MultiPassUnit` 每趟读 576 B）。**不建第二个内存主口、不复制装载器**（一份指针/计数/收拍逻辑）。

| 项 | 落点 | 说明 |
|:--|:--|:--|
| **触发** | `UnitExec.IDLE` 的 `go` 那一拍 | `dmaEn`（基址非 0）且**宽层** ⇒ `wideDmaOk` 成立才进 `WGTLD`，否则**响亮 err + 零搬运** |
| **段起点** | `LayerSched.wgtPtrR`（B1 已建，**未改**） | `WGT_BLOB_BASE` + 表序前缀和 `Σ N_j`；`N_i = C_out*(C_in/GROUP)*9`（宽层 `GROUP=1` ⇒ `C_out*C_in*9`，与 index 的 `bytes` 同式） |
| **段长** | `wgtLenR := Mux(dmaWide, C_out*C_in*9, chainLen*NENTRY)` | 宽层恒 `chainLen==1` ⇒ 段长 == `wgt_index.json` 的 `bytes` |
| **落点（本任务的核心）** | `wlWideDest`（组合） | `dest(co,ci,tap) = (cob*nCi + cib)*576 + (co%8)*72 + (ci%8)*9 + tap`（`cob=co/8, cib=ci/8, tap=ky*3+kx`）—— 指针按 **blob 序** `[co][ci][tap]` 逐字节前进（`wlTap` 9 进制、`wlCi`/`wlCo` 进位） |
| **写口** | `wRam.write` | 主机信箱（区域 1，**调试/覆盖**口）∥ DMA 装载器（**主路径**），地址/载荷 **DMA 优先**（与切片 `WeightStore` 同一套仲裁口径） |
| **收工去向** | `WGTRUN` 里 `when(!wlRun)` | `Mux(wlWideR, WIDERUN, RDSTART)` ⇒ 宽层装完直接进多趟相位 |
| **自报口** | `io.wgt_bytes`（B1 已有） | 宽层 = 真正写进 `wRam` 的字节数（= 段长；宽通路**没有**"段外道"被丢） |

**映射（blob 序 ↔ 趟序；判据① 的对照面）**：blob 里该单元的段是密集 `[co][ci][tap]`（`tap = ky*3+kx`，
1×1 的其余 8 抽头为 0），而 `MultiPassUnit` 每趟读的是 `[co_local][ci_local][tap]` 的 8×8 瓦片、趟序 =
**co-block 外、ci-block 内**（`pass = cob*nCi + cib`）。两者是**同一批 9 字节"行"的两种分块**：

```
wRam[(cob*nCi + cib)*576 + cl*72 + cil*9 + tap] == blob[off + ((cob*8+cl)*C_in + (cib*8+cil))*9 + tap]
```

`C_in%8==0 && C_out%8==0` 时两边字节数相等（`nCi*nCo*576 == 段长`）⇒ 装载是**纯重排**（8×8 块划分这一步
**从主机搬到了 NPU 自己**，一次 RD 一字节不多读）。**不做除法**（`co/ci` 的低 3 位就是块内下标）、只有
"位切片 + 常数乘（576/72/9）+ 一次 `*nCi`"。★ 闸门用**两条独立路径**算出这幅镜像并互证：本闸门按上式
从 blob 段算 vs `wide_exec_ref.py` 算的 `w.hex` ⇒ `MISMATCH=0/2304`。

### 9.2 判据（`run_wgtdma_wide_ab.sh`，真转换器产物）

用例 = **真表单元 `Conv_6`（idx/layer_id 4）**：`C_IN=16 C_OUT=16 GROUP=1`、`offset=2880`（32 B 对齐）、
`bytes=2304`（32 的整数倍）⇒ `nCi=nCo=2`、`nCi*nCo*576 = 2304 == bytes`。小几何 `H=4 W=64`（= 本网表
`WIDTH=64`、`H*W=256 = PIXW`）；权重**只经 DMA 进来**（信箱 WFILE 灌的是全 0 ⇒ 装载坏了一看就露）。

| 判据 | 期望 | 实测 |
|:--|:--|:--|
| **① 逐字节** | `wRam[0:2304]` == blob 段的趟序重排；`wRam[2304:36864]` 一字节未写 | `WRAM_BAD=0`、`WRAM_OUTSIDE_NONZERO=0`、`WRAM_EXP_NONZERO=244`（有分辨度） |
| **② 装载字节数（三方）** | `MEM rd == WGT_BYTES == index.bytes == 2304` | 2304 / 2304 / 2304 ✓（宽层无激活 RD ⇒ 读的**只有**权重段） |
| **③-a N1 翻一字节** | 红 **且定位** | `WRAM_BAD=1`、`dest=7`（趟 0 cl=0 cil=0 tap=7 ⇒ co=0 ci=0）⇒ **blob 偏移 2887**（= 2880+7）、`dut=01 exp=00`；读字节数仍 2304（判据② 不红） |
| **③-b N2 突变 +32 B** | **多读**：`MEM rd` 恰 +32，数据仍对 | `MEM rd=2336`、`WGT_BYTES=2304`、`WRAM_BAD=0` ⇒ 判据② 抓的是**字节数** |
| **③-c N3 突变 −32 B** | **少读**：`MEM rd`/`WGT_BYTES` 各 −32 **且**判据① 一起发火 | `MEM rd=2272`、`WGT_BYTES=2272`、`WRAM_BAD=3`（段尾 32 B 未装；首差 `dest=2277` ⇒ blob 偏移 5157） |
| **附：数值正对照** | DST 区逐字节 == `wide_exec_ref --lid 4` 的黄金 | `MISMATCH=0`、邻居 32 B 未被改（即"用 DMA 装进来的真权重算出来的输出"与参考逐字节同） |
| **附：能力边界** | `C_IN%8!=0` 的宽层 ⇒ 响亮 err + 零搬运 | `ERR_SEEN=1 DONE=0 MEM rd=0 WGT_BYTES=0`、`wRam` 非 0 字节 **0** |

> 方法论（沿用 B1 §2 的坑）：判据① 必须跑在**无信箱覆盖**的作业上（本闸门的 WFILE 是全 0，只用来把
> `wRam` 先清零 ⇒ 装载若坏，观察面**恰好**是"全 0 vs 期望"）。

### 9.3 宽层的**边界**（`dmaEn` 下响亮 err，绝不静默）

`wideDmaOk = wideGeomOk && GROUP==1 && 非 depthwise && C_in%8==0 && 段长%32==0 && 段尾在 28 bit DDR 窗内`：
- `C_in%8!=0`（如真表 `Conv_0`：`C_in=3`、段长 **432 B**）⇒ 趟瓦片有"跳过通道"补位、**段长 != nCi*nCo*576**，
  本版**响亮 err**（闸门 [4b] 证：`err` + 零搬运）；
- 段长 `%32!=0` / 段起点非 32 B 对齐 ⇒ DdrMaster 的 RD 契约（`len%32==0`、`src%32==0`）不允许**恰好读段长**
  （多读就破判据②）⇒ 同样**响亮 err**。
- ⚠ **诚实记录**：真 blob 里 `Conv_0`（off 0, 432 B）与多段 `off ≡ 16 (mod 32)`（因为前面有 144/288/9/36/90
  这些非 32 倍数的段）⇒ **真表仍不能整帧走 DMA**（这不是本任务引入的：B1 的整帧作业 J6 用的是
  "576 B 定长分段正好把真 blob 铺满"的合成几何）。**要让真帧整帧走 DMA，需二者之一**：
  ① 重新生成 blob（每段补齐到 32 B 且 32 B 对齐；会改 `wgt_index.json` 的 offset/bytes 与 blob md5 —— 冻结产物的变更须由控制器裁决）；
  ② 放宽主口粒度（允许 16 B 起、非 32 倍数的 `len`；属 `DdrMaster` 的契约变更）。
  本任务**两者都没做**（保持"描述符格式 + 寄存器契约 + 冻结 blob"不变）。

### 9.4 全回归（非 PDS）

`y1/tools/run_*_ab.sh`（30 个自包含闸门）**全部 `rc=0`**：`run_wgtdma_ab`（B1 窄通路，回归后全绿）、
`run_wgtdma_wide_ab`（本任务）、`run_unitexec_ab`/`run_unitexec_wide_ab`、`run_chain_ab`、`run_fuse_ab`/
`run_fuse_head_ab`、`run_sched_ab`、`run_nputop_sched_ab`/`run_nputop_ab`、`run_multipass_ab`、
`run_weightstore_ab`、`run_layout_ab`、`run_desc_ab`、`run_hostregs_ab`、`run_fusionbuf_ab`、
`run_linebuffer_ab`、`run_macarray_ab`、`run_bypass_ab`、`run_dw_ab`、`run_grouped_ab`、`run_tiling_ab`、
`run_convert_ab`、`run_quant_ab`、`run_ddrcopy_ab`、`run_ddrread_ab`、`run_ddrwrite_ab`、`run_ddrmaster32_ab`、
`run_axilite_cdc_ab`、`run_irqrst_cdc_ab`、`run_mem_cdc_ab`、`run_twoclock_ab`。

| 检查 | 结果 |
|:--|:--|
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop,MultiPassUnit,DwUnit}.v` | 全 `0` |
| 网表确定性 2×（连续生成两次，md5 逐字节相同） | `gen/UnitExec.v 842d9452ddb14f3a350ef8e474f7dfe5`、`gen/UnitExec_w32.v fa2aeaf683e766fbab613ef2d3d1352a`、`gen/LayerSched.v be4d3097b71c0b81d2f27380ea3f316f`、`gen/NpuTop.v 01b174daf5c07015b46ad819b259ca4e` |
| RTL / 装置 / 闸门指纹 | `rtl/UnitExec.scala e37f1f1c8ef058b736ada13615cdbf06`、`rtl_test/UnitExecWideTb.v b7ae3f90ff3fd6170de8842c181edc6b`、`tools/run_wgtdma_wide_ab.sh 8c65f93663b4fda0f2911aa0d13982d8` |
| `gen/wgt_blob.bin`（未改） | `2270b6795d46cf551c140164ef862310`（403,776 B）；`wgt_index.json` 未改 |
| `third_party/**` + 冻结工具 | `git status` 无变化 |

### 9.5 本轮修掉的**真回归**（由 B1 的闸门抓到，值得记一笔）

`dmaWide` 第一版写成 `dmaEn && wideDmaOk` —— 但 **`wideGeomOk` 对窄层也成立**（`C_out==8 ⇒ cOut%8==0`、
`chainLen==1`、`IMG_W==WIDTH` 都是真的）⇒ 窄层被误判成"落 `wRam` + 进 `WIDERUN`"。
**指纹**：`run_wgtdma_ab.sh` 的作业 J1 **挂住**（`busy=1 unitIndex=0`，帧不结束）—— 正是"窄层进了宽层
子 FSM、`wide_x` 没人喂"的形状。修法：`dmaWide = dmaEn && isWide && wideDmaOk`（`IDLE` 分派那条本来就
有 `when(isWide)` 守卫，只有 `runStart` 的 `wlWideR`/`wgtLenR` 需要它）。⇒ **跨任务回归（B1 的闸门）抓住
了新代码的 bug**，这也是"既有闸门必须保持全绿"这条纪律的价值所在。

### 9.6 控制器还要做什么（本任务**未做**）

1. **重跑 PnR**（`dev_map` + `pnr`）：本轮改了 RTL（`UnitExec`）⇒ 需重出 `All Constraints Met` + 面积 Δ 表
   （新增面积：1 个 `*nCi` 乘法 + 常数乘/加 + 3 个小计数器；`wRam` 写口多一个 2:1 仲裁）。**本任务不跑 PDS**。
2. **真帧整帧 DMA**：见 §9.3 的边界 —— 需要"重排 blob（32 B 对齐/补齐）"或"放宽主口粒度"，两者都要
   控制器裁决（前者改冻结产物、后者改 `DdrMaster` 契约）。
3. **B2**：`M`/`z_pad`/`bias_adj` 随 blob 同序投递 + 装载/计算**重叠纪律**（本任务与 B1 一样：装载与计算
   **串行**，一拍一字节 ⇒ 2304 B 段约 2304~2600 拍；重叠是 B2 的事）。

---

## 10) ★★ B0（后续任务）：**32 B 对齐权重 blob** —— §9.3 阻塞的**选项①**落地（2026-10-12）

**Status: DONE**（`run_convert_ab.sh` / `run_wgtdma_ab.sh` / `run_wgtdma_wide_ab.sh` 全绿 + 真单元装载扫描 6/6）。
用户裁决 §9.3 的**选项①**（改 blob：把每个单元的段**补齐到 32 B 倍 + 32 B 对齐**，补位 `0`），而非选项②（放宽主口）。

**改了什么（零 RTL / 零描述符 / 零寄存器改动）**：

| 层 | 变更 |
|:--|:--|
| 转换器 `tools/y1_convert.py` | 每单元物理段长 `N_i' = ceil32(N_i)`、起点 = `Σ_{j<i} N_j'`、`[N_i,N_i')` 补 0；`wgt_index.json` 逐单元新增 `aligned_bytes`/`align_pad`，`offset` 改为对齐后起点；`blob` 段新增 `sum_N_aligned`/`pad_overhead` |
| spec §4.2 / 计划 B1 | 布局修订（日期 2026-10-12），口径：`N_i = C_out*(C_in/GROUP)*9`（真实）、`N_i' = ceil32(N_i)`（物理）、补位 0 |

**新产物指纹**：`gen/wgt_blob.bin` = **404064 B**、md5 **`aa135f0f7d50780b7b13d9a1ba9c518a`**
（真实 `Σ N_i = 403776` + 补位 **288 B**）；`desc.bin`/`wgt_mult.bin` **未变**。

**判据**：
- `run_convert_ab.sh`：`BLOB_OFFSET_CUM_SUM ok=1 units=53 total=404064 (aligned)`；`WGT_BLOB_BYTES=404064 … SUM_N=403776 SUM_N_ALIGNED=404064 PAD_OVERHEAD=288`（显式断言，不静默放宽）；两次运行逐字节确定。
- `run_wgtdma_ab.sh`（B1 窄）：锚断言 **53/53 段 `offset%32==0` 且 `offset == Σ ceil32(N_j)`**；窄通路铺满 `[0,403776)`（尾 288 B 补位不读）⇒ `wgt_bytes==403776`；J1/J5/J7/J9 负对照全发火。
- `run_wgtdma_wide_ab.sh`（B1b 宽 + **[8] 真单元扫描**）：取真 index 的 **6 个真单元**（Conv_2/Conv_6/Conv_9/Conv_12/Conv_15/Conv_19，各自的**真 offset/nbytes**，blob 整体落在 DDR）
  逐个跑 RTL 装载 ⇒ **DONE=1 / ERR=0 / `WGT_BYTES == MEM rd == nbytes` / `WRAM_BAD=0`**（对齐后**无 DdrMaster err**）；
  负对照 SWEEP-N1（翻 lid13 段内第 7 字节）⇒ `WRAM_BAD=1` 且定位回 blob 偏移 38791。

**诚实边界（对齐**没有**解决的）**：`wideDmaOk` 的**另一条**几何前提 `C_in%8==0`（趟瓦片无"跳过通道"）仍挡下
`C_in` 非 8 倍数的单元 —— 典型 **`Conv_0`（`C_in=3`，432 B → 448 B 补齐）**：其**对齐契约**（`offset=0`、段 448 B）现已满足，
但在**宽通路**上仍**响亮 err**（归"多趟跳过通道"= B2+，**不是**对齐问题）。真表 53 个单元里，
满足 `wideDmaOk` **全部**几何前提的 = **14/53**。

**未做（控制器）**：RTL **一字未改** ⇒ **无需重跑 PnR / 重生成网表**（`gen/*.v` 未动）；`third_party/**` + 冻结工具**未动**。

---

## 11) ★★ B1c（本任务）：**宽层装载器的几何覆盖** —— `C_in<8` 零填补 / `C_out<8` / depthwise（2026-10-12）

**Status: DONE**（`run_wgtdma_geom_ab.sh`（新）全绿 + 四条判据全发火；回归 31/31 rc=0 + 台账 + 悬空 + 确定性 2×；PnR 待控制器重跑）
提交：`c40f87d`（阶段1：RTL + 三条闸门）+ 本报告（阶段2）。日期 2026-10-12。

### 11.1 为什么（B0 §10 的实测）与改了什么

B0 §10 实测：真 blob 已 32 B 对齐、6 个真单元装载逐字节相等，但 **53 个真 conv 单元里只有 14 个**满足装载器
的几何前提 `wideDmaOk`（`C_in%8==0 && C_out%8==0 && GROUP==1 && 非 depthwise`）。其余 39 个**不是算不了**
（算的通路早就支持：`3c16o1g` 见 C4a.5a、depthwise 见 C4a.6），而是**装载器太窄**。本任务把装载器（`UnitExec`
的 `WGTLD/WGTRUN`，落点 `wRam`）放宽到真表的全部几何。**三处改动，全在装载器一侧（计算侧语义一字未动、blob/转换器一字未动）**：

| # | 改动 | 落点（`rtl/UnitExec.scala`） |
|:--|:--|:--|
| 1 | **段长/落点按 GROUP 派生**：`cig = Mux(GROUP==1, C_in, 1)`（真表 `GROUP ∈ {1, C_in}` ⇒ 一次 2 选 1，**不做除法**）；落点 `ci = gco*cig + ciLocal`（`gco = Mux(GROUP==1, 0, co)`）；blob 内层计数上界改 `cig-1`；`N_i = C_out*cig*9` | `cgW` / `grpOkW` / `wgtWideLen` / `wlCiReal` / `wlCiLast` |
| 2 | **RD 长度改 `ceil32(N_i)`**（= B0 的 `aligned_bytes`；`DdrMaster` 的 `len%32==0`/`src%32==0` 契约**未放宽**）。多读的 ≤31 B 是**转换器补的 0**，装载器**不写**它们（写入字节数另存 `wgtWrLenR`）⇒ 判据② 的分工：`MEM rd == ceil32(bytes)`、`WGT_BYTES == bytes`（`bytes%32==0` 时两者相等 ⇒ 既有 14 个几何逐字节不变） | `wgtWideRdLen` / `wgtWrLenR` / `dmaWinOkW` |
| 3 | **零填充相位**（`WGTLD` 的新子相位，`wzGo`）：需要补零的几何先花 `Z = nCi*nCo*576` 拍把 `wRam[0,Z)` 逐字节写 0，**写完才发 RD**。为什么必须显式写：`wRam` 是**跨层常驻**的 `Mem` —— 那些"没有 blob 字节对应"的位置会**留上一层的旧权重** | `wzCnt` / `wzEnd` / `wzNeedW` / `wlZeroWr` |

**装载器前提 vs 计算侧前提解耦**：`wgtLoadOk` = `grpOkW && N_i!=0 && chainLen==1 && 段尾在 28 bit DDR 窗内`
（装载器只看这四条）；`wideGeomOk` 是**计算侧**的前提（含 `C_out%8==0`：宽 WR 相位按**整 co-block** 出料）。
⇒ 真表 `C_out ∈ {1,4,10}` 的单元现在**能把权重正确装进来**（判据①②可判），随后由 `WGTRUN` 收工那一拍**响亮 err**（不静默算错）；
装载器自己的前提不合时更早就在 `IDLE` 拦住（那时**零搬运**）。
**语义增量（明写）**：`dmaEn && isWide && !wideGeomOk` 这条路径从"err + 零搬运"变成"**先装、再 err**"。
（原来这条路径被 `wideDmaOk` 里的 `C_in%8==0` 顺带挡住；现在单独由计算侧前提挡。装载器前提不合仍是零搬运。）

### 11.2 ★ `C_in<8` 的**瓦片映射**（3 通道单元怎么落进 8 宽瓦片、零填补落哪）

以真表 **`Conv_0`（`C_in=3`、`C_out=16`、`GROUP=1`）** 为例：`cig = 3`、`nCi = 1`、`nCo = 2`，
每趟瓦片 576 B（`[8co_local][8ci_local][tap]`，`tap = ky*3+kx`），共**两趟**：

```
blob 段（432 B，密集 [co][ciLocal][tap]，ciLocal ∈ {0,1,2}）:
  seg[(co*3 + ci)*9 + tap]        co ∈ [0,16)  ci ∈ [0,3)  tap ∈ [0,9)
落点（RTL 逐字节按 blob 序推进指针，dest 是 (co,ci,tap) 的函数）:
  dest(co, ci, tap) = (co/8 * nCi + ci/8)*576 + (co%8)*72 + ci*9 + tap
                    = (co/8)*576 + (co%8)*72 + ci*9 + tap      (nCi=1 ⇒ ci/8 = 0)
  ⇒ 趟 0 = co 0..7（cl=0..7）、趟 1 = co 8..15
```

即 **3 个输入通道只占每行的 `cil ∈ {0,1,2}` 三格**（`cil*9 + tap`，27 B/行），
**`cil ∈ [3,8)` 的 5 格 × 9 tap = 45 B/行**是"跳过通道"，由**零填充相位**写 0；
`cl` 方向 8 行全用（`C_out=16` 正好两趟）。
`Z = nCi*nCo*576 = 1*2*576 = 1152 B`，其中真实字节 `N_i = 16*3*9 = 432`、补零 **720 B**。
★ `z_w ≡ 0`（§4.5 对称量化）⇒ **补 0 就是"跳过通道的真实零码点"**，与 `multipass_ref.weight_tiles()`
的 SKIP 填 0 **是同一个东西**（本闸门的参考**直接 import 该冻结函数**，不重写算术）。

- **`C_out<8`**（如 `Conv_60`：`64→4`、`GROUP=1`、`nCo=1`）：`co_t = 4` ⇒ `cl ∈ [4,8)` 的 **4 整行**
  （4×72 = 288 B/趟）零填补；真实字节 `4*64*9 = 2304`，`Z = 8*1*576 = 4608`。
- **depthwise**（如 `Conv_16`：`64→64`、`GROUP=64`）：`cig = 1`、`ciLocal` 恒 0 ⇒ `ci = co`
  ⇒ 实字节落**对角位置** `cl == cil`（8 个对角趟 × 8 行 × 9 B = 576 B = `N_i`），其余（跨组位置 +
  **56 个非对角趟**）全 0，`Z = 36864`。

### 11.3 判据（`run_wgtdma_geom_ab.sh`；参考 = 冻结 `tools/multipass_ref.py:weight_tiles()`）

| 判据 | 期望 | 实测 |
|:--|:--|:--|
| **① 逐单元逐字节** | 44 个**宽层**真单元（各自真 offset/nbytes）逐个跑 RTL 装载 ⇒ `wRam[0,Z)` == 冻结参考的趟序镜像；`wRam[Z,MAXW)` 一字节未写 | `WRAM_BAD=0`、`WRAM_OUTSIDE_NONZERO=0`（**44/44**） |
| **① 有牙（零填补）** | 信箱 `+WFILE=` 灌 **0xFF**（不是 0）⇒ 没被装载器写 0 的格子会露 0xFF | 44/44 仍 `WRAM_BAD=0` ⇒ **零填补真在写** |
| **② 装载字节数** | `WGT_BYTES == nbytes` 且 `MEM rd == ceil32(nbytes)`（**补位是"写"不是"读"**） | 44/44 相符（`Conv_0`：`WB=432`、`RD=448`；depthwise `C=16`：`WB=144`、`RD=160`；`C=64`：`WB=576`、`RD=576`） |
| **③ 负对照（发火 + 定位）** | `Conv_0` 段内第 7 字节翻 1 位 ⇒ 红且定位 | `WRAM_BAD=1` @ `wRam[7]` <-> blob 绝对偏移 **7**（`dut=ee exp=ef`）；读字节数仍 448（判据② 不红） |
| **④ 真表扫描** | 53 个真 conv 单元的**逐单元**裁决 + 计数 | 见 11.4 |

### 11.4 ★ 真表扫描（53 个真 conv 单元，逐单元表见闸门输出）

| 口径 | 数 | 说明 |
|:--|:--|:--|
| **装载器几何前提成立**（`grpOkW` ∧ `N_i!=0` ∧ 段尾在 28 bit 窗内） | **53/53** | 真表每个 conv 单元的 `GROUP ∈ {1, C_in}` ⇒ 全部成立（B0 的 **14/53** 是**旧**口径） |
| 其中**走装载器**（`isWide`：`C_in>8 ∥ C_out>8`） | **44/53** | 其余 9 个**非宽层** ⇒ 走窄通路（`WeightStore` 是 8x8 固定形状）⇒ 装载器根本不参与 |
| **整帧可跑**（装载器前提 ∧ 计算侧 `C_out%8==0`） | **29/53** | 14 个 B1b 已覆盖几何 + `Conv_0` + 14 个 depthwise(`C=16/32/64`) |
| **装完响亮 err**（计算侧 `C_out%8!=0`） | **15/53** | `C_out ∈ {1,4,10}`：`Conv_54/56/58/66/68/70`(co=1)、`Conv_60/62/64`(co=4)、`Conv_72/74/76`(co=10)、`Conv_73/75/77`(depthwise co=10) |
| **非宽层 ⇒ 窄通路装不了** | **9/53** | `Conv_55/57/59/67/69/71`（`C=1` conv3x3）+ `Conv_61/63/65`（depthwise `C=4`） |

⇒ **没有一个真单元是"装载器装不了"**：44 个宽层单元**全部逐字节装对**（判据①②全中，含 `C_in=3` 的 `Conv_0`）；
15 个再因**计算侧** `C_out%8!=0` 响亮 err（不是装载器的问题）；9 个连装载器都不参与（非宽层）。
`Conv_0` 从 B0 的"响亮 err"变成 **`DONE=1` + `WB=432` + `RD=448` + `WRAM_BAD=0`**。
（depthwise 的 10 个 `C=64` 单元：`WB=576`、`RD=576`、`Z=36864`、`WRAM_BAD=0`。）

### 11.5 全回归（非 PDS）

| 检查 | 结果 |
|:--|:--|
| `y1/tools/run_*_ab.sh`（**31** 个自包含闸门，含新增 `run_wgtdma_geom_ab`） | **全部 `rc=0`**：`axilite_cdc / bypass / chain / convert / ddrcopy / ddrmaster32 / ddrread / ddrwrite / desc / dw / fuse / fuse_head / fusionbuf / grouped / hostregs / irqrst_cdc / layout / linebuffer / macarray / mem_cdc / multipass / nputop / nputop_sched / quant / sched / tiling / twoclock / unitexec / unitexec_wide / weightstore / wgtdma(_geom)` |
| `run_wgtdma_ab.sh`（窄，回归后） | `RESULT: PASS`（J1/J2/J3/J5/J6/J7/J9 全绿；大作业 `wgt_bytes=403776`；突变锚已随改名同步） |
| `run_wgtdma_wide_ab.sh`（宽，回归后） | `RESULT: PASS`（[4b] 的能力边界已改口径，见 11.6） |
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop,MultiPassUnit,DwUnit}.v` | 全 `RESULT: PASS`（零悬空） |
| 网表确定性 2×（连续生成两次，md5 逐字节相同） | `gen/UnitExec.v de7eb4cc2b88d92bb2f352921715604f`、`gen/UnitExec_w32.v 78abb5decfc375f9e7e32ed559eb3a87`、`gen/LayerSched.v bab5d79fbdba5f79ef3b70b33789b87b`、`gen/NpuTop.v 57979041cacd76715194ddb2ac59cec4` |
| `gen/wgt_blob.bin`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a`（404,064 B）；`y1_convert.py` / `wgt_index.json` 未改 |
| `third_party/**` + 冻结工具 | `git status` 无变化 |

### 11.6 本轮改的**闸门侧**（既有锚点必须跟着动，不动就是自欺）

| 站点 | 变更 | 为什么 |
|:--|:--|:--|
| `run_wgtdma_ab.sh` / `run_wgtdma_wide_ab.sh` 的突变锚 | `(wlCnt < wgtLenR)` / `(wlCnt == wgtLenR)` → **`wgtWrLenR`** | RD 长度与"写入字节数"现在是**两个**寄存器（改动 2）。`mLen <= wgtLenR;` 那个锚**不动**；两条闸门的 J7/J9（多读/少读）重新对账后仍全绿 |
| `run_wgtdma_wide_ab.sh` 的 [4b] 能力边界 | 用例从 `CIN=3/GROUP=1`（**现已支持**）改成 **`CIN=3/COUT=16/GROUP=3`** | 装载器边界**搬家**了：`C_IN%8!=0` 不再是边界 |

★ **仍是装载器边界（响亮 err + 零搬运）**：`GROUP ∉ {1, C_in==C_out}`（映射式 `ci = gco*cig + ciLocal`
只在上面两种几何下退化成乘 0/乘 1）。真表**没有**这样的 conv 单元。

### 11.7 诚实边界（本任务**未做**、明写）

1. **depthwise 的端到端**：本任务只证"装载器把 depthwise 的趟瓦片按冻结布局**装对**"（判据①）。
   `UnitExec` 宽通路的**收集相位**仍是 `wCi == nCi-1`（**不是对角趟**）⇒ 除最后一个 co-block 外，
   depthwise 的端到端输出**不对** —— 那是**计算侧**的事（"不改计算语义"是本任务的前提）。
2. **`C_out%8!=0` 的端到端**：宽 WR 相位按**整 co-block** 出料（`nCo*8*H*W` 字节）⇒ `C_out ∈ {1,4,10}`
   写不下。本任务让它们**能装**（判据①②），随后**响亮 err**；整帧覆盖要动计算侧（B2+/控制器裁决）。
3. **`C ∈ {1,4}` 非宽层（9 个真单元）**：走窄通路，而窄通路的 `WeightStore` 是 8x8 固定形状 ⇒ 本版装不了。
   要不要把它们也并进宽通路（改 `isWide` 判定 = 计算侧语义）由控制器裁决。
4. **零填充的吞吐代价**：一拍一字节的线性扫描，最坏（depthwise `C=64`）`Z = 36864` 拍；`Conv_0` 只有 1152 拍。
   与"装载不与计算重叠"（B2 项）同为**吞吐**代价；本任务判据是**数值/字节**不是性能。
   `wzNeed` 为假的几何（`C_in%8==0 && C_out%8==0 && GROUP==1`）**一拍不加**。
5. **RTL 改过 ⇒ 控制器要重跑 PnR**（`dev_map` + `pnr`）。新增面积：2 个 32 位寄存器
   （`wgtWrLenR`/`wzCnt`）+ 1 个 `wlG*cgW` 乘（depthwise 时 `cgW=1` ⇒ 可折）+ `wRam` 写口一个 2:1 仲裁
   + `ceil32` 的 `+31`/移位。**本任务不跑 PDS。**

### 11.8 附：指纹

| 文件 | md5 |
|:--|:--|
| `y1/rtl/UnitExec.scala` | `15eb5cbdb8d53af64f4850408f5f8b88` |
| `y1/tools/run_wgtdma_geom_ab.sh`（新） | `c13d47828f241c6dbf8254d155cf6b22` |
| `y1/tools/run_wgtdma_ab.sh` | `5931399c17e3f28306f0ad16663885a6` |
| `y1/tools/run_wgtdma_wide_ab.sh` | `e3e60a99367e7c049adb50242062e05c` |
| `y1/gen/UnitExec.v` | `de7eb4cc2b88d92bb2f352921715604f` |
| `y1/gen/LayerSched.v` | `bab5d79fbdba5f79ef3b70b33789b87b` |
| `y1/gen/NpuTop.v` | `57979041cacd76715194ddb2ac59cec4` |
| `y1/gen/wgt_blob.bin`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` |

---

## 12) ★★ C4b-C1（本任务）：**宽层部分 co-block 尾块**（`C_out % 8 != 0`）端到端（2026-10-12）

**Status: DONE**（新闸门 `run_wide_tail_ab.sh` 全绿 + 负对照**定点**发火 + 3 条边界响亮 err；真表
**12 个 dense 尾块单元**端到端逐字节 == 黄金；回归 **34/34 rc=0** + 台账 + 悬空 + 确定性 2×；PnR 待控制器重跑）

### 12.1 为什么（§11 的实测）与改了什么

§11.4 实测：53 个真 conv 单元里 **15 个** `C_out ∈ {1,4,10}`（`C_out % 8 != 0`）。B1c 让它们的**权重**
能正确装进 `wRam`（判据①② 绿），但宽通路的 **WR/收料相位按整 co-block 出料**（`nCo*8` 行）
⇒ `wideGeomOk` 的 `C_out%8==0` 把这 15 个**响亮 err** 挡住（不算错、但整帧跑不了）。本任务给宽通路
加**部分尾块**。**三处改动，全在 `rtl/UnitExec.scala`**（描述符格式/寄存器契约/**blob/转换器一字未动**）：

| # | 改动 | 落点（`rtl/UnitExec.scala`） |
|:--|:--|:--|
| 1 | **WR 相位总字节** `nCo*8*H*W` → **`C_out*H*W`**（总字数 `nCo*H*W` → `C_out*H*W/8`）。`wideCoRows = dw.cOut` 是唯一真源 | `wideCoRows` / `wideWrBytes` / `wideWrWords` |
| 2 | **`wideGeomOk` 放开 `C_out%8==0`**，改"输出通道数可寻址"边界：**`0 < C_out ≤ 8*NCOB_MAX`** | `wideGeomOk` |
| 3 | 注释/边界口径同步（`wideDmaOk`/`wgtLoadOk` 的说明、`WGTRUN` 的 err 说明、文件头 §C4b 段） | 同文件注释 |

**为什么"按字节数截断"恰好干净**（本任务的结构性理由）：出料的字节序是 `[co-block][cl][pixel]`
（见 §"缺陷修-2"：取字内第 `cl` 个字节、8 个连续像素凑一拍），在 `co = cob*8 + cl` 上**单调**；
又因 `H*W % 8 == 0`（`wideGeomOk` **保留**这条）⇒ 总字节数 `C_out*H*W` 是整「拍」(8 B) 的整数倍
⇒ 逐字节拼拍指针走到 `co == C_out` 就**自然截止**，截断点**恰好**落在行边界（少一拍/多一拍都不可能）。
⇒ **既不写也不读 `C_out` 之后**。`C_out % 8 == 0` 时 `wideCoRows == nCo*8` ⇒ **既有宽层用例逐字节不变**
（实测：`run_unitexec_wide_ab.sh`（`C_out=16`）与 `run_wgtdma_wide_ab.sh`（`C_out=16`）改后仍 PASS）。

**收料相位（`wCollect`）不动**：末 co-block 的 8 行仍整字收进**片上** `wOutMem`（无效行的权重（零填补）
与偏置都是 0），而 WR 只**读**有效 `C_out` 行 ⇒ **DDR 侧只写 `C_out` 行**（判据② 的落点）。
**C_in 侧**（B1c 的零填补：跳过通道 / 跨组 / 空行）**一字未动**；**窄（≤8）通路**一字未动
（`wideR=0` 时 `wrTotalEff/wrLenEff/wrDataEff/wrValidEff` 逐字退回旧表达式）。

### 12.2 判据（`tools/run_wide_tail_ab.sh`（新））

| 判据 | 期望 | 实测 |
|:--|:--|:--|
| **[0] 自检** | blob 指纹 `aa135f0f…` + 真表里 `isWide ∧ GROUP==1 ∧ 0<C_out≤64 ∧ C_out%8!=0` 的单元**恰好 12 个**（含 `C_out ∈ {1,4,10}` 三档）+ 各自真 `offset/nbytes`（32 B 对齐、`N_i==nbytes`、段尾在窗内） | 12/12（`Conv_54/56/58/66/68/70` co=1、`Conv_60/62/64` co=4、`Conv_72/74/76` co=10） |
| **① 正对照（逐字节）** | 权重**从 DDR 真 offset 装载**（`+WBASE=BLOB_BASE+off`、`+WFILE=` 灌**全 0** ⇒ 片内权重只可能来自 DDR）⇒ DUT 跑完 ⇒ `DST` 区 `[DST, DST+C_out*H*W)` **逐字节 == 黄金**（`MISMATCH=0`）、黄金非退化、`RESULT: PASS`、自报 `WIDE_PASSES==n_ci*n_co` 且 `RTL_M/ZPAD/ZY/LAYER` == 灌进去的值 | **12/12 `MISMATCH=0`**（gold distinct 13/2/…/71/…/192） |
| **② 装载字节** | `MEM rd == ceil32(nbytes) == nbytes` 且 `WGT_BYTES == nbytes` | `576/576`（co=1）、`2304/2304`（co=4）、`5760/5760`（co=10） |
| **② 存储字节** | `WR_BYTES == C_out*H*W`、`AW == B == C_out*H*W/128`，且 **`[DST+C_out*H*W, DST+nCo*8*H*W)`（整 co-block 的尾部空行区）一字节未写** | `256`（co=1）/`1024`（co=4）/`2560`（co=10）；尾部空行区 `TAIL_BAD=0`（12/12） |
| **③ 负对照（必发火 + 定位）** | **网表突变** `wideCoRows := nCo*8`（= 改动前的"整 co-block"口径，**强制尾块写满 8 行**）⇒ `WR_BYTES` 变、尾部空行区**被写**、且**报出首个越界字节**；**前 `C_out*H*W` 字节仍逐字节对**（定位：毛病就在"多写的那几行"，不是算术） | co=1：`WR 2048≠256`、尾 1784 B 被写 @**256**；co=4：`2048≠1024`、尾 1020 B @**1024**；co=10：`4096≠2560`、尾 1530 B @**2560**；`MISMATCH(前 LEN)=0`（12/12 发火 + 定位准） |
| **[4] 边界（真不支持仍响亮 err）** | `+WBASE=0`（不走装载器）⇒ `ERR_SEEN=1` 且 `WR_BYTES=0`/`RD_BYTES=0`（**零搬运**） | `C_out=72`（`--synth 10 72`，`nCo=9 > 8*NCOB_MAX`）✅；`C_out=0` ✅；`IMG_W=32 != WIDTH=64` ✅ |

**"整帧可跑"计数（真表口径，[0] 里现算）**：装载器前提 53/53 成立（其中 44/53 宽层）；
**计算侧前提 `0 < C_out ≤ 8*NCOB_MAX` ⇒ 44/53**（旧口径 `C_out%8==0` 是 **29/53**）⇒ **新增 15**
= **12 个 dense 尾块（本闸门端到端证死）** + 3 个 depthwise 尾块（`Conv_73/75/77`：`GROUP=10`；
**对角趟调度**是计算侧另一件事，见 §11.7-1 ⇒ 它们现在**跑得完但数值不对**，本任务**不**声称其对）。

### 12.3 ★ 既有闸门锚点跟着搬（`run_wgtdma_geom_ab.sh`，**先红后绿**）

B1c 的几何闸门 [2] 扫描里有一条锚：`expdn=0; [ co%8 != 0 ] && expdn=0`（"`C_out%8!=0` ⇒ 期望装完 err"）。
本任务把 `C_out%8!=0` 从"计算侧不支持"变成"支持"⇒ **该锚必须跟着动**（不动就是自欺）。

**先红**（改前跑，实测）：`JUDGE-RED: 15 条判据未过`，且逐单元行**只有 DONE/ERR 那一项红**：

```
   lid=37 Conv_54    C=64->1  G=1  nci=8 nco=1 Z=4608  | DONE=1 ERR=0 WB=576   RD=576   WRAM_BAD=0 OUTSIDE=0 | ok DONE/ERR(1/0,期望装完 err)
   lid=55 Conv_72    C=64->10 G=1  nci=8 nco=2 Z=9216  | DONE=1 ERR=0 WB=5760  RD=5760  WRAM_BAD=0 OUTSIDE=0 | ok DONE/ERR(1/0,期望装完 err)
   lid=56 Conv_73    C=10->10 G=10 nci=2 nco=2 Z=2304  | DONE=1 ERR=0 WB=90    RD=96    WRAM_BAD=0 OUTSIDE=0 | ok DONE/ERR(1/0,期望装完 err)
```
（装载器三条判据 `WRAM_BAD/OUTSIDE/WGT_BYTES/MEM rd` 在 44/44 宽层单元上**全绿**，负对照 [3] 仍发火。）

**后绿**：把 `compgate`（计算侧前提）改成与 RTL 同口径 `0 < C_out ≤ 8*NCOB_MAX`、`expdn` 由它派生、
计数文案同步（旧 29/53 → 新 44/53）⇒ 44/44 行 `ok`，`RESULT: PASS`。**判据①/②/③ 与负对照语义未动**
（只搬"计算侧 DONE/ERR"这条锚）。

### 12.4 全回归（非 PDS）

| 检查 | 结果 |
|:--|:--|
| `y1/tools/run_*_ab.sh`（**34** 个自包含闸门，含新增 `run_wide_tail_ab`） | **全部 `rc=0`**：`axilite_cdc / bypass / chain / convert / ddrcopy / ddrmaster32 / ddrread / ddrwrite / desc / dw / fuse / fuse_head / fusionbuf / grouped / hostregs / irqrst_cdc / layout / linebuffer / macarray / mem_cdc / multipass / nputop / nputop_sched / quant / sched / tiling / twoclock / unitexec / unitexec_wide / weightstore / wide_tail / wgtdma / wgtdma_geom / wgtdma_wide` |
| （`run_numeric_ab.sh` 不在自包含集合内：它是**带参**helper —— `<mode> <cin> <cout> <H> <W> <seed>`，无参必打印 usage 且 rc=1，与本次改动无关） | — |
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop,MultiPassUnit,DwUnit}.v` | 全 `RESULT: PASS`（零悬空） |
| 网表确定性 2×（连续生成两次，md5 逐字节相同） | `gen/UnitExec.v 0c3560ff26deecc732b29dec6119d134`、`gen/UnitExec_w32.v c36cc79fdf3dfe6b9211a3c70134e862`（`LayerSched.v`/`NpuTop.v` 未变：接口未动） |
| `gen/wgt_blob.bin` / `wgt_index.json` / `y1_convert.py`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` / `aea0916db7e81e3508cf6b180d624439` |
| `third_party/**` + 冻结工具 | `git status` 无变化 |

### 12.5 诚实边界（本任务**未做**、明写）

1. **depthwise 尾块（`Conv_73/75/77`，`GROUP=10`，`C_out=10`）**：本任务让它们**不再响亮 err**（几何可寻址）
   ⇒ 它们**跑得完**，但输出**不对**（对角趟调度未实现，与 §11.7-1 的既有缺口同源）。§12.2 的"44/53 整帧可跑"
   是**几何口径**；**被端到端证死的只有 12 个 dense 尾块**。要不要把 depthwise 也挡住（`wideGeomOk` 加
   `GROUP==1`）会**改变既有行为**（14 个 `C_out%8==0` 的 depthwise 单元现在也"跑得完但不对"）⇒ 属**控制器裁决**。
2. **depthwise 的端到端正确化**：仍是计算侧的另一件事（§11.7-1）。
3. **`C ∈ {1,4}` 非宽层（9 个真单元）**：仍走窄通路（`WeightStore` 8x8 固定形状）⇒ 装不了（§11.7-3）。
4. **`C_out > 8*NCOB_MAX`（> 64）**：响亮 err（本任务新钉的边界）；真表**没有**这样的 conv 单元。
5. **吞吐**：本通路的判据是**数值/字节**不是性能；`C_out%8!=0` 的尾块**不额外加拍**（只是总字节数变小）。
6. **RTL 改过 ⇒ 控制器要重跑 PnR**（`dev_map` + `pnr`）。新增面积：**0 个寄存器** —— 与改前网表逐项对账：
   `reg` 声明**逐行相同（2226/2226）**、`wire` 声明数相同（2861）、全文件 `<=` 只多 **1** 处，且那 1 处是
   `wideGeomOk` 里的**比较符**（`(nCo <= 16'h0008)`），不是非阻塞赋值 ⇒ **无新触发器**。网表形状（新）：
   `assign wideCoRows = desc_2[31 : 16];`、`assign wideGeomOk = (((((desc_2[31:16] != 16'h0) && (nCo <= 16'h0008)) && …`；
   `wideWrBytes/wideWrWords` 的乘法源由 `nCo` 换成 `wideCoRows`（乘法器数量不变）。**本任务不跑 PDS。**

### 12.6 附：指纹

| 文件 | md5 |
|:--|:--|
| `y1/rtl/UnitExec.scala` | `193471759c09bfa8fc9a5c4bb63a03e9` |
| `y1/tools/run_wide_tail_ab.sh`（新） | `08b70cb1f73102b7af6d7b72742e38f5` |
| `y1/tools/run_wgtdma_geom_ab.sh`（锚点搬） | `4b2cf33dc3965a530570bd612ac67aa7` |
| `y1/gen/UnitExec.v` | `0c3560ff26deecc732b29dec6119d134` |
| `y1/gen/UnitExec_w32.v` | `c36cc79fdf3dfe6b9211a3c70134e862` |
| `y1/gen/LayerSched.v`（未改） | `bab5d79fbdba5f79ef3b70b33789b87b` |
| `y1/gen/NpuTop.v`（未改） | `57979041cacd76715194ddb2ac59cec4` |
| `y1/gen/wgt_blob.bin`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` |

---

## 13) ★★ C4b-C2（本任务）：宽通路的 **depthwise 对角趟调度**（2026-10-12）

**Status: DONE**（新闸门 `run_dw_wide_ab.sh` 全绿 + 负对照**定点**发火 + 2 条边界响亮 err；
真表 **17 个宽层 depthwise 单元**经**集成宽通路**（权重从 DDR 真 offset 装载）端到端逐字节 == 冻结
`wide_exec_ref` 黄金；回归 35/35 rc=0 + 台账 + 悬空 + 确定性 2×；PnR 待控制器重跑）

> ★★ **本轮最重要的实测结论是：§11.7-1 / §12.5-1 的那条"depthwise 数值不对"是**未测的假设**，实测为假。**
> 改动前的宽通路（`wCi == nCi-1` 收料 + 一般趟）在 17 个真宽层 depthwise 单元上**已经逐字节正确**
> （MISMATCH=0，见 §13.3-A）。原因是装载器的**零填充相位**把**非对角趟**整趟写成 0
> ⇒ 非对角趟对部分和的贡献**恰为 0** ⇒ "一般趟"与"对角趟"在整数加法下**逐字节等价**
> —— 这正是 C4a.6 在**单元级**证死的那条等价（`md5(DwUnit.v)==md5(MultiPassUnit.v)`），
> 本轮把它在**集成宽通路**上再测了一遍。⇒ **C2 不是"修数值错"，而是把集成宽通路接到 C4a.6 的
> 对角调度上**（结构/吞吐：`C=64` 从 64 趟降到 8 趟、输入列流少喂 8 倍；见 §13.1）。

### 13.1 为什么（口径澄清）与改了什么

| 口径 | 结论 |
|:--|:--|
| **"depthwise 端到端数值不对"** | **假**（实测）。改动前 17/17 `MISMATCH=0`；非对角趟的瓦片被零填充相位写成全 0 ⇒ 贡献恰 0 |
| **"集成宽通路没接到对角调度"** | **真**。改动前每层跑 `nCi*nCo` 趟、输入扇出 `nCo` 次；其中 `nCi-1/nCi` 的趟是**纯零权重空转** |
| **C2 做什么** | 把 `isDwW` 的几何切到 **C4a.6 的对角趟**（co-block `b` 只吃 ci-block `b`，一趟即成品），dense 一字不动 |

**改动（4 处，全在 `rtl/UnitExec.scala`；描述符格式/寄存器契约/blob/转换器一字未动）**：

| # | 改动 | 落点 |
|:--|:--|:--|
| 1 | **depthwise 判定** `isDwW = (GROUP!=0) && (GROUP==C_in) && (C_in==C_out)`（与装载器前提 `grpOkW` 的 depthwise 分支**同式**；单一真源） | `isDwW` |
| 2 | **偏置门** `(wCi==0) \|\| isDwW`：对角趟是该 co-block 的**唯一**一趟 ⇒ 必须带上本块偏置（`DwTb` 同口径；不改则 `b>0` 的 co-block 拿到 bias=0） | `wBiasR(co)` |
| 3 | **收料门** `wCollectCiOk = Mux(isDwW, wCi==wCob, wCi==nCi-1)`（dense 侧逐字沿用 C1） | `wCollect` |
| 4 | **换趟**：`isDwW` ⇒ 下一趟 = `(wCob+1, wCi=wCob+1)`，末 co-block 收工；dense 逐字沿用 C1。另：趟数自报 `wide_passes = Mux(isDwW, nCo, nCi*nCo)` | `wSt==4` / `io.wide_passes` |

★ **输入列流（对角口径）**：depthwise 的 `wide_x` = **输入喂一次**（`nCo` 块 × `H*W` 列 × 8 通道 =
`C*H*W` 字节）—— dense 的 `nCo` 倍扇出在这里被省掉。**这是一条对外列流契约的几何相关变化**（见 §13.6-2）。

### 13.2 判据（`tools/run_dw_wide_ab.sh`（新）+ `tools/dw_wide_ref.py`（新））

参考供料 `dw_wide_ref.py` **不重写算术**：黄金逐字复用**冻结** `tools/wide_exec_ref.py` 的 `build_one`
（§4.5-A `conv_acc` + `requant`，与 `run_unitexec_wide_ab.sh` / `run_wide_tail_ab.sh` 同一份黄金）；
新工具只做两件**数据布局**的事：① 把真 blob 的 depthwise **紧凑段**（`C_out*9` 字节）展开成**对角稠密**
`(C,C,3,3)`；② 把一般列流**裁**成对角列流（第一份）。

| 判据 | 期望 | 实测 |
|:--|:--|:--|
| **[0] 自检** | blob `aa135f0f…` + 真表 depthwise 20 个（宽层 17 / 非宽层 3）+ 宽层 distinct `C∈{10,16,32,64}` + 逐单元真 `offset/nbytes`（`nbytes==C_out*9`、32 B 对齐、段尾在窗内） | 全中（见闸门 `SELFTEST` / `UNIT` 行） |
| **[1] 正对照（逐字节）** | 每个真宽层 depthwise 单元：权重**从 DDR 真 offset 装载**（`+WBASE=BLOB_BASE+offset`，`+WFILE=` 全 0 自证）⇒ 对角趟跑完 ⇒ `DST` 区 **逐字节 == 黄金**；`WIDE_PASSES == nCo`（**对角趟数**）、`WR_BYTES == C_out*H*W`、`MEM rd == ceil32(nbytes)`、`WGT_BYTES == nbytes`、黄金非退化 | **17/17 `MISMATCH=0`**（`distinct` 63…256）；`C=64` ⇒ `PASSES=8`（旧口径 64）、`NCOL=2048`（旧口径 16384） |
| **[2] 负对照（必发火 + 定位）** | **网表突变** `wCollectCiOk := (wCi == nCi-1)`（= 改动前的收料门）⇒ 对角循环下**只有末 co-block** 收到料 ⇒ `MISMATCH>0`，且**末 co-block 段仍逐字节对** | 17/17 发火：`C=64` `MISMATCH≈14200/16384`（末段 `[14336..)` 错 **0**）；`C=32` `≈6117/8192`（`[6144..)` 错 0）；`C=16` `≈2032/4096`（`[2048..)` 错 0）；`C=10` `≈1987–2048/2560`（`[2048..)` 错 0）**首差异皆 @0** |
| **[3] 边界（真不支持仍响亮 err）** | `GROUP ∉ {1, depthwise}`（`C=64,GROUP=8`）/ `C_in==0` ⇒ `ERR_SEEN=1` 且 `WR_BYTES=0`、`RD_BYTES=0`（**零搬运**） | 两条 ✅（`DONE=0 ERR=1 … WR=0 RD=0`） |

### 13.3 关于任务书里的两条前置判断（**如实修正**）

**A. "真宽层 depthwise 经集成宽通路**数值不对**" —— 实测为假。**
把改动前的 RTL（提交 `58c0b54` 的 `gen/UnitExec.v`）用同一组真单元跑一遍：17/17 `MISMATCH=0`
（`C=16/32/64/10` 全中，含 `Conv_73/75/77` 三个尾块 depthwise）。§11.7-1 / §12.5-1 把它写成
"除最后一个 co-block 外不对"，**没有测**；它的推理漏了装载器的零填充相位会把非对角趟整趟写成 0。

**B. "负对照：强制改动前的 `wCi == nCi-1` 收料 ⇒ 红" —— 在*一般趟*下按字面**不会发火**（因为
  一般趟 == 对角趟，逐字节）；在*对角循环*下**会发火**（本闸门判据 [2] 就是它）。**
⇒ 判据 [2] 的负对照**必须与判据 [1] 的新调度配套**才有牙：它证的是"**对角循环 + 旧收料门 = 只有末
co-block 收料**"这条结构性事实，不是"非对角趟算错"（那件事本身不成立）。

### 13.4 ★ 真表"整帧可跑"计数（从 44/53 走向可达上界）

| 口径 | 数 | 说明 |
|:--|:--|:--|
| 真表 conv 单元（有权重） | **53** | — |
| 其中**宽层**（`isWide` = `C_in>8 ∥ C_out>8`） | **44** | 走集成宽通路（本闸门/`run_wgtdma_geom_ab.sh` 的对象） |
| **端到端逐字节证死**（改前） | **27/53** | 14（B1b 全 8 对齐 dense）+ 1（`Conv_0` `C_in=3`，B1c）+ 12（C1 dense 尾块） |
| **端到端逐字节证死**（本任务后） | **44/53** | **+17 个宽层 depthwise**（`C∈{10,16,32,64}`，含 3 个尾块 `Conv_73/75/77`） |
| **仍不可整帧跑** | **9/53** | `Conv_55/57/59/67/69/71`（`C=1` conv3x3）+ `Conv_61/63/65`（depthwise `C=4`）：**非宽层** ⇒ 走窄通路，而窄通路 `WeightStore` 是 8x8 固定形状 ⇒ **装不了**（§11.7-3，**未变**） |

⇒ **可达上界 = 44/53**，本任务把它**填满**（44/53 全部端到端逐字节）。剩下 9 个是**非宽层**，要它们
能跑得改**窄通路**（= 计算侧另一件事，控制器裁决）。

### 13.5 全回归（非 PDS）

| 检查 | 结果 |
|:--|:--|
| `y1/tools/run_*_ab.sh`（**35** 个自包含闸门，含新增 `run_dw_wide_ab`） | **全部 `rc=0`**（34 个既有 + `dw_wide`；`run_numeric_ab.sh` 是带参 helper，不在集合内） |
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop,MultiPassUnit,DwUnit}.v` | 全 `RESULT: PASS`（零悬空） |
| 网表确定性 2×（连续生成两次，md5 逐字节相同） | `gen/UnitExec.v fa5fed0f9436e647d08ac4073a48bdfa`、`gen/UnitExec_w32.v b461cc04ed7f7f758d635da1847e4bb0`、`gen/LayerSched.v 2b1eedab0b3de178868cbec0eb922b56`、`gen/NpuTop.v e087d4ff19d73262bd47ddb4c569c42d`；`gen/MultiPassUnit.v == gen/DwUnit.v == 76d2ca006baf1cea3fefe076d81ff2f3`（C4a.6 单元级等价**未破**）；`LayerSched`/`NpuTop` 因内含 `UnitExec` 实例而变（接口未动） |
| `gen/wgt_blob.bin` / `wgt_index.json` / `y1_convert.py`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` / `aea0916db7e81e3508cf6b180d624439` |
| `third_party/**` + 冻结工具（含 `wide_exec_ref.py`/`multipass_ref.py`/`DwTb.v`/`MultiPassUnit.scala`） | `git status` 无变化（`wide_exec_ref.py` 只被 `import`） |

### 13.6 诚实边界（本任务**未做**、明写）

1. **非宽层 depthwise（`C=4`，3 个真单元）**：`isWide` 为假 ⇒ 走窄通路（`WeightStore` 8x8）⇒ 装不了
   （§11.7-3，**未变**）。把 `C∈{1,4}` 并进宽通路会改 `isWide`（计算侧语义）⇒ 控制器裁决。
2. **★ depthwise 的列流契约随几何变短**：dense 仍是 `nCo*nCi*H*W` 列，depthwise 变成 `nCo*H*W` 列
   （**输入喂一次**）。这是**收益的来源**（省 `nCi` 倍喂列），也是**对主机/激活供料者的一条新契约**：
   "depthwise 单元的 `wide_x` = 自己那份输入按 ci-block 顺序喂**一遍**"。当前 `wide_x` 只由 TB 喂
   （真实激活"DDR→列流"的 gather 是 C4b/G6 项）⇒ 该契约**尚未被任何真实供料者消费**，本任务只在
   TB 层把它钉死（`dw_wide_ref.py` 产的就是这条流）。
3. **判定口径**：`isDwW` 用的是**描述符**的 `GROUP/C_in/C_out`（与装载器 `grpOkW` 同式）。
   `GROUP ∉ {1, depthwise}` 时 `isDwW=0` 且装载器前提假 ⇒ **IDLE 响亮 err + 零搬运**（判据 [3]），
   不会误入对角。
4. **吞吐**：对角趟把 depthwise 的趟数从 `nCi*nCo` 降到 `nCo`（`C=64`：64→8），但**不动**装载器
   （仍按几何装整段 + 零填充整个瓦片区）。装载与计算的**重叠**是 B2 项，**本任务不做**。
5. **RTL 改过 ⇒ 控制器要重跑 PnR**（`dev_map` + `pnr`）。**本任务不跑 PDS。**
   面积增量：`isDwW` 一个 3 项比较 + `wCollectCiOk` 一个 2:1 + `wSt==4` 一个 2:1 + `wBiasR` 的 D 端多一个
   `||` + `wide_passes` 一个 2:1 ⇒ **无新触发器**（都是组合选择）。

### 13.7 附：指纹

| 文件 | md5 |
|:--|:--|
| `y1/rtl/UnitExec.scala` | `c0bff19c59c613d1cf7d0cb46bad35be` |
| `y1/tools/run_dw_wide_ab.sh`（新） | `4d49bd8b877afc7a9bf27334dbfd7733` |
| `y1/tools/dw_wide_ref.py`（新） | `8918fcae4e0fc8565edb55120f70e9f3` |
| `y1/gen/UnitExec.v` | `fa5fed0f9436e647d08ac4073a48bdfa` |
| `y1/gen/UnitExec_w32.v` | `b461cc04ed7f7f758d635da1847e4bb0` |
| `y1/gen/LayerSched.v` | `2b1eedab0b3de178868cbec0eb922b56` |
| `y1/gen/NpuTop.v` | `e087d4ff19d73262bd47ddb4c569c42d` |
| `y1/gen/wgt_blob.bin`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` |

---

## §14 覆盖收尾 + PnR 收口（2026-10-12）—— **真网 53/53 单元全部可跑；时序未破**

**覆盖链（每片都有闸门 + 可发火负对照）**：
| 片 | 改什么 | 结果 |
|---|---|---|
| B1 | 窄路 DDR→`WeightStore` 装载（前置：修装载器 lane 跳字节 bug） | ✅ |
| B1b | 宽路趟瓦片 `wRam` 从 DDR 装载 | ✅ |
| B0 | blob 段按 **32 B 对齐**（用户裁决 ①；spec §4.2 修订）⇒ `DdrMaster` 契约满足 | ✅ 404,064 B（+288 padding） |
| B1c | 装载器几何覆盖真网形状（`C_in<8` 零填、depthwise 对角、`GROUP≠1`） | ✅ 装载 53/53 |
| C1 | 宽路**部分 co-block 尾部**（`C_out%8≠0`，15 个单元） | ✅ 可跑 29→44 |
| C2 | 宽路 **depthwise 对角趟序**（★ 前提被证伪：原故障是**未实测的假设**；旧 RTL 其实 17/17 `MISMATCH=0`，因为装载器的零填已让非对趟贡献 0 ⇒ 本片是**结构/吞吐**改进，passes 64→8） | ✅ |
| C3 | 路由改**几何判定**（只有真 8×8 走窄路），剩下 9 个 `C∈{1,4}` 单元进宽路 | ✅ **53/53** |

**★ PnR 收口（`tag=c4b_r1`，`pnr_c4a.tcl`）**：`Design Summary : All Constraints Met.`（**0 违例**）
```
cpu_clk  100 MHz → 110.558 MHz  +0.955
npu_clk   50 MHz →  53.039 MHz  +1.146
core_clk 125 MHz → 142.167 MHz  +0.966   rgmii 200.803 +3.020
```
比特流 `…/generate_bitstream/yeshen_mini_board_top.sbit` **9,188,552 B / md5 `33b2cba1a4f5b0c3bbccb4a20f5e0956`**。
⇒ **C1/C2/C3 的宽路 RTL 没有破坏时序**。

**诚实边界**：本轮只证"**权重装载 + 单单元在集成宽路里逐字节正确**"；**整帧**仍需 B2/B3/B6。

## §16 C4b 离线链路收口（2026-10-13）—— **PnR 全 MET；只剩 B6 上板**

后续各片（B4 布局适配 / D1+D1b stride≥2 / E1 `Add` 第二输入 / H1 `desc.bin` SRC 折进 / H2+H2b 内存图）
各自带可发火负对照、全绿。**PnR 最终轮**（`tag=c4b_r4`）：
```
cpu_clk  100 MHz → 108.731 MHz  +0.803
npu_clk   50 MHz →  55.176 MHz  +1.876
core_clk 125 MHz → 137.174 MHz  +0.710   rgmii 160.179 +1.757
Design Summary : All Constraints Met (0 violated)
```
比特流 `sim/reglogs/pds_pnr_c4a_c4b_r4_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`（9,188,552 B）。

**离"真帧上板"只剩 B6**（需用户时机）：① 写 H2b 的新 SD 镜像（`scripts/build_all.sh images,sdimg` → `sim/board/write_sd.ps1`）+ 重烧比特流；
② 跑 `y1/tools/npu_frame_run.py` 整帧，对 float ORT 容差（**离线预演**：IoU 0.887 ✓ / |Δconf| 0.0095 ✓ / 检出数差 0 ✓ / **关键点 L2 4.81px > 2px ✗**，属 spec §4.3 的校准口径项）；
③ 整帧 DDR 流量与帧时（C5 合账，含内存桥 beat-serialized 的 ≈4× 块拷贝代价）。

---

## §15 ★★ C4b-B2（本任务）：**逐层参数投递（M/z_pad/z_y/bias_adj）端到端 + 装载/计算重叠纪律**（2026-10-12）

**Status: DONE**（新闸门 `y1/tools/run_paramdel_ab.sh` 全绿 + 7×3 条负对照全发火 + 守卫受控实验发火；
回归 **36/36 rc=0** + 台账 + 悬空 + 确定性 2×；PnR 待控制器重跑）
「RTL + TB + gate」三件套：`rtl/UnitExec.scala`（**新增 `lidOk`**）+ `rtl_test/UnitExecWideTb.v`（**新增 `+DUMPB=` / `CYCLES=`**）+ `tools/run_paramdel_ab.sh`（新）。

### 15.1 ★ 真源裁决：**`M`/`z_pad`/`z_y`/`bias_adj` 的唯一真源 = `y1/gen/wgt_index.json` 的 `requant_mult` + `centering`**；**投递保留在权置信箱（区域 2/3/4/5、按 `LAYER_ID` 索引）**

**裁决**：**保留在信箱**（spec §4.4/§4.5 逐字钉的就是"排在权重 blob 之后、用**既有的 `WGT_ADDR/WGT_DATA/WGT_WE` 权置信箱**装载、用 `w7` 的 `LAYER_ID` 索引"，**描述符 8 字/寄存器契约一字未动**）。**不**改成"由 NPU 从 DDR 随权重段读回"。三条理由 + 两条等价证明：

| # | 理由 |
|:--|:--|
| ① | **§4.4/§4.5 的冻结口径就是信箱**：改成 DDR 侧读回 = **spec 级修订**（要改 §4.4 的投递句、要动 `UnitExec` 的装载器把参数段也读进来、要重跑 PnR）。本任务**不做**未获裁决的契约变更。 |
| ② | **不是逐像素量**：真表参数 = **67 个 `M` 字**（268 B）+ `53×2` 个 `z_pad/z_y` 字节 + Σ`C_out` 个 `bias_adj` 字 —— **每层一次**，与权重 blob（404 KB/帧）**不在一个量级** ⇒ 信箱带宽**不是**瓶颈。 |
| ③ | **"同源"落在同一份镜像上**：`wgt_index.json` 的 `mult.offset_in_mailbox == blob.bytes == 404064`（`M` **紧随** blob）、`fingerprints.mailbox_bytes == 404332 == len(blob)+len(mult)`、`mailbox_md5 == md5(blob ‖ mult)` ⇒ 权重与参数在**主机侧是同一份 `blob‖mult` 镜像**；差别只在**传输寻址**（区域 0/1 vs 区域 2/3/4/5）。 |

**等价证明**（闸门 [0] 离线 + [3] 在片回读，两条独立）：
1. **`M` 的每一个字**：`wgt_mult.bin` 的 67 个 LE 字 **==** `requant_mult` 顺序的 `M`（逐字节相等；`md5(wgt_mult.bin)=ff2ed3c6…`）；`mult.offset_in_mailbox == blob.bytes` 且 `md5(blob‖mult)==fingerprints.mailbox_md5`。
2. **冻结参考与真源同源**：`wide_exec_ref.build_real()` 的 `job.txt` 的 `M/ZPAD/ZY` **==** json（参考与转换器读的是同一份 json）；**硬件投递后按 `LAYER_ID` 回读** `RTL_M/RTL_ZPAD/RTL_ZY` **+** `biasReg` 白盒（`+DUMPB`）**+** 输出逐字节 == 由 json 生成的黄金（见 15.2）。

> B5（宿主整帧驱动，`tools/npu_frame_run.py:mailbox_writes()`）发的就是**同一份 json** 派生的区域 2/3/4/5 写序列（`region=2/3/4/5`、`[15:8]=LAYER_ID`），本任务把它**从"计划"升级为"被 RTL 回读证死"**（B5 标注"caliber 归 B2"的那一条就此收口）。

### 15.2 判据（`tools/run_paramdel_ab.sh`；7 个真 dense 单元，各用**真 `layer_id`**）

用例：`Conv_0(3→16)` / `Conv_2(16→16)` / `Conv_19(64→64)` / `Conv_54(64→1)` / `Conv_60(64→4)` / `Conv_55(1→1)` / `Conv_72(64→10)`；
权重经信箱 `WFILE` 喂（`+WBASE=0` ⇒ `MEM rd == 0`）⇒ **只测参数通路**；黄金 = **冻结** `wide_exec_ref.build_one`（与仓内宽路闸门同一份）。

| 判据 | 期望 | 实测 |
|:--|:--|:--|
| **[0] 自检** | json↔`wgt_mult.bin` 逐字、`mult`/`mailbox` 指纹、7 单元几何/段/参数完备（`z_pad==z_x`、`len(bias_adj)==C_out`、`layer_id ∈ requant_mult`） | 全中（`mult=268B ff2ed3c6`、`mailbox 404332B 151304d8`） |
| **[3] 参数 == json（逐单元、逐字）** | `RTL_M/RTL_ZPAD/RTL_ZY/RTL_LAYER` == json；`biasReg` 白盒前 `C_out` 字 == json 的 `bias_adj`（**逐字**），其余 == 0；`MEM rd == 0` | **7/7** `BIAS_BAD=0`（`BIAS_WORDS=64`）；`RTL_*` 全中；`MEM rd=0` |
| **[3] 数值端到端逐字节** | `DST` 区 == `gold.hex`（`MISMATCH=0`）、黄金非退化 | **7/7** `MISMATCH=0`（`distinct` 13…251） |
| **[4] 负对照 NC-M** | `M` **翻一位**（bit12）⇒ 输出**精确命中** `m12/gold.hex` **且** != 黄金 | **7/7** 命中 0、与黄金之差 **5…1795** |
| **[4] 负对照 NC-Z** | `z_pad + 1` ⇒ 精确命中 `zp1/gold.hex` **且** != 黄金 | **7/7** 命中 0、差 **4…1876** |
| **[4] 负对照 NC-B** | `bias_adj ≡ 0` ⇒ 精确命中 `gold_nobias.hex` **且** != 黄金 | **7/7** 命中 0、差 **256…16384** |
| **[5] 边界（新守卫）** | **窄几何**（8/8/G1）+ `LAYER_ID=64`（越界第一格）/`200` ⇒ `ERR_SEEN=1`、`WR_BYTES=0`、`RD_BYTES=0` | 两条 ✅（`DONE|ERR=0|1`、`WR=0 RD=0`）；**7 个真单元 `lid≤60` 全部正常** ⇒ **不误伤** |
| **[5b] 守卫是载荷（受控实验）** | 网表突变 `assign lidOk = (layerIdx < 8'h40);` → `1'b1` ⇒ `LAYER_ID=64` **不再 err 且真搬数据** | 突变体 `DONE|ERR=1|0`、**`WR_BYTES=2048`**（好网表 [5] 是 `0|1 / WR=0`） |

**负对照的构造**（**不改算术**）：三条预测都由**冻结** `wide_exec_ref.build_one` 生成 —— 只把 `spec` 里的一个字段改掉（`M ^ (1<<12)` / `z_pad+1` / `bias_adj≡0`）再跑同一个 `build_one`。⇒ "红"不是"随便红了"，而是**逐字节命中一条独立算出来的预测**（定位到**哪个单元、哪个参数**）。

### 15.3 ★ 装载/计算**重叠纪律**（G6 的"写明并实测"）：**裁决 = 不重叠（串行）；实测代价 = 单元周期的 11%–19%**

**裁决：层 `i` 的权重装载**不能**与本层计算重叠，也**不能**与层 `i−1` 的计算重叠** —— 三条结构性阻塞（可从 RTL/网表逐条指认）：

| # | 阻塞（非干扰条件**不满足**的原因） |
|:--|:--|
| ① | **单一 `DdrMaster` 主口**：权重 RD（`WGTLD/WGTRUN`）、激活 RD（`RDSTART/RDRUN`）、输出 WR（`WRSTART/WRRUN`）**共用**一个 `DdrMaster`（网表里 `layerSched_1.unitExec_1.ddrMaster_1` 唯一一份）；`rd_ready = wlTake || 激活读`（装载与激活读**抢同一根 ready**）。 |
| ② | **单一 `UnitExec` FSM**：状态 `IDLE→WGTLD→WGTRUN→RDSTART/WIDERUN→…→DONE` **严格串行**；`WGTRUN` 收工那一拍才进计算相位 ⇒ 本层"先装完再算"是硬约束。 |
| ③ | **单一在飞单元**：`LayerSched` 只在当前单元 `done` 之后才给下一个描述符 `go`（`RUNW`→`FETCHW`），且**权重段起点 = 表序前缀和**（`wgtPtrR` 每单元 `+= N_i`）⇒ 下一段的地址要等本单元记账完。 |

**受控实验（同一份 `x/w`，只切换 `+WBASE`）**：同一单元跑两遍 —— `+WBASE=0`（不装载，权重经信箱）=**纯计算**，`+WBASE=BLOB+off`（装载）=**串行装载+计算**；**两跑的 `DST` 都逐字节 == 黄金**（⇒ 装载没有改变数值，只是**时间**）。差值 = **串行装载的代价**：

| 单元 | 几何 | 装载跑 CYCLES | 纯计算 CYCLES | 串行装载代价 | 占比 |
|:--|:--|--:|--:|--:|--:|
| `Conv_0` | 3→16（含零填充 1152 拍） | 14029 | 12405 | **1624** | 11% |
| `Conv_19` | 64→64（64 趟） | 283643 | 243665 | **39978** | 14% |
| `Conv_54` | 64→1 | 33326 | 28093 | **5233** | 15% |
| `Conv_60` | 64→4 | 36225 | 29113 | **7112** | 19% |

**pass counts（重叠 vs 不重叠）**：**不重叠（现 RTL）4/4 逐字节 == 黄金**（`MISMATCH=0`、`RESULT: PASS`）；
**重叠 = 0/4 可实现**（现微架构下没有第二条通路，本任务**不造假**）。
**"若重叠"的上界**（不是模拟结果，是**计算**）：把装载完全藏进计算 ⇒ 省下上表的 1624…39978 拍/单元（**11%–19%**）。
**要真重叠必须同时满足（非干扰条件，本任务**未实现**）**：⑴ 权重**双缓冲**（第二套 `wRam`/`WeightStore`），否则下一段覆盖在用权重；⑵ 主口**按优先级仲裁**（激活读优先）且装载只吃**空闲拍** —— 从实测看，**装 1 字节/拍**的装载器会把主口占满（`Conv_19` 的 36864 B ⇒ 39978 拍），重叠的**真实收益被主口带宽封顶**（宽层的计算阶段不读 DDR、只有末尾 WR，才有一点空闲；窄层计算**一直读激活**，几乎没有）；⑶ 下一个描述符要在本单元 `done` **之前**取到（`DescFetch` 预取）；⑷ `bias_adj`/`M`/`z_pad` 表**按 `LAYER_ID` 索引** ⇒ **天然非干扰**（这一条**已经满足**，与 `lidOk` 一起把参数表钉成"按层寻址的独立资源"）。
⇒ 结论：**当前不重叠是"单主口 + 单 FSM"的直接后果，收益 11%–19%，改造成本是双缓冲 + 端口仲裁 + 描述符预取（另一档微架构任务）**。

### 15.4 RTL 改动（唯一一处）+ 全回归

**唯一 RTL 改动**：`rtl/UnitExec.scala` 新增 **`lidOk = layerIdx < PN_LAYERS`**，并把它并进 **`IDLE` 的 `go` 判定**与 **`runStart`**（两条同式）。
- **为什么**：参数表按 `LAYER_ID` 索引 ⇒ 越界会让"读到的参数"落到**别的层**（`mzRam` 512 B / `biasMem` 4096 字下标**回绕**）；此前**只有宽通路**被 `wideGeomOk` 里那一项挡住，**窄通路（信箱 / 窄 DMA）漏了这条** ⇒ **静默读到别的层的 `M`/`z_pad`/`z_y`/`bias_adj`**。现收敛到**一处**（头注释也改成指 `lidOk`）。
- **对真帧零影响**：53 个有权重单元 `layer_id ≤ 60 < 64`（`≥64` 的三个是旁路 `Sigmoid_109/117/125`，不进本单元的参数表）；既有闸门用的 `LID ≤ 8` 亦恒真。
- **净网表增量**：1 个 8 位比较（`layerIdx < 8'h40`）+ 两处 `&&`（无新触发器）。

| 检查 | 结果 |
|:--|:--|
| `y1/tools/run_*_ab.sh`（**36** 个自包含闸门，含新增 `run_paramdel_ab`） | **全部 `rc=0`**（`axilite_cdc / bypass / chain / convert / ddrcopy / ddrmaster32 / ddrread / ddrwrite / desc / dw / dw_wide / frame / fuse / fuse_head / fusionbuf / grouped / hostregs / irqrst_cdc / layout / linebuffer / macarray / mem_cdc / multipass / nonwide_wide / nputop / nputop_sched / paramdel / quant / sched / tiling / twoclock / unitexec / unitexec_wide / weightstore / wide_tail / wgtdma / wgtdma_geom / wgtdma_wide`） |
| `scripts/check_addr_map.py` | `PASS: address ledger consistent (16 sites reconciled)` |
| `check_dangling.py gen/{UnitExec,UnitExec_w32,LayerSched,NpuTop,MultiPassUnit,DwUnit}.v` | 全 `RESULT: PASS`（零悬空） |
| 网表确定性 2×（连续生成两次，md5 逐字节相同） | 见 §15.6 指纹表 |
| `gen/wgt_blob.bin` / `wgt_index.json` / `y1_convert.py`（**未改**） | `aa135f0f7d50780b7b13d9a1ba9c518a`（404,064 B）/ 未改 |
| `third_party/**` + 冻结工具（含 `wide_exec_ref.py`） | `git status` 无变化（参考只被 `import` / 当黄金用） |

**★ 既有闸门锚点跟着搬（`run_wgtdma_ab.sh` 的 J6，**先红后绿**）**：J6 的**合成**大作业（87×8 片链 + 1×5 片链 = 701 项）
原来把 `LAYER_ID` 取 `(lid+i) & 0xFF`（0..255）—— 真表**没有**这样的层，但**旧 RTL 的窄通路不查 `LAYER_ID`** ⇒ 当时无害。
新增 `lidOk` 后，J6 里 `LAYER_ID ≥ 64` 的项被**正确拦住** ⇒ 装置报 `本帧报了 err（不该报的作业）`、
`run_wgtdma_ab.sh` **先红**（rc=1，"作业 J6 装置未 PASS"）。修法：J6 的 `LAYER_ID` 改 `& 0x3F`（0..63；
该作业只测**权重装载的字节/落点**，`LAYER_ID` 与判据无关）⇒ **后绿**（J1/J1b/J2/J3/J4/J5/J6/J7/J9 全绿）。
**判据语义一字未变**（只搬"合成作业的 `LAYER_ID` 取值域"这一条前提）。

### 15.5 诚实边界（本任务**未做**、明写）

1. **depthwise 的参数投递**：本闸门的 7 个用例是 **dense（`GROUP==1`）**。depthwise 的 `wRam` 装载与数值已在 `run_dw_wide_ab.sh`（17 个真单元逐字节）证死，且其 `M/z_pad/z_y` 经同一信箱/同一 `LAYER_ID` 通路（同一条 `mzRam`/`biasMem` 代码）—— **但**"depthwise 单元的 `biasReg` 白盒逐字 == json"**没有**在本次单独跑（属**已知未跑**项，不是已知缺陷）。
2. **`M` 的负对照是"翻一位（bit12）"而不是"±1"**：实测 `M^1` 在多数真单元上**不改输出**（`M` 的 LSB 落在 `>>30` 之下）⇒ 用 bit12 才有牙（实测差 5–1795 字节）。这条"用哪一位"是**实测选出来的**，已写进闸门注释。
3. **重叠**：见 §15.3 —— **裁决不重叠**，`重叠 0/4 可实现`；11%–19% 是**串行代价**，不是"重叠后的收益"（收益被主口带宽封顶）。
4. **RTL 改过 ⇒ 控制器要重跑 PnR**（`dev_map` + `pnr`）：新增 1 个 8 位比较 + 2 处 `&&`。**本任务不跑 PDS。**
5. **上板（B6）仍要做**：本任务的判据是**网表级**（`gen/UnitExec.v` + 行为级内存模型）；**板级**的"宿主经 AXI-Lite 把 67 个 `M` 字 + bias 字逐拍写进信箱、NPU 按 `LAYER_ID` 取到"要在 **B6** 用真帧联调（Mailbox 时序 / AXI-Lite 带宽 / 与 `CTRL.start` 的先后）—— `npu_frame_run.py` 的 `mailbox_writes()` 已给出序列，但**没有**在板上跑过。

### 15.6 附：指纹（本任务）

| 文件 | md5 |
|:--|:--|
| `y1/rtl/UnitExec.scala` | `d64c60c50043bfcaaedbaff000a1a361` |
| `y1/rtl_test/UnitExecWideTb.v` | `95a7c17c49e65f4b12ffa542856e7b73` |
| `y1/tools/run_paramdel_ab.sh`（新） | `e2583319a0f076d2d13da9b36c345802` |
| `y1/tools/run_wgtdma_ab.sh`（J6 锚点搬） | `576b91bfd5ced3ddbe824619e4260405` |
| `y1/gen/UnitExec.v` | `de06ea0643b1e5d7c10cd3e2a1e19dc3` |
| `y1/gen/UnitExec_w32.v` | `c0d684619108b5d421d08d557e3fc146` |
| `y1/gen/LayerSched.v` | `f165e24b52fb57be7dbc6ab75d6da54c` |
| `y1/gen/NpuTop.v` | `d1fa4bdc7075d8d9a85577811f5537f6` |
| `y1/gen/wgt_blob.bin`（未改） | `aa135f0f7d50780b7b13d9a1ba9c518a` |
