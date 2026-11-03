# 3D 演示做成 yshell 桌面应用：实现与踩坑全记录（2026-11-01）

> 范围：`YeshenGui`（板端 yshell 应用 + GPU 绘制单元）与 `VexiiYeshenLinux`（板级
> GUI 帧存/bank 口径、验证探针）。**RTL 零改动**。
> 前置：`docs/reports/gpu-p2a-3d.md`（3D 引擎）、`docs/reports/gpu-clock-domain.md` §8（时钟域与上板）。

## 1. 交付形态

| 项 | 内容 |
|---|---|
| 应用 | `YeshenGui/ui/apps/cube3d.c`（桌面图标 **3D**，`app_cube3d_open()`） |
| 入口 | 桌面点图标；或 `yshell --no-uart --cube3d`（开发钩子） |
| 画面 | 窗口 664×500，内含 640×448 的实时 3D 视口（立方体自转 + 触摸拖拽改视角） |
| 数据通路 | GPU 3D 引擎画进 `GPU_COLOR3D`(0x9300_0000) → `gpu_draw_unit_bind_image()` 把它按**物理地址**绑成 LVGL 图像源（零拷贝 BLIT） |
| 帧调度 | 150 ms 定时器：CPU 算 12 个三角形（背面剔除 + 逐面 N·L 光照 + 每面常数深度）→ `CLEAR3D/DRAW_TRIS/FENCE` → 图像失效 |
| 构建 | `cd YeshenGui && GUI_VARIANT=mainline_gpu bash scripts/build_board_app.sh` → `board/variants/mainline_gpu/yshell` |
| 部署 | 推到 `/root/gui/yshell.new` → `mv` 覆盖 `/root/gui/yshell`（旧版备份 `/root/gui/yshell.bak`）→ `setsid /root/gui/yshell --no-uart </dev/null >/tmp/gui.log 2>&1 &` |

提交：`YeshenGui` `45c77f2`（应用）、`ea4a504`/`c193045`（bank）、`93039d6`/`c57ccfa`（重绘）、
`036e35a`（BLIT 夹紧）、`84d8e1d`（GPU/软件同序）。

## 2. 显示链路的最终口径（含两处**历史文档写错**的地方）

```
                 ┌──────────── LVGL(DIRECT) 只画这块
                 ▼
  bank0 = 0x9200_0000 + 60 行偏移   ── 每帧一次硬件 BLIT 整帧镜像 ──►  bank1 = 0x9280_0000 + 60 行偏移
     (1024×720 画布，可见 60..659)                                     （LCD 固定读这块）
```

- **GUI bank1 = 0x9280_0000，不是 0x9220_0000**：RTL 里 GUI 的 bank 偏移是
  `ar_gui = GUI_BASE_WORD + {gui_bank, 21'd0}` —— 32-bit **字地址**的 bit21 ⇒ 2²¹ 字 = **8 MiB**。
  （`docs/reports/gui-framebuffer.md` 与本仓若干注释里"2 MiB"的说法是错的，以本条为准。）
- `gui_bank = GUI_CTRL[1]（0x09C bit1）^ GPU.flip_toggle`。
- 本应用**不翻页**：启动写 `GUI_CTRL = 0x3`（bit0=GUI 源、bit1=1）把 LCD 钉在 bank1；
  LVGL 永远只画 bank0（不被扫描 ⇒ 绘制过程不可见），每帧 flush 末尾一次硬件 BLIT
  把可见区 1024×600 镜像到 bank1（约 1–2 ms）。

## 3. 踩坑清单（症状 → 根因 → 修法 → 判定证据）

### 3.1 "左上角黑屏"：Z 值饱和，被 LESS 全部拒掉

- 症状：3D 窗口里只有底色；实测 3D 颜色缓冲中心 `0x1082`（底色）、Z 缓冲**整片 `0xFFFF`**。
- 根因：演示的深度映射写成 `(z+1)*0.5*65535`，而 `z` 是**视空间深度**（3~5）而不是
  [-1,1] 归一值 ⇒ 全部 clamp 到 65535；Z 缓冲清成 `0xFFFF` 且 `zmode=LESS` ⇒ `65535 < 65535`
  恒假 ⇒ 一个像素都不写。
- 修法：`zc ∈ [0.2, 8] → 0..60000` 线性铺开。
- 证据：修前中心 `0x1082`/Z `0xFFFF`；修后中心出现面色、Z 有值。

### 3.2 "面错位"（连续 5 个几何 bug，与 GPU 无关）

