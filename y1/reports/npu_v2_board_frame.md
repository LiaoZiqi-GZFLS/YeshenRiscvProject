# S3-上板：**t18c 比特流首次上板 + 真帧首次在板上跑到单元级**（NPU v2 线；2026-10-16 / S3-3 续报 2026-10-17）

- 上游：本文件同目录 `npu_v2_accounting.md` 的 T18c 轮（比特流 `d8993bfe…`、板钟 56.25 MHz）、
  `c4b_frame.md`（F1 的投递通路 + 上板事故 root cause）、spec `2026-10-16-y1-npu-v2-single-skeleton-design.md` §5。
- 交付面：`scripts/*`（两个传输健壮性修复）、`pds/flash_yeshen.tcl`（JTAG 端口环境变量）、
  `y1/tools/npurun_t.c` + `y1/tools/build_npurun_t.sh`（板内单进程帧计时器）、本报告。
- **Status: PARTIAL（部分达成）** —— 烧写 + 启动 **PASS**；整帧**首次在板上跑过 desc[0]**（跑到 desc[2] done）；
  **首个失败单元 = `desc[3]`（MaxPool）**，根因 = **每层布局位（信箱区 7 道 2）未投递**（F1 §4.4 已记的必办项；
  离线镜像 `--layout zero` **逐项复现**首错单元与错单元集合）；**G7 = n/a**（没有完成的帧）。
  附带两项**首次实测**：逐单元墙钟（0.735 / 1.256 / 1.578 s，见 §5）与"XDMA_EN 必须 = 1"的板上裁决（§4）。
  **没有完成的帧 ⇒ 没有 measured fps**（不拿模型数冒充；诚实记账）。
- **★ S3-3 续报（2026-10-17，见 §13）** —— 布局投递后整帧**首次板上 `done=1, err=0`**（npurun_t ×3 =
  **6.4916 / 6.4904 / 6.4909 s** ⇒ **measured fps = 0.1541**，散布 ±0.02%）；12 路输出**全部收齐入库**
  （含指纹，§13.5）；**G7 = 否定性红（FAIL）**：板输出与同口径黄金逐字节不等，且**与输入无关**
  （正脸/无脸两帧的 cls_8/obj_8/cls_16/obj_16 **逐字节相同**）；**首个失败点钉到 `desc[0]` Conv_0 的激活读**：
  其输出 = 全 1.6 MB 常数 `0x29`（canary 实验证明"写确实发生、值是填充常数"），下游 66 个单元在
  这些常数上**确定性**地跑完。⇒ 本帧 = **一个与输入无关的确定性常数函数**；"能跑完"成立、"数值对"不成立。
  **停顿归因**（§13.6）：实测 6.4909 s 对照 ideal MAC 地板 95.6 ms = **67.9×**；逐段墙钟与
  "常数化数据"无关（同帧时间在两种输入下相同）⇒ 停顿属**每单元固定开销/DDR 往返**档，不是数据相关的算力/带宽。

---

## 1. 烧写与启动（PASS）

**判别句**：`scripts/flash_and_verify.py --tag pnr_c4a_t18c --com COM7 --secs 180 --no-net`
⇒ `done bit = 1` + **启动 marker 8/8 全过**（SDR 帧 / misoHi=1 / OpenSBI / `Linux version 5.10` /
LiteEth `eth0: … slots:` / dropbear / `VEXIIYESHEN-OK` / `login:`）。RC=0（本机设 `PYTHONIOENCODING=utf-8`，
未触发任务书提到的 GBK 收尾异常）。

**烧进去的比特流（逐字节对账）**：
`sim/reglogs/pds_pnr_c4a_t18c_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
= 9,188,552 B，md5 **`d8993bfed723a4564470c0107f84360f`** —— 与任务书/T18c-4 的指纹**逐字节一致**。

**两个工具面坑（都修了，各一个 commit）**：
1. **tag 拼法**：`flash_yeshen.tcl` 的比特流路径模板是 `pds_${tag}_p10.000`（不是 PnR 工程的
   `pds_pnr_c4a_${tag}_p10.000`）⇒ 必须 `--tag pnr_c4a_t18c`（先例：`pnr_c3_r4` / `pnr_c4a_npuclk`）。
   用 `--tag t18c` 会得到 `no sbit`（无害失败，当场纠正）。
2. **JTAG 端口被 Windows 动态保留区覆盖**：`cdt_js.exe` 报
   `Cannot create listening port: Socket bind error`；`netsh interface ipv4 show excludedportrange
   protocol=tcp` 实测排除区 **65399–65498 ⊃ 65420**（本机此次开机档如此——不是"端口被占"）。
   处置：`cdt_js.exe -port 65500` 起服务 + `pds/flash_yeshen.tcl` 新增环境变量
   `YESHENMINI_JTAG_PORT`（缺省仍 65420，与 `YESHENMINI_TAG` 同一手法）⇒ **commit `3e2cede`**。

**启动/探活**（三层互证）：UART 登录 `scripts/uart_login_pw.py COM7 115200 yeshen` = `== LOGGED IN ==`；
网络路径 `scripts/board_ssh.py` = `Linux buildroot 5.10.1 … riscv32` + `eth0 192.168.1.110/24`；
寄存器窗 `ID=0x594E5031`、`STATUS=0`（干净）；驱动 `--dry` 自检 `DRY_RESULT: PASS`
（`DRY_OUTPUTS=12 / DRY_FOLD_REWRITES=0 / DRY_HARD=0`，arena_top `0x01C50440`）。

## 2. 传输层修复（上板实测逼出来的两个工具 bug；判据不放宽）

现网下 WSL→板 ssh 会话**偶发 `rc=255`**（收尾掉线；小命令实测 10 次 8 成 2 败），且 stdout 会混入
别的会话残行。它把"已经拿到正确 md5"的回读误判为失败，连续做废三帧：

- `scripts/board_ddr.py::_rd_md5`：重试 `tries` 次；只要出现 32 位十六进制 token 即采纳——
  **最终判据仍是调用方与主机 md5 逐字节相等**（不等照 raise）⇒ commit **`8fb54d9`**。
- `scripts/board_ddr.py::prepare`：`mkdir` 一步也重试（原为"一手一锤"）⇒ commit **`5749821`**。

修复后整帧传输三块映像（input/desc/blob）**全部整块回读 md5 对账通过**（§3/§4 两次运行）。

## 3. 第一次整帧（驱动默认参数）：err 于 `desc[0]`，根因 = **XDMA_EN=0**

命令（F1 §7 形状）：`npu_frame_run.py --run --port COM7 --xfer net --img <grace_hopper.jpg>`。
传输全过（详见同次 net 日志），`CTRL.start` 后 ~1.7 s：`STATUS=0x00000002`（**err=1，done=0**）。
用 F1 的前缀二分探针定位：**第一个报 err 的前缀 N=1 ⇒ `desc[0]`**（`type=1 layer=0 320x320 C3->16`）。

**根因（RTL 证据 + 镜像交叉）**：`XDMA_EN`（信箱区 7 道 0）**驱动默认不投**；而宽通路的 tiled 路由
`tilingWideC` **要求 `xDmaOnR`**（`y1/rtl/UnitExec.scala:1650-1658`）。XDMA_EN=0 ⇒ `desc[0]`（宽单元）
落回 legacy 路由 ⇒ `WGTRUN` 收工那一拍的 `wlWideR && !wideGeomOk && !tilingW` 把住
（`:2079` 的 **`!tilingW` 豁免不生效**）⇒ `inWOk`（本网表行宽 640 > `WIDTH=34`）**响亮 err**。
这正是 `c4b_frame.md` §8-2 的预判："`XDMA_EN` **必须 = 1**：本板没有外部 `wide_x` 喂料口"。
（`frame_preflight.py` 的 DISPATCH 口径本来就写着 `XDMA_EN=1（= 真帧驱动）`——是**驱动默认值与
镜像前提不一致**，本片把口径钉死：真帧必须 `--xdma-en`。）

## 4. 第二次整帧（`--xdma-en`）：desc[0..2] 板上 **done**；**首个失败单元 = `desc[3]`（MaxPool）**

命令：`npu_frame_run.py --run --port COM7 --xfer net --xdma-en --net-chunk 262144 --net-tries 8
--img <grace_hopper.jpg>`（`--net-chunk/tries` 纯传输面；数值判据不变）。
- 传输三块全过（含重试）；**权重信箱 7291 条**（= 7290 + 1 条 `XDMA_EN=1`）就地回读一致。
- 起跑后：`poll0 STATUS=0x00000000`（此刻未 done 未 err），`poll1 STATUS=0x00000002` ⇒ **err 不是首单元**。
- 逐单元定位（新增临时件 `y1/build/s3_bisect.py` + 板内 `npurun_t`；**冻结 desc.bin 的字节前缀** +
  哨兵写回 DESC_TABLE，`DESC_COUNT=N`；mailbox/input/blob 沿用驱动已就位的状态）：

| N（前缀） | 结果 | 墙钟 ns | 折 s | 增量单元 |
|--:|:--|--:|--:|:--|
| 1 | **done** | 734,580,080 | 0.735 | `desc[0]` Conv_0（3→16, s=2, 320²） |
| 2 | **done** | 1,256,202,970 | 1.256 | + `desc[1]` Conv_1（1×1 16→16） |
| 3 | **done** | 1,578,164,000 | 1.578 | + `desc[2]` depthwise 16→16 |
| 4 | **err** | 1,577,496,270 | 1.577 | + `desc[3]` **MaxPool 160² 16>16**（`go` 即 err，零增量） |
| 6 | err | 1,578,205,310 | 1.578 | 复现同一界限 |
| 67（全表） | err | 1,578,235,410 | 1.578 | 与 N=4 同时刻（后续项未被触达） |

⇒ **第一个失败单元 = `desc[3]`（MaxPool，`bypass-tile` 类）**；`desc[0..2]` 首三片**首次在板上 loud-done**
（此前"整帧从未过 desc[0]"）。

## 5. 失败根因（`desc[3]`）：**每层布局位（信箱区 7 道 2）未投递**（F1 §4.4 的必办项）

**证据链（板上 + 镜像，两边独立给出同一单元）**：

1. **板上**：§4 的二分——`desc[3]` 在 `go` 那一刻 err、零增量时间（无搬运前兆）。
2. **RTL**：`BypassExec.scala:1121-1126`——`wholeOk`（`geomOk` 含 `rowWOk`/`outPix≤MAXPIX`/
   `blkPlanarOk`）与 `tileOk` 都不成立 ⇒ 同一条**响亮 err + 零搬运**；其中 `blkPlanarOk` 需要
   **平面通路**（= 布局位）。
3. **镜像逐项复现（判决性）**：`y1/tools/frame_preflight.py --layout zero`（= 板上真实状态，
   区 7 道 2 恒 0）⇒ `DISPATCH_ERR=8 / 67`，**首个 err 单元 = 3（maxpool）**，8 个 err 单元
   = `3,12,17,22,29,30,33,34`（**全是旁路算子**：maxpool/resize/add）；同一命令 `--layout derived`
   ⇒ `DISPATCH_ERR=0`。单元的**编号与类别**与板上二分的边界**逐项一致**。
4. **归属**：`c4b_frame.md` §4.4 早就点过——"信箱区域 7 道 2（每层两位布局表）**未投递**：它需要
   `layout_adapt_ref.py` 那套逐层推导……**不猜；这是'真几何网表'上的必办项**"。驱动至今没投它。

**修复路径（下一片，不即兴）**：把冻结契约 `reports/c4b_input_layout.md` §1 的**可执行镜像**
（`frame_preflight.derive_layout`，按 `LAYER_ID` 每层两位）投进区 7 道 2（驱动 `mailbox_writes`
补一步"layout 记录"），再加一条**驱动侧判据**（该表与镜像逐项相等）；然后重跑本片 §4 的二分确认首错单元后移。

## 6. 墙钟首次实测（本片最重的新数字）

量具 = `y1/tools/npurun_t.c`（新，板内静态 riscv32、**单进程 mmap**）：写 `CTRL.start` 前读
`CLOCK_MONOTONIC`，忙等 `STATUS(done|err)`（单次 load，无 fork/无串口），⇒ **µs 级**分辨。
（驱动的 UART 轮询每次 ~1.5 s，**测不了**百毫秒级帧——这是本工具存在的理由；先例 = `ddmem.c`。）

| 量 | 值 | 口径 |
|:--|--:|:--|
| `desc[0]` 单独一帧 | **0.735 s** | 实测（板上真钟） |
| `desc[0..1]` | **1.256 s** | 实测（Δ unit1 = 0.521 s） |
| `desc[0..2]` | **1.578 s** | 实测（Δ unit2 = 0.322 s） |
| 到 `desc[3]` err 的总墙钟 | **1.578 s** | 实测（err 在 go，零增量） |
| 三单元的 64 MAC/拍地板（纯算术） | 23.2 ms | `mac_account` 口径：691,200+409,600+204,800 拍 ÷ 56.25 MHz |
| 全帧 A+B1+DCI 模型 | 96.3 ms（10.38 fps） | 5,418,000 拍 ÷ 56.25 MHz（T18c-5，**modeled**） |

**读数**：仅 3/67 个单元就花掉 **1.578 s** —— 对照其"地板"**68×**、对照全帧模型 **16× 以上**；
P0 §3 记的"as-built 墙钟上界 1.10 s/帧（11 拍/像素，issued 口径，**不含 gather 停顿**）"被
**单元级实测反超**。⇒ **停顿项（gather/喂列/每 tile 相位与 prime）主导墙钟**，P0 §7-5 挂着的
"11 拍/像素没有真作业逐拍对账"现在有了第一个真实数量级（**未归因**，见 §8）。
**没有完成的帧 ⇒ 本片不产生 measured fps**——这是诚实结论，不是"没测"。

## 7. G7 与负对照：**n/a + 为什么**（与 F1 §6 同因不同层）

G7 的四个量（IoU / 关键点 L2 / |Δconf| / 计数差）定义在两个**检出集**之间；本片帧在
`desc[3]` loud-err ⇒ **没有 12 路输出可读**（DST 无本轮语义）⇒ 四个量在数学上不存在。

| G7 量 | 本片 | 说明 |
|:--|:--|:--|
| 匹配框 IoU ≥ 0.5 | **n/a** | 无完成帧 ⇒ 无检出集 |
| 关键点 mean L2 ≤ 2 px | **n/a** | 同上 |
| \|Δconf\| ≤ 0.1 | **n/a** | 同上 |
| \|检出数差\| ≤ 1 | **n/a** | 同上 |
| 负对照（无人脸 ⇒ 0 检出） | **n/a** | 同因（跑不到输出段）；不拿"err"冒充"0 检出" |

**已就位、留给下一片的 B 侧（离线实测，本片记账）**：float ORT 基线 `grace_hopper.jpg`
⇒ **1 det**（conf 0.9405, box [228.0,128.4,206.2,232.6]）；`--no-face` ⇒ **0 det**。

## 8. 数字分类（measured / modeled / assumed；先例同前）

**Measured（板上现跑）**：烧写 done bit=1 + 8/8 启动 marker；`ID/STATUS` 探活；三块映像的
**板内整块回读 md5**（input `8c1bd05c…` / desc `4bd68b36…` / blob‖mult `151304d8…`，均与主机逐字节相等）；
信箱 7291 条就地回读一致；§4 的逐单元 done/err 与**墙钟 ns**（npurun_t）；前缀二分的首错单元；
镜像 `--layout zero/derived` 的 8-vs-0 对比。

**Modeled**：三单元"地板 23.2 ms"（纯算术）；全帧 96.3 ms / 10.38 fps（承 T18c-5）；
"`layout zero` 下的 8 个 err 单元"由镜像推得（板上只实测到其首个）。

**Assumed**：① 板钟 = 56.25 MHz（PLL RATIO0=12.0 的推值；本片未直接读 PLL 输出——fps 类换算
只在此假设下成立）；② `desc[0..2]` done 的**数值正确性未测**（本片只证"跑完"；逐层对账要另做）；
③ 传输 flake（~2/10）归属未定（板/网/主机其一），已用重试兜住、**未当作结论**。

## 9. 诚实边界（本片**没有**证明的）

1. **无完成帧**：无 measured fps、无 12 路输出、无 G7、无负对照——根因已钉死到单元
   （`desc[3]` + 布局位），但"修好后能过多远"未测。
2. **`desc[0..2]` 的数值正确性**未对账（只到 done）。
3. **墙钟 68× 的机制未归因**（候选：单发 32B 读的每请求延迟量级 / 每 tile prime 与收尾固定开销 /
   halo 重喂；判据建议：同一单元的 AR 请求计数 + 逐拍对账）。
4. **`XDMA_EN=1` 的其余内涵**（gather 路径在板上从未跑过完整帧）只到"desc[3] 之前不 err"。
5. 板卡现状（若下一片接手）：DDR 里 = input/blob/mailbox + **4 项前缀表**（二分残留）；
   NPU 空闲、`errSticky=1`；再跑驱动会**全部重灌**，无需重烧。

## 10. 复现（本片按序跑过的命令）

```bash
# ① 烧写（tag 必须是 pnr_c4a_t18c；JTAG 端口若被保留区覆盖见 §1-2）
cd /d/code/PDS/VexiiYeshenLinux && YESHENMINI_JTAG_PORT=65500 \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe -u \
  scripts/flash_and_verify.py --tag pnr_c4a_t18c --com COM7 --secs 180 --no-net

