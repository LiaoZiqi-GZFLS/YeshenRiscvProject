# W1：宽路 tile-WR 的 LOAD 相位流水化（2 拍/像素 → 1 拍/像素）

日期：2026-10-23。被测：`y1/rtl/UnitExec.scala` 的 **宽路 tile-WR 小 FSM**（`wtSt==1` 的 LOAD 相位）。
结论：**conv15 作业周期 7,876,639 → 6,187,039（−21.4%），数值逐字节不变**。板级 A/B 见 §5（待填）。

---

## 1. 先钉死 "LOAD 到底花多少拍"

上一轮遗留的问题：`PHASE2 wt_load=3,379,200 / wt_stream=921,600`（conv15 作业，总 7.88M 拍），
但当时把分母记成了"字"，得出 "16.5 拍/字" 这个**无法解释的数**。本轮先把口径钉死：

- 一个"段" = 一个 `(co, tile 行)` 的 32 B 对齐 burst。
- conv15（160×160、C_in=32、C_out=64、tile 32×32、`tTw=32`）：25 tile × 32 行 × 64 co = **51,200 段**。
- `3,379,200 / 51,200 = 66.0`、`921,600 / 51,200 = 18.0` —— 两个**整数**。

对照 RTL（改前）：

```
is(1) { when(!wtLdS) { wtLdS := True }            // 拍 A：只翻相位，不干活
        .otherwise { wtLdS := False              // 拍 B：落一个像素 + wtK++
                     when(wtK < tTw) {...} .otherwise {→STREAM} } }
```

⇒ 每像素 2 拍（`readSync` 晚一拍，地址/数据必须错开），32 像素 = 64 拍，
再加收尾 2 拍 = **66 拍/段**，与实测**逐拍吻合**。所以 LOAD 不是异常，它是
"设计上的 2 拍/像素" 直接把整条写回通路的 75%（66/84）钉成了非 DDR 时间。

## 2. 改动（12 行，行数中性，`if (TILING)` 门）

地址每拍发一个、数据晚一拍落一个 —— 两级流水：

```
if (TILING) { when(!wtLdS) { wtLdS := True; wtK := 1 }        // 第 1 拍：发像素 0 的地址
  .otherwise { wtRowB((wtK-1).resize(5)) := wtByte             // 之后每拍：落上一拍的数据 + 发下一个地址
               when(wtK === tTw) { →STREAM } .otherwise { wtK := wtK + 1 } } }
else { ...原文逐字... }
```

- 每段 LOAD：66 → **33 拍**（32 + 1）。
- `wtLdS` 变成"数据有效"电平（进 LOAD 后置 1，`done` 时清 0），不再每拍翻转。
- 越界读：`wtK==tTw` 那一拍地址指向"下一行像素 0"（`wtQ·32+32 ≤ 1024 < PIXW=1088`），
  数据丢弃 ⇒ 不改 `wtRdAdr`（不与 TILING=false 的地址锥纠缠）。
- `TILING=false`：走 `else` 原文；源码**行数不变**（`git diff --numstat` = 7/7）。

## 3. 判据（conv15 作业，`/tmp/.../conv15`，GEXP=924,800）

| 项 | 改前 | 改后 | 判据 |
|---|---|---|---|
| `CYCLES` | 7,876,639 | **6,187,039** | −21.4% |
| `wt_load` | 3,379,200 | **1,689,600** | == 51,200 × 33（模型逐拍命中） |
| `wt_stream` | 921,600 | 921,600 | 一字未动 |
| `MISMATCH`（DST vs 冻结黄金） | 0 | **0** | 逐字节 |
| `NEIGHBOR_BAD`（DST 前后 32 B） | 0 | **0** | 不越界 |
| `GATHER_BYTES / GB_OK` | 924,800 / 1 | 924,800 / 1 | 输入读计数不变 |
| `RESULT` | PASS | **PASS** | — |

改前 `CYCLES` 由"改后实测 + 保存的 33 拍/段 × 51,200"回算（= 7,876,639），与上一轮记录的 7.88M 一致。

## 4. `TILING=false` 中性证据（不是"我觉得等价"）

同一份源码分别生成到两个目录（`build/wr_slice/base_tfalse` 由 HEAD 源码、`new_tfalse` 由本轮源码）：

- **HEAD 源码生成的 `UnitExec.v / _w32 / _w640` 逐字节等于冻结三元组**
  `7593b189 / 817ab5bb / 5d2cd81a`（⇒ 冻结三元组就是 HEAD 产物，可复现）。
