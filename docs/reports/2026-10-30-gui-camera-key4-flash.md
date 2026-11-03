# 2026-10-30 会话总结：相机应用 + KEY4 返回 + 显示/触摸服务 + 配置 flash 固化

> 范围：`VexiiYeshenLinux`（RTL / 内核 / rootfs / 镜像 / 卡 / flash）与 `YeshenGui`（板端应用）。
> 结论先说：**上电即进 GUI 桌面**（FPGA 从配置 flash 自加载，`ctp2` 位流 @11.76 MHz 配置钟），
> 相机应用可选「人脸检测 / 纯画面」、可切 CAM0/CAM1（默认 CAM1），KEY4 或左上热角返回桌面；
> 显示走异步 flush、触摸走独立线程。全部判据在板上跑过（§5）。

---

## 1. 交付物指纹

| 产物 | 大小 | 指纹 |
|---|---|---|
| `ctp2` 比特流（2.99 MHz，JTAG 用） | 9,188,552 B | sha256 `c01d6a6f30300956b0862de5dc8bf61b1907c498442c97a6b77b401725eededa` |
| **`ctp2` 比特流（11.76 MHz，已固化）** | 9,188,552 B | sha256 `DA5190B1331CF0B47041350D80183FD0B869DD5D8F27B664B91790FA21E054C6` / md5 `6258560c8d0270204ebbb1e86a25d5c5` |
| 固化用 SFC | 9,188,552 B | md5 `6258560c…`（= 上面那份，回读逐字节 MATCH） |
| `Image` | 6,205,492 B | md5 `8d0cab8bdb82787d0ba149fcebdfa017` |
| `linux.dtb` | 3,183 B | md5 `e09b154d9e07985ece9e7f2c946b13be` |
| `rootfs.cpio` | 6,452,224 B | md5 `b82005849e2dfbb39c7b4023cfe88891` |
| ↳ `root/gui/yshell`（主线变体） | 1,319,892 B | md5 `0eebfe98f8b8702529882691c1ea181b` |
| ↳ `root/y1/y1cam`（10-28 版） | 95,568 B | md5 `9cb5a2557bbe043b3a3393c263c9cddf` |
| `sd_ab_k2_ctp.img`（双计划全 Linux） | 33,554,432 B | md5 `9fca5c089e2171a9b50cfd1b2783e7d6` |
| **`sd_score_ctp.img`（两用卡，已写卡）** | 16,838,144 B | md5 `844b3ed1c4780dfa1ec0f36ba8f753e6` / sha256 `78C434AA4767A85B70242F2B8FB66AB02624759D563F8147C5B574FD823262FF` |

卡布局：计划0（LBA 0）= Linux GUI 镜像（5 段）；计划1（LBA 32768）= CoreMark i5500。
开机 `[Y1] L=Linux C=CoreMark >` 窗口按 `L`/超时进桌面，按 `C` 跑分。

---

## 2. RTL 改动（主线）

1. **KEY4（B20）→ GPIO12**：顶层新增 `input key4`（低有效、有源上拉）→ `soc_clk` 2FF →
   `gpio_in[12]`（原来是恒 0 的保留位）。FDC 新增 `p:key4 = B20`。
   端口 / FDC 集合脚本核对 **166 == 166**，差集为空（`ctp1` 是 165）。
   · KEY0=C22 复位、KEY1=C23 装载 strap、KEY2=B22 硬件双目切换（同源 `CAM_CTRL[0]`）、
     KEY3=A22 本板未接 ⇒ **只有 KEY4 能当通用返回键**。
2. `ctp2` dev_map：0 error；**LUT 88,083（56%）/ FF 119,648 / DRM 312 / APM 257 / IO 166**。
3. `ctp2` PnR（strategy 1，4 seed）：**All Constraints Met**
   （soc +0.462 / cpu +0.609 / npu +0.557 / core +0.506；
   `phy_dq_sysclk_0→core_clk` **+3.299**，`ctp1` 的那条 −0.010 弧不再出现）。

> dev_map 启动后只改过顶层文件的**注释**（端口数说明），逻辑未动。

---

## 3. 内核 / rootfs / 应用

### 3.1 内核

- DTS 新增 `gpio-keys-polled`：`gpios = <&gpio_ctp 12 GPIO_ACTIVE_LOW>`、
  `linux,code = KEY_F13`、`poll-interval = 20`；DTB 反编译实证 `gpios=<0x04 0x0c 0x01>`、
  `linux,code=<0xb7>`（KEY_F13）。
- 配置新增 `CONFIG_INPUT_KEYBOARD` + `CONFIG_KEYBOARD_GPIO_POLLED`（均已回读 `.config` 确认 `=y`）。

