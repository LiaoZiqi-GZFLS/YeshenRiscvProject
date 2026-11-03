# Y1-C4b-F1 —— 大映像走网络投递 + 整帧上板（B6 的前置）

**结论一句话**：**投递通路建成并逐块回读验过**（1.2 MB input / 404 KB 权重信箱 / 2.1 KB 描述符表
全部整块 md5 对上，7290 条信箱寄存器写一次会话投完）；整帧**确实起跑了**，但**跑不动**：
`CTRL.start` 之后 NPU 在第一项描述符就报 `errSticky`（**零搬运**），根因**不在投递、不在表**，
而在**比特流里的网表几何**——`LayerSched`/`UnitExec` 是按 C3 的**定点用例**（`C=8, WIDTH=32,
IMG_H_MAX=16`）生成的，而真帧第一层的描述符是 `IMG_W=320, STRIDE=2` ⇒ 单元的行宽对账
`inWOk` 直接否掉 ⇒ **响亮 err**（这正是 RTL 的设计意图：宁可红，不做静默错值）。

因此 **12 路输出与 G7 容差比较本轮拿不到**（见 §6 的"n/a + 为什么"）；G7 的**离线**预报值
（同口径 int8 vs float ORT）见 `run_frame_ab.sh` 的记录，本轮不重复。

---

## 0. 交接摘要（谁改了什么）

| 文件 | 动作 | md5 |
|---|---|---|
| `y1/tools/ddmem.c` | **新**：板内 mmap 式 `/dev/mem` 搬运器（`wr`/`rd`/`mb`） | `83e96244514062ba346a9442ee05c3eb` |
| `y1/tools/build_ddmem.sh` | **新**：交叉编 ddmem（buildroot rv32 gcc，`-static`） | `46d9fbef2c1179de060d55c2a9d78d03` |
| `y1/tools/npu_frame_run.py` | **改**：`--xfer net` 真实现 + 补 `wgt_mailbox` 投递 + 同口径反量化 + 冻结表逐字节搬 | `84858d47b7876e9c072d9d70c14dbb0b` |
| `scripts/board_ssh.py` | **新**：WSL+askpass+压 KEX 的**带外** ssh/scp 唯一入口 | `cd1748629ebd31db85b426282710e01c` |
| `scripts/board_ddr.py` | **新**：分块投递 + 逐块/整块双层回读校验 + 信箱成批投递 | `2b7330d2acbf57b30aef4971d992821d` |
| `y1/reports/c4b_frame.md` | **新**：本报告 | — |

（板内二进制 `y1/build/ddmem_rv32` = 66804 B，md5 `4d42cf4d8608d5356e2c75ad544b2cf5`；`y1/build/`
在 `.gitignore` 里，按 `build_ddmem.sh` 一条命令可重建。）

冻结件（`ddr_traffic.py` / `fusion_buffer.py` / `bypass_traffic.py` / `mac_ref.py` / `bypass_ref.py` /
`conv_unit_ref.py` / `desc_table.py`）与 `third_party/**` **一字未动**（`git status` 可证）。
B5 闸门 `run_frame_ab.sh` 在本改动后**复跑 PASS**（§5）。

---

## 1. 为什么必须发明一条非 UART 的通路（实测口径，不是推测）

C4b-B5 的 `do_run` **无论 `--xfer` 是什么**都走 `_devmem_words`（板内 `devmem` 逐 word）。三笔账：

| 映像 | 体量 | UART 逐 word 的代价（`Board.send` 是**逐字符 10 ms**，C3 定下的串口纪律） |
|---|---|---|
| `input_int8` | 1.2 MB = 307200 word | 直接撞 R5 守卫（`--uart-word-limit=4096`）⇒ **被拒** |
| `wgt_mailbox` | 404332 B = 101083 word | 同上，被拒 |
| `desc_table` | 2176 B = 544 word | "安全"档，但 544×2 条命令 ≈ **42 KB 命令行 ⇒ ~7 分钟** |
| 权重信箱寄存器 | 7290 条（每条 3 个 `devmem`） | ≈ **925 KB 命令行 ⇒ ~2.6 小时** |

⇒ UART 逐字路径对**整帧**是死的（不是"慢"，是"不可行"）。R5 守卫本身没错，错的是"没有第二条路"。

**★ 顺手证伪了任务书里设想的 `dd` 写法**（这条值得记下来）：

```
$ dd if=/tmp/pat.bin of=/dev/mem bs=4096 seek=$((0x801F0000/4096)) conv=notrunc
Segmentation fault        (rc=139)
[  1118.896083] Unable to handle kernel paging request at virtual address be1f4000
[  1118.904718] Oops [#3]
[  1118.907499] CPU: 0 PID: 221 Comm: dd Tainted: G      D           5.10.1 #2
[  1118.978087] status: 00040120 badaddr: be1f4000 cause: 0000000f
```

根因（不是"没对齐"，也不用猜）：riscv32 的 `/dev/mem` **read/write 系统调用**走
`xlate_dev_mem_ptr(p) = __va(p)` 的**线性映射**换算，而 H2b 之后内存节点从 phys `0x8200_0000`
起（`/proc/iomem` 只有 `82000000-8fffffff : System RAM`）⇒ 凡是 `phys < 0x8200_0000` 的地址，
`__va()` 算出来的虚拟地址落在 `PAGE_OFFSET`（= `0xBE00_0000`，`va_pa_offset = 0xBE000000-0x82000000`
经 32 位截断）**之下、根本没建映射** ⇒ 内核取/存指令页错。`badaddr = 0x801F4000 + 0x3E000000`
与实测逐位相符。
busybox 的 `devmem` 走的是 **mmap**（`ioremap` 那一路，不看线性映射）⇒ 同址读写没问题。

