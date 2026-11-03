# GPU P0：核加 Zicbom（cbo.clean/flush/inval）实施与验收记录

> 规格：`docs/superpowers/specs/2026-10-30-simple-gpu-design.md` §9
> 计划：`docs/superpowers/plans/2026-10-31-gpu-p0-zicbom.md`
> 日期：2026-10-31 ｜ 状态：**上板验收通过**（`CBO POS=1 NEG=1 GATE=1` → VERDICT PASS，见 §6）

## 1. 做了什么

| 件 | 内容 | 提交 |
|---|---|---|
| 核网表 | `scripts/gen_core.sh` 的 `--with-isa` 加 `zicbom`，重生成 `rtl/vexiiriscv/VexiiRiscv.v` | `c59c812` |
| M 态放行 | OpenSBI `nax_early_init` 写 `menvcfg.CBCFE=1`（CSR 0x30a，bit6） | `746f162` |
| U 态放行 | 内核补丁 `0004-riscv-enable-user-zicbom.patch`：`start_thread()` 写 `senvcfg.CBCFE=1`（CSR 0x10a） | `746f162` |
| 判据工具 | `y1/tools/cbotest.c`（写 → `cbo.flush` → `/dev/mem` 直读 DDR；正/负对照） | `746f162` |

为什么需要两处放行位：核的判据是 S 态看 `menvcfg.CBCFE`、U 态再与 `senvcfg.CBCFE`
（`LsuPlugin.scala:255-256`，两位复位都是 0）；本内核是 5.10.1，早于 Zicbom 支持，
`start_thread` 不碰 `senvcfg`，OpenSBI 也不写 `menvcfg`。**不改 RTL、不改 DTS。**

## 2. 结构证据（核网表真的带 CBM）

- `scripts/gen_core.sh:27` → `--with-isa m,a,c,s,u,zicbom`
- `rtl/vexiiriscv/VexiiRiscv.v` 里 CBM 请求/CSR 通路存在（grep `cbm` 35 处），
  含 `cbmCsr_menvcfg_cbcfe` / `cbmCsr_senvcfg_cbcfe` / `cbmCsr_invalIntoClean` 等；
- 核网表 md5 **`54931ad7…`**（`md5sum rtl/vexiiriscv/VexiiRiscv.v`）。

## 3. 资源与时序（tag `gpu0`，cpu_clk 10.000 ns）

dev_map（`sim/reglogs/devmap_gpu0.log`）：

| 项 | 值 |
|---|---|
| LUT | **88,172.5** |
| FF | 119,661 |
| DRM | 312（上限 415） |
| APM | 257 |
| Distributed RAM | 8,079 |
| errors | **0** |

PnR（`sim/reglogs/pnr_gpu0.log`，strategy 默认，4 seeds）：

- **Design Summary: All Constraints Met.**
- Best Seed 0；`soc_clk` WNS **+0.606 ns**（106.45 MHz @ 100 MHz 约束）、
  `cpu_clk` +0.509、`npu_clk` +0.694。
- 比特流：`sim/reglogs/pds_gpu0_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit`
  **9,188,552 B**，sha256 `cf3838c2…`。

## 4. 二进制级自证（放行位真的进了交付件）

方法：CSR 指令编码扫描（`csrrs` funct3=2 / `csrrw` funct3=1 / `csrs` funct3=6，
csr 字段 0x10A=senvcfg、0x30A=menvcfg；**按 2 字节步长扫**——本核有 C 扩展，
32 位指令可落在 2 mod 4 的边界上，按 4 字节扫会漏）。正对照：`sstatus`(0x100)
在 Image 里 csrrs 命中 1,140 处，证明扫描器与镜像格式都对。

| 件 | 旧件 | 新件 | 判读 |
|---|---|---|---|
| `Image` | `bak_k2_20261029/Image`（md5 `3aa9ae07…`）：senvcfg **0** 条 | md5 **`45ac4f04…`**：`csrrs` @0x2383E + `csrrw` @0x23846 | 内核 `start_thread` 的 read-modify-write 一对，**U 态放行在镜像里** |
| `fw_jump.bin` | `bak_k2_20261029/fw_jump.bin`（md5 `d24f4b36…`）：menvcfg `csrrs` **5** 条 | md5 **`1e809d43…`**：menvcfg `csrrs` **6** 条（新增 @0x7982） | OpenSBI `nax_early_init` 的写，**M 态放行在固件里** |

反过来说明这两条判据也会"变红"：旧件都是 0 / 5，新件才会出现第 6 条与那一对。

## 5. 交付件指纹

| 件 | 指纹 |
|---|---|
| 卡 | `sw/images/sd_gpu0.img` **14,626,304 B**（28,567×512），sha256 **`0d09ce688c954bc9e958326dd7f07db19b6babae8b23fcaa0a3cd5073cbfe113`** |
| 写卡（2026-10-31 12:19） | `sim/board/write_sd.ps1 -Disk 2 -Part 1 -Letter E`；GUARD PASS（7.4 GB USB）→ 写 14,626,304 B → 回读逐字节 → **CARD VERIFY PASS** → E: 重新挂载；transcript `sim/reglogs/write_sd.log` |
| 卡内 CRC（独立复验） | header `E492CAD5` OK；5 段全 OK：fw `115B64B4` / Image `5239D937` / dtb `7E69E519` / rootfs `E66F01C0` / payload `B491A323` |
| P0 比特流 | `gpu0`，sbit sha256 `cf3838c2…`（9,188,552 B） |
| 固件/内核 | `fw_jump.bin` md5 `1e809d43…` / `Image` md5 `45ac4f04…` |
| 判据工具 | `y1/build/cbotest` **201,792 B**，md5 **`ea121937…`**（源码 `y1/tools/cbotest.c`）；诊断 `y1/build/cbodiag` md5 `3e957ce5…` |

