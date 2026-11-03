# TF 卡镜像 v2（sd_y1_v2.img）—— 软件全集 + 开机自启 YuNet

日期：2026-10-23。宿主侧完成；**尚未写卡/上板**（板子仍在 Cam known-good 比特流上，等用户给窗口）。

## 产物与指纹

| 产物 | 大小 | md5 | 状态 |
|---|---|---|---|
| `sw/images/sd_y1_v2.img` | 10,706,432 B (20,911 blk) | `dd484418272d7acce85d36b4802d2016` | 已核验（头/条址/md5/可执行位） |
| `sw/images/rootfs_v2.cpio` | 2,659,360 B（395 条） | 段 md5 `bdad259f…` | 已核验（嵌入镜像逐字节相同） |

`sw/images/` 在 `.gitignore` 里 ⇒ 镜像不入库；**配方**（`scripts/initramfs_add.py` + 本文件）入库可重建。

## 卡内布局（大端 YSLD，与 sd_y1_safe.img 同序同址）

| DDR 地址 | 段 | LBA | 块数 | md5 |
|---|---|---|---|---|
| 0x8000_0000 | fw_jump（OpenSBI） | 1..262 | 262 | `44ea1d6b…`（与 safe 相同） |
| 0x8200_0000 | Image（Linux） | 263..12137 | 11875 | `566ecc68…`（与 safe 相同） |
| 0x82F8_0000 | linux.dtb | 12138..12141 | 4 | `fc4d959c…`（与 safe 相同） |
| 0x8300_0000 | **rootfs_v2.cpio** | 12142..17336 | 5195 | `bdad259f…`（新） |
| 0x81E0_0000 | payload（Y1PL） | 17337..20910 | 3574 | `542895b9…`（与 safe 相同） |

DDR 区间互不重叠，最高结束地址 `0x8328_9000`。rootfs 比 safe 版多 168 块（+85,536 B），
其后 payload 的 LBA 顺移 168 块 —— SdLoader 按头表装载，**LBA 变化无影响**。

## 相对 sd_y1_safe.img 的软件变化

重打包了 rootfs（其余四个段逐字节沿用 safe 版）：

- 替换：`etc/init.d/S97uart_dbg.sh`、`S98naxmini_net.sh`、`S99naxmini_marker.sh`、
  `etc/inittab`、`etc/motd`、`etc/profile`、`root/y1/y1run`、`sbin/getty_ixon`
  （都是仓库 overlay 里的现值，和 safe 版一致，只是重新封装）。
- **新增 `root/y1/y1cam`（83,268 B，md5 `e4806746…`）**、`root/y1/y1run`（62,752 B，md5 `fc4ec0b6…`，含 `--unit-trace`） —— 板内 C 版 YuNet + 画框程序（`--once/--loop`）。
- **新增 `etc/init.d/S99leds.sh`** —— LED 软件诊断位（心跳/y1cam/NPU busy/网口），后台子进程。
- **新增 `etc/init.d/S99y1cam.sh`** —— 开机自启：`/root/y1/y1cam --loop --quiet &`，
  pid 写 `/run/y1cam.pid`，启动结果写 `/dev/kmsg`（串口可见 `Y1CAM-BOOT …`）。

## 构建配方（可复现）

```bash
ov=sw/buildroot-external/boards/naxmini/linux/rootfs_overlay
MSYS_NO_PATHCONV=1 python scripts/initramfs_add.py --in sw/images/rootfs.cpio \
  --out sw/images/rootfs_v2.cpio \
  --add "$ov/etc/init.d/S97uart_dbg.sh:/etc/init.d/S97uart_dbg.sh" \
  --add "$ov/etc/init.d/S98naxmini_net.sh:/etc/init.d/S98naxmini_net.sh" \
  --add "$ov/etc/init.d/S99naxmini_marker.sh:/etc/init.d/S99naxmini_marker.sh" \
  --add "$ov/etc/init.d/S99y1cam.sh:/etc/init.d/S99y1cam.sh" \
  --add "$ov/etc/inittab:/etc/inittab" --add "$ov/etc/motd:/etc/motd" \
  --add "$ov/etc/profile:/etc/profile" \
  --add "$ov/root/y1/y1cam:/root/y1/y1cam" \
  --add "$ov/root/y1/y1run:/root/y1/y1run" \
  --add "$ov/sbin/getty_ixon:/sbin/getty_ixon"
python sim/mk_sd_image.py --out sw/images/sd_y1_v2.img \
  --entry 0x80000000=sw/images/v2_seg/fw_jump \
  --entry 0x82000000=sw/images/v2_seg/Image \
  --entry 0x82F80000=sw/images/v2_seg/linux.dtb \
  --entry 0x83000000=sw/images/rootfs_v2.cpio \
  --entry 0x81E00000=sw/images/v2_seg/payload
```

