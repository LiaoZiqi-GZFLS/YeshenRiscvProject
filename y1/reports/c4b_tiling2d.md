# Y1-C4b / **T-S0** 报告 —— **2-D tiling（64×32）+ halo == 整层**的离线逐字节证明（**零 RTL**，钉 halo 规则）

- 日期：2026-10-14
- 上游：spec `docs/superpowers/specs/2026-10-13-y1-runtime-width-and-tiling-design.md`
  （§2 缓冲随 P=W×H 放大 / §3 方案 C（2-D 64×32 tile + 运行期 `rowW`）+ halo / §3.1 `rowW` 改法 / §5 **T0**）。
- 工具：`y1/tools/tiling_ref.py`（**扩展现有 C4a.4 工具**，不写第三条参考）+ 新闸门 `y1/tools/run_tiling2d_ab.sh`。
- 范围：**Python only、零 RTL、零 PDS**；`third_party/**` 与冻结工具（`quant_ref`/`bypass_ref`/`ddr_traffic`/…）**只 import，未改**。

**Status: DONE（闸门全绿，负对照全发火，发火证据齐）**

---

## 0) 交付物

| 文件 | 说明 |
|:--|:--|
| `y1/tools/tiling_ref.py` | **扩展**：新增 2-D tiling + halo 段（`TH2D=32`/`TW2D=64`、`tiled_conv`、`tiled_maxpool`、`tiled_resize2x`、`tiled_add`、`selftest2d`、`gate2d`、`traffic2d`）；**原 C4a.4 拆趟判据一字未动** |
| `y1/tools/run_tiling2d_ab.sh` | 新闸门：`--selftest2d` + `--gate2d` + 3 条发火注入；退出 0/1/2/3；单 `RESULT:` 行 |
| `y1/reports/c4b_tiling2d.md` | 本文件 |
| `y1/gen/c4b_tiling2d_gate.log` | `--gate2d` 全量输出（生成物，gitignore） |

复现（全仓唯一可用 Python 组合）：
```bash
cd y1
PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  <py> tools/tiling_ref.py --selftest2d
PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  <py> tools/tiling_ref.py --gate2d
bash tools/run_tiling2d_ab.sh          # 综合闸门，退 0
```

---

## 1) **halo 规则（逐字，RTL 可照此实现）**

> **输出平面 `Ho×Wo` 按 `TH=32` 行、`TW=64` 列切 tile**（tile 起点 `(oy0,ox0) = (32i, 64j)`）。
> 每个 tile 的**输入窗口** = 该 tile **全部输出像素的精确感受野**（左闭右开）：
> ```
> iy = [ sh*oy0 - pt ,  sh*(oy1-1) - pt + KH )      # oy1 = min(oy0+32, Ho)
> ix = [ sw*ox0 - pl ,  sw*(ox1-1) - pl + KW )      # ox1 = min(ox0+64, Wo)
> ```
> 其中 `KH,KW` 是核高宽，`sh,sw` 是 stride，`pt,pl,pb,pr` 是 pad（ONNX `pads`）。窗口**越界处取该算子的
> pad 值**：conv / depthwise 补 `z_x`（中心化后即补 **0**）。窗口做出来后**用冻结参考在窗口上算**，
> 再把每 tile 输出写回 `out[oy0:oy1, ox0:ox1]`。

**逐族展开（真表实际用到的情形）：**

| 族 | 核/stride/pad | 输入窗口 | halo |
|:--|:--|:--|:--|
| conv3x3（s1,p1） | k3,s1,p1 | `[oy0-1, oy1+1) × [ox0-1, ox1+1)` | **上/下/左/右 各 +1 像素** |
| depthwise 3x3（s1,p1） | k3,s1,p1 | 同上 | **±1** |
| conv3x3 **stride 2**（仅 `Conv_0`） | k3,s2,p1 | `[2*oy0-1, 2*oy1) × [2*ox0-1, 2*ox1)` | **下/左 +1、上/右 +0**（非对称；因 `KH-1-pt-s = 0`） |
| conv1x1 | k1,s1,p0 | `[oy0, oy1) × [ox0, ox1)` | **0** |
| maxpool 2×2/s2 | k2,s2,p0 | `[2*oy0, 2*oy1) × [2*ox0, 2*ox1)` | **0**；**tile 输入边必须偶数对齐**（32/64 全偶 ⇒ 满足） |
| resize ×2 nearest | — | `[oy0/2, oy1/2) × [ox0/2, ox1/2)` | **0**；**输出 tile 边必须偶数对齐**（32/64 全偶 ⇒ 满足） |
| add | 逐点 | `[oy0, oy1) × [ox0, ox1)` | **0**；**第二操作数必须与第一操作数同一 tile 网格** |

