# 板级 Bring-up 手册（VexiiYeshenLinux / 盘古 100K200K MINI）

> 目标读者：拿到这台机器、要**从零把它跑起来**或**在出问题时快速定位**的人。
> 配套：一页功能总览见 `docs/开发板功能清单-2026-10-08.md`；逐轮过程与踩坑见 `docs/交付-2026-10-07.md`。

---

## 0. 一页流程

```
 ① 一键构建        bash scripts/build_all.sh                 → 比特流 + 四镜像 + sd.img（逐阶段打指纹）
 ② 写卡            powershell -File sim/board/write_sd.ps1    → 需管理员；自带 GUARD + SHA256 回读
 ③ 烧板 + 验启动    python -u scripts/flash_and_verify.py      → done bit=1 + 启动 marker 全过
 ④ 网络/ssh 判据    （③ 已含；也可单跑）scripts/eth_*.py / ssh
```

> ⚠️ **FPGA 配置是易失的**（JTAG 下载）：**每次断电/换卡之后都要重烧一次**。
> 症状是"串口**连 SDR 行都没有**" —— 这跟"卡没插好"完全不是一回事（后者 SDR 有帧但 `misoHi=0`）。

---

## 1. 前置

| 类别 | 要求 |
|---|---|
| 硬件 | 盘古 100K200K MINI（PG2L200H-6IFBB676）；TF 卡插在 **J25 的 TF 模块**上；USB 下载器 + 串口（COM7） |
| Windows 工具 | 紫光 **PDS 2025.2**（`C:\Pango\PDS_2025.2-ads\bin`：`pds_shell.exe` / `cdt_js.exe` / `cdt_cfg_shell.exe`）；JDK 17 + sbt（核网表用）；`scala-cli`（胶合用，`%LOCALAPPDATA%\Coursier\data\bin`） |
| WSL | 编镜像用（buildroot 2025.02.18）；工作区 `$HOME/vexii-build`（首次会自动拉取） |
| 代理 | WSL **够不到** Windows 上只绑 127.0.0.1 的 Clash ⇒ 先在 Windows 起 `python scripts/win_proxy_relay.py`，WSL 里 `export http_proxy=http://172.21.128.1:7898`（宿主 IP 用 `ip route | awk '/^default/{print $3}'` 取） |
| Python | 3.9 venv 给 LiteEth 黑盒生成（**必须 3.9**，3.14 的 migen/LiferX tracer 会失效）：`D:\code\PDS\NaxYeshenLinux\sim\reglogs\lxvenv\Scripts\python.exe` |
| 三方资产 | `third_party/` 不入库，按 `third_party/PINS.md` 的 SHA 复现（VexiiRiscv + 4 子模块） |

---

## 2. 构建（①）

```bash
bash scripts/build_all.sh                    # 默认：glue liteeth devmap pnr images sdimg
bash scripts/build_all.sh --with-core        # 连核网表（要 sbt，慢）
bash scripts/build_all.sh --only images,sdimg # 只重做镜像/卡镜像（改内核补丁、overlay、DTS 后常用）
bash scripts/build_all.sh --from pnr         # 从 PnR 起（RTL 变了、镜像没变）
TAG=m10 bash scripts/build_all.sh --from devmap
```

- 每个阶段跑完立刻打印**产物指纹（字节数 + md5）**，最后有总表 ⇒ 抄进交付记录。
- `devmap` 阶段带**闸门**：`check_devmap.py` 必须 0 error / 0 DRC 才继续（避免白跑一小时 PnR）。
- `pnr` 阶段带判据：必须出现 `YESHENMINI_PNR_DONE` + **`All Constraints Met`** + 比特流文件存在。
- 改了**内核补丁 / overlay / DTS** 时，`images` 阶段要带 `REBUILD_PKGS=linux`
  （buildroot 不把 `BR2_EXTERNAL` 里的板级文件当依赖，不强制 dirclean 会**静默沿用旧产物**）。

---

## 3. 写卡（②）

```powershell
Get-Disk                                   # ⚠️ 先核对盘号！写错盘不可逆
powershell -File sim/board/write_sd.ps1 -Disk 2 -Letter E
```
- **需要管理员**（裸写 `\\.\PhysicalDriveN`）；脚本自带 **GUARD**（只认 USB / <16GB / 盘分区匹配 / 镜像装得下）
  与 **写后全量 SHA256 回读比对** ⇒ 必须看到 `CARD VERIFY PASS`。
- 卡镜像由 `sim/mk_sd_image.py` 生成（`YSLD` 块 0 装载表 + 四镜像；段内字节与源文件逐字节校验）。

---

## 4. 烧板 + 验启动（③）

```bash
python -u scripts/flash_and_verify.py                 # 烧 m9 + 验启动 + 网络/ssh
python -u scripts/flash_and_verify.py --tag m10 --no-net
```
脚本做的：前置检查（别的会话/进程是否占板）→ 起 cdt_js（读自报端口）→ 起串口采集 → 烧写（读 **`done bit`**，不看 LED）
→ 校验启动 marker → （可选）ping + ssh。

