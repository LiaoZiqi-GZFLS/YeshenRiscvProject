# 交付物校验清单（130zbb）

生成日期：2026-11-04。md5 用 `md5sum`，sha256 用 `sha256sum`。

## 比特流与 SPI 烧录

| 文件 | 字节 | md5 |
|---|---:|---|
| `bitstream/pds_cpu130_20261102.sbit` | 9,188,552 | `89f4e1f09ae1c2337605e7ef9e967164` |
| `spi/cpu130_20261103.sfc` | 9,188,552 | `89f4e1f09ae1c2337605e7ef9e967164` |
| `spi/cpu130_20261103_rb.sfc` | 9,188,552 | `89f4e1f09ae1c2337605e7ef9e967164` |

`cpu130_20261103.sfc` 由 `pds/gen_cpu130_sfc.tcl` 从 sbit 生成（XT25BF128，起始地址 0）；`..._rb.sfc` 为固化后的独立读回，三者逐字节相同。

## TF 卡镜像

| 文件 | 字节 | md5 | sha256 |
|---|---:|---|---|
| `images/sd_y1_618_zbb.img` | 14,944,256 | `72c0d92b1a2345ee2537df1765044a7d` | `4e7eff11f0996816c13889921f7d8b350b0b1db4220c0043694f8e14e692fcd1` |
| `images/sd_score_618zbb_i20000.img` | 16,840,192 | `03a0c1a19e5ee546bb7ad2fe17316675` | `f7407be20a4870df6629e1946909382fe18815f45fbbc7e8dd8f1f43a8290739` |

## 镜像组件（卡内段）

| 文件 | 字节 | md5 | 卡内落点 |
|---|---:|---|---|
| `artifacts/fw_jump.bin` | 133,872 | `1e809d4355ef4d69c21ea06b18cd57aa` | `0x8000_0000` |
| `artifacts/Image.618.zbb` | 6,431,232 | `123af9834091db97227a5d34b459aae3` | `0x8200_0000` |
| `artifacts/linux.618.dtb` | 3,337 | `9b9e0de145167734400158d477888b52` | `0x82F8_0000` |
| `artifacts/rootfs_618_zbb.cpio` | 6,544,896 | `5eb600f405f8953a4b8907580a4710ef` | `0x8300_0000` |
| `artifacts/y1_payload.bin` | 1,829,568 | `7cec60cab6d9cd496ff729f72cb58930` | `0x81E0_0000` |
| `artifacts/coremark_zbb_i20000.bin` | 62,464 | `687d87f0ee9debd00e13748c967e50c7` | 跑分卡 plan1，`0x8000_0000` |

`coremark_zbb_i20000.bin` 从跑分卡 plan1 段（LBA 32768 + 1，122 块）原样提取，末尾含 512 B 块对齐填充。

## 上板日志

| 文件 | 内容 |
|---|---|
| `logs/fv_flash.out` | SPI 固化：`Finish program …pds_cpu130_20261102.sbit`，done bit=1，7.7 s |
| `logs/fv_boot.txt` | 固化后冷启动：Linux 6.18.60，`VEXIIYESHEN-OK` |
| `logs/bootsel_C_live_20261104.log` | 次日启动抓取：`YGUI-BOOT` / `GPU-UNIT-ON` |
| `logs/bootsel_C_live_20261104b.log` | CoreMark：ITERS=20000，583.526233 iter/s，crcfinal `0x382f` |
| `logs/write_sd_raw_sd_score_618zbb_i20000_elev.out` | 跑分卡写入回读校验（sha256 两侧一致） |
| `logs/pnr_cpu130_seed0.log` | cpu130 单种子 PnR 运行日志（节选，完整工程已清理） |
| `logs/gen_sbit_cpu130.log` | 从 cpu130 PnR 工程出比特流的日志 |

## 复校命令

在仓库根目录运行：

```bash
md5sum -c <<'EOF'
89f4e1f09ae1c2337605e7ef9e967164  deliver/bitstream/pds_cpu130_20261102.sbit
89f4e1f09ae1c2337605e7ef9e967164  deliver/spi/cpu130_20261103.sfc
89f4e1f09ae1c2337605e7ef9e967164  deliver/spi/cpu130_20261103_rb.sfc
72c0d92b1a2345ee2537df1765044a7d  deliver/images/sd_y1_618_zbb.img
03a0c1a19e5ee546bb7ad2fe17316675  deliver/images/sd_score_618zbb_i20000.img
123af9834091db97227a5d34b459aae3  deliver/artifacts/Image.618.zbb
9b9e0de145167734400158d477888b52  deliver/artifacts/linux.618.dtb
5eb600f405f8953a4b8907580a4710ef  deliver/artifacts/rootfs_618_zbb.cpio
1e809d4355ef4d69c21ea06b18cd57aa  deliver/artifacts/fw_jump.bin
7cec60cab6d9cd496ff729f72cb58930  deliver/artifacts/y1_payload.bin
687d87f0ee9debd00e13748c967e50c7  deliver/artifacts/coremark_zbb_i20000.bin
EOF
```
