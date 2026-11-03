# 版本与指纹说明（130zbb 交付）

本文件记录本仓库冻结件的来源、指纹和已知口径差异，供复核与后续维护使用。

## 1. 源码快照

| 项 | 值 |
|---|---|
| 来源仓库 | `VexiiYeshenLinux`（本地工作区 `D:\code\PDS\VexiiYeshenLinux`） |
| 快照提交 | `2b48ca9fec3487b5eb88cd0dc8dccb7d89675fbc`（2026-11-02 17:44:24 +0800） |
| 提交标题 | `core/freq: Zbb+Zbs 核 + CPU 130.645MHz 过约束定档 + GPU 101.25MHz（tri_raster 两拍流水）` |
| 导出方式 | `git archive 2b48ca9`（工作树全部纳入版本控制的文件） |

快照之外补入的构建输入：

| 文件 | 来源/说明 |
|---|---|
| `y1/gen/NpuTop.v` | 生成网表，2026-10-29 05:40（130zbb PnR 实际使用版本） |
| `y1/gen/DmaEngine.v` | 生成网表，与 `DmaEngine_28b_v1.v` 同 md5；端口 `axi_aw_payload_addr[29:0]`（30 位） |
| `y1/gen/NpuAxiLiteCdc.v` / `NpuMemCdc.v` / `NpuIrqCdc.v` / `NpuResetSync.v` | 生成网表，2026-10-21 |
| `third_party/ddr3_ip_200h` | PDS DDR3 IP（原厂，含 `.idf` / `.v` / `.vp`） |
| `third_party/liteeth_mac` / `third_party/eth_stack_2_11` | LiteEth MAC 黑盒与 RGMII 接口 |

## 2. 130zbb 比特流

| 项 | 值 |
|---|---|
| 文件 | `deliver/bitstream/pds_cpu130_20261102.sbit`（9,188,552 B） |
| md5 | `89f4e1f09ae1c2337605e7ef9e967164` |
| PnR tag | `cpu130`，`cpu_clk` 7.000 ns 过约束，strategy 1，单种子 |
| 交付频点 | 130.645 MHz（PLL RATIO0=7.75 / DUTY0=7；7.6543 ns） |
| 时序判据 | `Some Constraints Violated`，仅 `cpu_clk` 一项（−0.413 ns @ 7.000 ns）；按 7.6543 ns 计 +0.241 ns；其余域全正（报告：soc +0.464 / npu +0.493 / gpu +0.401 / core +0.460） |
| 资源 | LUT 98,529.5（62%）/ FF 129,618 / DRM 316 / APM 293 |

## 3. 核网表指纹差异（重要）

报告和提交信息记录的核网表 md5 为 **`9b738e97e5e3d5f6d5f0e6c4a2e32ded`**，但提交 `2b48ca9` 中 `rtl/vexiiriscv/VexiiRiscv.v` 的 blob md5 为 **`16c650557e237466d9d7372a89a21fd1`**（两者均为 34,626 行）。

- 本仓库随源码交付的是提交里的 `16c65055` 版本；仓库内不存在 `9b738e97` 字节副本。
- 该差异属于原仓库既有的指纹偏差（生成后可能经过空白清理脚本再提交）；**交付比特流以 `89f4e1f0` 为准**，源码用于阅读与重建参考。
- 提交 `2b48ca9` 的网表是 512 MiB PMA 版本；后续提交 `389bc3c` 把 PMA 扩到 1 GiB（工作树网表 `4503634b`，提交 blob `fe7f1499`）。130zbb 比特流对应前者。

## 4. 软件镜像与卡

| 件 | 值 |
|---|---|
| `Image.618.zbb` | 6,431,232 B，md5 `123af9834091db97227a5d34b459aae3`；`linux-6.18.60`，`-march=rv32imac_zicsr_zifencei_zacas_zabha_zbb_zbs`，GCC 13.4.0 |
| `linux.618.dtb` | 3,337 B，md5 `9b9e0de145167734400158d477888b52`；`timebase-frequency=100 MHz`，`isa-extensions` 含 `zbb/zbs`，两段内存 0x8040_0000+252 MiB / 0xA000_0000+256 MiB |
| `rootfs_618_zbb.cpio` | 6,544,896 B，md5 `5eb600f405f8953a4b8907580a4710ef`；buildroot 2026.02.3，uClibc，`BR2_RISCV_ISA_EXTRA="zbb_zbs"` |
| `fw_jump.bin` | 133,872 B，md5 `1e809d4355ef4d69c21ea06b18cd57aa`（OpenSBI） |
| `y1_payload.bin` | 1,829,568 B，md5 `7cec60cab6d9cd496ff729f72cb58930`（NPU 权重/描述符载荷） |
| `sd_y1_618_zbb.img` | 14,944,256 B，md5 `72c0d92b1a2345ee2537df1765044a7d`；5 段卡 |
| `sd_score_618zbb_i20000.img` | 16,840,192 B，md5 `03a0c1a19e5ee546bb7ad2fe17316675`；plan0 与 zbb 卡逐字节相同，plan1 为 CoreMark（LBA 32768，`0x80000000`，122 块） |

镜像构建入口：`software/image-build/kzbb.sh`（内核）、`software/image-build/naxmini_618_zbb_defconfig`（根文件系统）、`sim/mk_sd_image.py` + `sim/reglogs/mk_score_card_v2.py`（卡/跑分卡拼装）。

## 5. 已知口径差异 / 使用注意

1. **CoreMark 计时基准**：裸机端 `EE_TICKS_PER_SEC=100 MHz`，日志 `5.84 Coremark/MHz` 按该基准打印；CPU 实际 130.645 MHz。原始 ticks/秒数见 `deliver/logs/bootsel_C_live_20261104b.log`。
2. **内存窗口**：卡内 DTB 声明两段内存（合计 508 MiB），交付网表（`2b48ca9`）PMA 为 512 MiB（0x8000_0000 起）。第二段起始 0xA000_0000 超出该 PMA 覆盖范围；CoreMark 为裸机运行，不经过 DTB 内存分配。若用该 zbb 卡启动 Linux 并希望吃满第二段内存，建议先做一次 `memtest`/PMA 版本确认（后续 1 GiB PMA 网表在提交 `389bc3c` 中）。
3. **上板日志对应关系**：`fv_boot.txt` 是固化 cpu130 后立即抓取的 6.18 启动日志（读回 md5 已验证）；`bootsel_C_live_20261104*.log` 为次日的启动/跑分抓取；日志内未记录当时插入的卡镜像名，卡与日志的对应以时间线和卡内段 CRC 为准。
4. **网络与 PDS 路径**：`pds/*.tcl` 中的 `set root` 是原工作区绝对路径；迁移到本仓库后需改为仓库根后再跑。