### 3.2 rootfs overlay

- `root/gui/yshell`：主线变体（`GUI_CTRL` 偏移 **0x09C**）、`--no-uart` 版。
- `root/gui/assets/wallpaper_{ink,paper}.bin`：壁纸（默认 paper）。
- `root/y1/y1cam`：**从当前源码重建**（见 §4.2）。
- `/etc/y1gui.autostart`：开机自启标记；`S99gui.sh` 改为 `setsid /root/gui/yshell --no-uart ...`。
- `S99y1cam.sh`：默认**不**自启（仅 `/etc/y1cam.autostart` 存在时起），人脸检测由相机应用按需拉起。

### 3.3 YeshenGui 应用（提交 `3ea6767`）

- **相机卡片**：进入时二选一 **Detect faces / Plain view**；CAM0/CAM1 按钮写 `CAM_CTRL[0]`，
  默认 **CAM1** 并落 `/etc/y1cam.default`；进入前 `wm_show_desktop()`，
  返回统一走 `desktop_camera_leave()`（停 y1cam → `OVERLAY_CTRL=0` 清框 → `gui_src=1` → 立即重绘）。
  KEY4 与左上热角调用同一函数。
- **显示服务** `platform/board_present.c`：`flush_cb` 只把条带拷进 4 个缓存 staging 槽就返回
  （LVGL 立刻可复用 draw buffer），独立线程按序写 DDR；`pthread_create`/malloc 失败自动退回同步 flush。
- **触摸服务**：独立线程 `poll()` evdev 维护 `(x,y,pressed)` 快照；`EVIOCGABS` 改为开设备时查一次；
  无线程时（如 `--touch-probe`）退回同步 drain。
- 其它：y1cam 遥测改落 `/tmp/y1cam.log`（原来接 `/dev/null`）；新增 `--no-uart`；
  桌面 CPU% 改 `/proc/stat` 真占用（旧版用 loadavg，恒显 100%）；默认浅色壁纸。

---

## 4. 本次修掉的两个真缺陷

### 4.1 点「Plain view」必崩：OVERLAY_CTRL 偏移少加 0x400

- 现象：点 Plain view 后界面“卡住”（LCD 停在最后一帧）。
- 证据：`yshell[93]: unhandled signal 11 … at 0x0001ff8c`，`cause 7`（Store/AMO access fault），
  `badaddr` = 视频页基址 + `0x008`；`addr2line` 落在 `platform_clear_overlay()` 的 `sw zero,0(a5)`。
- 根因：VIDEO CSR 窗从 **`0xF000_7400`** 起，`/dev/mem` 只能按页（`0xF000_7000`）映射；
  `0xF0007000 + 0x008 = 0xF0007008` 落在 SoC **未译码**的空洞 ⇒ 总线错杀进程。
- 板上实证：`devmem 0xF0007408` → `0x0`（正常）；`devmem 0xF0007008` → **Segmentation fault**。
- 修复：`VIDEO_OVERLAY_CTRL_OFF = 0x408`，并给三个视频寄存器加
  `_Static_assert(off >= 0x400, "must sit in 0xF0007400..77FF")`。

### 4.2 人脸检测看不到框：卡上的 y1cam 是 10-23 旧构建

- 现象：Detect faces 进入相机态后没有检测框。
- 证据：`/root/y1/y1cam` 是 **10-23 21:20** 的 83,268 B 二进制，而 `y1/tools/y1cam.c` 最后修改
  **10-28 01:41**（关键提交 `60b4ee3`：反量化口径 + BOX 字序 + 阈值 0.65 未烘进卡）。
  旧二进制残留 BOX0 = `{0x000001E3, 0x01690344}` ⇒ x 0..361、**y 483..836（越界且未裁剪）**，
  与现源码 `map_boxes()`（`x+192 / y-20` + 裁剪到 1023/599）不一致。
- 附带确认：“没人时 dets=0”是正确行为——用 `--once --dump` 取回 640×640 快照转 PNG 看过，
  当时画面只是房间/挂着的衬衫。
- 修复：`bash y1/tools/build_y1cam.sh --install` 重建（95,568 B，`--loop` 在），
  板上真人测试为连续 20 个采样 `OVERLAY_CTRL=0x0101`（en=1、count=1），
  BOX 解码 x 369→563、y 60→284（194×224，全部在屏内），目视绿框正常。

---

## 5. 板上验收证据