⇒ **低 2 MB 主机写入区与 `0xF000_C000` 寄存器窗，只有 mmap 能碰**。

---

## 2. 投递通路（"net/dd" 的真实形状）

```
主机 (Windows)                          WSL                       板 (Linux, 192.168.1.110)
  npu_frame_run.py --run --xfer net
    └ scripts/board_ssh.py ── wsl -e bash -lc ── ssh root@board ──> /tmp/npu_f1/ddmem wr <phys> -   (stdin)
    └ scripts/board_ddr.py  ─ 每块合并成一条命令 ─────────────────> /tmp/npu_f1/ddmem rd <phys> <len> - | md5sum
```

* **ssh 走法**逐字沿用本工程唯一可用的那条（`docs/board_bringup.md` §6 / `flash_and_verify.py`）：
  **WSL 的 askpass + `SSH_ASKPASS_REQUIRE=force`**。Git Bash 的 ssh 即使强制 askpass 也拿不到
  dropbear 的口令（实测 `Permission denied, please try again` ×2），所以不留第二条路。
  dropbear ↔ 新版 OpenSSH 的 PQ-KEX 互操作问题照压 KEX（`curve25519-sha256` / `ssh-ed25519`）。
  另两个已踩的坑：`WSL_UTF8=1`（否则 wsl.exe 自己的告警是 UTF-16LE，会把 ssh 的 ASCII 输出读成乱码）；
  二进制一律 `base64` 过网（stdout 只当字节流用）。
* **`scp -O`**：新版 OpenSSH 的 scp 默认走 SFTP 子系统，板内 dropbear **没有** `sftp-server`
  （实测 `sh: /usr/libexec/sftp-server: not found`）⇒ 必须 `-O` 回老协议；失败还有 `ssh "cat > ..."` 退路。
* **板内 `ddmem`**（`y1/tools/ddmem.c`，静态 riscv32，66804 B）：`open("/dev/mem", O_RDWR|O_SYNC)`
  → `mmap`（页对齐换算在内部做）→ `memcpy`。三种模式：
  * `wr <phys> <file|->`：写完**就地回读逐字节比较**，打 `WROK … RSEG=OK`；
  * `rd <phys> <len> <out|->`：裸数据进 stdout（可管进 `md5sum`/`base64`）；
  * `mb <regbase> <off_a> <off_d> <off_we> <file|->`：**信箱成批投递**（输入是 8 B/条的小端
    `wgt_addr,data` 记录流，末条 `0xFFFFFFFF`），一次进程把 7290 条寄存器写打完。
* **为什么不落 /tmp 再 dd**：① 不落盘少一步、少一次校验面；② 每一块都**当场回读**，比"文件哈希"更强
  （它直接证明 **DDR 里**就是那些字节）。ssh **不分配 tty** ⇒ 完全不占 COM7，也不违反串口纪律。
* **对齐**：所有目标地址 4096 对齐（`0x80100000` / `0x80140000` / `0x80200000`），块大小 131072 B
  也是 4096 的整数倍 ⇒ `ddmem` 的页内偏移恒为 0（内部仍按页对齐换算，不依赖这个巧合）。

### 实测（`y1/build/f1_run3.log`；`--xfer net`）

```
-- 灌 input_int8（1228800 B = 307200 word）--
  [net] wr input_int8   phys=0x80200000  1228800 B  分块 131072（10 块）
  [net] wr input_int8   OK  整块回读 md5=8c1bd05c5141d597 （逐块+整块双重校验）
-- 灌 desc_table（生效表 2176 B = 544 word）--
  [net] wr desc_table   phys=0x80100000     2176 B  分块 131072（1 块）
  [net] wr desc_table   OK  整块回读 md5=fec587a13fb51ed0 （逐块+整块双重校验）
-- 灌 wgt_mailbox（404332 B = 101083 word）--
  [net] wr wgt_mailbox  phys=0x80140000   404332 B  分块 131072（4 块）
  [net] wr wgt_mailbox  OK  整块回读 md5=151304d8d9e44116 （逐块+整块双重校验）
-- 编程权重信箱（7290 条寄存器写；区 6 基址 + 区 2/3/4/5 参数）--
  [net] mailbox 7290 条寄存器写（58328 B 记录流，一次会话）
  [net] mailbox OK  n=7290（寄存器就地回读一致）
```

* 三个整块 md5 都是**板内新进程、新映射**重读出来的，与主机侧逐字节一致；
* `desc_table` 的板内回读 md5 = `fec587a13fb51ed0…` = **冻结 `gen/desc.bin` 的 md5** ⇒ 板收的就是冻结表；
* 体量/耗时：131072 B/块、一条 ssh 会话 ≈ 3 s（WSL 起进程 + curve25519 握手是主要成本）⇒
  1.2 MB ≈ 68 s、404 KB ≈ 25 s（把"写"和"回读"**合并进同一条 ssh**，否则翻倍：实测 121 s → 68 s）；
* 幂等：`ddmem` 按 md5 比对，已是最新就不重传。

---

## 3. 上板结果：`done/err`、12 路输出、G7 比较