**启动判据（全过才算 PASS）**

| marker | 含义 |
|---|---|
| `SDR …` 有帧 且 第 3 个 hex ∈ `[89A-F]` | SD 装载在跑且 **`misoHi=1`**（卡在、在读） |
| `Platform Console Device` / `OpenSBI` | OpenSBI banner 出来了 |
| `Linux version 5.10` | 内核起来 |
| `liteeth … eth0: irq … slots: tx 2 rx 4` | 网卡驱动 probe + **rx 4 槽**（与 DTS 一致） |
| `Starting dropbear sshd: OK` | sshd 起来 |
| `VEXIIYESHEN-OK` | **到了用户态**（最强的一条） |
| `login:` | getty 在等登录 |

---

## 5. 故障排查（症状 → 判据 → 处置）

| 症状 | 判据（怎么确认） | 处置 |
|---|---|---|
| 串口**完全静默**，**连 SDR 行都没有** | 采集里 `grep SDR` 空 | **FPGA 配置丢了**（断电/换卡）⇒ 重烧一次。**不是**卡的问题 |
| SDR 有帧但 **`misoHi=0`**（第 3 个 hex ∈ `0-7`） | `SDR 103A90…` 这种形状 | **卡没插实 / J25 模块接触抖** ⇒ 重插卡（别怀疑镜像） |
| 控制台在 **`login:` 之前**就静默 / shell 无回显 | 静默时 `devmem 0xF0001014`→`LSR=0x60`、`0xF0001008`→`IIR=0xC1`、`0xF0001004`→`IER=0x05`（**硬件空闲**） | **`IXON` 流控**（一个杂散 `0x13` 停发）⇒ 临时：发 `^Q`；根治：镜像里的 `getty_ixon` + `profile`（见 §7）。⚠️ 在 `login:` 发 `\r` 得 0 字节是**正常**，别当卡死 |
| 串口收字节偶发错 | `cat /proc/tty/driver/serial` 看 `fe/oe/pe`（只在非零时打印） | 我们实测 RX **很稳**（88 KB 零 `oe/fe/pe`）；若出现 `fe` ⇒ 查波特/时序；`oe` ⇒ 缓冲/响应 |
| 主机 ping 不通、邻居 `Incomplete` | **先确认板子接在主机哪个网口**：让板子发广播（板内 `ping <主机IP>`），看**哪个口的 `ReceivedBroadcastPackets` 在动** | 本工程板子在 **ifIndex 5**（`以太网`，192.168.1.105/24），**不是** ifIndex 27 |
| 主机 ARP 学到**不是板子的 MAC** | `Get-NetNeighbor <板IP>` 的 MAC 应为 `02-00-00-00-00-01` | 那段网可能有**代理 ARP 代答** ⇒ 换判据（板侧计数 / 板内 `ip neigh`），别用 ping 单判 |
| 线上一帧都不走（板能发但主机收不到） | 板内观测窗 `devmem 0xF000B014` 的 **`txRunMax`**：正常 ≥68（一帧），坏时 ≈4 | 历史根因：`dw=8 + with_sys_datapath` ⇒ 现版已是 `dw=32`；若复现先查这条 |
| ssh 卡在 `expecting SSH2_MSG_KEX_ECDH_REPLY` | 客户端日志 | 协商到 **`sntrup761`** ⇒ 加 `-o KexAlgorithms=curve25519-sha256 -o HostKeyAlgorithms=ssh-ed25519` |
| ssh 慢 / 偶发失败 | 板内 50 帧背靠背突发的收包数 ≈ **槽数**（4） | 已知边界（在飞缓冲）；**别用 NAPI**（试过 ⇒ softirq 风暴挂死） |
| 出带复用了旧工程（改了源却没生效） | `run_pnr_yeshen.tcl` 打了"入口 A 复用" | 改源之后必须 `YESHENMINI_PNR_FRESH=1`（或用不同 TAG） |
| 镜像改了却像没生效 | 新 rootfs 里 `grep` 你的改动 | `REBUILD_PKGS=linux`（先 `-dirclean`）；DTS 变了 ⇒ 内核也要重建 |
| 板内命令偶发坏字节 | 计数全 0 / 没复现 | 把命令**压短**；工具开口先补 `^Q` |
| 卡写进去却没生效 | 写卡日志有没有 `CARD VERIFY PASS` | 写卡必须**管理员**；失败时脚本**不返回非零退出码**，要看 transcript |

---

## 6. 常用命令速查