**内点 tile 的 halo 字节放大**：`(TW+2)(TH+2)/(TW·TH) = 66·34 / 2048 = 2244/2048 = 1.095703`（+9.57%）。
（边界 tile 的 halo 一侧落在图外 = pad，不额外读；平均放大 ≤ 1.0957，见 §5。）

> 说明：设计 §3 把 conv3x3 / dw3x3 的 halo 概括为"±1 行 ±1 列"——对 **s1** 精确成立；`Conv_0` 是
> stride 2，精确感受野给出**非对称** halo（下/左 +1、上/右 +0），本报告以**精确感受野公式**为准（RTL 按公式实现即可，无需分支）。

---

## 2) 覆盖（真表 27 个有 halo 的项 + 旁路族）

`--gate2d` 对 spec §3 列出的 **27 个 `desc.bin` 下标**逐项跑 `tile(+halo) == 整层`。分类：

| 类别 | 项数 | 代表（`idx/名/几何`） |
|:--|--:|:--|
| conv3x3 **s1** | 6 | 38 `Conv_55` 1→1 80×80、40 `Conv_57` 1→1 40×40、42 `Conv_59` 1→1 20×20、50/52/54 `Conv_67/69/71` |
| conv3x3 **s2** | 1 | 0 `Conv_0` 3→16 640×640→320×320 |
| depthwise/分组 3x3 **s1** | 20 | 2 `Conv_3`(16ch,320)、5/7/9/11(160)、14/16(80)、19/21(64ch,40)、24/26/28(64ch,20)、32 `Conv_46`(40)、36 `Conv_52`(80)、44/46/48 `Conv_61/63/65`(4ch)、56/58/60 `Conv_73/75/77`(10ch) |
| **合计** | **27** | **27/27 `MISMATCH=0`（逐字节）** |

**旁路 / 0-halo 族**（`--gate2d` 全量，几何取自真表 / ONNX）：

| 族 | 项数 | 结果 |
|:--|--:|:--|
| conv1x1 | **26**（全部） | `MISMATCH=0` |
| maxpool 2×2/s2 | **4**（`MaxPool_5/18/25/32`） | `MISMATCH=0` |
| resize ×2 | **2**（`Resize_43/49`） | `MISMATCH=0` |
| add | **2**（`Add_44/50`） | `MISMATCH=0` |

> **未覆盖 / 说明**：`Sigmoid`（`Sigmoid_85..125`，逐元素、0 halo）本步**没有**纳入 `gate2d`（其数值判据在 C3.7/旁路闸门；对本步的 tile/halo 结论无增量——它是纯逐点、无几何）。
> `Concat` 未出现在本模型的载荷序里。
> 旁路族的数值黄金来自冻结 `bypass_ref`（整层参考）；输入用其**非平凡向量**生成器（`nontrivial`/`add_nontrivial`），
> 几何（`C/IMG_W/IMG_H`）来自真表 / ONNX。

**正对照总判**：`GATE2D_TOTAL positive_mismatch=0  halo_ok=27/27  bypass_ok=8  guard_bad=0`
（`guard_bad` = 整层参考 != 黄金 / 输出为常数 的计数，均为 0）。

---

## 3) 判据证据（正对照 + 三条负对照 + 定位 + 发火）

### 3.1 正对照
`tile(+halo) == 整层` 逐字节，27/27 + conv1x1 26 + 旁路 8 全 `MISMATCH=0`。
小张量自检（`--selftest2d`）另有 **int32 恒等式**：把每 tile 的累加平面拼回 == 整层 `int32 acc`（逐项相等）。

### 3.2 负对照 ①：**不给 halo ⇒ 接缝**（必发火、且**定位**）
27/27 全部发火；**错配点 100% 落在 tile 的边界环上**（`边界环占比=1.00`），即"接缝"而非随机误差。
**定位**（`--gate2d` 打印 `tile(i,j) 局部(r,c) 全局(y,x)`）示例：