| # | bug | 症状/判定 |
|---|---|---|
| 1 | `sin/cos` 用**泰勒近似**（`sy=a-a³/6+a⁵/120`） | 只在 \|a\|≲1 rad 成立；yaw=π 时 cos 算成 **0.13**（真值 −1）⇒ 旋转矩阵非正交、立方体被剪切。改 libm（构建加 `-lm`） |
| 2 | 投影深度符号反了：`zc = z + 4`（应 `4 − z`） | 一半立方体落到相机背后，除以负深度 ⇒ 几何镜像 |
| 3 | ±X 面三角形索引把 `x=−1` 与 `x=+1` 的顶点混在一个三角形里 | 斜穿立方体的怪三角形；左右向露出杂色 |
| 4 | ±Z 面三角化沿**两条不同对角线**切 | 右半 25% 楔形缺口（`n=110,784 = 147,456×0.751`） |
| 5 | 没有背面剔除 | 侧对相机的面在透视下仍投出 **77 px 宽梯形**（不是零面积），切进正面方块 |

- 判定证据：`gpu3ddemo --selftest` 六向（前/后/左/右/上/下）逐像素闸门 —— 每个方向都要求
  **bbox 精确 384×384、147,456/147,456 像素、整块同色（且是该朝向那面的颜色）、单一深度**。
  全绿即 `六向自检 PASS（bad=0/6）`。修完 5 个 bug 后该闸门一次通过。

### 3.3 2D 引擎的 **scissor 是持久状态**

- 症状：桌面渐变壁纸在 y≈256 处突然断掉，后半段不画。
- 根因：yshell 被中止时留下一个小的裁剪窗；演示从不设 scissor ⇒ 超过窗的部分被裁掉。
- 修法：演示启动先 `SET_SCISSOR(0,0,1024,600)`。

### 3.4 视口背景用 3D 三角形画 = tile 大户

- 症状：加"3 条背景色带"后帧率 4.6 → **1.6 fps**。
- 根因：3D 引擎按 32×32 tile 读写，3 条大色带 ≈ **600 个 tile/帧**，每个 tile 约 0.7 ms
  （DDR 延迟主导，64 笔 burst/tile）。
- 修法：视口底改 `CLEAR3D` 纯色（0 tile）。

### 3.5 ★ 整屏闪烁 + 图标消失：**bank1 地址账算错**

- 症状：yshell 每帧在 flip 与"新/旧画面"之间交替，左上角图标周期性消失。
- 根因：yshell 每帧 `gpu_flip_async()` 翻 bank，而 LVGL 只画 bank0；我按文档把"第二个 GUI bank"
  写成 `0x9220_0000`（2 MiB），**RTL 实际是 `0x9280_0000`（字址 bit21 = 8 MiB）** ⇒ 镜像写进了
  没人读的地址，LCD 翻到 bank1 时读到的是旧内容。
- 判定方法（可复用）：`y1/tools/fbprobe.c` —— 把 `0x9200_0000` 涂红、`0x9220_0000` 涂绿、
  `0x9280_0000` 涂蓝，再用 GPU `R_FLIP(0x028)` 翻 bank；屏幕表现"红↔蓝交替"直接证明
  **bank1 = 0x9280_0000**。
- 修法：镜像目标改 `+0x800000`。

### 3.6 单缓冲：DIRECT 模式画的就是被扫描的那块

- 症状：即使 bank 地址改对，刷新时仍能看到"画的过程"（撕裂/闪）。
- 根因：LVGL 在 DIRECT 模式下只有一个固定缓冲（bank0），若它正被扫描，绘制过程全程可见。
- 修法：**LCD 钉 bank1、LVGL 只画 bank0、每帧整帧硬件镜像**（见 §2）。撕裂只剩镜像那 1–2 ms 一条细线。

### 3.7 "结构性重绘"整屏失效会把一帧放大 32 倍

- 症状：开/关窗口时卡顿、局部黑块。
- 实测（`GPU-UNIT stat`）：整屏失效时一帧被抽成 **80 个任务 / 1,960 万像素**（≈32 个整屏的过量绘制）。
- 修法：只失效**受影响矩形** —— `wm_open` 失效新窗口 root + 任务栏；`wm_close` 删窗前记坐标、
  删完失效那块 + 任务栏；`wm_focus` 只失效该窗口 root。**不要整屏失效**。

### 3.8 白屏：图像 BLIT 越界时"整块跳过"

- 症状：桌面/窗口出现白块（DDR 初值 0xFFFF）。
- 根因：`gpu_dispatch` 的图像分支在 `sx+w > 图宽` 等条件下**整块跳过**却把任务标成完成
  ⇒ 那块留成 LVGL 底色。而桌面在 DIRECT 模式下派下来的任务区域**可能大于图像本身**
  （实测：640×448 的 3D 图被按整屏 1024×600 派下来）。