| 判据 | 结果 |
|---|---|
| 寄存器窗探活 | `ID=0x594E5031` ✅ |
| `CTRL.soft_reset` 清 errSticky | ✅ |
| 三块 DDR 映像投递 + 回读 | ✅ 三个整块 md5 全对（§2） |
| 权重信箱投递 | ✅ `n=7290`，`RREG=OK` |
| **`done`** | **❌ 没等到**（run1：起跑 1.8 s 内 `STATUS=0x00000002` 即 `err=1`） |
| **`err`** | **❌ errSticky 立刻置 1（零搬运，DST 一个字节没动）** |
| 12 路输出 | **n/a** —— 没跑完，没有可回读的 12 路（§6） |
| G7 容差比较 | **n/a** —— 同上（容差是"两条路径都比得出来"才能算的量） |

### 3.1 逐步定位（每一步都是板内实测，不是读代码猜）

**① 是哪一项？**（`y1/build/probe_prefix.py`）把描述符表按"单元边界"截前 N 项、`DESC_COUNT=N` 起跑：

```
payload=67 单元边界（可截断项数）=[1, 3, 4, 12, 13, 17, 18, 22, 23, 29, 30, 31, 33, ...]
N=1   STATUS=0x00000002 done=0 err=1  (1.1s)  cut_after=type=1 layer=0 320x320 C3->16
>>> 第一个报 err 的前缀：N=1
```

⇒ **第一项描述符**（`desc[0]` = `LAYER_ID=0`，conv3x3 `s=2`，`IMG_W=IMG_H=320`，`C_IN=3 → C_OUT=16`，
`IN_BYTES=1228800`，`QUANT_SHIFT=6`）就红。`ls -l` 意义上的"表本身"没问题：`desc_table.validate`
离线跑**全表 PASS**（67 项 + 哨兵），`FLAGS[7:2]` 全 0、无载荷内哨兵、`SRC2_K` 合法。

**② 搬运发生了吗？**（`probe_dst.py`）起跑前后各回读 `desc[0]` 的 DST（`0x0032C000`，1638400 B）：

```
before nonzero=1516130 md5=96d1e9a16478
STATUS=0x00000002 done=0 err=1 (1.1s)
after  nonzero=1516130  diff_bytes=0/1638400
VERDICT: NO_WRITE(零搬运：派发前/装载相位 err)
```

⇒ **一个字节都没搬** ⇒ err 落在"派发前/几何判据"这一档（不是算到一半炸的）。

**③ 是"派发前表校验"还是"权重 DMA 装载相位"？**（`probe_split.py`）同一项表，只改信箱区 6：

```
[A_dma_on ] blob_base=0x00140000 STATUS=0x00000002 done=0 err=1 (1.1s)
[B_dma_off] blob_base=0x00000000 STATUS=0x00000002 done=0 err=1 (1.1s)
=> 故障在 **派发前/几何判据**（qShiftOk/chainOk/lidOk/wideGeomOk/inWOk 之一）
```

**④ 哪个判据？**（`probe_width.py`，**判决性**）只把 `desc[0]` 的几何改成网表定点几何：

```
desc[0] 原样              : IMG_W=320 IMG_H=320 STRIDE=2 C_IN=3 C_OUT=16 IN_BYTES=1228800 SHIFT=6 LAYER_ID=0
A) 真帧几何      (IMG_W=320 s=2): STATUS=0x00000002 done=0 err=1 ( 4.6s) DST_md5=17debec3ccba
B) 定点几何副本  (IMG_W=32  s=1): STATUS=?          done=0 err=0 (98.1s) DST_md5=17debec3ccba
```

⇒ **同一项、同一权重、同一寄存器**，只换 `IMG_W/IMG_H/STRIDE`：真帧几何 **1 s 内响亮 err**，
网表定点几何 **不再 err**（98 s 的窗口里既没 done 也没 err —— 见下面的"挂死"一节）。

### 3.2 根因（一句话）

**flash 里的网表是按 C3 的定点用例生成的**：

* `y1/rtl/NpuTop.scala:138` `val layerSched = new LayerSched(C = 8, WIDTH = 32, IMG_H_MAX = 16)`；
* `y1/rtl_test/LayerSchedGen.scala` 的注释自己写着"本片 C3.10a/C3.10b 的几何是**定点用例**，
  写死在这里 —— `C=8`、`WIDTH=32`、`IMG_H_MAX=16`"，并说明 `gen/UnitExec.v`（WIDTH=64）与
  `gen/UnitExec_w640.v`（WIDTH=640，D1/D1b 的）是**另两份例化**；板级走的是 `y1/gen/NpuTop.v`
  → `LayerSched` → `UnitExec(WIDTH=32)`；
* `gen/LayerSched.v` 里确有两处 `20'h00020`（= 32）的常量。

而 RTL 的行宽对账是**`WIDTH` 必须在 `[IMG_W·s − s + 1, IMG_W·s]` 里**（`UnitExec.scala` 的
`inWMin/inWMax/inWOk`，`WIDTH` 是**展开期常量**）：

```
inWMin = 320*2 - 2 + 1 = 639 ;  inWMax = 320*2 = 640 ;  WIDTH = 32  ⇒  inWOk = false
⇒ wideGeomOk = false ⇒ `go` 那一刻 errR := True（**零搬运**，一个 AR/AW/W 都没发）
```

⇒ 真帧**每一项**都会撞这一条（真表的 `IMG_W ∈ {320,160,80,40,20}`，`WIDTH=32` 只对
`IMG_W=32/s=1` 成立）。**这不是投递问题、不是表问题、不是邮箱问题**，是"网表几何 ≠ 真帧几何"。