| idx / 层 | 首错 tile（局部→全局） | 无 halo 变点数 | 边界环占比 |
|:--|:--|--:|--:|
| 0 `Conv_0`（s2） | `tile(0,1) 局部(0,0) 全局(y=0,x=64)` | 4097 | 1.00 |
| 2 `Conv_3` | `tile(0,0) 局部(0,63) 全局(y=0,x=63)` | 8176 | 1.00 |
| 19 `Conv_27`（40×40） | `tile(0,0) 局部(31,0) 全局(y=31,x=0)` | 80 | 1.00 |
| 24 `Conv_34`（20×20） | `tile(0,0) 局部(0,9) 全局(y=0,x=9)` | 76 | 1.00 |

（20×20 与 40×40 层在 **64×32** 网格下不足 2 个 tile（前者 1 tile、后者 1 列 tile），单 tile 无接缝 ⇒ 这两类
在**更细的 `ctl_tile = (min(32,Ho/2), min(64,Wo/2))`** 网格上引爆负对照——**halo 规则与 tile 尺寸无关**，
故合法；`--gate2d` 里 "无 halo" 负对照统一走 `ctl_tile`，正对照走冻结 **64×32**。）

### 3.3 负对照 ②：**MaxPool tile 边奇数偏移**（必发火、且定位到该 tile）
把 tile 的输入窗口整体偏移 **1 像素（奇）** = tile 边的相位没偶数对齐：

| idx / 层 | tile 网格 | 奇数偏移变点 | 首错位置 |
|:--|:--|--:|:--|
| 3 `MaxPool_5` | 64×32 | 237568 | `tile(0,0) 局部(0,0)` |
| 12 `MaxPool_18` | 40×32 | 307200 | `tile(0,0)` |
| 17 `MaxPool_25` | 20×20 | 76800 | `tile(0,0)` |
| 22 `MaxPool_32` | 10×10 | 16000 | `tile(0,0)` |

（与"无 halo 只在接缝"不同，奇数偏移是**相位错**：整块 tile 的配对全错 ⇒ 边界环占比只有 0.10–0.36，
其余在 tile 内部 —— 这正好区分"接缝类"与"相位类"两种错。定位仍**精确落在被偏移的 tile** 上。）

### 3.4 发火证据（判据有牙；`run_tiling2d_ab.sh` 自动断言）
| 注入 | 期望 | 实测 |
|:--|:--|:--|
| `--inject2d tile-drop`（漏一趟：不写最后一个 tile） | rc=1、正对照红 | **rc=1，`positive_mismatch=27`** |
| `--inject2d halo-nofire`（抑制"无 halo"负对照） | rc=2、`neg_nofire>0` | **rc=2，`neg_nofire=27`** |
| `--inject2d misalign-nofire`（抑制奇数偏移/错网格负对照） | rc=2、`neg_nofire>0` | **rc=2，`neg_nofire=8`** |

---

## 4) `Add` / `SRC2` 问题（**实验答案**，不是意见）

**问题（spec R3，标注"未证"）**：`Add` 的第二操作数（`SRC2`）在 tile 调度下**能否按"某个先算子的 tile"寻址**？

**真表事实（`gen/desc.bin` 逐字读，非本工具编）**：两个 `Add` 的 `SRC2_K`（`w3[31:16]`）**都 = 1**，
生产者是**同一 tile 网格**的输出：

| Add | idx | `SRC2_K` | 生产者 = 表序 `idx-K` | 生产者输出几何 | 与 Add 同网格 |
|:--|--:|--:|:--|:--|:--|
| `Add_44` | 30 | 1 | `Resize_43`（idx 29） | (1,64,40,40) | **是** |
| `Add_50` | 34 | 1 | `Resize_49`（idx 33） | (1,64,80,80) | **是** |

**实验（真几何 C=64，40×40 与 80×80）**：
- **B 按"生产者同一 64×32（或其细分）tile 网格"取** ⇒ `tiled_add` 拼回 == 整层，**差 = 0**（逐字节）；
- **B 按"错网格"取**（窗口平移 1 像素）⇒ **必红**：`Add_44` 变 47400 点、`Add_50` 变 189600 点。

**答案**：**能**。因为 `Add` 是**逐点**算子、两路几何相同，只要**生产者与消费者用同一张 tile 网格**（本方案的
全局 64×32 网格对所有算子一致），`SRC2` 的 tile `(i,j)` 与第一路的 tile `(i,j)` **就是同一块矩形**——第二操作数
可以直接按"先算子的 tile"寻址。**结论**：R3 风险在**几何层面不成立**（两条真实 Add 的生产者均为同网格的
`Resize` 输出）。**代价/前提**：需要保证 `SRC2` 指向的生产者也走**同一 tile 循环**（本方案统一网格已满足）；
若将来某生产者用**不同 tile 原点/分辨率**，则该结论失效（实验里"错网格"一档即为反例）。

