# third_party 版本钉死表

> `third_party/` 整体不入库（`.gitignore` 只放行本文件）。此处记录**确切的 commit SHA**，
> 供复现与自证。复现命令见每条下方。

## VexiiRiscv（核）

- 远端：`https://github.com/SpinalHDL/VexiiRiscv.git`
- 分支：`dev`
- commit：**`ecfd4930bb079af4dea0dba49417f0ad2822dfe8`**（2026-10-06，"Merge pull request #190 from inochisa/feat/param/desc"）

克隆（需要代理；直连 GitHub 会 connection reset）：

```bash
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
git clone --recursive https://github.com/SpinalHDL/VexiiRiscv.git third_party/VexiiRiscv
```

### 其子模块（由上面的 `--recursive` 一并拉取）

| 路径 | commit | 备注 |
|---|---|---|
| `ext/SpinalHDL` | `90b7d8eeed46e20e102df498516ebe845c9e4a6e` | `v1.7.0-3750-g90b7d8eee`；`build.sbt` 默认 **从源码编**（`SPINALHDL_FROM_SOURCE=1`） |
| `ext/NaxSoftware` | `0db55313d79395a90220fb8b635f5918db94749d` | `v0.1.0-67-g0db5531`；**RV32 buildroot recipe 出处**（`buildroot/configs/rv32ima.sh`） |
| `ext/riscv-isa-sim` | `6bd1623d89e1859e32b6547cca4d94045e3a64bc` | spike；仅 ISA 回归用 |
| `ext/rvls` | `847ce99fd2b28a5c0ccb1ec2683311cf97a9fefc` | `origin/pmp`；`build.sbt` 引用其 `bindings/{jni,spinal}` |
| `ext/SpinalHDL/tester/src/test/python/cocotblib` | `a98830423924fc89bfebae84cb802fc90d352602` | 上游测试用 |

自证：`cd third_party/VexiiRiscv && git rev-parse HEAD && git submodule status --recursive`

## SpiralHDL CNN 加速器（M0 用，只读）

- 远端：`https://github.com/19801201/SpinalHDL_CNN_Accelerator.git`
- commit：**`e9597a9ff3857f8cbd79d77e06c7eb60ec3514bf`**（2026-09-29，"update spinal version to 1.15.0"）
- 用途：AI 加速模块可行性探针（M0）的被集成对象；设计取向 = YOLOv5 族 640×640 INT8 检测器（见 `docs/superpowers/specs/2026-10-08-ai-accelerator-m0-design.md` §3.1）
- 克隆（需要代理）：
  ```bash
  export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
  git clone https://github.com/19801201/SpinalHDL_CNN_Accelerator.git third_party/SpinalHDL_CNN_Accelerator
  ```
- 自证：`cd third_party/SpinalHDL_CNN_Accelerator && git rev-parse HEAD`
- **本地改动：无**（`git status --porcelain` 为空）。M0 的一切改动落在 `ai_npu_exp/port/override/`，用"整文件覆盖"机制施加。

## 模型资产（不入库）

| 路径 | 来源 | 指纹 |
|---|---|---|
| `third_party/yunet/yunet.onnx` | OpenCV Zoo（LFS 需走 `media.githubusercontent.com`） | 232,589 B / sha256 `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| `ai_npu_exp/models/yolov5s.pt` | ultralytics/yolov5 **v3.0** release 资产 | 15,184,597 B / sha256 `b15456e31d4491cc4ff57b07ed0f45e3dbaa043592099abbe24cebe4d2b2a678` |

来源、可获取性与为何选 v3.0：详见 `ai_npu_exp/reports/model_provenance.md`。

## 工具链（实测）

| 项 | 值 |
|---|---|
| JDK | **Temurin 17.0.20**（`JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-17.0.20.8-hotspot`） |
| sbt | runner **2.0.6**，路径 `C:\Users\Ziqi\AppData\Local\Coursier\data\bin\sbt.bat` |
| scala-cli | 同目录 `scala-cli.bat`（胶合块构建用） |
| 代理 | `http_proxy=http://127.0.0.1:7897`（Clash 类；先 `netstat` 确认端口在听） |

## 纪律：本克隆只读

`ext/SpinalHDL`、`ext/NaxSoftware`、`VexiiRiscv` 一律**不修改** —— 一切配置走 `Generate` 的命令行旗标。

**若将来必须改 VexiiRiscv 源码**：不要就地改，改为整体复制成 `third_party/vexiiriscv-fork/`，
让构建指向副本，并用逐 hunk diff 自证原件未动（与 `NaxYeshenLinux` 的 `nax-fork` 同法）。

## 非核第三方资产（同样不入库，从模板复制）