**这是 RTL 的设计意图被触发**：`UnitExec` 文件头写得很清楚——"描述符的 `IMG_W` **必须** ==
生成本网表时的 `WIDTH`"，不合就**响亮 err，绝不静默错值**。板子这次的表现**恰好符合契约**。

### 3.3 附带发现：`CTRL.soft_reset` **不能**复位调度器 ⇒ 一旦"挂死"就要重下比特流

`NpuTop.scala:288` 只做了 `when(hostRegs.io.soft_reset) { errSticky := False; irqR := False }`
——**没有**复位 `LayerSched`/`UnitExec`/`BypassExec` 的 FSM（它们的复位来自 `NpuResetSync` 的
SoC 域复位，主机不可写）。后果实测到两次：

* `probe_width` 的 B 档（几何合法）让 FSM 进了一个**等不到**的状态（98 s 无 done 无 err，
  与 B3 报告 §1 一致：`XDMA_EN=0` 时宽层激活要由**外部 `wide_x` 端口**喂，而本板没有那个喂料口）
  ⇒ 之后**所有**起跑都被忽略：`run2`（`--xdma-en`）与 `run3`（默认）都是 `STATUS=0x00000000`
  一直到底（172 次轮询 / 301 s）。
* `err` 档**可以**恢复（err 路径都 `state := IDLE`），`hang` 档**不能**——宿主侧没有任何补救手段，
  必须**重下比特流**（JTAG）或断电重启。

⇒ 因此本报告的**权威上板证据是 `y1/build/f1_run.log`（第一次 `--run`，状态干净）**；`f1_run3.log`
的挂死是**上一轮污染**的结果，不能当"表修好之后还是不行"的证据（也不能当"表修好之后行了"的证据）。

---

## 4. 顺带修掉的两个**驱动侧真 bug**（都在 F1 范围里）

### 4.1 缺 `wgt_mailbox` 灌写（B5 的注释写着"由 B6 决定"，实际是**根本没灌**）

B5 的 `do_run` 从来**没有**把 `wgt_blob.bin ‖ wgt_mult.bin` 写进 DDR（只有一句
`-- 灌 wgt_mailbox 由 B6 决定（网络/分段）`），却把信箱区 6 的 `WGT_BLOB_BASE` 指到 `0x00140000`
⇒ 权重 DMA 会去读**没有内容的地址**。F1 补上（net 走网络/`devmem` 走 UART 并带 R5 守卫）。

### 4.2 生效表**重打包**会抹掉 `SRC2_K`（E1 的表内偏移）——静默读错源

B5 用 `desc_table.pack_table(eff[:-1])` 在内存里重打包生效表。`desc_table.FIELD_ORDER` 只有 14 个
字段，**不含 `SRC2_K`**（= `w3[31:16]`，★ E1 2026-10-13 的"表内偏移"）⇒ `unpack → pack` 会把
它**当 0 写出**。实测：

```
raw    md5 fec587a13fb51ed00914e5ce9c04db02  (2176 B, gen/desc.bin)
repack md5 5b525947a997a2bfab2954a61620208e  (2176 B, pack_table(unpack(...)))
differing entries: [30, 34]
  entry 30 TYPE=19 LAYER_ID=30  raw w3=00010101  repack w3=00000101 (SRC2_K=1)
  entry 34 TYPE=19 LAYER_ID=34  raw w3=00010101  repack w3=00000101 (SRC2_K=1)
```

`wgt_index.json` 的 `src2_add` 正是 `[(30, k=1), (34, k=1)]` —— 两个 `Add` 单元的第二路源会从
`idx−1` 被抹成 `idx−0` ⇒ **静默读错源**（E1 当初选 `w3[31:16]` 就是因为它在两处冻结校验之外）。

H1 之后 `fold_src_rewrite` 恒为 0 ⇒ 本驱动**不需要任何改写** ⇒ F1 改成**逐字节搬冻结 `desc.bin`**；
只有真出现改写时才重打包，并**响亮警告** `SRC2_K` 会丢。跑后核对：
`desc.bin md5 = 生效表 md5 = fec587a1…`，板内回读 md5 也 = `fec587a1…`（传输层已证）。

### 4.3 补上缺失的"同口径反量化"

B5 的 `readback_to_tensors` 返回的是 **int8 码点**，却直接喂给 `yunet_post.postprocess`
（`score=sqrt(cls*obj)`、`w=exp(bbox[2])*stride`）—— 那是**反量化后**的口径。F1 补上：
按冻结 `quant_ref` 的 `act` 定标取 12 路 `(scale, zp)`（`--deq-cache` 可缓存），`(q − zp)·s` 后再进后处理。
本次 12 路定标（真帧 `grace_hopper.jpg`，input `s=1, z=-128`）：

| 输出 | s | z |  | 输出 | s | z |
|---|---|---|---|---|---|---|
| cls_8 | 0.0035065111 | -128 | | bbox_8 | 0.013647207 | -71 |
| cls_16 | 0.0024556945 | -128 | | bbox_16 | 0.0057495236 | -29 |
| cls_32 | 0.0034809669 | -128 | | bbox_32 | 0.020473595 | -18 |
| obj_8 | 9.3826359e-05 | -128 | | kps_8 | 0.031484041 | -10 |
| obj_16 | 1.9525547e-05 | -128 | | kps_16 | 0.0045292794 | -117 |
| obj_32 | 0.003921413 | -128 | | kps_32 | 0.04021742 | -4 |

### 4.4 明确**没有**做的事（写在明处）