# ② 上板整帧（真帧必须 --xdma-en；net 通路）
cd y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  /d/code/PDS/NaxYeshenLinux/sim/reglogs/lxvenv/Scripts/python.exe -u \
  tools/npu_frame_run.py --run --port COM7 --xfer net --xdma-en --net-chunk 262144 --net-tries 8 \
  --img ../ai_npu_exp/deps_export/matplotlib/mpl-data/sample_data/grace_hopper.jpg \
  --json build/s3/board_face.json --deq-cache build/s3/deq_cache.json

# ③ 逐单元二分（临时件；板内 npurun_t 计时器）
python build/s3_bisect.py            # 输出见 §4 表
# ④ 镜像交叉复现（判决性）
cd y1 && python tools/frame_preflight.py --layout zero   # 首个 err 单元 = 3（maxpool）
cd y1 && python tools/frame_preflight.py --layout derived # DISPATCH_ERR=0
```

（量具源码：`y1/tools/npurun_t.c` + `y1/tools/build_npurun_t.sh`；板内二进制
`y1/build/npurun_t_rv32` = 66,804 B，md5 `060d4c1086262dc733e3503b81bb8683`。）

## 11. 指纹链（本片实际消费/生产的字节）

| 件 | md5 | 备注 |
|:--|:--|:--|
| 比特流（烧进板里的那份） | `d8993bfed723a4564470c0107f84360f` | 9,188,552 B（t18c / 18.4 ns / PLL 12.0） |
| 输入图 `grace_hopper.jpg` | `314296a0a5dd3c394e57f4efac733c20` | 61,306 B |
| input_int8 映像（NCHW int8，板 DDR 实收） | `8c1bd05c5141d597ebb22c45f4de588a` | 1,228,800 B；**主机 = 板上回读**互证 |
| 权重 blob `wgt_blob.bin` | `aa135f0f7d50780b7b13d9a1ba9c518a` | 404,064 B |
| `wgt_mult.bin` | `ff2ed3c66041e196718d9c62d8202b7d` | 268 B |
| blob‖mult（信箱映像，板上实收） | `151304d8d9e441162df1e1578c5619de` | 404,332 B；**主机 = 板上回读**互证 |
| `desc.bin`（冻结表，板上实收） | `4bd68b3610bcf7754cd50d39e27c2442` | 2,176 B；**主机 = 板上回读**互证 |
| **12 路输出 md5** | **n/a** | 没有完成的帧 ⇒ 无输出可读（不拿别的数冒充） |

## 12. 本片提交

- `3e2cede` flash_yeshen.tcl：`YESHENMINI_JTAG_PORT`（65420 被动态保留区覆盖的处置）。
- `8fb54d9` board_ddr._rd_md5：重试 + 容忍 rc=255（判据不放宽）。
- `5749821` board_ddr.prepare：mkdir 重试。
- （本报告 + `npurun_t.c` + `build_npurun_t.sh` 同批入库。）

---

## 13. **S3-3 续报（2026-10-17 夜）**：布局投递后整帧 `done=1` + **首测 fps=0.1541** + **G7 否定性红**（输出与输入无关的常数化帧）+ 首个失败点钉到 `desc[0]` 激活读

> 前提：**未重烧/未重 PnR**（板内比特流仍为 `d8993bfed723a4564470c0107f84360f`，§1 那份）；板自 S3-2 起未断电
> （uptime 连续）。上一片死在**回读传输迭代**上，本片先把传输面收口（§13.1），再把"完整帧"拿到手（§13.2），
> 然后做了三组**判决性实验**把"跑得完"和"算得对"分开（§13.4）。

### 13.1 传输面收口（WIP triage + UART 救块）

- **死手 WIP 判决 = 保留 + 一处修正**（commit **`f3c03f9`**）：
  - `board_ddr._read_tftp` 分块（`TFTP_CHUNK=8192`：板内 busybox tftp 停等、总耐心 ∝ 块数；
    64 KB 单文件四档 blksize 全灭、≤8 KB 可重试成功）+ `_read_tftp1` 本地块缓存 —— 但**缓存新鲜度判据
    收紧**：命中必须 = 本地 md5 == **刚刚 `ddmem rd` 从 DDR 重读出来**的板上 md5（死手原版查的是
    "上一轮的板上文件"，DDR 内容变过时会拿陈旧缓存冒充）。
  - `board_tftp`：`tries 4→6`、梯子改**优先 4096 重复试探**、发起前 `ping` 预热本机 ARP/邻居表
    （WSL NAT 下 Windows 邻居表冷掉 ⇒ 实测连续多轮 "WRQ 到了、OACK 无影"）；`pull_board_file`
    新增 `md5_want`（调用方刚取得的板上 md5 ⇒ 省一条 ssh）。
  - 行尾陷阱核查：`git diff --numstat` == `git diff -w --numstat`（无 CRLF 噪声）；`scripts/__pycache__/`
    已删（未跟踪碎屑）。
- **kps 子块 @0x81C34C00（8192 B）两轮会话共 >60 次 tftp 全灭**（WRQ 到、OACK 发、板内客户端每次
  `tftp: timeout`；相邻块稳定）——不是随机丢包。处置：**UART 控制台救块**（`ddmem rd - | base64`
  逐块 8 KB；`run_wait` 完成标记纪律；**UART 读到 == 板上 `ddmem` 落盘 md5** 才写本地缓存）
  ⇒ 8/8 块全部救回（md5 逐块在 `build/s3b/uart_rescue.log`），随后 harvest 在同款"新鲜 md5"判据下
  全部命中缓存走完。**UART 纪律**：控制台 PATH 没有 `/tmp/npu_f1` ⇒ 必须全路径 `ddmem`（本片踩坑一次）。

### 13.2 整帧结果（**首次 done**）

- 驱动侧（`npu_frame_run.py --run --xfer net`，layout=derived、XDMA_EN=1、7/9 两区信箱投递
  **7358 条**且就地回读一致）：**`final STATUS=0x00000001`（done=1 err=0）**；三块映像整块回读 md5
  全部对上（input/desc/blob‖mult，见 §13.5）。
- **板内 npurun_t（单进程 mmap、CLOCK_MONOTONIC、无串口）全帧 ×3**：

| run | 帧墙钟 ns | 折 s |
|--:|--:|--:|
| 0 | 6,491,551,220 | 6.4916 |
| 1 | 6,490,397,540 | 6.4904 |
| 2 | 6,490,934,340 | 6.4909 |

⇒ **measured fps = 1 / 6.4909 s = 0.1541 fps**（三帧散布 **±0.018%**；这是本计划**第一个实测 fps**）。
无脸输入再跑一帧 = 6,491,165,000 ns（**6.4912 s**，同一时间量级，见 §13.4）。

### 13.3 12 路输出采集与 G7 判定

12 路输出（int8 码点）**全部收齐**（拆分块 + UART 救块 + 双侧 md5 判据），指纹见 §13.5。检出（同口径 decode/NMS）：
板上 **8 dets**（conf 全 0.9085，框含负 y）vs float ORT 1 det（conf 0.9405）/ 同口径 int8 黄金 1 det（conf 0.931）。

**G7（比较器 `yunet_post.py --compare-a <board> --compare-b <ref>`；比较器自检 4/4 负对照发火，先过）：**

| G7 量（spec §4.3 拟定容差） | board vs **float ORT**（正式 B 侧） | board vs **同口径 int8 黄金** | 说明 |
|:--|:--|:--|:--|
| 匹配框 IoU ≥ 0.5 | **FAIL**（matched=0，无对） | **FAIL**（matched=0） | 板上 8 dets 与参照框零重叠 |
| 关键点 mean L2 ≤ 2 px | n/a（无配对） | n/a（无配对） | |
| \|Δconf\| ≤ 0.1 | n/a（无配对） | n/a（无配对） | |
| \|检出数差\| ≤ 1 | **FAIL**（count 8/1，diff=7） | **FAIL**（diff=7） | unmatched a=8 b=1 |
| 负对照（无脸 ⇒ 0 检出） | **0 检出（见 §13.4，但语义打折：全链与输入无关）** | 同 | |

**参照行（黄金自己）**：同口径 int8 vs float = **1/1 配对，IoU 0.8866 ✓、|Δconf| 0.0095 ✓、
检出数差 0 ✓，但 kp mean L2 = 4.81 px ✗** ⇒ **即便板上完全正确（输出=黄金），按拟定 2 px 容差的 G7
也会在关键点上红**——这是**容差口径**的账（spec §4.3 本就标注"拟定、可调"），与板结果分开记。

### 13.4 判决性实验：**"跑得完" ≠ "算得对"；且本帧与输入无关**

1. **desc[0] 单独跑（prefix(1)+表尾哨兵，npurun_t `DESC_COUNT=1`）**：done=1，**0.7343/0.7344 s**（与 S3-2 的
   N=1=0.735 s 复现）——但它的 DST（phys 0x8032C000，1.6 MB）**整个区间 = 常数 0x29**（多点抽读：
   偏移 0/0x140/0x19000/尾部 全 0x29）。
2. **Canary 写**：主机把 `0x5A×2048` 写进 desc[0] 的 DST（UART 复核 0x5A）→ 跑 prefix-1 → 读回
   **`0x5A` 被抹掉、变回全 `0x29`** ⇒ **NPU 确实在写这块区域，但写出来的是填充常数**。
3. **无脸整帧**：把驱动同口径的 no-face 输入（md5 `a38d9830…`）灌进 input 区，全帧 6.4912 s done；
   读回 **cls_8 / obj_8 / cls_16 / obj_16 与正脸帧逐字节相同**（md5 逐路相等，见 §13.5），
   cls/obj 六路 score = sqrt(cls·obj) 最大 0.003/0.004/0.018 ⇒ **0 检出**。
4. **cls_8 canary**：`0x5A×512` 写进 cls_8 区 → 跑全帧 → 读回**与历来完全相同的 cls_8 字节**
   （`0a2c302a…`）⇒ 该区**确实被本帧重写、确定性、且与输入无关**。
5. **常数输入的黄金对照**（离线 quant_ref，unit0）：输入=常数（int8 码 41 或 0）时黄金输出**不是常数**
   （border 逐行零填充会留出边界结构：head = `80bfbf…` / `80caca…`，distinct≈25）——而板上 desc[0]
   的输出是**无边界结构的全 0x29** ⇒ 不是"常数图过正确卷积"，是**数据通路被填充短路**。

⇒ **归因链（本片能钉到的最后一环）**：**首个失败点 = `desc[0]`（Conv_0）的激活读**——它拿到的不是主机
写进 phys 0x80200000 的 input_int8，而是常数（0x29 档）；下游 desc[1..66] 在这些常数上**确定性**地跑完
（6.49 s），12 路输出 = 该常数帧的确定性函数。**`0x29` 的产地**（未写区 DDR 上电填充 vs 读路径返回
填充 vs 写路径的 strobe/数据缺失）**未判决**——但"数据通路与输入无关"这一点已被两组独立实验钉死。
**下一个探针（建议）**：desc[0] 的 SRC 常数换成可区分值（如主机把 input 区**整块**换成 0x40 填），
看 desc[0] DST 是否跟着变——若不变 ⇒ 读的是别处/填充；若变 ⇒ 读的 input 区但搬运有系统性错位。
**注意**：驱动 phys 约定（`phys = 0x80000000 + npu`）与胶合块 28→32 位**零扩展**
（`src/YeshenSocGlue.scala:942-945`）之间的关系**必须逐位核对**（谁把 0x8 高位带进 DDR）——这是本次
"读不到真数据"的首要嫌疑面，但本片**没有判决**是它。

### 13.5 指纹链（S3-3 消费/生产的字节）

| 件 | 指纹 | 备注 |
|:--|:--|:--|
| 比特流（板上那份，未重烧） | md5 `d8993bfed723a4564470c0107f84360f` | 9,188,552 B（t18c） |
| 输入图 `grace_hopper.jpg` | md5 `314296a0a5dd3c394e57f4efac733c20` | 61,306 B |
| input_int8（正脸，板上实收） | md5 `8c1bd05c5141d597ebb22c45f4de588a` | 1,228,800 B；主机=板上互证（run1） |
| no-face input（§13.4-3） | md5 `a38d9830…`（12 位前缀，全量在 `build/s3b/noface_net.log`） | 1,228,800 B |
| `desc.bin`（冻结表，板上实收） | md5 `4bd68b3610bcf7754cd50d39e27c2442` | 2,176 B |
| blob‖mult（板上实收） | md5 `151304d8d9e441162df1e1578c5619de` | 404,332 B |
| 布局表投递（区 7 道 2） | `LAYOUT_BITS_MD5=f24fb2bc42f115f0b8e43409569f5d65` | 67 层×2 bit；drv 打印 |
| 信箱投递 | 7358 条寄存器写就地回读一致 | XDMA_EN=1 + LAYOUT + 7290 参数 |
| **12 路输出（int8 全量 md5；§13.3 那个"板上输出"）** | 见下 12 行 | 与同口径黄金**全不等**；与输入**无关** |

| 输出 | int8 md5（板） | 输出 | int8 md5（板） |
|:--|:--|:--|:--|
| cls_8 | `59508e944fa6e7c2fbb28751a72337d3` | bbox_8 | `78ccd5ca7070544587615faca21eda12` |
| cls_16 | `a7b68906046eeb3ea9db07979b4f63a5` | bbox_16 | `e919c1afd4a1b2227f6049ecc808b022` |
| cls_32 | `801ed83891a9d5fe80f04496a32ce7fa` | bbox_32 | `24012b3b41dc62a9626c8f44da80113e` |
| obj_8 | `b2797afa633987694925ddb068b86686` | kps_8 | `9669d9a469addb0921343430f3cf5577` |
| obj_16 | `ead3904efafa3a7a8856639fd8ba373f` | kps_16 | `5b59a88f5a5c930a60f42b8b91a159e1` |
| obj_32 | `d73b0caead970a7e2f8bb8f9e5686122` | kps_32 | `13bc4c709e8efceb4fa59c93cd7ae0ef` |

（原始对齐块 md5（含 pad）在 `build/s3b/board_face.json::block_md5`；12 路 int8 与黄金的**逐像素差**
统计在 §13.4 引用的本地分析里：cls_8 6277/6400 不等（多数 |Δ|=127）、obj_8 169/6400（全在 row0/col0 +
两簇）、bbox/kps 大面积不等（|Δ| 分布宽）——"近而全错"的形状。）

### 13.6 停顿归因（对照表与边界）

| 量 | 值 | 口径 |
|:--|--:|:--|
| **全帧墙钟（本片实测）** | **6.4909 s**（×3 散布 ±0.02%；无脸 6.4912 s） | npurun_t，板内单进程 |
| desc[0] 单独 | 0.7344 s（本片）/0.735 s（S3-2） | 同上；layout 投递前后一致 |
| ideal：全帧 64 MAC/拍地板 | 95.6 ms（10.46 fps） | `mac_account`（344.2 MMAC ÷ 64 ÷ 56.25 MHz） |
| as-built issued 拍 | 801.3 ms（1.25 fps） | 同上（issued_beats 45.08 M） |
| IMPL_A（切片 A 口径） | 247.5 ms（3.59 fps） | 同上 |
| 实测/ideal = **67.9×**；实测/issued = **8.1×**；实测/IMPL_A = **26.2×** | | |

**能定的边界**：驱动轮询被排除（npurun_t 单进程、无串口、no fork）；**时间与输入数据无关**
（正脸/无脸两帧同时间、desc[0]/全帧两个尺度都一致）⇒ 停在**每单元固定开销/搬运往返**档（每单元平均
96.9 ms；前 3 个大单元占 1.578 s=24%）。**未定的**：每单元内部这 96.9 ms 的拆分（setup / prime /
gather 往返 / 写回 / 权重装载）。

**前缀梯子（本片实测，layout=derived，全 13 点 done=1；`build/s3b/ladder_out2.log`）**：

| N | 墙钟 s | 增量 s（含单元） | MAC 地板 ms（该段） | 实测/地板 |
|--:|--:|:--|--:|--:|
| 1 | 0.735 | desc[0] Conv_0 | 12.29 | 59.8× |
| 2 | 1.256 | +desc[1] Conv_2 | 7.28 | 71.7× |
| 3 | 1.578 | +desc[2] Conv_3(dw) | 4.10 | 78.3× |
| 4 | 1.681 | +desc[3] **MaxPool（0 MAC！）** | **0.00** | **∞（104 ms 纯开销）** |
| 5 | 1.805 | +desc[4] Conv_6 1×1 | 1.82 | 68.1× |
| 6 | 1.882 | +desc[5] Conv_7(dw) | 1.02 | 75.5× |
| 8 | 2.283 | +desc[6..7] | 5.69 | 70.5× |
| 12 | 4.043 | +desc[8..11]（含 32/64 趟大 1×1） | 27.99 | 62.9× |
| 16 | 5.002 | +desc[12..15] | 15.59 | 61.5× |
| 24 | 5.371 | +desc[16..23] | ~4.0 | ~92× |
| 32 | 5.544 | +desc[24..31] | ~3 | ~58× |
| 48 | 6.287 | +desc[32..47] | ~32 | ~23× |
| 67 | **6.490** | +desc[48..66]（19 个尾单元） | ~5 | ~41× |

**读法**：**比值在 23–92× 之间、且与"单元类"无明显相关**；**零 MAC 的 MaxPool 花 104 ms**
（=纯固定开销，任何算力口径都无法解释）；1×1 小卷积也各 ~60–75× 其地板。⇒ **当前限流项 =
每单元固定开销档**（setup/相位 + 张量往返；单单元 50–120 ms），**不是** MAC/带宽极限；96.9 ms/单元
的内部拆分（setup vs gather vs store vs 权重装载）**仍未归因**（需逐相位量具/AR 计数；本片没有）。
末点 N=67=6.4904 s 与 §13.2 的 ×3 独立复测一致。**诚实一句话**：这不是"算力/带宽不够"的证据——
因为这一帧根本没在算真数据；**它是"每单元开销"的上界量，不能拿来定价真帧**。

### 13.7 measured / modeled / assumed + 尚未证明

- **Measured**：整帧 done=1 err=0（驱动 + npurun_t ×4）；6.4909 s/帧（×3 散布 ±0.02%）；desc[0] 单跑
  0.7344 s；三块映像+信箱的板上 md5；12 路输出字节与 md5；canary 被覆盖（两处：desc[0] DST→0x29；
  cls_8→同值重写）；无脸帧与正脸帧四路输出逐字节相同、六路 cls/obj 分数 ≤0.018；UART 救块 8/8。
- **Modeled**：95.6/801.3/247.5 ms 三档地板（`mac_account`）；"0x29 是 DDR 上电填充"（候选，未判决）。
- **Assumed**：板钟 56.25 MHz（换算 dependent）；"输入无关"对 bbox/kps 未逐路做（cls/obj 8/16 已证，
  desc[0] 已证；同链路上外推）；§13.4-5 的"无边界结构"只抽读头部 4 处。
- **尚未证明（not yet proven）**：① `0x29` 产地与"读不到真数据"的确切环节（胶合 28→32 零扩展 vs
  驱动 phys 约定 vs 更深处）；② desc[0] SRC 换成可区分填充后的行为（下一探针，§13.4 尾）；③ 本片
  ladder 的逐单元增量（已启动、未落表则以日志为准）；④ **真数据的正确性**：既然帧是常数函数，G7
  只证明了"输出≠黄金"，**没有**证明 RTL 数值通路在真数据上对/错；⑤ 断电重启后的确定性。

### 13.8 板卡现状（交接）

- 未断电、未重烧；NPU IDLE（最后一次 npurun_t 全帧 done=1，STATUS 粘滞位 done；再跑会 soft_reset）。
- DDR：input = **正脸** input_int8（已恢复，md5 `8c1bd05c…` 复核通过）；DESC_TABLE = **整表**（md5
  `4bd68b36…` 复核通过）；arena：desc[0] DST = 0x29 填充；其余为最后一次全帧的确定性值。
- COM7 空闲（本片所有串口会话均已正常收尾）；`/tmp/npu_f1/` 内有 ddmem/npurun_t + 救块落文件（可再用）。

### 13.9 复现（本片按序跑过的关键命令）

```bash
# ① 传输面收口（WIP triage+修正）
git show f3c03f9            # board_ddr/board_tftp 的处置
# ② UART 救块（tftp 拉不动的 8 个 kps 子块；UART==板上 md5 才写缓存）
cd y1 && PYTHONIOENCODING=utf-8 PYTHONPATH='./.pydeps;../third_party/yunet/deps' \
  $PY -u build/s3b/uart_rescue.py          # 8/8，日志 build/s3b/uart_rescue.log
