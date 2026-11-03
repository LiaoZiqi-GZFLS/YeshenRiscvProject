# 附属工程

三块与主 SoC 配套的工作线源码。为控制仓库体积与评审噪音，只保留源码/构建输入，去掉了各工程自己的 `build/`、`sim/`、`images/`、`out/` 与生成物（最终交付以主工程和 `deliver/` 为准）。

## YeshenGui —— LVGL 9.2 桌面

- 位置：`aux-projects/YeshenGui/`
- 内容：`ui/`（桌面、窗口管理、文件、设置、终端、游戏）、`platform/`（板端 framebuffer/touch/GPU 抽象）、`host/`（SDL 模拟器入口）、`board/`（板端 rootfs overlay 与卡构建脚本）、`scripts/`、`tests/`、`tools/`、`docs/`。
- `third_party/lvgl/` 仅保留 `src/` 与构建所需头文件（`.git`、`demos/`、`tests/`、`docs/`、`examples/`、`env_support/` 未收录）；版本记录在 `third_party/lvgl.commit`。
- 与主工程关系：板端 GUI 应用，独立构建；主工程的 `sw/buildroot-external/.../root/gui/yshell` 是当时卡内实际使用的二进制。

## YeshenGuiKernel —— 触屏/内核工作线

- 位置：`aux-projects/YeshenGuiKernel/`
- 内容：`config/`（内核配置片段）、`drivers/`（GT911/触屏驱动源）、`dts/`、`build_touch_kernel.sh`、`inspect.sh`。
- 与主工程关系：触屏 bring-up 的内核侧工作线；主工程最终使用的补丁在 `sw/buildroot-external/patches/linux/custom/`。

## YeshenGuiTouch —— 触屏独立 RTL 工程

- 位置：`aux-projects/YeshenGuiTouch/`
- 内容：`board/`（板级顶层/摄像头/CDC）、`rtl/`（核网表与胶合网表）、`gen/src/`（Chisel 胶合源码）、`gen/rtl/`（生成的 `YeshenSocGlue.v`）、`constraints/`、`pds/`、`third_party/`。
- 与主工程关系：触屏 bring-up 的独立 SoC 工程（含 CTP 推挽 SCL 等改动）；最终 RTL 已并入主工程 `board/` / `rtl/`。未收录其 `sim/`、`gen/YeshenSocGlue.jar`、`out/`。

## 未收录

- `YeshenGuiRtl`、`YeshenGuiRtl2`：两份 700 MB 级的主工程 RTL 独立副本，内容与主工程重复。
- `YeshenGui/images/`、`YeshenGui/build/`：GUI 的构建产物与历史卡镜像（非 130zbb 交付件）。
- 253 MB 的 LLM 大卡（`sd_y1_618_zbb_wchar_llm.img` 等）：超过 GitHub 单文件 100 MB 限制。