---

## 5) DDR 流量 delta（离线，caliber 明示）

**基线（冻结 `ddr_traffic.py`，策略 `fuse_both`，可跑，逐层和自证）**：
`SUM = 12,576,000 B = 12.576 MB/帧`（十进制）—— 与设计 §3 的 **12.58 MB** 一致。

**halo 放大**（本工具精确算出）：内点 tile halo 因子 `= 66·34/2048 = 1.095703`。
真表 **27 个 halo 层的输入平面字节和** `Σ in_bytes = 8,300,832 B`（逐层取 `wgt_index.json` 的 `in_bytes`）。

**设计口径（= 对 27 个 halo 层的整输入平面都按 halo 放大）**：
```
delta = 8,300,832 × (1.095703 − 1) = 794,416 B
total = 12,576,000 + 794,416 = 13,370,416 B = 13.370 MB/帧   (+6.32%)
```
⇒ **复现设计 §3 的 13.37 MB / +6.3%**（本工具 `TRAFFIC2D` 行逐字打印）。

**更精细的口径（融合感知，作为 refinements，供 S1/S2 记账参考）**：
在 `fuse_both` 下，27 个 halo 层里**只有 `Conv_0` 的输入（整帧 640×640×3 = 1,228,800 B）真从 DDR 读**
（其余 halo 层的输入被融合上游，`bytes_in=0`）。若 tiling **不破坏融合**（halo 从**片上**生产者的
邻行取），则
```
delta = 1,228,800 × 0.095703 = 117,600 B  ⇒  total ≈ 12.694 MB/帧  (+0.94%)
```
**caliber 说明**：**13.37 MB（+6.3%）是保守上界**（假设 halo 层的输入一律回 DDR 读，不给融合留面子）；
**12.69 MB（+0.94%）是"融合缓冲区能提供跨 tile 邻行"的乐观下界**。真实值在两者之间，取决于
`FusionBuf`（今天仅 3 行窗口，`FusionBuf.scala`）能否在 tile 边界为下一 tile 保留 ±1 邻行——
**这属 S2 的实现选择，本步不证**。两者都 **< 预算 27.59 MB/帧**（2× 余量）。

---

## 6) **未能验证 / 开口项**（诚实记账）

1. **halo 的物理取法**（spec §4.2）：本步只证**算术等价**（窗口内容对），**不证** RTL 怎么 gather
   （"行跨步窗口读 / pitch `rowW·C`"是新 RTL，今天 gather 走线性平面 `UnitExec.scala:1300-1362`）。属 S2。
2. **`SRC2` 的物理寻址**（§4）：本步证"**几何上**同网格可寻址"，**未**证 DDR 里第二路的地址生成/对齐/拍数。
3. **融合是否跨 tile 提供 halo**（§5 的 12.69 MB 口径前提）：未证；`FusionBuf` 深度是承重项。
4. **`Sigmoid` / `Concat`** 未纳入 `gate2d`（`Sigmoid` 逐点无几何；`Concat` 不在载荷序）。
5. **`W_MAX=66` / `H_TILE=32` 的器件占用**（spec §3.1/T2）：属 RTL dev_map，本步零 RTL。
6. **行宽 `rowW` 的运行期重放**（spec T1）：属 S1 RTL，本步不涉及。

---

## 7) 判据清单（`run_tiling2d_ab.sh`，单 `RESULT:` 行）

```
[0] --selftest2d          : PASS（6 形状正对照逐字节 + int32 恒等式 + 三条负对照发火）
[1] --gate2d 正对照        : PASS（halo 27/27 + conv1x1 26 + 旁路 8；MISMATCH=0；整层参考==黄金）
    --gate2d 负对照        : PASS（无 halo 接缝 27/27 发火且定位到 tile 边；maxpool 奇数偏移 4/4；add 错网格 2/2）
[4a] --inject2d tile-drop  : rc=1（positive_mismatch=27）
[4b] --inject2d halo-nofire: rc=2（neg_nofire=27）
[4c] misalign-nofire       : rc=2（neg_nofire=8）
RESULT: PASS
```

退出码语义：`0` 全绿 / `1` 判据红（`positive_mismatch>0` 或整层参考 != 黄金）/ `2` 负对照没发火（判据无牙）/ `3` 前置缺失。