- 本轮源码生成的差分**只有 2 个标识符改名**（SpinalHDL 匿名信号按**语句所在行**命名，
  else 支的 `when` 因与 `if (TILING)` 同行而落到 l2463）：
  `when_UnitExec_l2459→l2463`、`_zz_when_UnitExec_l2462→l2463_1`。**逻辑零变化**（12 行 diff，全为名字）。
- 因此 `gen/UnitExec.v / _w32 / _w640` 保持冻结三元组（从 `build/wr_slice/base_tfalse` 还原），
  六个闸门的 md5 锚不动；`gen/UnitExec_tiled.v` 换新：`f01da4da → 645d16fd`。
- 产品网表 `gen/NpuTop.v`（内联 `UnitExec`，TILING=true）已重生成：`af39c4d5`（含 `wtLdS` 新流水）。

## 5. 回归 / 面积 / 时序 / 板级

**闸门（都对 `gen/UnitExec_tiled.v = 645d16fd` 跑）**
- `run_b1_tilebuf_ab.sh` → **RESULT: PASS / B1_RC=0**
  （conv15 逐字节 0 错 + `GATHER_BYTES=924,800`；c64_40 3×3 逐字节 0 错 + 123,904；
  负对照 `b1_play=0` 照旧发火：数值仍对、`gather_bytes` 回到 8×）。
- `run_b2_halo_ab.sh` → **RESULT: PASS / B2_RC=0**
  （c64_40x40 / c16_160x160 / **dw16_80x80** / **s2_3x16** 四档逐字节 0 错；负对照 `b2_hit=0` 发火；
  G7 CYC 标定 −3.9% 与本次改动无关，是 B2 halo 的既有口径）。
  ⇒ 覆盖了 `tTw=32 / tTw=8 / tTw=16` 三种 LOAD 长度与**非 0 `wtS0`（64 B burst）**。

**面积（dev_map，tag `video1wr`，speed）**：LUT **82,985.5（52%）**、FF **114,733（36%）**、
DRM **273（66%）**、APM **263（36%）** —— 本改动不加寄存器，与改前同量级。

**时序 / 比特流（PnR，tag `video1wr`，seed 0）**：**All Constraints Met**；
`yeshen_mini_board_top.sbit` 9,188,552 B，md5 `4295b8d44943770c3abf981a4480f735`。

**板级 A/B（2026-10-23，已做）**：基线 = `video1p5` 的帧 RUN **2,074.4 ms / 12-12 CRC**。
烧 `video1wr`（sbit md5 `4295b8d4`，启动 8/8 marker PASS）后：

| 指标 | 基线 `video1p5` | `video1wr`（W1） | Δ |
|---|---|---|---|
| `y1run --frames 1` RUN | 2,074.4 ms | **1,770.7 ms** | −303.7 ms |
| `y1run --frames 3` 稳态 | — | **1,770.98 / 1,771.24 / 1,771.20 ms** | **−303.2 ms，−14.6%（1.171×）** |
| 数值 | 12/12 CRC | **12/12 CRC**（每帧 `outputs=12/12`） | 不变 |
| 退出 | `Y1RUN: PASS` | **`Y1RUN: PASS frames=3 pass=3 fail=0`** | — |

⇒ **保留**（判据 ≥5%，实测 −14.6%；数值零回归）。
★ 口径：板上 `y1run` 的 RUN 含 NPU 之外的同一条驱动路径，A/B 两侧同卡同表同输入 ⇒ 差值可归因到 W1。
★ 屏：本轮卡内 payload 只有 `y1run`（无 `y1cam`），**没有做目视复核**；视频/叠加通路本次未改一根线。


## 6. 下一步（不依赖 owner 契约的剩余空间）

- `wt_stream` 的 18 拍/段 = 1（start）+ 4×2（攒拍）+ ~9（等 `done`）。攒拍可做到 1 拍/拍；
  `done` 等待要靠**双缓冲 + 段间重叠**（LOAD 下一段与 STREAM 本段并行）才能吃掉。
  LOAD 已降到 33 拍，重叠后单段可望 ≈ 33 拍（现在是 51）⇒ 再省 0.92M 拍（≈15%）。
- 这需要第二份 `wtRowB` 与"下一段几何"预计算（行内新增寄存器用**行尾分号**挂到既有声明行，保持行数中性）。