```bash
# 串口（控制台要口令 yeshen；本镜像已关 IXON）
python -u scripts/uart_login_pw.py COM7 115200 yeshen
python -u scripts/guest_cmd.py COM7 115200 "grep eth0 /proc/net/dev"

# 片上观测窗（只读）：W4=GMII tx/rx 字节，W5=txRunMax/rxRunMax
python -u scripts/eth_dbg_read.py COM7 115200 2
#   devmem 0xF000B000 W0 | 0xF000B004 sysCnt | 0xF000B008/0xC 最后 CSR 读写
#   devmem 0xF000B010 W4 | 0xF000B014 W5 | 0xF000B01C 延迟旋钮(写 {txclk,rx})

# 网络数据面
python -u scripts/eth_udp_e2e.py COM7 115200 192.168.1.110     # burst vs paced
python -u scripts/eth_tcp_client_test.py COM7 115200 192.168.1.105 8080

# ssh（KEX 必须压；askpass 见下）
MSYS_NO_PATHCONV=1 wsl -e bash -lc \
 'SSH_ASKPASS=$HOME/askpass.sh SSH_ASKPASS_REQUIRE=force ssh \
  -o KexAlgorithms=curve25519-sha256 -o HostKeyAlgorithms=ssh-ed25519 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password root@192.168.1.110 "uname -a"'
# 前置：WSL 里 printf '#!/bin/sh\necho yeshen\n' > $HOME/askpass.sh && chmod +x $HOME/askpass.sh

# 串口错误计数（判"是溢出还是采样错"）
python -u scripts/uart_stress_probe.py COM7 115200 200 400
python -u scripts/uart_xoff_ab.py COM7 115200        # ^S 停 / ^Q 救 的正反 A/B
```

---

## 7. 两条必须记住的"镜像内"修复（改 overlay 后要重建镜像）

| 文件 | 作用 |
|---|---|
| `rootfs_overlay/sbin/getty_ixon` + `etc/inittab` 指向它 | exec getty **之前** `stty -ixon` ⇒ **登录提示符之前**那段窗口也不受 `^S` 影响 |
| `rootfs_overlay/etc/profile` | 登录后再钉一遍 `stty -ixon` |
| `scripts/listen_uart.py` / `guest_cmd.py` | 开口/每条命令前补 `^Q`（挡主机侧开串口吐的杂散字节） |

---

## 7b. 软复位 / `reboot`（2026-10-29）

板上没有可编程的复位键（KEY0 是硬复位，按下去等价于断电）。现在有两条软件路径：

```bash
# ① Linux 里（需要配套的 DTB + 内核配置，见下）
reboot

# ② 只有新比特流、没有新镜像时（用户态直接写寄存器，等效）
devmem 0xF0007498 32 1        # VIDEO 窗 0x098 = RST_CTRL, bit0
```

RTL 链条：`video_regs.RST_CTRL[0]` → `rst_ctrl`（clk_in 27 MHz 域）→ **20 ms** 低有效
`sys_rstn` → 与板级复位链相与 → `soc_resetn`。

**语义 = 除两颗板级 PLL 外等同冷启动**：DDR3 IP 也被复位（重新走 0.37 ms 复位脉冲 +
PHY 校准），胶合块的 SD 装载器复位 ⇒ 走与冷启动同一条装载路径。整次重启约 **8 s**
（DDR 校准几百 ms + 1 s BootSel 窗口 + SD 装载约 7 s）。

- **为什么 DDR 也要复位**：reboot 那一刻视频通路几乎必然有一笔 DDR 读在飞；只清 SoC
  会让那笔 R 数据无人取、R 通道堵死 ⇒ 重启后装载器读回残数。细节见 `board/rst_ctrl.v` 头注释。
- **不自锁**：请求位 `RST_CTRL[0]` 的复位端就是 `soc_resetn` ⇒ 本次复位必然把它清掉；
  `rst_ctrl` 另有"一个请求只兑现一次"的保险（U7 闸门 + 负对照）。
- **配套软件**（本次一并改了，需重建镜像才生效）：
  - DTS 根下 `syscon@f0007400` + `reboot { compatible = "syscon-reboot"; offset = <0x98>; }`
  - 内核 `CONFIG_POWER_RESET=y` / `CONFIG_MFD_SYSCON=y` / `CONFIG_POWER_RESET_SYSCON=y`
    （缺任一条 DT 里的 reboot 节点就是死的，`reboot` 只会卡在 `machine_restart` 死等）
  - 台账：`scripts/check_addr_map.py` 会对 `offset` ↔ `video_regs.A_RSTCTRL` 与
    `syscon` 基址 ↔ `VIDEO_BASE` 两处对账
- **没起来怎么办**：串口应当先看到 `R` 行重启（`SDR` 报文），再是 BootSel 提示。
  若见到 `errCode=7/8`（SD 段 CRC 错）⇒ DDR 校准没完成就放行了（说明
  `ddr_init_done` 没跟随 DDR 复位掉落）；若一个字都没有 ⇒ 断电重启一次并记下现象。

---

## 8. 复现指纹（示例，随交付轮次更新）

| 件 | 路径 | 指纹 |
|---|---|---|
| 比特流 | `sim/reglogs/pds_<TAG>_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit` | m9：9,188,552 B / md5 `a06782ae0a75a7edb1621f726f3fcf07` |
| 卡镜像 | `sw/images/sd.img` | md5 `5b2c25f0816e602110fb87ba57470cd3` |
| 四镜像 | `sw/images/{fw_jump.bin,Image,linux.dtb,rootfs.cpio}` | `build_all.sh` 收尾总表会打 |