# ③ 12 路输出采集（缓存命中 + 新鲜 md5 判据）
cd y1 && ... $PY -u build/s3b/harvest.py   # → build/s3b/board_face.json（12 路 md5+dets）
# ④ 精确 fps（板内计时器 ×3）
scripts/board_ssh.py "/tmp/npu_f1/npurun_t 0x00100000 67 3"   # 6.4916/6.4904/6.4909 s
# ⑤ G7（比较器；先 --selftest）
$PY -u y1/tools/yunet_post.py --selftest
$PY -u y1/tools/yunet_post.py --compare-a y1/build/s3b/board_face.json \
  --compare-b y1/build/s3b/float_face.json          # FAIL: count 8/1
# ⑥ 判决实验（canary / 无脸 / prefix-1）见 §13.4，脚本 build/s3b/{unit_probe,uart_rescue}.py
#   与内联片段；日志 build/s3b/{canary_net,canary2_net,noface_net,unit0_net2}.log
# ⑦ 停顿梯子（N 前缀墙钟）
cd y1 && ... $PY -u build/s3b/ladder_run.py        # 结果 build/s3b/ladder_out.log
```

### 13.10 本片提交

- **`f3c03f9`** —— tftp 回读分块+缓存（新鲜度判据收紧）+ ARP 预热 + 重试梯子（WIP triage 落地）。
- （本条提交）—— 本报告 §13 全文（S3-3 结果/判决实验/指纹链/归因与边界）。临时件（`build/s3b/*`）不入库。

---

## 14. **S4-A 复跑（2026-10-17 晨）**：根因修复后 —— 输入依赖恢复 **9/12 路**、**3 路仍与输入无关**；**G7 仍红（13 vs 1）**；fps = 0.1541（不变）；**逐单元归因**（成本 ∝ 激活体量，不是"固定 97 ms/单元"）

> 前提：**未重烧、未重 PnR**（板内比特流仍为 `d8993bfed723a4564470c0107f84360f`）；驱动侧带**两个已提交的修复**复查：
> `b8ad521`（M 投递跳过 lid≥PN_LAYERS=64，消回绕）+ `698315e`（起跑前 `STATUS=1` 清 done 粘滞位）。
> 本次要回答三件事：① 输入依赖是否恢复（正脸 vs 无脸）；② G7 的裁决；③ 每单元固定开销到底是什么。

### 14.1 复跑与一致性（**首次 poll0=0** 与 **逐字节复现**）

- 命令：`npu_frame_run.py --run --port COM7 --xfer net --xdma-en --net-chunk 262144
  --net-tries 8 --img grace_hopper.jpg --json build/s4b/board_face.json`（+ `--no-face` 的第二次）。
- **粘滞位修复生效（板上证据）**：`poll0 STATUS=0x00000000 done=0 err=0`（**首次不再假 done**）→
  `final STATUS=0x00000001`（轮询 5 次、8.7 s）。无脸帧同样 poll0=0 → done=1 err=0。
- 传输面：input/desc/blob 三块**整块回读 md5 全对**；信箱 **7346 条**（= 7358 − 12：
  `b8ad521` 跳过的 3 条 M 记录 ×4 道；`LAYOUT_BITS_MD5=f24fb2bc42f115f0b8e43409569f5d65`）。
- **确定性**：s4b 正脸帧与上一会话 s4a 正脸帧 **12 路输出逐字节相同**（ALL SAME）⇒ 修复后的帧是
  确定性函数；s4a 03:49 的那份 harvest 事后被证明是有效数据。
- 无脸帧回读在 **kps_8 的诅咒块**（tftp 停等链路对该块确定性失效，S3-3 同款）上中止 ⇒ 驱动没写
  JSON；已读的 cls/obj/bbox 落块缓存，kps 三路经 **UART 救块 11/11**（md5 双侧判据）救回，
  再用驱动自己的 `readback_to_tensors`+`postprocess` 拼出 `build/s4b/board_noface.json`
  （来源注明"驱动回读 + UART 救块"，字节仍是 DDR 实测）。

### 14.2 输入依赖检查：**9/12 恢复，3/12 仍免疫**（含 canary 判决）

同一驱动、同一参数、只换输入（正脸 `8c1bd05c…` vs 无脸 `a38d9830…`）：

| 输出 | 正脸 int8 md5 | 无脸 int8 md5 | 判决 |
|:--|:--|:--|:--|
| cls_8 | `4e1a99e949c85ffcb25c77b4d31f74f5` | `cd863fd2036765138b74b2a3020d12e2` | **变** |
| cls_16 | `f4148b81d97def99a3dfd3a487dfcfdd` | `b3a23b6623e4e7c028342935b152c686` | **变** |
| cls_32 | `5edbd1285d398314a4c9492b8f0d93a6` | `5edbd1285d398314a4c9492b8f0d93a6` | **不变** |
| obj_8 | `eea87bb1e89f22945d30e10cb5e54ca3` | `f05c72823814d20aecefd82ff4bc87a8` | **变** |
| obj_16 | `ead3904efafa3a7a8856639fd8ba373f` | `ead3904efafa3a7a8856639fd8ba373f` | **不变** |
| obj_32 | `d73b0caead970a7e2f8bb8f9e5686122` | `d73b0caead970a7e2f8bb8f9e5686122` | **不变** |
| bbox_8 / 16 / 32 | `94e8897a…` / `91a5afb1…` / `dbb09b4a…` | `d6def02a…` / `1a0b1c3f…` / `22cfadec…` | **全变** |
| kps_8 / 16 / 32 | `12dddd6f…` / `23a4806c…` / `231991e1…` | `f3b4febd…` / `7d774f39…` / `a3f72e21…` | **全变** |

**canary 判决（0x5A 灌满 → 跑帧 → 回读；区分"没被写"vs"写了但常数"）**：

| 区 | canary 结果 | 结论 |
|:--|:--|:--|
| cls_32（416 B 块、写 400 B） | 400 B 载荷**逐字节复原**（`5edbd128…`），尾 16 B 对齐 pad 保留 0x5A | **被写**，且值与输入无关 |
| obj_16（1600 B 全写） | 1600 B **逐字节复原**（`ead3904e…`），n(0x5A)=0 | **被写**，且值与输入无关 |
| obj_32（416 B 块、写 400 B） | 400 B 载荷**逐字节复原**（`d73b0cae…`），尾 16 B = 0x5A | **被写**，且值与输入无关 |

⇒ **诚实结论**：M 回绕修复把输入依赖恢复给了 9 路（cls_8/16、obj_8、bbox×3、kps×3），
**但 `desc[63]`(cls_32) / `desc[65]`(obj_16) / `desc[66]`(obj_32) 三路仍与输入无关**——
它们被这一帧**确定性重写**成同一份字节；其中 obj_16/obj_32 **连 M 修复前的常数帧值都逐字节相同**
（obj_16 `ead3904e…`、obj_32 `d73b0cae…` 在 s3b 就是这枚指纹），cls_32 随修复变过（`801ed838→5edbd128`）
但**不随输入变**。三路的生产者分别是 `desc[42]`(Conv_59) / `desc[52]`(Conv_69) / `desc[54]`(Conv_71)
（都是 32 B 权重的 1×1→3×3 尾卷积）——这是**下一步的第一探针位**（见 §14.7）。**修复不完整**，如实记录。

### 14.3 G7 判定：**仍红**（13 个检出 vs 1 个；零配对）

| G7 量（spec §4.3 拟定容差） | board vs **float ORT**（正式 B 侧） | board vs **同口径 int8 黄金** | 说明 |
|:--|:--|:--|:--|
| 匹配框 IoU ≥ 0.5 | **FAIL**（matched=0；unmatched 13/1） | **FAIL**（matched=0） | 板上 13 个检出与参照框零重叠 |
| 关键点 mean L2 ≤ 2 px | n/a（无配对） | n/a（无配对） | |
| \|Δconf\| ≤ 0.1 | n/a（无配对） | n/a（无配对） | |
| \|检出数差\| ≤ 1 | **FAIL**（count 13/1，diff=12） | **FAIL**（diff=12） | |
| **负对照（无脸 ⇒ 0 检出）** | **PASS**（0 dets；score 上界 0.0176 ≪ 0.90） | 同 | 与 float/int8 两参照 0/0 配对 |

**失败签名（可复算）**：13 个检出**全部 stride=32、conf 全部 = 0.9085、全部锚在特征图第 0 行**、
框 y 为负——直接来自 32 路的头：板上 `obj_32 ∈ [0.50,1.00]`（黄金：除 1 个锚 ~1.0 外**全 0**）
⇒ 顶行锚的 `sqrt(cls·obj)` 集体越过 0.9。此外逐张量对黄金：cls_8 相关 0.17、bbox/kps 相关 ≈0.05
（"近而全错"的形状延续）——**不是只有三路常数头的问题，整个头部数值还远**。

**kp 容差口径（独立记账，不混入板上裁决）**：同口径 int8 黄金 vs float ORT 本身
`kp_l2 = 4.81 px > 2 px`（IoU 0.8866 ✓、|Δconf| 0.0095 ✓、count 0 ✓）⇒ **2 px 这条线对"完美板"
也走不通**，是容差口径账（spec §4.3 本就标注"拟定、可调"）。

### 14.4 measured fps（墙钟；板内 npurun_t ×3）

| 状态 | 三次帧墙钟 ns | 折 s | fps | 散布 |
|:--|:--|--:|--:|:--|
| **正脸**（灌回 `8c1bd05c…` 后） | 6,490,581,110 / 6,490,339,970 / 6,490,968,830 | **6.4906** | **0.15407** | ±0.005% |
| 无脸（UART 救块时同状态） | 6,500,084,930 / 6,460,797,140 / 6,495,421,190 | 6.4854 | 0.15419 | 0.6%（含一枚 6.4608 离群） |
| 梯子末点 N=67（第 4 枚独立读数） | 6,491,623,370 | 6.4916 | 0.15405 | — |

⇒ **measured fps = 0.1541**（与 S3-3 的 0.1541 相同：修复不改变帧时间；帧时间对输入不敏感 ≤0.1%）。
**驱动轮询账**：UART `devmem` 轮询量化 8.7 s/帧（5 次轮询）——比真帧多 ~2.2 s，是**主机侧**成本，
npunrun_t 单进程忙等口径里为 0。

### 14.5 逐单元归因（本片新增量具：67 点细梯子）

**做法**（比 s3b 版省 66 次整表写）：完整表在 DDR，前缀 N = 只改 2 个 32 B 项
（项 N−1 真值 + 项 N 哨兵）+ `DESC_COUNT=N` → npurun_t 1 帧。
**坑（已修）**：busybox `printf '\0NNN'` 不是三位八进制（按 `\0NN` 收 2 位 + 字面数字，且 `\377` 走
UTF-8 编成 2 B）——首次梯子把表写坏、全点 20 µs 响亮 err；改走 **ssh stdin 喂 `ddmem wr -`**
（二进制安全，RSEG=OK 判据仍在）后 66/67 点成功（丢 desc[44]/desc[52] 两点，N=45 三次无标记）。
本次梯子跑在**正脸真数据**上，与 s3b 常数帧梯子在共享点吻合（0.734/1.257/1.578/1.681 vs
0.735/1.256/1.578/1.681）⇒ **逐单元时间也是数据无关的**。

**聚合**（Σ 增量 = 5.762 s（64 读数）+ desc[0]=0.734 s ⇒ 6.496 s ≈ 整帧 6.4916 s，闭合 0.07%）：

| 类 | n | Σ 增量 (s) | 占帧 | 备注 |
|:--|--:|--:|--:|:--|
| conv1x1 | 26 | 3.967 | 61% | 大张量 1×1 是绝对大头 |
| depthwise | 19 | 1.363 | 21% | 次大头 |
| maxpool | 4 | 0.255 | 3.9% | **0 MAC、0 权重** |
| add | 2 | 0.109 | 1.7% | 0 MAC |
| resize | 2 | 0.053 | 0.8% | 0 MAC |
| conv3x3 | 5 | 0.015 | 0.2% | 全是 32 B 小尾卷积 |
| sigmoid | 6 | 0.000 | 0.0% | 各 ~1 ms |

**top-12（Σ 占 85%）**：`Conv_15`(0.866 s！32 趟 1×1 160²) > `Conv_2`(0.522) > `Conv_12`(0.433) >
`Conv_19`/`Conv_22`/`Conv_51`(各 0.388) > `Conv_3`(dw, 0.321) > `Conv_16`(dw, 0.308) > `Conv_9`(0.247)
> `Conv_10`/`Conv_13`(dw, 各 0.154) > `Conv_6`(0.124)。**零权重单元 14 个合计仅 0.417 s（6.5%）**。

**相关性（有权重 50 单元）**：inc~outB **0.83**、inc~inB **0.70**、inc~wgtB **0.30**；
线性拟合 `inc_ms ≈ −20 + 4.6·wgtKB + 0.311·inKB`（rms 残差 106 ms）。
**读法（拆 setup / 权重装载 / DDR 往返 / 轮询）**：

1. **驱动轮询 = 0**（npunrun_t 单进程；UART 路径才 +2.2 s，见 §14.4）。
2. **权重装载不主导**：整帧 blob 才 404 KB、相关性 0.30；反例 `Conv_15`（18 KB 权重）0.866 s
   vs `Conv_19`（36.9 KB 权重）0.388 s——权重多的反而快 ⇒ 排除"权重装载主导"。
3. **每单元 setup 也是小头**：最小的 30+ 个单元各 ≤20 ms、sigmoid ~1 ms ⇒ flat setup 在天花板
   1–20 ms 档，**§13.6 的"97 ms/单元"是"对大单元求平均"的假象**，本片把它修正掉。
4. **主导项 = 随激活体量走的搬运算**：成本与 in/out 字节强相关；有效"有用字节"速率
   ≈ 0.30 µs/B（≈3.3 MB/s）。**对照该量级的另一把尺**：A2 实测本板可达 DDR 带宽（CPU u32 路）
   仅 38–47 MB/s；把 mac_account 标定的 **~23× 读放大**计入 ⇒ 真 DDR 读流量 ~75 MB/s 量级 ——
   与"可达带宽"同阶 ⇒ **与"帧被 DDR 往返/读放大限住"自洽**，与 4000 MB/s 的 raw 天花板无关。
   （放大模型只在 2 个标定点上校准过；旁路单元的放大未测——见 §14.7。）

### 14.6 指纹链（S4-A 消费/生产的字节）

| 件 | 指纹 | 备注 |
|:--|:--|:--|
| 比特流（板上那份，**未重烧**） | md5 `d8993bfed723a4564470c0107f84360f` | 9,188,552 B（t18c） |
| 输入图 `grace_hopper.jpg` | md5 `314296a0a5dd3c394e57f4efac733c20` | 61,306 B |
| input_int8（正脸，板上实收×2） | md5 `8c1bd05c5141d597ebb22c45f4de588a` | 1,228,800 B；run 与灌回两次互证 |
| input_int8（无脸，板上实收） | md5 `a38d9830a1c9cc5a61e9345bf7921496` | 1,228,800 B（日志 12 位前缀 `a38d9830a1c9` 吻合） |
| `desc.bin`（冻结表，板上实收） | md5 `4bd68b3610bcf7754cd50d39e27c2442` | 2,176 B（复跑 + 修复后回写两次互证） |
| `wgt_blob.bin` / `wgt_mult.bin` | md5 `aa135f0f7d50780b7b13d9a1ba9c518a` / `ff2ed3c66041e196718d9c62d8202b7d` | 404,064 B / 268 B |
| blob‖mult（信箱映像，板上实收） | md5 `151304d8d9e441162df1e1578c5619de` | 404,332 B |
| 布局表投递（区 7 道 2） | `LAYOUT_BITS_MD5=f24fb2bc42f115f0b8e43409569f5d65` | 67 层×2 bit；drv 打印 |
| 信箱投递 | **7346** 条寄存器写就地回读一致 | XDMA_EN=1 + LAYOUT + 参数（−12 = 跳过的 M 记录） |
| 板内量具 | npurun_t md5 `060d4c1086262dc733e3503b81bb8683`；ddmem md5 `4d42cf4d8608`（12 位） | /tmp/npu_f1/ |
| **12 路输出（正脸 int8 md5）** | 见 §14.2 表左列 | 与 s4a 逐字节相同（确定性） |
| **12 路输出（无脸 int8 md5）** | 见 §14.2 表右列 | 3 路与正脸相同（输入无关） |

### 14.7 measured / modeled / assumed + 尚未证明

- **Measured**：修复后 poll0=0 与 done=1 err=0（正/无脸两帧）；12 路正脸输出对 s4a **逐字节复现**；
  9/12 输入依赖、3/12 输入无关；3 路 canary"被写 + 逐字节复原"；G7 13 vs 1（零配对）；
  负对照 0 dets（score 上界 0.0176）；fps 正脸 ×3 = 6.4906 s ±0.005% 与无脸 ×3；67 点细梯子
  66 读数（Σ 闭合 0.07%）；UART 救块 11/11。
- **Modeled**：23× 读放大 ⇒ 真 DDR 流量 ~75 MB/s 的换算；`inc≈0.311 ms/KB(in)` 拟合
  （rms 106 ms）；§13 的 0x29 产地等旧条目不变。
- **Assumed**：板钟 56.25 MHz（fps 换算 dependent）；"分块顺序/几何"未逐单元复核。
- **尚未证明（not yet proven）**：① **三路常数头的机制**——写侧还是读侧？（`desc[42]/[52]/[54]`
  的 DST 是否真被写、`desc[63]/[65]/[66]` 的 Sigmoid 读的是不是它）——本轮只证"输出与输入无关且
  被重写"，**没有**做中间张量与黄金的逐层比对（上一会话的 walkback 起过头，未收口）；
  ② 为什么 cls_32 随 M 修复变、却不随输入变；③ 9 路"输入依赖"输出的**数值正确性**——它们对黄金
  的相关 0.05–0.2，**仍未在任何单元上证明算对**；④ tftp 诅咒块的确定性失效归属（板/网/内容）；
  ⑤ "DDR 往返限定"缺 AR 计数直证；⑥ 断电重启后的确定性（未测）。

### 14.8 板卡现状（交接）

- **未断电、未重烧**；NPU IDLE（末次梯子 N=67 done=1，done 粘滞位=1）。
- DDR：input = **正脸**（`8c1bd05c…` 复核）；DESC_TABLE = **完整表**（梯子末点自动还原；起点曾
  全表回写 `4bd68b36…` 复核）；输出区 = 正脸帧确定值（末次 N=67 全跑）。
- COM7 空闲；`/tmp/npu_f1/` 有 ddmem/npurun_t + rd_* 落盘（可清）。
- **复现（本片新增）**：

```bash
# ① 修复后整帧（正脸；先决 = 板已启动、DDR 空）
cd y1 && ... $PY -u tools/npu_frame_run.py --run --port COM7 --xfer net --xdma-en \
  --net-chunk 262144 --net-tries 8 --img .../grace_hopper.jpg \
  --json build/s4b/board_face.json --deq-cache build/s4b/deq_cache.json
# ② 无脸帧 = 同命令 + --no-face（kps_8 撞 tftp 诅咒块时：build/s4b/uart_rescue2.py 救 11 块，
#    build/s4b/assemble_noface.py 拼 board_noface.json）
# ③ 输入依赖表 = build/s4b/board_face.json vs board_noface.json 的 out_int8_md5（§14.2 表）
# ④ canary 判决 = build/s4b/canary3.py（0x5A 灌三区 → npurun_t 67×3 → 回读比对）
# ⑤ fps = board_ssh "/tmp/npu_f1/npurun_t 0x00100000 67 3"（正脸态）
# ⑥ 细梯子 = build/s4b/fine_ladder.py（64 B flip + DESC_COUNT=N；结果 build/s4b/fine_ladder.log）
# ⑦ G7 = tools/yunet_post.py --compare-a build/s4b/board_face.json --compare-b build/s3b/float_face.json
```

### 14.9 本片提交

- （本条提交）—— 本报告 §14 全文（输入依赖检查 / G7 / fps / 逐单元归因 / 指纹链 / 边界）。
  临时件（`build/s4b/*`）不入库。**修复本体**已是先前的 `b8ad521` + `698315e`（本片只验不改）。

## 15. **S4-B（2026-10-17 午）**：常数化帧的**三个宿主侧根因**（D1/D2/D4）+ 免 RTL/PnR 的修法

> 前提：仍**未重烧、未重 PnR**（板内比特流 `d8993bfed723a4564470c0107f84360f`）。本片把 S4-A 的三路
> 常数头**向上追到最底层**：不是 RTL 算错，而是**交付量表/驱动投递**的三处口径缺陷，其中任意一处
> 都足以让整帧变成"近而全错"的常数帧。

### 15.1 证据链（逐层回读，S4-A 的 DDR 现场）

对 S4-A 那一帧的 DDR 逐区回读（`ddmem rd + tftp`，md5 双侧判据）并与同口径黄金比对：

| 张量 | desc | 板端实测 | 判决 |
|:--|--:|:--|:--|
| `Conv_54/56/58/66/68/70`（6 个 1×1 头尾） | 37/39/41/49/51/53 | 全部与黄金**逐字节不等**（mismatch 400..6400/6400） | 头链**上游**已错 |
| `Conv_55/57/59/67/69/71`（6 个 3×3 尾） | 38/40/42/50/52/54 | 同上；`Conv_59` = `[-24,5,19,29,31,31,…]`（第 4 像素起恒 31）、`Conv_67` = `127,-128,-128,…` | 同上 |
| **`desc[0]`（Conv_0）整区** 1.6 MB | 0 | **全部 = 127**（5 点抽样：偏移 0/400000/800000/1600000/1638336 全 127，单值） | **首个单元就饱和成常数** |

`desc[0]` 的 127 是**判决性**的：用转换器表里的 `M=1423026`（S4-A 时是旧口径；见下）配 `z_y=41` 算
（真图码点、真权重）⇒ 每像素 `(acc·M)>>30 + 41 ≈ 128+41 ⇒ clamp 127`；而若用**折进后的** `z_y_eff=-128`
⇒ 输出 ≈ **0**。板端是 127 ⇒ **板上 epilogue 用的是 `z_y`（conv 自刻度），不是 `z_y_eff`**。这就是 D2。

### 15.2 三个根因

**D1 —— 标定域不一致（承重）**：转换器 `y1_convert.build()` 用 `qref.Model(onnx)` 的**默认合成输入
`U[0,1)`**（`quant_ref.synth_input`）做激活标定 ⇒ 输入激活 `s_x=1/255`；而驱动 `to_int8_input()`
对真图（`0..255`）量化得 `s=1, z=-128`。**码点相同、解释不同** ⇒ 首层
`bias_adj = round(bias/(s_x·s_w)) − z_x·Σw` 与 `M = s_x·s_w/s_y` 差 **255 倍**：
实测 `centering[0].s_x = 0.00392156`（=1/255），黄金同口径为 **1.0**。
后果：`acc` 被 ~2×10⁶ 的 bias 主导（卷积项仅 ±2×10⁴）⇒ **Conv_0 每通道近似常数**
（合成口径黄金 `Conv_0` distinct=**39**；真图标定后 =**246**）。整网从第一层起就是常数帧。

**D2 —— 折进 Relu 的 epilogue 零点投错**：15 个 `folded_ops` 单元的 `M` 用的是**折进后的**
`s_y_eff`（`c4a_coverage.md` §7-O1 的冻结语义），但驱动 `mailbox_writes` 的 `RGN_ZY` 投的是
`centering[*].z_y`（conv **自刻度**的零点）。折进单元的 `z_y_eff` 全是 **-128**（ReLU 输出域），
而 `z_y` 是 41/-3/5/30/... ⇒ epilogue 整体偏移 `z_y_eff − z_y`，15 个单元的输出逐通道饱和。

**D4 —— Sigmoid 的固定点与冻结 LUT 不同源（结构性）**：`SigmoidUnit.scala` 的 256 项 LUT 是
**冻结的 Q3.4→Q0.7**（`out = floor(127·sigmoid(x/16)+0.5)`，输入 `s=1/16,z=0`、输出 `s=1/127,z=0`），
而转换器/黄金按**每层标定刻度**造 LUT（如真图口径 `s_x=0.0117,z_x=-55`、`s_y=0.0035,z_y=-128`）。
⇒ 即使 D1/D2 修好，6 个 cls/obj 头仍是"另一个函数"。这是 `SigmoidUnit.scala` 文件头点名的
"换刻度 = 换这张表"的 C4 开口项，本代**未闭合**。

### 15.3 修法（全部宿主侧；**无 RTL、无 PnR、无重烧**）

| 项 | 改动 | 判据 |
|:--|:--|:--|
| D1 | 新 `tools/y1_caliber.py::calib_nchw()`；`y1_convert.py` 加 `--calib-image`（缺省仍是合成 U[0,1)，既有闸门逐字节不变） | 用**与黄金同一张** `grace_hopper.jpg`（0..255）标定 ⇒ `centering[0].s_x == 1.0` |
| D2 | `npu_frame_run.mailbox_writes`：`RGN_ZY` 投 `z_y_eff`（缺则回退 `z_y`） | 15 个折进单元投 **-128**；非折进项不变 |
| D4 | `y1_caliber.apply_sigmoid_fix(act, nodes)`：把 6 个 Sigmoid 的**生产者输出 + 视图**钉到 `s=1/16,z=0`、**输出**钉到 `s=1/127,z=0`（转换器与驱动的黄金/反量化共用同一份） | logit 实测 ±40（obj 头）⇒ 在 ±8 外由 sigmoid 自然饱和（sigmoid(±8)=0.00034/0.99966），数值无害 |

重生成（`y1_convert.py --gate --calib-image <grace_hopper>`）：**`RESULT: PASS`**；
`desc.bin`（`4bd68b36…`）与 `wgt_blob.bin`（`aa135f0f…`）**逐字节不变**（表=几何、blob=权重，与标定无关），
`wgt_mult.bin` `ff2ed3c6… → 4843b8f6…`、`wgt_index.json` `723a5185… → 4c531067…`。
离线黄金（同一份 `apply_sigmoid_fix`）**检出人脸 1 个**：`conf=0.9264`、框 `[231.7,135.3,193.9,219.3]`
（与修前两步黄金 `0.931/[231.7,135.3,193.9,219.3]` 同框）；`desc[0]` 黄金 distinct **246**（不再是 39）。

### 15.4 新口径下的期望与实际（板端）

- 期望：板上 12 路输出与**新黄金**近逐字节（差 ≤ O1 折进取整 + Q3.4/Q0.7 取整），G7 对 float
  `IoU≥0.5 / |Δconf|≤0.1 / 计数差≤1` 转绿。
- 实测：见 §15.5（板跑在飞，本行留待补）。

### 15.5 板端复跑（新口径；**未重烧、未重 PnR**）

**跑通**：同一比特流（`d8993bfe…`）上重投新表/信箱/输入后整帧 **`done=1 err=0`**（poll0=0、终态 1，
轮询 5 次 8.8 s）。信箱 **7346 条**（含 z_y_eff 与新区 2 的 M；LAYOUT 位 `f24fb2bc…` 不变），
输入/表/信箱三块整块回读 md5 全对。

**6 路 cls/obj（读全）**：不再是常数——`cls_8` distinct **8**、range **[67,81]**；`cls_16` range [54,67]；
`obj_8` [0,33]；`obj_16` [0,54]（S4-A 时其中三路是**逐字节常数**）。但仍与新口径黄金差 ~93%
（cls_8 mismatch 5981/6400）——**"常数化"已消除，数值仍未对齐**。

**逐单元抽样（每单元 64 B；比较对象 = **折进口径**黄金 `fold_sim`，即硬件语义：单次 requant + `z_y_eff` + Sigmoid Q3.4/Q0.7）**：

| 单元 | 类型 | 板端 vs **折进**黄金 | 判决 |
|:--|:--|:--|:--|
| `desc[0] Conv_0` | conv3x3 s2 3→16 | **逐字节相等**（20 行整块 6400 B：mismatch **0/6400**，corr 1.0000） | **完全正确** |
| `desc[1] Conv_2` | 1×1 16→16（宽路，2 ci-block） | 内点 3 点：corr 0.84–0.93、mean\|d\| **2.5–4.2 码**（起点样本 3.56） | **首个真实分叉** |
| `desc[2]…desc[37]` | 3×3 / dw / maxpool / resize / add | corr 逐层跌到 ~0，mean\|d\| 涨到 10–27 | 误差累积 |

**已排除**（在 `desc[1]` 的 4 个 64 B 样本上逐一试过）：
M 投递（转换器 M 与黄金逐位相等 5,502,370）/ `M_two_step` / 无 bias / bias×2 / 两 ci-block 各自 requant 再相加 /
单通道替换或丢弃（16×16 全扫）/ 单通道 ±1、±2、±32 像素移位 / `ci>=8` 整块 ±1 像素移位
（后者 mean 2.45 vs 基线 3.29，仅弱改善，**不构成根因**）。
**输入侧已彻底排除**：`desc[0]` 输出对折进黄金 —— **全部 16 个平面**在 rows 160..179 整块验证
（14 个平面各 **0/6400 mismatch**；plane 4/14 因传输面拉取失败后以 row 170 的 64 B 补验，同样 **0/64**），
含 channel-block 边界 7/8。⇒ **`desc[1]` 的输入逐字节精确**。
**`desc[1]` 的 20 行整条**（plane 0 rows 160..179，6400 B）：mean\|d\|=**2.77 码**、corr **0.947**、
max 50；误差**弥散**（mod 8/16/32/64 的相位差仅 2.1–6.4，无强周期；mean signed +0.28、43% 为正）。
⇒ **首个真实分叉 = `desc[1]`（宽路 1×1，Ci=16，两 ci-block 多趟）**，误差 ~3 码且随层累积；下一步：**同几何 RTL 仿真**（W=320/H=320/Ci=16→Co=16、2 ci-block、XDMA gather，输入=折进黄金的 `184`）
逐字节对黄金 —— 若仿真复现 ⇒ RTL 缺陷（二分 pass 2 部分和写回 / B 段 requant / p8 相位）；若仿真全对 ⇒ 板上 gather 握手/时序面。

**中间张量回读**（4 路）：`Conv_54/55/56/57` 的**首行/首列恒值**是上游已被压平的**结果**（不是独立缺陷）；
`Conv_54` 的输入来自 `desc[36]`，而误差早在 `desc[1]` 就出现。

**传输面**：`bbox_8`（25.6 KB，8 KB 分块）起 tftp 停等链确定性超时（"诅咒块"），12 路回读在 6 路后中止
（cls/obj 6 路已落盘：4 路 net + 2 路 UART devmem 重建）。

### 15.5b 判据目标的自洽性：折进黄金本身**可检出人脸**

若板端与折进黄金逐字节一致，G7 就能过——已离线验证折进黄金的后处理：

| 口径 | 检出数 | conf | 框 |
|:--|--:|--:|:--|
| **折进黄金**（硬件语义） | **1** | **0.9349** | `[231.6, 131.8, 197.9, 223.8]` |
| 两步黄金（原 G7 参照） | 1 | 0.9264 | `[231.7, 135.3, 193.9, 219.3]` |

两者 IoU > 0.9、`|Δconf| = 0.0085` ⇒ **折进语义不是"另一种网络"**，它是原参考的等价实现（差仅取整级）。
⇒ 板端只要对齐到折进黄金，G7（IoU≥0.5 / |Δconf|≤0.1 / 计数差≤1）就有依据转绿。

### 15.7 ★★ 根因定案（RTL 同几何仿真，2026-10-17 下午）：**1×1 的抽头约定** —— slot 0 = 窗口左上，ONNX = 居中

**判词：宽路数据通路逐字节精确；"~2.8 码误差"其实是所有 1×1 单元的 (-1,-1) 像素偏移。**

装置（`y1/build/s4c_rtl/`，**未碰板/未改 RTL**）：`gen/UnitExec_tiled.v`（这才是板上网表：
`NpuTop.scala:149` → `LayerSched(WIDTH=34, IMG_H_MAX=32, TILING=true)`；`gen/UnitExec.v` 是
TILING=false 的冻结件），单单元 desc[1]（TYPE=2、320×320、16→16、GROUP=1、XDMA、输入=`fold3['184']`）。

| 对照 | mismatch | mean\|d\| | max | corr |
|:--|--:|--:|--:|--:|
| **偏移 1×1**（`x[y-1,x-1]`） | **0 / 1,638,400** | **0** | **0** | **1.0000** |
| 居中 1×1（brief/黄金） | 1,376,725 | 3.61 | 90 | 0.9444 |

- 仿真 DUT 的整份输出与**板上实测逐字节相同**（`d1_strip.bin` 0/6400、三个 64 B 样本 0/64）；
- 居中黄金与 `fold3['185']` **逐字节相同**（0/1.6 M）；
- 已由逐字节精确**排除**：PSB pass-2 写回/读回、单次 requant、32 B band gather、tile 环、掩码 WR
  （`AW=B=51200`、`X1_BEATS=448,800` = 4 趟 × 1122 px × 100 tile）。

**根因（file:line）**：`LineBuffer.scala:84-89` 的窗口行 = `[y-1,y,y+1]`；`Conv3x3Slice.scala:347-359`
列窗口 `[x-1,x,x+1]`；`371-407` 的拍序 `ph=1 → (ky,kx)=(0,0)`；`675-681` 的 **1×1 跳过只发 tap 0**
⇒ 硬件把 slot 0 的权重乘在 **(y-1,x-1)** 上。转换器 `y1_convert.py:827-843` 也把 1×1 核放在
slot 0（*"单抽头落在 (ky,kx)=(0,0)"*），**RTL 与转换器自洽**；但 ONNX/`quant_ref.conv_vec` 的 1×1
是**居中**的（pads=0）⇒ 基准与硬件差 1 像素。所有 RTL 闸门的参考（`tiling_ref.conv_tiled` +
slot 0）用的是同一个偏移约定，所以一直全绿——**没有一条闸门拿 1×1 对 `conv_vec`**。

**影响**：真表 **26 个 1×1 单元**的输出全部相对 ONNX 偏移 (-1,-1) ⇒ 整网从 desc[1] 起逐层错位，
下游相关性崩到 0（本报告 §15.5 的 corr 阶梯正是它）。

**修法（需 spec/参考修订 + 重 regen + PnR + 重烧）**：
1. **RTL（最省）**：`one_x1` 时强制 `arrX(ci) := colWin(1)(ci)(1)`（中心采样），**保持 `tapK=0`**
   ⇒ blob 布局不变（slot 0 权重仍有效），参考改成真 1×1（= `conv_vec` = `'185'`）；
2. 或把转换器的 1×1 核挪到 slot 4 且跳过逻辑发 tap 4（blob 26 单元布局变化，更贵）。
配套：更新 `run_x1skip_ab.sh` / `run_tiling2d_wide_ab.sh` / `run_tiling2d_rtl_ab.sh` 的
`tiling_ref.conv_tiled` 调用约定，并**新增一条"1×1 对 `quant_ref.conv_vec`"的闸门**（今天缺这条）。

### 15.6 判词（S4-B）

- **D1/D2/D4 已修并上板验证了"送去的东西"**：输入域 1.0、z_y_eff、Sigmoid Q3.4/Q0.7 都在板上生效
  （三路常数头消失、值域合理、帧 done/err 干净）；**首层 desc[0] 与黄金 corr 0.997**。
- **仍红**：**第一个出错单元 = `desc[1]`（宽路 1×1，16→16，两个 ci-block）**——corr 0.739、mean 3.6 码，
  误差沿链放大到输出（与黄金差 ~93%）。**未定位到根因**（已排除输入布局 / M 投递 / 单通道错位）。
- **根因已定案（§15.7）**：1×1 抽头约定（slot 0 = 左上 vs ONNX 居中）⇒ 26 个 1×1 单元整体偏移
  (-1,-1)；宽路各件（PSB/requant/gather/tile/WR）**逐字节精确**。
- **未做**：12 路完整回读（传输面）、负对照、fps 复测；**修复需 RTL 一行 + 参考修订 + 重 regen/PnR/重烧**。

### 15.8 ★ S4-C 修复与验证（2026-10-17 傍晚）：1×1 居中采样

**修法**（`Conv3x3Slice.scala`，commit `86f39c8`）：像素起点 `tapKx/tapKy = Mux(one_x1, 1, 0)`，
权重槽仍 `tapK=0`（blob 布局零变化）；3×3 路径逐字不变。1×1 的单拍仍只发 1 拍（**9×→1× 优化保留**）。

**全几何仿真**（重生成的 `gen/UnitExec_tiled.v` md5 `1ab97e09…`；desc[1] 320²/16→16/2 ci-block/XDMA，
输入 = 折进黄金 `184`）：

| DUT vs | mismatch | mean\|d\| |
|:--|--:|--:|
| **居中黄金（ONNX/`conv_vec`）** | **0 / 1,638,400** | **0** |
| 旧左上口径 | 1,376,725 / 1,638,400 | 11.30 |

`RESULT: PASS`、`X1_BEATS=448,800`（4 趟 × 1122 px × 100 tile）、`AW=B=51,200`。旧口径的 1,376,725
恰等于**修前**对居中黄金的 mismatch ⇒ 误差方向翻转、残差归零。

**闸门**：新增 `run_x1center_ab.sh`（TYPE=2 vs `quant_ref.conv_vec` **0/1024**；负对照 1009 精确发火；
网表突变 `_zz_one_x1=0` 逐字节复现旧行为）。全套件 **16 条 PASS**；唯一红是既有设计性红
`run_chain_wide_ab`（宽链 ≥2 无通路）。闸门参考已按居中口径重基线（commit `1ed9181`）。
网表新 md5：`UnitExec_tiled` `1ab97e09…`、`NpuTop` `baff2361…`、`LayerSched` `1337b662…`、
`UnitExec/_w32/_w640` 亦如期变更（行为修复，旧冻结基线作废）。

**在飞**：PnR tag `c4a_s4c`（工程 `sim/reglogs/pds_pnr_c4a_c4a_s4c_p10.000/`）→ 完成后烧写跑帧。

### 15.9 ★★ S4-C 上板（新比特流 `8e452d68…`）：**整帧检出正确人脸**，G7 的 IoU/conf/计数全过

**比特流**：`pds_pnr_c4a_c4a_s4c_p10.000`（PnR **1h30m**、seed 0 收敛、**All Constraints Met**；
cpu 107.11 MHz/+0.664、npu **56.912 MHz/+0.829**、core 138.26/+0.767、rgmii 151.47/+1.398），
sbit **9,188,552 B** md5 **`8e452d684fb05e319d520c69f2a0db8f`**。烧写 done=1、8/8 启动 marker 全过。

**整帧**（同驱动、同口径；`done=1 err=0`，poll 8.7 s）：12 路回读全成功（本次无 tftp 诅咒）。

| 输出 | int8 范围 / distinct |
|:--|:--|
| cls_8 / cls_16 / cls_32 | [65,77]/7、[54,71]/8、**[50,111]/38**（修前 cls_32 是常数） |
| obj_8 / obj_16 / obj_32 | **[0,0]/1**、**[0,0]/1**、[0,127]/7（与黄金 obj 近全 0 一致） |
| bbox_8/16/32、kps_8/16/32 | distinct 103/137/206/153/198/245（有纹理、非平凡） |

**检测（vs float ORT，正式 B 侧）**：

```
COMPARE count=1/1 diff=0 matched=1 unmatched=0/0
COMPARE iou_min=0.9237 kp_l2_max=2.787 conf_d_max=0.0056
=> IoU>=0.5 ✓  |Δconf|<=0.1 ✓  计数差 0 ✓  仅 kp_l2=2.79 > 2.00
```

- 板上检出 **conf=0.9349、box=[231.6,131.8,197.9,223.8]** —— 与**折进黄金逐位相同**
  （折进黄金 conf 0.9349、同框）；对 float 的 IoU **0.9237**、|Δconf| **0.0056**。
- **唯一红是 kp 的 2 px 容差**：**同口径 int8 黄金对 float 本身就是 4.81 px**（§14.3 已记账）⇒
  这条线对"完美板"也走不通，属**容差口径**问题（板端 2.79 已优于 int8 黄金的 4.81）。
- 结论：**S4-C 修复把整帧从"常数化/零配对"推进到"1 个检出、IoU/conf/计数全过"**；G7 的形式判词
  需把 kp 容差按其口径改成 ≥5 px（spec 修订），或对 int8 黄金比较。

**无脸负对照（PASS）**：`--no-face` 整帧 `done=1 err=0`，**`HW_DETS=0`**（score_thr 0.90）；
12 路与正脸**逐路不同**（cls_8 `f5a918…`→`6e7b6f…`、cls_32 `264c79…`→`607931…`、bbox/kps 全变；
obj 两帧均全 0，与黄金一致）⇒ **输入依赖恢复、负对照干净**。

**fps（板内 `npurun_t 0x00100000 67 3`，无脸态）**：
`6,492,500,690 / 6,491,794,010 / 6,491,991,420 ns` ⇒ **6.4921 s/帧、0.15403 fps**（与修前 0.1541 同档：
1×1 仍是 1 拍/像素，帧时对本次修复不敏感）。

**S4-C 判词**：1×1 居中修复后，**整帧检出正确的 1 张人脸**（conf 0.9349、框与折进黄金逐位相同；
对 float IoU 0.9237、|Δconf| 0.0056、计数 1:1），**负对照 0 检出**；唯一红是 kp 的 2 px 容差
（同口径 int8 黄金对 float 本身 4.81 px，板端 2.79 px 更优）⇒ **容差口径待 spec 修订**。
性能未变（0.15403 fps），流量/吞吐优化仍是后续独立课题。

## 16. **2026-10-17 晚：第 5 槽卡 + 板内纯 C runner 冷启动验收（PASS）**

**卡镜像**：`sw/images/sd_y1_safe.img`，**10,620,416 B**，md5 **`20e6921e3fa2a9e59931c926b8acfc92`**；
5 槽（旧已知-good fw/Image/dtb + 新 rootfs + 第 5 槽 payload@`0x81E00000`）；写卡 **CARD VERIFY PASS**
（file/card SHA256 均为 `A15B1C8F…AD5745`）。

**启动 marker**：`SDR`（misoHi=1）→ `Platform Console Device: uart8250` → `Linux version 5.10.1`
→ `liteeth … slots: tx 2 rx 4` → `Starting dropbear sshd: OK` → **`VEXIIYESHEN-OK`**（5.74 s）。

**冷启动纯 C 整帧**（`/root/y1/y1run --frames 1 --quiet`，payload 由 SdLoader 直载）：

```
RUN 0 ns=6262773280 status=0x00000001 outputs=12/12
Y1RUN: PASS frames=1 pass=1 fail=0
```

- payload 5 段 CRC32 + arena 拷贝回读 CRC + 12 路输出 CRC/逐字节黄金（`y1/fixtures/s4c_noface_raw`）全过；
- 黄金来自 S4-C 无脸帧的 raw 输出；C runner 与 Python 路径**逐字节等价**；
- 板内不需要任何主机传输（`/root/y1/y1run` 在 rootfs，payload 在卡第 5 槽）。

**poison 64 B 假故障的最终结论**：早先 `--poison` 在 kps_16/kps_32 各留下 64 B=0x5A，
**不是 RTL 漏写**；不带 poison 重跑后 NPU 正常写满。真因是 CPU 脏 cache 行在帧后回写 DDR，
覆盖了 NPU 输出（两处空洞落在同一 cache 组偏移 0x640）。该 poison 控制实验**不作判据**；
冷启动卡测才是有效控制。新进程 ddmem 读 + 大块 cache 换出后仍 0x5A 的观察与"脏行回写"一致。

**计时口径**：C runner 6.2628 s（×3 稳定）与 `npun_t` 6.492 s 的 3.6% 差异仍未归因；
gather/CDC 的 A/B 一律用**同一个 C runner**，绝对 fps 的差异留作独立量具问题。

**下一刀**：`NpuMemCdc` 的 per-beat 4 相握手（单 outstanding）是 gather 32 B 握手的真正承重点
（见性能 spec §8）；先做 burst FIFO（#431），再做 DdrMaster/gather 队列（#429/#430）。

## 17. **2026-10-17 深夜：CDC burst FIFO + L_MAX=2（面积大砍）**

**两把杠杆一起落地**（用户指令：先做 CDC burst FIFO；再把 L_MAX 由 8 收到最小、FIFO depth 16→8）：

1. **`NpuMemCdcFifo`**（`y1/rtl/NpuMemCdcFifo.scala`，新模块）：把 5 条跨域通道（AW/W/B/AR/R）的
   "逐 beat 4 相握手、单 outstanding" 换成 **源/目的双环 FIFO + `lanes=4` 个 `CdcPipeSp` 轮转并发**。
   承重点是：旧结构一次只能有一个 beat 在跨域，gather 的逐 32 B 往返被 CDC 串行化；新结构最多
   4 个 beat 同时在飞。闸门 `run_mem_cdc_ab.sh` **PASS**（三道负对照都压在跨域承重点上发火；
   比较器自检恰好 1 字节）。
2. **`L_MAX=8 → 2`**：真表已 de-fuse（全 plain，`chain_len=1`），`UnitExec` 里 8 套 `Conv3x3Slice`
   只有 slice0 被用；其余 6 套是**死逻辑**。`L_MAX=1` 在本实现**不可行**（链结构是
   `slice0 + sliceRest(1..L-1) + tail`，L=1 时 `sliceRest` 为空，展开期在
   `TraversableOnce.reduce` 处失败；`UnitExec` 的 `require` 已把这一点写进错误文本）。
   取 **L=2 = 最小合法值**：删掉 6 套切片，保留链首+尾的最小链形态。
   链覆盖不降级：`NpuTop(LMax)` 参数化，板级生成 `gen/NpuTop.v`（L=2），作业 W2 的 8 片链
   单独吃 **`gen_chain8/NpuTop.v`**（L=8 验证网表，仅闸门用，不进板级/不入库）。
3. **`NpuMemCdc` 五通道 FIFO depth 16 → 8**：`lanes=4` 不变；depth ≥ lanes 即不限制并发，
   8 足够覆盖 4 lane，省下寄存器。

**闸门证据（全绿）**：

| 闸门 | 结果 |
|---|---|
| `run_mem_cdc_ab.sh`（depth 8） | **PASS**；跨域无丢失/无重复/字节级正确；3 道负对照发火 |
| `run_twoclock_ab.sh`（L=2 网表 + depth-8 桥） | **PASS**：单时钟 `MISMATCH=0`、两时钟 `MISMATCH=0`、确定性 2×、AR 掐断负对照红（`N5B-OK`） |
| `run_nputop_sched_ab.sh` | **PASS**：3 plain 单元 + 非法表负对照；**W2 8 片链 `MISMATCH=0`**（吃 `gen_chain8`）；`run_nputop_ab.sh` / `run_ddrcopy_ab.sh` 回归 PASS |

**dev_map（整板，PDS `pds_c4a_l2d8`，0 error）**：

| 资源 | L=8 + depth16（`pds_c4a_l2a`，20:22） | **L=2 + depth8（本片）** | Δ |
|---|---|---|---|
| LUT | 128,055（81%） | **68,366.5（43%）** | **−59,688.5（−46.6%）** |
| FF | 155,943（49%） | **89,877（29%）** | −66,066（−42.4%） |
| APM | 542（74%） | **260（36%）** | **−282（−52.0%）** |
| DRM | 247.5（60%） | **241.5（59%）** | −6 |
| DistRAM | 7,872（20%） | 7,872（20%） | 0 |

**归因边界（诚实）**：APM 的 −282 可**精确**归到 6 套切片（`282 / 6 = 47.0` APM/切片，与
`Conv3x3Slice` 的实测单价一致；depth 改动静止 APM）。LUT/FF 的降幅是 **L=2 + depth 16→8 两把
杠杆的合计**，未单独拆 depth 的贡献；depth 只影响 FIFO 寄存器阵列（5 通道 × 8 深 × 位宽），
量级远小于 6 套切片。

**判词**：资源目标 **LUT < 70% 已达成（43%，余量 57%）**；功能由上述闸门钉住；
PnR/时序与上板 A/B 见下一节。

### 17.1 PnR 结果（2026-10-18 00:55）：**NPU 在 18.4 ns 认证约束下未收敛 —— 本比特流不能按现板钟 56.25 MHz 上板**

**流程**：复用 `pds_c4a_l2d8` devmap 工程，4 个 seed（seed 0..3，每个约 20–25 min），全部完成布线；
最终报告取 **seed 1**（数字与 seed 1 行逐项一致）。比特流已生成：
`sim/reglogs/pds_c4a_l2d8_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`，
**9,188,552 B，md5 `eaceb7e7da3d6baccd51b750aae75124`**（**未认证**，见下）。

**Performance Summary（final `.rtr`，slow corner）**：

| 时钟 | 请求 | 估计 | 周期请求/估计 | Slack | 判词 |
|---|---|---|---|---|---|
| clk_in | 27.03 MHz | 246.61 MHz | 37.000 / 4.055 ns | +32.945 | MET |
| cpu_clk | 100.00 MHz | **101.64 MHz** | 10.000 / 9.839 ns | **+0.161** | **MET** |
| core_clk | 125.00 MHz | **127.62 MHz** | 8.000 / 7.836 ns | **+0.164** | **MET** |
| rgmii_clk | 125.00 MHz | 237.02 MHz | 8.000 / 4.219 ns | +3.781 | MET |
| rst_clk | 125.00 MHz | 277.32 MHz | 8.000 / 3.606 ns | +4.394 | MET |
| **npu_clk** | **54.3478 MHz** | **51.9642 MHz** | **18.400 / 19.244 ns** | **−0.844** | **VIOLATED** |

- 设计判词：`Some Constraints Violated`；**唯一违例族 = `npu_clk` setup slow**（79 个失败端点，
  TNS −21.114 ns，全部 ≥ 290,158 个 NPU 端点里的同一锥）。hold / recovery / removal 在 slow 与
  fast 两角**全部 MET**（npu hold 最差 +0.083 / +0.059 ns）。
- **板钟口径（关键）**：`board/pll_50m.v` 的 RATIO0=12.0 ⇒ 板上 `npu_clk` 实际是 **56.250 MHz
  (17.778 ns)**（t18c 起）。t18c 的认证关系是"请求 54.3478 ≤ 板钟 56.25 ≤ est 56.2683"。
  本比特流 est **51.964 MHz < 板钟 56.25** ⇒ **按现板钟上板不安全**（对 17.778 ns 折算
  slack ≈ −1.47 ns）。只有把板钟降回 **50 MHz** 才有 +0.756 ns 余量（代价：NPU 计算慢 ~11%）。

**最差路径（同一锥，79 端点）**：
`u_soc/u_npu/layerSched_1/unitExec_1/N1688/gopapm/CLK` → `wOutMem_*/gopdrm_36k/WEA[0]`
（14 级逻辑，逻辑 11.158 ns / 布线 7.707 ns；数据到达 21.421 ns，要求 20.577 ns）。
后半段是 `tOutPerRow` → `N9239.lt` 比较链 → **扇出 64 的 `_N49767`（布线 2.399 ns）** → 34 块
`wOutMem` DRM 的写使能。**整条路径在保留的 slice0 输出写口上**，L=2 没有改变它的逻辑深度；
与上一版板级比特流（S4-C：npu 56.912 MHz / +0.829）相比 fmax 低约 4.9 MHz，落在
**布局/布线差异**（同逻辑、不同 seed）上，不是链切片删除带来的逻辑加深。

**结论与选项**：
1. **不烧这块比特流**（按 56.25 MHz 板钟）。
2. 选项 A（推荐）：修 `wOutMem` 写使能锥 —— 给高扇出 `_N49767` 加寄存器级或按 DRM 组复制驱动，
   目标省出 ≥1.5 ns，再跑 PnR；功能上需同步延迟写数据/地址，闸门照旧（字节级）。
3. 选项 B：把 `pll_50m.v` 的 RATIO0 回调 13.5 ⇒ 板钟 50 MHz（est 51.96 > 50，余量 +0.756 ns），
   立刻可上板，但 Y1 计算吞吐掉 ~11%。
4. 选项 C：只加 seed 重跑（本次 4 seed 的 setup 散布 −2.415…−0.844，最差到最好差 1.57 ns；
   能否越过 18.4 ns 不保证，成本约 1.5–2 h）。

**诚实边界**：LUT/APM 的面积目标已达成；**时序目标未达成**（在 18.4 ns 认证约束下），
上板 A/B 因此**暂停**，等修法定案。

### 17.2 时序修复（2026-10-18 01:10）：写口几何寄存化

**修法**（`y1/rtl/UnitExec.scala:1706` 一行 + 同块 11 行，**行数中性**）：把 tile 几何
`tTw/tTh`、`tOutPerRow`、`wxPixTot` 各打一拍（3 级寄存），写口收料用寄存副本
（`tKeepW/tOutIdxW/oColW/wCollect`）。依据：
- 最差路径是 `tWo/tTx → tOx0 乘 → tTw → tNCol 乘 → tOutPerRow → (tTh+1)·tOutPerRow → 比较
  → 34 块 wOutMem 的 WEA`（21.421 ns）；
- tile 几何**在整个 tile 内恒定**，换 tile 后要过 ≥577 拍载权 + 整窗喂列才第一次写 `wOutMem`
  ⇒ 3 拍寄存副本在首写前早已稳定，**数值/地址/字节序逐字节不变**；
- 只 `TILING=true` 生效；`TILING=false` 三份冻结网表 md5 **逐字节不变**。

**指纹**：`TILING=false` 三份 = `dd9ee31e…` / `af509071…` / `781bb0fd…`（与冻结值逐字节相同）；
`TILING=true`：`UnitExec_tiled 34d183f8…`、`LayerSched 87e6e330…`、`NpuTop 895de11b…`、
`gen_chain8/NpuTop 9181cc44…`。

**闸门（全 PASS）**：
- `run_tiling2d_rtl_ab.sh`：s1 320×320/160×160/64×32/80×80/40×40/20×20 + s2 32×32 **整层 MISMATCH=0**；
  负对照①漏 tile 列 MISMATCH=8165、②无 halo MISMATCH=991（均发火）；
- `run_unitexec_wide_ab.sh` / `run_wide_tail_ab.sh`：正对照 + 变异负对照全 PASS；
- `run_nputop_sched_ab.sh`：3 plain + W2 8 片链 + 非法表负对照 + C2 回归 PASS；
- `run_twoclock_ab.sh`：单/两时钟逐字节 0 + 确定性 2× + AR 掐断负对照红（N5B-OK）。
- 说明：`run_chain_wide_ab.sh` 仍是**先红闸门**（宽路整链未实现，plan T-S3f），与本修无关。

**dev_map（`c4a_l2d8t`，0 error）**：LUT **68,386.5（43%）**、FF 89,904（29%）、APM 263（36%）、
DRM 241.5（59%）——相对修复前 `c4a_l2d8` 仅 **+20 LUT / +27 FF**。

**PnR**：复跑中（tag `c4a_l2d8t`）；结果见下一条。

### 17.3 时序收口②（2026-10-18 03:06）：PnR **All Constraints Met** + 板钟降到 54 MHz

**第二处修复**：写口寄存化后，PnR 的新最差路径转移到 FSM 收工判据 ——
`tInWi → … → tOutPerRow → wxPixTot 乘 → wEmitCnt 比较 → wSt`（−0.406 ns，6 个端点）。
把 `when(wEmitCnt === wxPixTot-1)` 改用同一寄存副本 `wxPixTotG`（`UnitExec.scala:2142`，
换 tile 后 ≥577 拍才用到，语义不变）。闸门复跑：`run_tiling2d_rtl_ab.sh` 全几何 + 2 负对照 PASS、
`run_nputop_sched_ab.sh` PASS；`TILING=false` 三网表 md5 仍冻结
（`dd9ee31e… / af509071… / 781bb0fd…`）。

**PnR（tag `c4a_l2d8u`，旧 56.25 MHz PLL）**：seed 0 即 **`All Constraints Met`**（UserFilter=1）：

| 时钟 | 请求 | 估计 | Slack |
|---|---|---|---|
| cpu_clk | 100 MHz | 108.98 MHz | +0.824 |
| core_clk | 125 MHz | 132.12 MHz | +0.431 |
| **npu_clk** | **54.3478 MHz (18.4 ns)** | **54.6747 MHz (18.290 ns)** | **+0.110** |
| rgmii / rst / clk_in | — | — | +3.91 / +4.74 / +33.16 |

hold / recovery / removal 全 MET。比特流：`9,188,552 B`、md5 **`77ac8920…`**
（**已作废**：它内嵌 56.25 MHz PLL，板钟会高于 est 0.51 ns，不能上板）。

**板钟定档**：按文件既有的认证关系 **板钟 ≤ est**，把 `board/pll_50m.v` 的 `RATIO0` 12.0→**12.5**
⇒ clkout0 = 675/12.5 = **54.000 MHz（精确）**，比 est 54.6747 低 0.675 MHz（1.2% 余量；
T-18c 当年只留 0.033%）。fdc 的 `npu_clk 18.400 ns` 一字未改（请求 54.3478 现在比板钟更紧，保守）。
代价：NPU 计算钟 56.25→54.0（−4.0%），远小于 0.51 ns 的时序风险。

**重出比特流**：devmap/PnR 以 tag `c4a_l2d8v` 复跑（含 54 MHz PLL），结果见下一条；
在此之前 `c4a_l2d8u` 的比特流**不得烧板**。

### 17.4 OC 实验（2026-10-18 05:00）：收紧过约束 **反噬** —— 回退 18.4 ns + 54 MHz

**假设（用户提出）**：18.400 ns（54.35 MHz）低于板钟 56.25 MHz，PnR 只按低档优化（est 54.6747）；
把约束收紧到 **17.500 ns（57.1429 MHz，相对板钟 +2.3%）**，逼工具朝 ≥56.25 优化，保住 56.25 MHz 板钟。

**控制变量**：同一 RTL 网表（`NpuTop 895de11b…`）、同一 devmap/PnR 流程、同一 seeds 策略；
只改 fdc 的 `npu_clk` 周期与板级 PLL（12.0=56.25 MHz）。A 档 = 18.4 ns（`c4a_l2d8u/v`），
B 档 = 17.5 ns（`c4a_l2d8w`）。

| 档 | seed | Setup(Slow) | 线长 | est（由 slack 折算） |
|---|---|---|---|---|
| **A: 18.4 ns** | 0 | **+0.006**（最终报告 +0.110） | **939,319** | **54.67 MHz (18.290 ns)** |
| B: 17.5 ns | 0 | **−2.444** | 1,060,750（+13%） | ≈50.1 MHz (19.944 ns) |
| B: 17.5 ns | 1 | **−1.179** | 954,934 | ≈53.5 MHz (18.679 ns) |

**判词**：两个 seed **同向恶化**（−2.4 / −1.2 ns），B 档在 seed 0 还伴随线长 +13% ⇒ **过约束反噬**，
不是 seed 噪声；不需要再跑 seed 2/3（已停）。**回退 A 档**：
- fdc `npu_clk` **18.400 ns**（一字不改地恢复）；
- `board/pll_50m.v` RATIO0 **12.5 ⇒ 54.000 MHz**（板钟 ≤ est 54.6747，1.2% 余量）；
- **认证交付比特流 = `c4a_l2d8v`：9,188,552 B，md5 `a8be97d7148dabccaa6ba71473264605`**
  （All Constraints Met；可上板）。
- `c4a_l2d8u/77ac8920…`（56.25 MHz PLL，est 54.67 < 板钟）与 `c4a_l2d8w`（17.5 ns 反噬）
  均**作废，不得烧板**。

**方法学记录**：这条是"过约束能改善时序"假设的**否证实验** —— 在 118k LUT→43% 的新布局密度下，
把 NPU 约束从 18.4 收到 17.5 会改变布局器的优化取舍（seed 0 线长显著上升），fmax 反而下降。
后续若要再提 NPU 频率，应走结构性路径（`DdrMaster`/gather 队列、L1 复用等），而不是继续收紧时钟约束。

### 17.5 上板 A/B（2026-10-18 06:05）：**12/12 PASS，单帧 4.598 s（旧 6.2628 s，−26.6%）**

**烧写**：认证比特流 `c4a_l2d8v`（sbit `a8be97d7…`）。JTAG 65420 落在 Windows 排除区
（`65399-65498`）⇒ `cdt_js.exe -port 62000` + `YESHENMINI_JTAG_PORT=62000` 手工烧写；
**done bit = 1**。启动判据全过：`SDR 20…`（misoHi=1）、OpenSBI banner、`Linux version 5.10.1`、
`liteeth … slots: tx 2 rx 4`、`Starting dropbear sshd: OK`、`VEXIIYESHEN-OK`（5.748 s）、`login:`。

**板内纯 C `y1run --frames 3 --quiet`**（payload 第 5 槽直载，零主机传输）：

```
RUN 0 ns=4598110970 status=0x00000001 outputs=12/12
RUN 1 ns=4597365940 status=0x00000001 outputs=12/12
RUN 2 ns=4598259350 status=0x00000001 outputs=12/12
Y1RUN: PASS frames=3 pass=3 fail=0
```

**A/B（同一 C runner、同一 payload/黄金）**：

| 指标 | 旧：L=8 + per-beat CDC + 56.25 MHz | **新：L=2 + CDC FIFO depth8 + 54.0 MHz** | Δ |
|---|---|---|---|
| 单帧 | 6,262,773,280 ns | **4,598,110,970 ns**（×3 稳定 ±1.2 ms） | **−26.6%** |
| 吞吐 | 0.1597 fps | **0.2175 fps** | **1.362×（+36.2%）** |
| 输出 | 12/12 | **12/12（逐字节黄金）** | 不变 |
| LUT / APM | 81% / 74% | **43% / 36%** | 大幅下降 |

**归因**：新档的 NPU 时钟反而低 4.0%（56.25→54.0 MHz），帧时间却降 26.6% ⇒ 收益来自
**CDC burst FIFO 去掉每 beat 的跨域往返**（与性能 spec §8 的预测方向一致），不是时钟或面积。
L=2 删掉 6 套死切片和写口几何寄存化只影响面积/时序，**未改变 12 路输出**（逐字节对账）。

**本片收口**：面积目标（LUT <70%）与功能/时序/上板判据全部达成；L2a 的 A/B 基线更新为
**`y1run` 4.5981 s/帧 @ 54 MHz**。下一刀按 spec：`DdrMaster`/gather 读请求队列（多 outstanding）。

### 17.6 归因（2026-10-18 07:20）：两时钟差分 —— **G≈1.856 s（40.4%）与 NPU 时钟无关**

**方法**：同一网表/约束/`y1run`/payload，只把 NPU PLL 从 54 MHz 临时降到 **27 MHz**
（RATIO0 12.5→25.0，sbit `42522ed5…`，仅实验用），测 `T27`；用 `T(f)=C/f+G` 分解。

| 档 | 单帧（RUN 0） | 输出 |
|---|---|---|
| 54 MHz | 4,598,110,970 ns | 12/12 |
| **27 MHz** | **7,340,589,670 ns**（×3 稳定 ±0.6 ms） | **12/12** |

- `C/f54 = T27 − T54 = **2.7425 s (59.6%)**`（随 NPU 时钟缩放：计算/FSM/流式处理）；
- `G = T54 − (T27−T54) = **1.8556 s (40.4%)**`（与 NPU 时钟无关：DDR/gather 服务与固定延迟）。
- 校验：`C ≈ 148.1 Mcyc`；27 MHz 预测 `148.1/27 + 1.8556 = 7.3406 s`（实测 7.3406 s）。

**判词**：CDC FIFO 把 6.2628→4.5981 s 之后，**gather/DDR 侧仍占约 1.86 s（40%）** ⇒ L2b 的读预取
有明确收益空间（若把 AR/R 往返重叠掉一大半，帧时间可望进入 3.4–4.0 s 档）。
**边界**：这是**两点差分**的有效分解，`G` 包含所有不随 NPU 时钟缩放的固定项（DDR 延迟/带宽、
CDC 往返、主机轮询等），不是逐相位计数器；27 MHz 档比特流仅用于本实验，**已回退 54 MHz**。

**即时动作**：PLL 已恢复 12.5（54 MHz），重烧认证比特流 `c4a_l2d8v`（`a8be97d7…`）。

## 18. **2026-10-18：L2b —— DdrMaster 读块槽预取（Q=4）+ 合并点多 outstanding 读**

### 18.1 落地内容

`DdrMaster` 的 **mode=1（RD）** 增加 4 深 × 128 B 块槽状态 `QRUN`：

- AR 可提前发到后面 1..3 块（`qRemain/qAddr/qIssCnt` 推进，`qIssCnt−qDrCnt < 4` 约束槽数）；
- R 按序落槽（`qbuf[slot][beat]`、`qRcvCnt`），**槽 0 排空与后续槽填充同拍并行**；
- `rd_valid/rd_ready/rd_data` 消费者契约**不变**；mode 0/2 的 COPY/WR 路径**一字未动**（`QRUN`
  只在 mode==1 的 CHK 分支进入）。
- Q=1 负对照档由 `DdrMasterGen` 产出（`gen/DdrMaster_q1.v`）。

**闸门（新）** `y1/tools/run_ddrmaster_rdq_ab.sh`：3 笔 RD（1024/992/320 B）背靠背，
AxiMemModel 扩 4 深 AR 队列并统计在飞峰值：

| 档 | MAXOUT（io_mem 在飞峰值） | cyc（三笔） | 收流 |
|---|---|---|---|
| q4（product） | **4** | **147 / 143 / 59** | 逐字节 == 内存 |
| q1（负对照） | **1** | 266 / 258 / 85 | 逐字节 == 内存 |

### 18.2 结构性前提（实测发现，必须一起改）

`DmaEngine` 把通道换 q4 后，`run_dmaeng_ab.sh` 的 RD LEN=160（2 块）**挂死**。排查发现
**全 SoC 的合并点都是"首个 rlast 即释放 owner"**，而 NPU 的 `arvalid` 在授权期内持续直通：

- 第二笔预取 AR 会被收下；首笔 `rlast` 一到 `owner` 回 IDLE，第二笔的 R 拍**无人接收** ⇒ 死锁。
- 因此本片追加两条**承重改动**：
  1. `YeshenSocGlue`：读主人授权保持到**末笔 rlast**（`rdOut` 0..4 计数，`rdOut_next==0` 才释放）。
     单笔主人（CPU Fetch/LSU、DMA）`rdOut` 恒 0/1 ⇒ 逐拍行为不变：glue TB 的**单主人
     transcript 与 golden 0 差异**。
  2. `DmaEngine`：两通道 **rqDepth=1**（其通道间仲裁器是事务级单笔语义）。
- **新闸门 J_MM5**（`sim/glue_pbus/tb_memmerge.cpp`）：NPU 背靠背 3 笔读（4/2/3 拍），内存模型
  4 深 AR 队列。结果：**AR=3 笔（首拍 R 前 2 笔）/ 在飞峰值=3 / 字节错=0**。
- **红对照 NC_L2B**（`negctl_memmerge.sh`）：把释放条件 `(rdOut === 1.U)` 改成 `true.B`
  ⇒ **J_MM5 超时（TEST FAILED）**；跑完恢复源码并核对网表 md5 与跑前**逐字节一致**
  （`014fe3c8…`）。

### 18.3 回归闸门（全绿）

| 闸门 | 结果 |
|---|---|
| `run_ddrmaster_rdq_ab.sh` | PASS（q4 MAXOUT=4 / q1 MAXOUT=1；两档逐字节） |
| `run_dmaeng_ab.sh` | PASS（D1/D2 全过；RD LEN=160 恢复） |
| `run_ddrmaster32_ab.sh` | PASS（5 几何 + 5 非法入参 + RD/WR 流） |
| `run_ddrcopy_ab.sh` | PASS |
| `run_nputop_ab.sh` | PASS |
| `run_nputop_sched_ab.sh` | PASS（含 W1/W2/别名负对照） |
| `run_twoclock_ab.sh` | PASS |
| glue memmerge（J_MM1–J_MM5 + golden） | PASS（transcript 0 差异；J_MM5 峰值 3） |
| `check_dangling.py` / `check_dup_modules.py` | PASS（0 悬空 / 0 重名） |

`TILING=false` 三份网表（`UnitExec.v` / `UnitExec_w32.v` / `UnitExec_w640.v`）**保持字节冻结**
（`dd9ee31e…`/`af509071…`/`781bb0fd…`）——板级只用 `NpuTop.v`（已重生成，含 QRUN）。

### 18.4 面积（integrated dev_map）

| 资源 | L2d8w（L2b 前） | **L2b** | Δ |
|---|---|---|---|
| LUT | 68,453.5 (43%) | **73,049 (46%)** | +4,595.5 |
| FF | 89,905 (29%) | **102,848 (33%)** | +12,943 |
| APM | 262 (36%) | 262 (36%) | 0 |
| DRM | 241.5 (59%) | 241.5 (59%) | 0 |

FF 增量与"4 个 NPU DdrMaster 实例 × 3 个新增 128 B 槽（≈4k FF/实例）"的量级一致；
`check_devmap.py` PASS（0 error）。

### 18.5 PnR（18.4 ns）：ads 档未收敛 ⇒ **speed 综合档 seed0 `All Constraints Met`**

- **ads（默认）**：seed0 npu **53.0645 MHz / 18.845 ns / −0.445**（cpu +0.722、core +0.836）；
  seed1 −0.584。**失败路径不在队列上**，而是既有计算/线缓冲写路径
  （`N1716/gopapm → … → mpu/sl/lb/hist1_7_29[2]/D`，17 级，route 8.65 ns）。
  该路径在 L2d8v 交付时是同一始点、不同终点（`ddrMaster_4/wbase[25]/CE`）且 MET ⇒
  属于**布线/映射漂移**，不是 L2b 逻辑本身。
- **speed**（`pds/run_pnr_yeshen.tcl` 新增 `YESHENMINI_SYNTH_MODE=speed`：
  `synthesize -ads -resource_sharing FALSE -retiming`，tag `c4a_l2b_s`，FRESH 从零）：
  seed0 即 `UserFilter: 1`，**`Design Summary : All Constraints Met`**：

| 时钟 | 请求 | 估计 | Slack |
|---|---|---|---|
| cpu_clk | 100 MHz | 107.3192 MHz | +0.682 |
| core_clk | 125 MHz | 131.7003 MHz | +0.407 |
| **npu_clk** | **54.3478 MHz (18.4 ns)** | **56.3444 MHz (17.748 ns)** | **+0.652** |

- speed 档 dev_map：LUT 73,093.5 (46%)、FF 102,883 (33%)、APM 269 (37%)、DRM 241.5 (59%)
  —— 与 ads 几乎相同，时序收益来自 retiming/布局，而非资源换时序。
- 比特流：`sim/reglogs/pds_c4a_l2b_s_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  **9,188,552 B / md5 `cdc5a6b781630e384b08011629a12b14`**。板钟 54.000 MHz ≤ est 56.3444（4.2% 余量）。