- 修法：把源起点与宽高一起**夹紧**到图像范围（`sx<0/sy<0` 时同步挪目标原点），画能画的部分；
  3D 图像另加显式 `lv_obj_set_size(640,448)`。

### 3.9 ★ 图标被盖掉：**GPU 异步队列与软件绘制不同序**

- 症状：桌面图标列整片消失/剩壁纸色（用户视角是"白块/图标没了"）。
- 根因：GPU 命令是**异步排队**的，而 LVGL 的软件绘制（图标圆角、符号字形、文字）是 CPU
  **即时**写的。GPU arena 从 1 MiB 扩到 4 MiB 后，壁纸（1024×600 = 1.17 MiB）开始走 GPU BLIT
  —— 排在队首的大 BLIT 可能在图标已画完之后才执行，把图标整列刷成壁纸色。
- 修法：`gpu_dispatch` 末尾对每个任务 `finish_frame()`（等它落地）⇒ GPU 与软件绘制严格同序，
  代价 0.2–2 ms/任务。
- 证据：修前图标区只剩 `0xE77E/0xE75E`（壁纸）；修后 Files `0x2B7A`、Games `0xA806`、
  面板 `0xEF7E`、壁纸 `0xD6DC` 全部在位，开 3D 窗口后图标仍在，`YGUI-FPS 36`。

### 3.10 其它

- **窗口超出桌面可用区**：桌面可用区 = **1024×524**（顶面板 40 + 任务栏 36），窗口必须 ≤524 高
  ⇒ 视口改 640×448、窗口 664×500。
- **GPU arena 太小**：1 MiB 装不下 1.17 MiB 的壁纸 ⇒ 壁纸每帧退回软件绘制（整屏刷新只剩 1.5 fps）
  ⇒ arena 扩到 **4 MiB**（物理区 0x9320_0000..0x935F_FFFF，与 NPU arena/相机/GUI bank 不重叠）。

## 4. 板测证据汇总（2026-11-01，gpuclk7 比特流）

| 项 | 值 |
|---|---|
| 六向自检 | `gpu3ddemo --selftest` → PASS（bad=0/6），每向 147,456/147,456 像素 |
| 桌面元素 | 图标 `0x2B7A`/`0xA806`、顶面板 `0xEF7E`、壁纸 `0xD6DC`、任务栏 `0xEF7E` |
| 3D 窗口 | 图区 `0xE77E`（背景）+ `0x6004`（立方体面）；窗外壁纸 `0xDF3D`；窗口 body `0xF7DF` |
| bank 一致性 | 五个采样点 bank0 与 0x9280_0000 完全一致 |
| 帧率 | 3D 窗口打开时 `YGUI-FPS 36`；3D 渲染本身约 3.8 fps（每帧约 110 个 32×32 tile） |

## 5. 复现/诊断工具（都在板上 `/tmp`，源码在 `y1/tools/`）

| 工具 | 用途 |
|---|---|
| `fbprobe 0|1` | bank 判定：bank0 涂红、0x9220_0000 涂绿、0x9280_0000 涂蓝，并按参数设 `GUI_CTRL[1]` |
| `fbscan` | 扫描两个 bank 的可见区，报 0xFFFF（白）像素数量/bbox/16×12 分布 |
| `gpu3ddemo --selftest` | 六向逐像素闸门（3D 几何/深度/剔除的回归判据） |

## 6. 已知限制与下一步

- 3D 渲染 ~3.8 fps：受 3D 引擎的 32×32 tile 读写限制（每帧约 110 tile × 0.7 ms）。
  可选杠杆：相机再拉远（更小立方体）、降低刷新率、或后续在 RTL 侧做 tile 复用。
- 当前是"离屏绘制 + 整帧镜像"，镜像那 1–2 ms 仍有极小概率被扫描到。**真正的乒乓双缓冲**
  需要给 GPU CSR 加一个 `flip_toggle` 回读位（1 行 RTL + 重出比特流），届时 yshell 可以
  直接画背面再在 vsync 翻转，不需要镜像。
- **卡镜像已改为 buildroot 全量重建**（§7）：`sd_gui3d_buildroot.img` 内 yshell 就是当前二进制；
  仍待写卡上电验收（板上此前是手工替换的 `/root/gui/yshell`，备份 `yshell.bak`）。

## 7. 烘焙进卡镜像

### 7.1 最终口径：buildroot 全量重建（2026-11-02，用户裁决）

不走"就地改 cpio"的捷径，交付镜像的 rootfs 必须由 buildroot 自己产出：

