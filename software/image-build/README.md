# 130zbb 镜像构建补充件

主工程的 `sw/` 目录已包含 buildroot 外部树、内核补丁、OpenSBI 平台与镜像打包脚本。本目录放的是 **快照提交 `2b48ca9` 之后、实际构建 zbb 镜像时仍在工作树里的那一部分输入**，以及构建口径说明。

## 文件

| 文件 | 用途 |
|---|---|
| `naxmini_618_zbb_defconfig` | buildroot 外部树 defconfig（`BR2_RISCV_ISA_EXTRA="zbb_zbs"`，uClibc，dropbear/dhrystone/micropython） |
| `kzbb.sh` | 6.18 内核重建：`-march=rv32imac_zicsr_zifencei_zacas_zabha_zbb_zbs`，产物 `Image.618.zbb` |
| `linux.618.zbb.decompiled.dts` | 交付 DTB 的 dtc 反编译（交付卡内 DTB 的权威内容；含 `zbb/zbs`、两段内存、100 MHz timebase） |
| `mk_score_card_v2.py` | 跑分卡拼装：plan0 取基底卡前 16 MiB，plan1 放 CoreMark bin（依赖 `sim/mk_sd_image.py`） |

## 构建口径

| 项 | 值 |
|---|---|
| Buildroot | 2026.02.3（外部树 `sw/buildroot-external`，`BR2_EXTERNAL_NAXMINI`） |
| 工具链 | buildroot 内建 GCC 13.4.0，uClibc，目标 `riscv32-buildroot-linux-uclibc` |
| 内核 | `linux-6.18.60.tar.xz`，`linux618.config` + 强制 32 位（`NONPORTABLE` / `ARCH_RV32I`），CTP 驱动补丁 |
| ISA | `rv32imac_zicsr_zifencei_zacas_zabha_zbb_zbs` |
| DTB | `linux_raw.dts` 经 `-DLX618` cpp 展开 + dtc；卡内实际 DTB md5 `9b9e0de1…` |
| 根文件系统 | `rootfs_618_zbb.cpio`，md5 `5eb600f4…` |
| 卡 | `sd_y1_618_zbb.img`（5 段），跑分卡在其 plan0 基础上加 plan1 |

## 备注

- 交付 DTB 的源 DTS 在构建时是未提交工作树状态；后续提交 `389bc3c` 又把 PMA/内存图改成 1 GiB。因此**以交付 DTB（反编译稿）为准**，不要拿当前 `sw/.../linux_raw.dts` 直接重编后对比指纹。
- 卡内 DTB 的两段内存与 512 MiB PMA 的口径差异见 [`docs/PROVENANCE.md`](../../docs/PROVENANCE.md) 第 5 节。
- `mk_score_card_v2.py` 的 `coremark.bin` 输入已从跑分卡 plan1 提取为 `deliver/artifacts/coremark_zbb_i20000.bin`，可用于重建同一张跑分卡。