`v2_seg/` 由 sd_y1_safe.img 按头表切出（fw_jump/Image/dtb/payload）。

写卡（**未执行**，等窗口）：

```bash
# 物理盘号先核对再写；写后回读头表自证
python scripts/build_y1_card.sh   # 现有流程参考；或直接 raw dd sd_y1_v2.img 到 LBA 0
```

## 踩过的真坑（已修）

1. **cpio 权限不能沿用宿主**：Windows 上 `st_mode` 只有 `0o666`，第一版镜像把新增/替换条目全写成
   0666 ⇒ 开机会话脚本与 `/root/y1/*` 全部不可执行（rootfs 会起来，但 S97/S99 与 y1cam 静默失败）。
   已改成默认 0644、可执行目录/`--exec` ⇒ 0755，并逐条核对嵌入镜像里的 mode。
2. `MSYS_NO_PATHCONV=1` 必须加：否则 `src:/dst` 被 Git Bash 改写成 Windows 盘符路径
   （实测把 `dst` 变成 `C:`）。
3. 不用 `cpio -id` 解包：WSL 非 root 无法 `mknod dev/console`，设备节点会丢。

## 2026-10-23 追补：镜像里的 y1cam 曾是**过期二进制**（已修）

- 现象：overlay 的 `y1cam` 时间戳 10-19 **05:55**，而 `y1cam.c` 是 10-19 **17:22**；
  它恰好停在 `0fec76d`（continuous `--loop`）**之前**，也不含 `75bc5a7`（帧存 bank stride
  16 MiB 修复）⇒ **`S99y1cam.sh` 的 `--loop` 会直接不被识别，开机自启形同虚设**；
  即便跑起来，bank stride 也是错的（取到错误帧存）。
- 修：WSL 里 `bash y1/tools/build_y1cam.sh --install` 重建并装回 overlay
  （`e4806746bb59b401fd4de0b95e87cf98`，`strings` 已确认 `--loop/--quiet/--frames/--interval-ms` 与
  `CAMRUN … bank=%u …` 遥测在），再重打 rootfs 与卡镜像（指纹见上表）。
- 教训：**二进制产物入库时必须在报告里同时记"源码提交 + 二进制 md5 + strings 冒烟"**，
  否则镜像会悄悄带旧程序。

## 2026-10-23 追补 2：`y1run` 同样是过期二进制（已修）

- 现象：overlay 的 `y1run` = **10-17 18:46**，源码到 **10-21 13:29** 还有两次提交
  （`a407bae` 逐单元遥测 `--unit-trace`、`ee05ea2` 逐单元归因）⇒ 镜像里的 runner **没有遥测口**，
  上板做逐单元归因时会"命令不认"。
- 修：`build_y1run.sh --install` 重建（`fc4ec0b6`），`strings` 已确认 `--unit-trace` 在。
- 两者一起重打后的最终镜像指纹见上表（`dd484418…`）。

## 2026-10-23 追补 3：payload 来源核对（无过期）

- 卡内 `0x81E00000` 段 = `y1/build/y1_payload.bin`（1,829,568 B，md5 `7cec60ca…`）**+ 320 B 零填充**
  （1,829,888 B）；前缀逐字节相等、尾部全 0（已用 Python 断言）。
- manifest `y1/build/y1_payload.bin.json`：`desc_md5=4bd68b36…`，与当前 `y1/gen/desc.bin`
  （`4bd68b36…`，10-17 12:44）**一致**；payload 构建时间 10-17 18:48 晚于输入 ⇒ 无过期。
- 其余三段（fw_jump/Image/dtb）逐字节沿用 `sd_y1_safe.img`（known-good 内核），md5 见上表。

**来源链结论**：卡内每个"程序"都能对上当前源码/构建产物；没有第二处过期二进制。