1. 把要交付的二进制放进 overlay（`BR2_ROOTFS_OVERLAY` 指到它，见生成的
   `configs/naxmini_defconfig:107`）：
   `sw/buildroot-external/boards/naxmini/linux/rootfs_overlay/root/gui/yshell`（0755）。
2. WSL 里跑完整构建（脚本默认 `REBUILD_PKGS="opensbi linux"`：先 `-dirclean` 再重编，
   然后全量 `make` 重打 rootfs）：
   ```bash
   MSYS_NO_PATHCONV=1 wsl -e bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && JOBS=8 \
     bash scripts/build_images.sh > sim/reglogs/rv32_buildroot_gui3d.log 2>&1'
   ```
   本轮 02:16 起、02:18:36 打出 `DONE`（其余包命中缓存，只重编 opensbi/内核 + 重打 rootfs）。
3. 用新的四件套 + 未变的 `y1_payload.bin` 走 `sim/mk_sd_image.build_plan` 重拼 YSLD 卡镜像
   （地址与顺序不变：fw → Image → dtb → rootfs → payload）。

本轮产物（2026-11-02）：

| 项 | 值 |
|---|---|
| 卡镜像 | `sw/images/sd_gui3d_buildroot.img`，14,729,728 B，md5 `1e4470607041516202f164544362974a` |
| `fw_jump.bin` | 133,872 B，md5 `1e809d4355ef4d69c21ea06b18cd57aa`（与旧卡逐字节相同） |
| `Image` | 6,205,492 B，md5 `5e9485d8e9e9fdd43080d2b50b1a10d2`（尺寸不变；重编后 UTS 时间戳变，故 md5 变） |
| `linux.dtb` | 3,183 B，md5 `e09b154d9e07985ece9e7f2c946b13be`（与旧卡逐字节相同） |
| `rootfs.cpio` | 6,452,224 → 6,555,648 B，md5 `b05ef554992b3f9947ce95604c1f4aac` |
| 卡内 yshell | 1,423,288 B、mode `0100755`、md5 `3d9ee7b58ac6975ab4514964989f5d06`（== 板上正在跑的二进制） |
| 卡内 wallpaper | `wallpaper_ink.bin` `051fec5a…` / `wallpaper_paper.bin` `191c9b5e…`（未变） |
| 校验 | 计划头 CRC + 5 段 CRC + 每段内容逐字节 + **从卡镜像里 rootfs 抽出的 yshell md5** 全过 |
| 地址 | fw 0x8000_0000 / Image 0x8200_0000 / dtb 0x82F8_0000 / rootfs 0x8300_0000 / payload 0x81E_00000 |

`Image` 尺寸不变但 md5 变是正常的：内核 UTS 版本串里带构建时间，重编必换；功能面无差别
（同一份 config、同一套 4 个补丁，其中 0004 = P0 Zicbom）。

**A/B 对账**（buildroot 产物 vs §7.2 就地补丁产物，逐条目比 `(mode,size,md5)`）：
401 项对 401 项，无新增/缺失，**唯一差异是 `etc/shadow`**（buildroot 每次构建随机 salt，
195 B、mode 0600）——其余包括 `root/gui/yshell`、wallpaper、全部库和 init 脚本逐字节相同。
即两条路径产出的 rootfs 语义等价，buildroot 这条只是多了可复现的构建来源。

### 7.2 历史工具（保留，不再是交付路径）

`scripts/bake_yshell_into_card.py`：就地改卡镜像里 `rootfs.cpio`（newc）的
`root/gui/yshell`，再重拼 YSLD 计划（commit `75d9d58` 的 `sd_gui3d.img`，
md5 `a4cf71141cec0bc7a35770df86845b7c`）。适合快速迭代看效果，**不作为交付镜像来源**。

```bash
python scripts/bake_yshell_into_card.py --base sw/images/sd_gpu0.img \
  --yshell ../YeshenGui/board/variants/mainline_gpu/yshell --out sw/images/sd_gui3d.img
```

⚠️ 两个 newc 细节（踩过）：名字的 NUL 填充对齐的是**绝对偏移**（`110 + namesize` 补齐到 4），
不是名字长度本身；文件数据才按长度补齐到 4。

⚠️ 未做：**写卡 + 上电验收**（物理动作，等板窗口）。写卡命令与既有流程一致
（`sim/reglogs/write_sd_*.log` 的那套 raw 写卡脚本），写完请按 `docs/board_bringup.md` 核
8/8 marker + ping/ssh，并确认 `md5sum /root/gui/yshell` = `3d9ee7b5…`。