* **信箱区域 7 道 2（每层两位的布局表，B4）未投递**：它需要 `layout_adapt_ref.py` 那套逐层推导，
  仓里没有一个"逐层两位"的可信落盘来源（`wgt_index.json` 只有 `layout_fold` 的步长/顺序）。
  **不猜**；这是"真几何网表"上的必办项。
* **区域 7 道 0（`XDMA_EN`）默认不开**，提供 `--xdma-en` 显式开。理由见 §3.3：在**现在这版
  定点几何网表**上，打开它会把"1 s 响亮 err"变成"既无 done 也无 err 的挂死"（而挂死**不可恢复**）。
  它是真几何网表的**必要条件**（本板没有外部 `wide_x` 喂料口），但现在开没有正收益、只有风险。

---

## 5. 纪律与回归（都跑过）

* **R5 守卫保留**：`--xfer devmem` 下 input / wgt_mailbox 仍被 `--uart-word-limit` 拒绝并打
  `JUDGE-RED: … R5：大映像走网络/分段，本驱动拒绝 UART 硬灌`（原话未改）。
* **UART 路径仍在跑**：每一次运行里探活 / `soft_reset` / `DESC_ADDR`·`DESC_COUNT`·`CTRL.start` /
  `STATUS` 轮询都是 `devmem` 逐字（小块仍走 UART：本轮的 `net` 模式下 `--net-min-bytes=1024`
  会让 400 B 的 `cls_32/obj_32` 回读走 UART）。
* **完成标记/节流纪律未动**：`Board.send`（10 ms/字）+ `run_wait`（`B=<tok>; echo "X${B}X"` 的
  完成标记 + 回显免疫）一字未改；网络通路**不占 tty**（`ssh` 无 `-t`）。
* **B5 闸门复跑**（`bash y1/tools/run_frame_ab.sh`，**在最终代码上**）：`RESULT: PASS`
  （`DRY_PLAN_MD5=bd49993b4dd07ace511272336b9588d0` 两次相等、`DRY_OUTPUTS=12`、
  `DRY_FOLD_REWRITES=0`、`DRY_HARD=0`、ORT 两方向、同口径 int8 两方向 + 确定性、比较器 4/4 负对照发火）。
  ★ 该 `DRY_PLAN_MD5` **= F1 之前的原值** ⇒ 默认（不含可选的信箱新档）程序序列**逐字未变**：
  F1 是**加法**（`--xfer` 换通路，序列不变）。
* **G7 比较器本身**（`yunet_post.py --selftest`）在闸门里过了正/负对照，所以"比较器无牙"这个
  解释被排除。

---

## 6. 12 路输出与 G7：**n/a，以及为什么**

G7 的量（IoU / 关键点 L2 / |Δconf| / 检出数差）是"**硬件 12 路 + CPU 后处理**"与"**float ORT +
官方后处理**"两个**检出集**之间的比较。本轮硬件在第一项描述符就 `err`（零搬运）⇒ **没有任何
12 路可回读** ⇒ 这四个量在数学上不存在（不是"没测"，是"无处可测"）。

不给替代数字（例如拿离线 int8 冒充硬件）——那会把 B6 的核心判据变成橡皮章。离线口径的
"同口径 int8 vs float"数字在 `run_frame_ab.sh` 的输出里（**只记录、不判**，是 B6 差距的离线预报），
本轮不重复粘贴。

**下一轮要在真几何网表上重跑**，命令就是本报告用的那一条（`--run --xfer net`，见 §7），届时
12 路输出会逐路打出 `int8_md5 / int8 范围 / distinct / 反量化范围`，`--json` 还会落
`out_int8_md5` 与检出集，直接喂 `yunet_post.py --compare-a <board.json> --compare-b <ort.json>`。

---

## 7. 复现（逐条命令都跑过）

```bash
# ① 交叉编板内搬运器（WSL；工具链取自 buildroot 输出）
wsl -e bash -lc 'bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_ddmem.sh'
#    -> y1/build/ddmem_rv32  66804 B  md5 4d42cf4d8608d5356e2c75ad544b2cf5

# ② 离线规划（不碰板）
cd y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/npu_frame_run.py --dry \
  --img ../ai_npu_exp/deps_export/matplotlib/mpl-data/sample_data/grace_hopper.jpg

# ③ 上板整帧（碰 COM7 + 网络）
cd y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe tools/npu_frame_run.py \
  --run --port COM7 --xfer net \
  --img ../ai_npu_exp/deps_export/matplotlib/mpl-data/sample_data/grace_hopper.jpg \
  --json build/board_f1.json --net-log build/net_f1.log --deq-cache build/deq_cache.json

# ④ 定位探针（临时件，在 .gitignore 的 y1/build/ 下）
python build/probe_prefix.py   # 哪一项：N=1 → desc[0]
python build/probe_dst.py      # 搬没搬：零搬运
python build/probe_split.py    # 派发前/几何 vs 权重 DMA
python build/probe_width.py    # 判决：IMG_W/STRIDE 一改，err 消失
```

环境事实（本轮实测）：板 `192.168.1.110`，dropbear ssh，口令 `yeshen`；`/dev/mem` 可读可写（**只能
mmap**）；`/tmp` 是 rw tmpfs；`/proc/iomem` = `82000000-8fffffff : System RAM`（**新内存图已生效**）；
busybox 有 `dd/md5sum/seq/base64/devmem/cmp`，**没有** python/gcc/nc。

---

## 8. 开口项（给 B6 / 下一轮，按优先级）