| 判据 | 结果 |
|---|---|
| 启动 8 项 marker（SDR/OpenSBI/Linux/LiteEth/dropbear/VEXIIYESHEN-OK/login） | 全 PASS |
| GUI 开机链 | `YGUI-AUTOSTART pid=93` → `YGUI-BOOT` → `YGUI-VARIANT gui2`（`0x92000000`，行 60..659）→ **`YGUI-PRESENT async`** → **`YGUI-TOUCH-SVC`** → `YGUI-FB-OK`，内核时间 3.9–5.0 s |
| 线程 | `/proc/93/task` = 主 + 显示 + 触摸 共 3 个 |
| 输入设备 | `input0 = gpio-keys`、`input1 = Goodix Capacitive TouchScreen`；PLIC 源 5 `gt911` 在计数 |
| 寄存器 | `GUI_CTRL(0xF000749C)=0x1`、`CAM_CTRL(0xF000740C)=0x3`（CAM1、ready、idle） |
| KEY4 / 热角返回 | 日志 `YGUI-CAMERA gui GUI_CTRL=0x1 readback=0x1`；Plain view 清框 `YGUI-OVL off`，不崩 |
| 冷启动（**无 JTAG**） | 断电上电后 kmsg 里上述 GUI 链齐全，`devmem` 两个视频寄存器可读 ⇒ 跑的是 `ctp2` |

---

## 6. 配置 flash 固化（掉电不丢）

板级：核心板 2× QSPI（`XT25BF128`），JTAG 间接编程（`cfg_jtag_flash_*`），配置钟键
`master_configuration_clock_frequency`。

1. 备份当前 flash（Y1 cmd18）：回读 9,188,552 B，md5 `2c5835ef…`，
   落 `sim/reglogs/spi_flash/flash_backup_20261030.sfc`。
2. 生成 11.76 MHz 位流（**不重跑 PnR**）：
   `open_project …/pds_ctp2_p10.000/yeshenmini_ctp2.pds` →
   `clean -action [get_actions gen_bit_stream -of_objects [get_tasks pnr_1]]` →
   `set_option -options {master_configuration_clock_frequency 11.76M} …` →
   `launch_tasks / wait_on_tasks … gen_bit_stream`。
   结果与 2.99 MHz 版**仅差 14 字节**（头部时间戳 + `0x8AF 0x00→0x11` + 两处工具重算校验），
   该字节即 `option0_data[6:0]=17`（ini 映射表在
   `arch/vendor/pango/logos2/pg2l200h/data/config/ini_data/Logos2-PG2L200H.ini`）。
3. `cfg_gen_sfc -device_name XT25BF128` → erase 29.4 s / program 223.1 s / verify 76.4 s /
   readback 76.3 s，**回读与 SFC 逐字节 MATCH**。
4. 回滚：同一流程写 `flash_backup_20261030.sfc`（Y1）或 `sbit_cmd18_plain.sbit`（2.99 MHz）。

---

## 7. 复现命令

```bash
# 应用
cd YeshenGui && GUI_VARIANT=mainline bash scripts/build_board_app.sh      # -> board/variants/mainline/yshell
bash y1/tools/build_y1cam.sh --install                                   # 重编 y1cam 并落 overlay

# 镜像 / 卡（WSL）
REBUILD_PKGS= bash scripts/build_images.sh                               # 只重打 rootfs（内核不变）
python3 -u sim/reglogs/mk_card_ctp.py && python3 -u sim/reglogs/mk_score_card.py
powershell -File sim/reglogs/run_write_sd_elevated.ps1 -Img sw\images\sd_score_ctp.img

# RTL（PDS）
YESHENMINI_DEVMAP_TAG=ctp2 pds_shell.exe -file pds/run_devmap_yeshen.tcl
YESHENMINI_PNR_TAG=ctp2 YESHENMINI_STRATEGY=1 pds_shell.exe -file pds/run_pnr_yeshen.tcl

# 固化（见 §6 的 tcl 序列）
```

---

## 8. 已知遗留

1. **单缓冲撕裂**：GUI 只有一个帧存（`0x92000000`）；异步 flush 已把“逐条带长出来”压到最短，
   但 LCD 边扫边被写仍可能出现一条随帧移动的撕裂边。彻底消除需 RTL 第二个 GUI bank
   （`GUI_CTRL[1]` 选 bank、帧首翻转）——一次性 PnR 成本。
2. **触摸手感**：按下-保持 1–2 s 后的停顿、快速滑动仍偏难（见 `docs/reports/ctp-touch.md`），
   与 100 MHz 单核 + GT911 采样率相关；服务线程已把 UI 侧的阻塞去掉。
3. **配置钟**：11.76 MHz 是 Y1 已验证点；再往上（15.38/22.22 MHz）需重新验冷启动可靠性。
4. 其他会话的 WIP（`scripts/eth_memread.py`、`grab_cam.py`、`cam_*`/`fb*` 等）未纳入本次提交。