### 18.6 诚实边界

- **只有"一笔 RD 跨多块"受益**：窄路行 gather（272/160/128 B）与每单元权重段（576 B）；
  **宽路的 32 B 单块平面 gather 不受益**（那是方案 B 的范围）。
- `DdrMaster` 的块槽预取只加在 mode=1；COPY/WR 的逐拍行为与旧版一致。
- 本节上板 A/B 见 §18.7（待板）。

### 18.7 上板 A/B（2026-10-18 13:00，tag `c4a_l2b_s`）

**烧写**：`flash_and_verify.py --tag c4a_l2b_s --com COM7` ⇒ `done bit = 1`；启动判据 8/8
（SDR `misoHi=1`、OpenSBI、Linux 5.10.1、LiteEth、dropbear、`VEXIIYESHEN-OK`、`login:`）；
网络 ping PASS。板内纯 C `y1run --frames 3 --quiet`（第 5 槽 payload，零主机传输）：

```
RUN 0 ns=4546991280 status=0x00000001 outputs=12/12
RUN 1 ns=4546802820 status=0x00000001 outputs=12/12
RUN 2 ns=4546294520 status=0x00000001 outputs=12/12
Y1RUN: PASS frames=3 pass=3 fail=0
```

| 指标 | L2d8v（L2b 前） | **L2b（Q=4 块槽预取）** | Δ |
|---|---|---|---|
| 单帧（均值） | 4,598,110,970 ns | **4,546,696,207 ns** | **−51,414,763 ns（−1.12%）** |
| 吞吐 | 0.21748 fps | **0.21994 fps** | +1.13% |
| 输出 | 12/12 | **12/12（逐字节黄金）** | 不变 |
| 稳定性 | ±1.2 ms | ±0.7 ms | — |

**判词（按 spec §4 的预设规则）**：A 的收益 **<5%**（实际 **−1.12%**）⇒ 说明"同一行内的块间
AR 往返"已不是主要固定项；`G≈1.856 s` 的主体更可能是**宽路 32 B 单块 gather 的每请求往返**
（方案 A 结构性帮不到）与计算侧。因此**不直接上方案 B**，下一步应先做"宽路 gather 的跨请求
在飞"归因（或在 gather FSM 内提前入队下一条 32 B 请求），并重算 `C/f+G` 两时钟差分。
**收益为正且 12/12 逐字节不变**，本片作为"低风险、小步"改动收口。

**本片指纹**：NpuTop.v `23ae0e92…`、DdrMaster.v `d521c282…`（q4）/ `5091eaa9…`（q1）、
DmaEngine.v `0797dd53…`（Q=1）、YeshenSocGlue.v `014fe3c8…`（注释行数中性，构建链逐字节一致）、
比特流 `cdc5a6b781630e384b08011629a12b14`（9,188,552 B）。