1. **★ 用真几何重新生成 + PnR + 重下比特流**：`LayerSched`/`UnitExec` 的 `WIDTH` 要覆盖真帧行宽
   （真表 `IMG_W ∈ {320,160,80,40,20}`；`STRIDE=2` 的首层要求 `WIDTH ∈ [639,640]` ⇒ D1/D1b 的
   `UnitExec(WIDTH=640)` 那份例化就是为此准备的），`IMG_H_MAX` 要 ≥ 真帧最大行数（320）——
   现在写死的 `16` 连输出存储都装不下。**这是唯一的根治项**，没有它整帧跑不到第 2 项描述符。
2. **`XDMA_EN`（区域 7 道 0）必须 = 1**：本板没有外部 `wide_x` 喂料口，开着才走"从 `SRC_ADDR`
   gather 通道平面"。宿主侧的开关已经就位（`--xdma-en`），但要在**真几何网表**上开才有意义。
3. **每层两位的布局表（区域 7 道 2）**：旁路算子（maxpool/resize/add/sigmoid）的 NHWC↔平面适配
   靠它（B4）。需要一个**逐层两位的可信落盘来源**（从 `layout_adapt_ref` 的推导反过来落到
   `wgt_index.json`），别在驱动里现推。
4. **`CTRL.soft_reset` 加一条"复位调度器"**：现在它只清 `errSticky`/`irqR`（`NpuTop.scala:288`），
   调度器一旦进了"等不到"的状态，宿主侧**无法**恢复（实测：之后所有 `start` 被忽略，只能重下
   比特流）。要么把 `soft_reset` 也接进 `LayerSched` 的复位，要么加一个"abort"寄存器。
5. **表尾元数据**（C3.11 已记的开口项，未变）：`desc_count` 少写时哨兵之后的项被静默忽略。
6. **性能**：每块一次 ssh 会话 ≈ 3 s（WSL 起进程 + 握手）是当前瓶颈；若整帧要反复跑，考虑一条
   长驻 ssh 会话（`ControlMaster`）或把"投递+回读"合成一条脚本上板跑（现在的 68 s / 1.2 MB 够用）。

---

# Y1-frame（2026-10-13）：**真几何网表** —— 结论

**一句话**：把 F1 判定的**唯一根治项**（真几何）**真的做了**（`WIDTH 32 → 640`），生成/确定性/结构
判据全绿；但 `dev_map` 与 PnR 都给出**同一条硬判词**：**这份网表装不下 PG2L200H** ——
`Adm-4088`（DRM 不够，掉 LUTRAM）**418**（独立 NPU）/ **436**（板级）条，根因是**片上输出/部分和
存储随 `WIDTH` 线性放大**（`PartialSumBuf` 一项就要 **2.62 MB**，器件只有 **~1.87 MB / 415 DRM**）。
⇒ **没有比特流、没有重刷、没有板级整帧**（诚实记账，见 §9.4）。同时本轮**证死**了整帧跑不完的
**第二条结构性原因**：`inWOk` 对 `s=1` 层退化成 `IMG_W == WIDTH` ⇒ **单张网表只能满足一个输入行宽**。

## 9.1 真几何的数字（before → after，逐条可核）

**当前（flash 里的定点值）**：`LayerSched(C=8, WIDTH=32, IMG_H_MAX=16)` —— 两处钉点：
`y1/rtl_test/LayerSchedGen.scala:38`、`y1/rtl/NpuTop.scala:138`（`LayerSched.scala:185` 的类默认另有）。

**真表（`y1/gen/desc.bin`，2176 B = 68 项 = 67 载荷 + 1 哨兵；md5 `fec587a1…`）逐项解码**得到：

| 量 | 值 | 出处（desc 下标） |
|---|---|---|
| conv 类**输入行宽** `IMG_W·s` 的**最大值** | **640** | `desc[0]` `Conv_0`：`IMG_W=320, STRIDE=2`（640×640 → 320×320） |
| conv 类输入行宽集合 | `{640, 320, 160, 80, 40, 20}` | `desc[0]`=640；`desc[1..3]`=320；`desc[4..]`=160/80/40/20 |
| **最大 `IMG_H`**（conv 类） | **320** | `desc[0..2]`（320×320） |
| **最大输出像素数** `IMG_H·IMG_W`（逐描述符） | **102400** | `desc[0..2]` = 320·320 |
| bypass 最大 `outPix` | **25600** | `desc[3]` maxpool 160×160 |
| sigmoid 平铺项（`IMG_W=6400, IMG_H=1`） | 6400 | `desc[61..66]`（输出头 reshape） |

**`UnitExec` 的两条几何判据（`rtl/UnitExec.scala`）**：
* **`inWOk`**（`UnitExec.scala:704-706`）= `WIDTH ∈ [IMG_W·s − s + 1, IMG_W·s]`。
  `desc[0]`（`IMG_W=320, s=2`）⇒ `WIDTH ∈ [639, 640]`；**当前 32 直接被否 ⇒ `go` 那拍响亮 `err`**
  （与 F1 的 `probe_width` 实测逐字一致）。`s=1` 时区间塌成单点 ⇒ `WIDTH == IMG_W`。
* **`MAXPIX = WIDTH·IMG_H_MAX`**（`UnitExec.scala:511-512`）= 输出存储 / 部分和存储的容量上限；
  `BypassExec.geomOk` 显式要求 `outPix ≤ MAXPIX`（`BypassExec.scala:263-269`）。