| 路径 | 来源 | 说明 |
|---|---|---|
| `third_party/ddr3_ip_200h/` | `NaxYeshenLinux/third_party/ddr3_ip_200h/` | 紫光 DDR3 IP **200H 版**（装 100H 版会 `ddr_init_done`=0） |
| `third_party/liteeth_mac/` | `NaxYeshenLinux/third_party/liteeth_mac/` | LiteEth MAC 黑盒（由 `sim/liteeth_gen/gen_liteeth.py` 生成） |
| `third_party/eth_stack_2_11/` | `NaxYeshenLinux/third_party/eth_stack_2_11/` | 厂家以太网栈；**只取 `rgmii_interface.v`** 作为 RGMII PHY |

## ⚠️ 本工程对第三方资产的**本地改动**（必须逐条留档，因为 `third_party/` 不入库）

### 1) `third_party/eth_stack_2_11/source/rgmii_interface.v` —— 加了两个端口（2026-10-07）

- **改了什么**：新增输入 `dly_txclk[7:0]` / `dly_rx[7:0]`；把 `assign delay_step_c = 8'd100;`
  改成 `= dly_txclk;`、`assign delay_step_b = 8'd247;` 改成 `= dly_rx;`。
- **为什么**：这两处是 `GTP_IODELAY_E2` + `DELAY_STEP_SEL("PORT")`，**本来就是运行期可编程**；
  提成端口后，RGMII 延迟扫描从"每档重出一遍带（~12 分钟）"变成"一次烧写 + `devmem` 扫"。
- **默认行为不变**：`board/liteeth_wrap.v` 里两个寄存器的**复位值就是厂家原值（100 / 247）**
  ⇒ 上电行为与厂家/eth211 逐字一致；旋钮挂在 `0xF000B01C`（写 `{dly_txclk[15:8], dly_rx[7:0]}`）。
- **自证**：与 **`eth_demo_exp/eth211_exp/source/rgmii_interface.v`（上板跑通过的副本）**
  `diff` 只应出现上述端口/两条 assign（可用 `diff -u` 复核；其余逐字节相同）。

### 2) `third_party/liteeth_mac/liteeth_mac_top.v` —— **重新生成**（2026-10-07）

- **怎么来的**：由 `sim/liteeth_gen/gen_liteeth.py` 生成（**不是**从模板复制的那份）。
- **生成环境（硬约束）**：必须用 **Python 3.9**：
  `D:\code\PDS\NaxYeshenLinux\sim\reglogs\lxvenv\Scripts\python.exe`（Miniconda 3.9.1）。
  用 3.14 的 venv 会报 `Cannot extract clock domain name from code` /
  `Cannot extract CSR name from code`（migen/LiteX 的 tracer 在新 Python 上失效）。
- **与模板那份的关键差异 = 真根因的修复**：`ResetSync` 的同步链改成 `reset_less=True`
  ⇒ 产物里不再有 `if (eth_rx_rst) resetsync0_sr <= 2'd0;`
  （否则"复位把自己清零 ⇒ 链永远填不满 ⇒ PHY 两域永久复位"，症状见 `docs/交付-2026-10-07.md` §15）。
- **数据宽度/字节序（2026-10-07 深夜，第二个真根因）**：生成参数从
  `dw=8, endianness="big"` 改成 **`dw=32, endianness="little"`**。理由（详见 §17）：
  - `with_sys_datapath=True` 时 sys 域数据通路是 **1 字节/拍**；sys=100MHz ⇒ 生产 100 MB/s
    追不上 GMII 的 125 MB/s ⇒ **TX 的 CDC 中途饿空**、`pads_tx_en` 碎成 ≤5 拍。
    LiteEth 自己的生成器只在 **16/32 位**下开 sys_datapath（`liteeth/gen.py`：
    `with_sys_datapath = data_width in [16,32]`）⇒ `dw=8` 那个组合是库不会产出的。
  - `dw=8` 时 `endianness` 是 no-op；`dw=32` 取 `"big"` 会让**每组 4 字节组内反序**
    （读槽器 `reverse_bytes`），而驱动按**字节偏移** `memcpy_fromio/toio`
    ⇒ **必须 little** 才能保持字节自然的槽布局。
  - **连带契约变化**：`bus_rx`/`bus_tx` 从 **8bit 字节寻址**变成 **32bit 字寻址 + 4bit sel**
    ⇒ `board/liteeth_wrap.v` 的槽闸门同步改写（反而更简单）。**DTS/driver 契约不变**
    （槽跨距仍 0x800 字节、rx 前 tx 后）。
  - 复现命令：`<venv>/Scripts/python.exe sim/liteeth_gen/gen_liteeth.py`
    → `third_party/liteeth_mac/liteeth_mac_top.v`（另出 `.json` 记参数与 CSR 顺序）。
