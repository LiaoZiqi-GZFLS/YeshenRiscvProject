# TF 卡镜像台账（哪张卡装什么、怎么选、怎么跑分）

> 起因：2026-10-30 把 GUI/触摸镜像写卡后要跑 CoreMark，才发现**“双计划”不等于
> “计划 1 就是 CoreMark”**——取决于打的是哪种卡。这里把台账钉死，免得再混。

## 1. 计划机制（RTL 行为，不是镜像约定）

- SdLoader 读一张 **YSLD 表**：`magic(4) + 条目数(4)` + 每条 `(DDR 地址, 起始块, 块数)`，
  表头有 CRC32（偏移 160），**每段还有独立 CRC32**（偏移 128 起，4 B/条），装载时当场校验。
- 表的位置二选一（[SdLoader.scala:410](file:///D:/code/PDS/VexiiYeshenLinux/src/peripheral/SdLoader.scala#L410)）：
  `hdrSel = 0 → LBA 0`（Linux 计划）；`hdrSel = 1 → LBA 32768 = 16 MiB`（另一份计划）。
- `hdrSel` 由 `BootSel` 在上电 window 里决定（板级 1.0 s）：串口 115200 打
  `[Y1] L=Linux C=CoreMark >`，敲 **`C` → 计划 1**，敲 `L` 或超时 → 计划 0。
- ⚠️ 极性反直觉：**KEY1 未按（高）= 装载模式 ⇒ 默认就进这个窗口；按住 KEY1 反而跳过**。

## 2. 卡台账（`sw/images/`）

| 镜像 | 大小 | md5 | 计划 0 | 计划 1 @LBA32768 |
|---|---|---|---|---|
| `sd_ab_k2_ctp.img` | 33,554,432 | `110f0049…` | 新内核 Linux（5 段：fw_jump/Image/dtb/rootfs/y1_payload） | **同一份 Linux**（敲 C 也只是再装一次 Linux） |
| `sd_score_ctp.img` | 16,838,144 | `29151c25…` | 与上一行**逐字节相同**（前 16 MiB 原样搬运） | **CoreMark ITERS=5500** @`0x80000000`（60,000 B，md5 `fd1dd52d…`） |
| `sd_boot.img`（旧，10-18） | 16,838,144 | `60a3914e…` | 旧内核 Linux | CoreMark **ITERS=10**（只作 CRC，**不是合法分数**） |
| `sd_y1.img`（单计划基底） | 10,620,928 | — | Linux 5 段 | （无） |

**当前插在板上的卡 = `sd_score_ctp.img`**（2026-10-30 写，`CARD VERIFY PASS`，sha256 `CD323724…`）。
它就是**“GUI/触摸 + 跑分 两用卡”**：计划 0 与 GUI 卡的计划 0 **逐段逐字节相同**
（已比对 5 段：fw_jump/Image/dtb/rootfs/payload + 前 16 MiB 全同），计划 1 才是 CoreMark。
⇒ **推荐只用这一张**；`sd_ab_k2_ctp.img`（纯 GUI 卡）只在“不想多那 1 s 选择窗口”时才有意义，
且两者不可与比特流混搭对（比特流只有一颗 `ctp1`，两卡通用）。

两用卡上操作为二选一（物理互斥，不能同时）：
- 不敲 / 敲 `L` → Linux（串口登录，手动起 GUI：`setsid /root/gui/yshell --demo </dev/null >/tmp/gui.log 2>&1 &`）；
- 敲 `C` → CoreMark 裸机跑分（此时无 Linux/GUI）；跑完想回 Linux 要断电/复位。

## 3. CoreMark 口径

- **ITERS=10 只用来对 CRC**；要出**合法分数**必须让运行 ≥10 s ⇒ 约 4.6 CM/MHz ⇒ **ITERS ≥ 5500**。
- `crcfinal` 随 ITERS 变，**不能跨档位比**。
- 分数只能与**同 CPU 配置**比（当前比特流是 Cache32 档：I$ 32K / D$ 16K）。

## 4. 怎么生成 / 怎么写卡

```bash
# A. GUI/触摸卡（计划 0/1 都是 Linux）
python -u sim/reglogs/mk_card_ctp.py            # → sw/images/sd_ab_k2_ctp.img

# B. 跑分卡：直接复用 A 的计划 0，只换计划 1
python -u sim/reglogs/mk_score_card.py          # → sw/images/sd_score_ctp.img（默认 ITERS=5500）

# C. 另一条路（会重建 y1_payload，需要 onnx venv）
bash scripts/build_y1_card.sh
CORE_BIN=sw/images/coremark_rv32_i5500.bin OUT=sw/images/sd_boot_x.img bash scripts/build_boot_card.sh

# 写卡（必须提权；-Img 指定镜像）
powershell -NoProfile -ExecutionPolicy Bypass -File sim/reglogs/run_write_sd_elevated.ps1 `
    -Img "D:\code\PDS\VexiiYeshenLinux\sw\images\sd_score_ctp.img"
```

写卡脚本的判据是 `CARD VERIFY PASS`（整盘回读 SHA256 与文件一致）；
`Start-Process -Verb RunAs` 不能与 `-RedirectStandardOutput` 同用（ShellExecute 参数集互斥），
所以包装脚本用提权 `cmd /c powershell … > log`。