**⇒ 本轮改的真几何**：`WIDTH 32 → 640`（`desc[0]` 的 `inWOk` 需要它）。
`IMG_H_MAX` 另有**两条硬夹逼**（所以不可能照任务书示例取 640）：

1. **展开期硬上限**：`PartialSumBuf` 的 `depth` **自报口是 16 bit**（`PartialSumBuf.scala:85,94`），
   `DEPTH = NCOB·PIXMAX = 8·(WIDTH·IMG_H_MAX)` ⇒ `8·640·IMG_H_MAX ≤ 65535` ⇒ **`IMG_H_MAX ≤ 12`**。
   实测 `IMG_H_MAX=16` ⇒ **sbt 展开直接报错**：`literal 0x14000 can't fit in UInt(16 bits)`
   （`PartialSumBuf.scala:94`）—— 连网表都生不出来。
2. **器件 RAM 上限**：真表整图输出 `H·W = 102400` ⇒ 若要"输出存储装得下整层"，需
   `MAXPIX ≥ 102400` ⇒ `IMG_H_MAX ≥ 160` ⇒ `PartialSumBuf` 要 `8·(640·160)·64 B ≈ 52 MB`
   （见 §9.3 的容量式）—— **远超器件**。
   ⇒ 本轮取 **`IMG_H_MAX = 8`**（`maxPix = 5120`），是"能展开"的一档；`dev_map` 证明**它还是装不下**。

## 9.2 生成 / 确定性 / 结构判据（全绿）

| 件 | 大小 | md5 | 确定性 |
|---|---|---|---|
| `y1/gen/LayerSched.v` | 34,145,218 B（旧 5,394,822 B，×6.3） | `bafd4de310b9269a13e4ee4241be7c86` | **2× 逐字节相同** |
| `y1/gen/NpuTop.v` | 34,201,243 B（旧 5,450,847 B，×6.3） | `84c8b9fa370552a81da3777cdf72578e` | **2× 逐字节相同** |

* 生成器：`LayerSchedGen.scala` / `NpuTop.scala`（`headerWithDate=false` / `headerWithRepoHash=false`，
  与既有口径逐字相同）—— **只改这两个钉点，其余不动**。
* `tools/check_dup_modules.py`（tcl 反推源清单，`pnr_c4a.tcl`）：**77 源 / 81 module / 0 重名 ⇒ PASS**。
* `tools/check_dangling.py y1/gen/NpuTop.v`：**19 module / 0 悬空 ⇒ PASS**。
* `gen/NpuTop.v` 内 `WIDTH` 常量已从 `20'h00020`(=32) 变为 `20'h00280`(=640)（与 F1 §3.2 的观测同处）。

## 9.3 面积判词：**装不下**（dev_map + PnR 同判）

**`W: Adm-4088: Not enough DRM resource to implement ram '…', trying to decompose using LUT ram.`**
* 独立 NPU 探针（`YESHENMINI_C4A_MODE=nputop`，只 `NpuTop.v`）：**418 条**；首批报的正是
  `layerSched_1/unitExec_1/mpu/psb/mem_207…` 与 `layerSched_1/unitExec_1/mzRam*`；
* 板级 PnR（`pnr_c4a.tcl`，`tag=frame640`）：**436 条**，同样从 `…/mpu/psb/mem_207…` 起。

**APM 对照**（几何无关，只作旁证）：独立 NPU `WIDTH=640` = **543** 个 `GTP_APM_E2`
（C3 的 `LayerSched(L=8, WIDTH=32)` 单独综合 = 323）—— 器件 740，**APM 不是瓶颈**。

**为什么 DRM 会爆（容量式，逐字取自 RTL 字面）**：宽层输出/部分和存储随 `WIDTH`（与 `IMG_H_MAX`）
**线性**放大（`WIDTH=32→640` 是 **20×**）：

| 存储 | RTL 定义 | `WIDTH=640, IMG_H_MAX=8` | `WIDTH=32, IMG_H_MAX=16` |
|---|---|---|---|
| `PartialSumBuf.mem` | `Mem(64 B, NCOB·PIXMAX)`，`PIXMAX=WIDTH·IMG_H_MAX` | **2.62 MB** | 256 KB |
| `wOutMem` | `Mem(8 B, PIXW·NCOB)` | 320 KB | 32 KB |
| `FusionBuf ×9` | `Mem(C·8, 3·WIDTH)` each | 138 KB | 7 KB |
| `wRam` / `outMem`+`outMemT` | — | 36 KB + 40 KB | 36 KB + 8 KB |
| 合计（仅这几项） | | **≈ 3.1 MB** | ≈ 0.34 MB |
| 器件 PG2L200H 可用 | 415 × DRM36K | **≈ 1.87 MB** | ≈ 1.87 MB |

⇒ `WIDTH=640` 一档的内存需求就是器件的 **≈1.7×**，`Adm-4088` 与"DRM 满"是**必然**，不是布线/约束问题。

**合法的缩小？** 任务书的示例（`IMG_H_MAX ≥ 640`）按上面两条夹逼**在数学上不可能**（展开期 16 bit 上限
只到 12；容量上要 52 MB）。而"把 `WIDTH` 缩小"又**直接违背 `desc[0]` 的 `inWOk`**（必须 ∈{639,640}）——
**没有**"既装得下又满足真网行宽"的合法档。唯一能把 DRAM 压进器件的方向是**把 `IMG_H_MAX` 压到 ~2**
（`PartialSumBuf` 线性），但那等于承认"输出存储连一层 320×320 都装不下"——**不是缩小，是换架构**
（见 §9.6）。