## 6. 上板判据与实测结果（2026-10-31 13:23）

1. 烧 `gpu0` → 启动 marker 8/8 → 卡用 `sd_gpu0.img`。
2. 推 `y1/build/cbotest` 到 `/tmp`，`python scripts/gpu_board_judge.py --test cbo`。

**实测（原文）**：

```
pushed: ...cbotest -> /tmp/cbotest（201792 B）
CBO POS=1 NEG=1 GATE=1 LEN=32768
RC=0
VERDICT: PASS
```

- **POS**：32 KB 缓冲 CPU 写 + 逐行 `cbo.flush`，**逐页**取 PA 读 `/dev/mem` 与写入值逐字节相同
  （页数 8/8）。真正承重的是"`cbo.flush` 不被拒 + 不破坏数据"。
- **GATE**：`cbo.inval` 必须 SIGILL（CBIE=0）⇒ CBO 解码 + CSR 门控链生效，放行位只放了 CBCFE。
- **NEG**：判据自证——读 **buf 的物理页**、比"改坏一个字节的期望值"，同一条比对路径必须报不一
  致且落在第 0 页。见 §6b 为什么不能做成"缓存 vs DDR"对照。

### 6a. 板上实测：本核 D\$ 是**写直达**（`cbodiag`，同一比特流）

```
A) cbo.inval trapped=1 (exp 1)
B) clean: hw==buf 4096/4096
C) flush: hw==buf 4096/4096
E) no-flush 4KB: hw==buf 4096/4096 (write-through => 4096)
D) chunk0 (0KB..4KB): 4096/4096      D) chunk4 (16KB..20KB): 13/4096
D) chunk1 (4KB..8KB): 4096/4096      D) chunk5 (20KB..24KB): 23/4096
D) chunk2 (8KB..12KB): 24/4096       D) chunk6 (24KB..28KB): 18/4096
D) chunk3 (12KB..16KB): 18/4096      D) chunk7 (28KB..32KB): 11/4096
```

- **E 是写直达的判据**：4 KB（< D\$16K）**完全不 flush**，DDR 也与 CPU 缓冲逐字节相同
  ⇒ 普通 store 直接可见，"不 flush 就该不一致"这种负对照在本核上**构造不出来**。
- **D 是"物理页不连续"的判据**：32 KB 用首页 PA 做一次 mmap，只有前 2 页（8 KB）对得上，
  其余 6 个"块"命中率 ~0.4%（随机耦合）。这正是早期 `cbotest` 报 `CBO FAIL` 的原因——
  `posix_memalign` 只保证**虚拟**连续。修法 = 逐页 `pagemap` 取 PA 再 mmap 比对。
- 顺带结论：核是写直达 + 不写分配 ⇒ GPU/DMA 与 CPU 的一致性**不依赖** Zicbom；
  驱动本来就走 `/dev/mem + O_SYNC`（uncached），`gpu_mem_sync()` 是记录在案的空操作。

### 6b. 判据修正史（两处**判据自身**的缺陷，都非 RTL）

| 现象 | 根因 | 修法 |
|---|---|---|
| `CBO FAIL`（POS=0） | 32 KB 单次 mmap 假定物理连续 | 逐页 `pagemap` + 逐页 mmap（`hw_page_match`） |
| `NEG=0` | 自证拿"改坏副本**自己**的 PA"当读源；写直达下那份 DDR 内容就是改坏值 ⇒ `memcmp` 恒真 | 把 `hw_page_match` 拆成 `(pa_src, exp)`：NEG 读 **buf 的物理页**、比改坏的 `exp` |

### 6c. 失败分诊（照计划 §故障表，**不要改 RTL 去"放行"**）
`CBO SIGILL` ⇒ 先复查 `fw_jump.bin`/`Image` 的 md5 是否就是本表的值；再按 §4 的方法扫
`senvcfg`/`menvcfg` 指令是否在镜像里（旧件 0/5 条是新件的判据基线）。

## 7. 已知偏差与备注

- 计划里写"本内核是 5.14"，实际构建出的是 **5.10.1**（`strings Image` 的 banner：
  `Linux version 5.10.1 ... #2 SMP PREEMPT Sat Oct 31 00:59:33 CST 2026`）；
  补丁上下文按 5.10.1 的 `process.c` 生成，已 dry-run 过。
- `linux-touch` 那棵树（`~/vexii-gui-build/linux-touch`，10-29 22:22）**不含**本补丁，
  是更早的构建树；P0 卡用的是 `~/vexii-build/buildroot`（10-31 00:59）那份，
  其 `output/build/linux-dev/arch/riscv/kernel/process.c:98` 有
  `csr_write(CSR_SENVCFG, …)`。**别拿 `linux-touch` 的 vmlinux 当本卡的内核**。