## 9.4 板级：本轮**未重刷、未跑帧**（诚实记账 + 为什么）

DoD 要求"重刷 + 上板跑 + 过 `desc[0]`"。**做不了**，因为没有**能装下**的比特流：
* `dev_map` 在 `synthesize -ads` 之后即因 **DRM 不够**掉 LUTRAM（`Adm-4088`），PnR 因此**不能收敛到合法布局**；
* 本轮的 PnR 在**后台继续跑**（`sim/reglogs/pds_pnr_c4a_frame640_p10.000`，日志 `y1/pds/pnr_frame640.log`），
  依指示**不杀**；但它作为"WIDTH=640 装不下"的**第二份证据**已经在 `synthesize` 阶段把判词打出来了。
* **没有比特流 ⇒ 不重刷 ⇒ 12 路输出与 G7 = n/a**（与 F1 的 n/a 同因不同层：F1 是"几何判据拦在派发前"，
  本轮是"几何对了但装不下"）。

## 9.5 can / cannot prove（诚实边界）

**能证明的**：
1. F1 的根因**属实**且**已修**：`WIDTH=32` 被 `inWOk` 否掉，`WIDTH=640` 满足 `desc[0]` 的 `[639,640]`
   （判据逐字来自 `UnitExec.scala:704-706`，与 F1 `probe_width` 实测一致）。
2. **真表几何**已量化：conv 输入行宽 `∈{640,320,160,80,40,20}`、`max IMG_H=320`、`max H·W=102400`。
3. **这份真几何网表装不下 PG2L200H**：`Adm-4088` ×418（NPU）/×436（板级）+ 容量式（§9.3）。
4. `PartialSumBuf` 的 16-bit `depth` 自报口是**展开期硬上限**（`IMG_H_MAX ≤ 12` @ `WIDTH=640`）。
5. 网表确定性（2×）+ 结构判据（重名/悬空）全绿。

**不能证明的（本轮明确未做/做不到）**：
1. **没有**"重刷后过 `desc[0]`"的板级证据 —— **没有比特流**（装不下）。**不拿离线/仿真冒充板级**。
2. 12 路输出与 G7 容差：**n/a**（原因同上，不是"没测"）。
3. 时间收敛（`All Constraints Met`）：**未取**（PnR 在做布局之前就撞 DRM 墙；时序无从谈起）。
4. "改小 `IMG_H_MAX` 就能过"——**未实测**（分析说是 ~2，但这已不是"一行改形状"的事，见 §9.6）。

## 9.6 整帧在本器件上跑不完的**两条结构性原因**（本轮新增第二条）

1. **（F1 已知 + 本轮修的一步）单张网表只有一个 `WIDTH`**：`inWOk` 对 `s=1` 层退化成 `IMG_W == WIDTH`
   ⇒ 真表 `{640,320,160,80,40,20}` 六种行宽，**一张网表只满足一种**。`WIDTH=640` 只够 `desc[0]`；
   `desc[1]`（`IMG_W=320, s=1`）**仍会被 `inWOk` 响亮 err**。⇒ 整帧要么**逐层多份网表/多份比特流**，
   要么把 `WIDTH` 改成**运行期可变**（行缓冲/切片按运行宽度组织）——**都是架构改动，不是改一个常量**。
2. **（本轮新增）片上输出/部分和存储正比于"整层像素数"，本器件装不下**：`PartialSumBuf` 与
   `wOutMem` 按 `WIDTH·IMG_H_MAX` 线性分配（§9.3）。整帧最大的层 `320×320` 需要 ≥102400 像素容量
   ⇒ 光 `PartialSumBuf` 就 52 MB 级（器件 1.87 MB）。⇒ 必须**行条带（strip）流水**：把每层的输出按
   行瓦片处理，描述符按条带切（`IMG_H` = 条带高，如 D1 闸门用的 4），片上只留一个条带的存储。
   这正是 D1/D1b 那份 `UnitExec_w640.v`（`WIDTH=640, IMG_H_MAX=4`）的**设计本意**——但它**只被仿真过、
   从未 `dev_map`**（本轮第一次让 Pango 工具链看到"真行宽"的面貌，结果就是 §9.3 的 418/436 条）。

## 9.7 下一步（按优先级，合法且不静默）

1. **行条带调度**：把转换器/驱动改成"逐层按 `H_TILE` 行切条带"（描述符 `IMG_H = H_TILE`，边界带 halo
   由相邻条带重叠喂入），片上存储按 `WIDTH·H_TILE` 分配。**先离线证明"条带拼起来 == 整层"**（与
   `tiling_ref.py` 同法），再选能把 DRAM 压进器件的 `H_TILE`（分析：`WIDTH=640` 时 `H_TILE ≤ ~2`
   才够，需实测），最后才是 PnR + 上板。
2. **运行期可变行宽**（更彻底）：`inWOk` 从"展开期常量比对"改成"运行期宽度 ≤ 展开期上界"，
   切片/行缓冲按上界组织、按运行宽度收列。这样一张网表能跑 `{640,320,160,80,40,20}` **全部**层
   ⇒ 单比特流跑完整帧。**这是把 §9.6-1 消掉的唯一干净办法**。
3. 上述任一落地后，`npu_frame_run.py --run` 才能有"过 `desc[0]` 之后一路到 12 路输出"的可测对象；
   届时 G7 判据（IoU/L2/|Δconf|/计数差）才**有数可算**。

