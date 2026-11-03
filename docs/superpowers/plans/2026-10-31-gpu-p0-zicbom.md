# GPU P0：给 VexiiRiscv 加 Zicbom 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 CPU 能用 `cbo.flush/clean/inval` 把脏 cache 行写回 DDR，从而让 GPU 读到 CPU 刚写的数据；产出一个可上板的 `gpu0` 比特流并用硬件读回判据验证。

**Architecture:** 上游 VexiiRiscv 的 `LsuL1Plugin` 已实现 Zicbom（`withCbm`）；本计划改 `scripts/gen_core.sh` 的 `GEN_ARGS`（加 `zicbom`）重生成核网表，再补两处**放行位**：M 态固定件（OpenSBI `nax_early_init`）写 `menvcfg.CBCFE=1`，内核补丁 `0004` 在 `start_thread` 写 `senvcfg.CBCFE=1`（核的判据见 `LsuPlugin.scala:255-256`，两位复位都是 0；本内核是 5.14，早于 Zicbom 支持，不会自己写）。然后结构闸门 → dev_map/PnR → 上板用 `cbotest` 做“写→flush→/dev/mem 直读 DDR”的正/负对照。**不改 RTL、不改 DTS。**

**Tech Stack:** SpinalHDL/sbt（核生成）、PDS 2025.2（dev_map/PnR）、Verilator（既有单测）、RV32 uClibc 工具链（板端 C 工具）、板级 `flash_and_verify.py`。

**依据：** `docs/superpowers/specs/2026-10-30-simple-gpu-design.md` §9、§13。

---

## 文件与职责

| 文件 | 动作 | 职责 |
|---|---|---|
| `scripts/gen_core.sh` | 修改 | 唯一改动点：`--with-isa m,a,c,s,u,zicbom` |
| `rtl/vexiiriscv/VexiiRiscv.v` | 重生成 | 核网表（绝不手改） |
| `sw/buildroot-external/boards/naxmini/opensbi/platform.c` | 修改 | `nax_early_init` 写 `menvcfg.CBCFE=1`（M 态） |
| `sw/buildroot-external/patches/linux/0004-riscv-enable-user-zicbom.patch` | 新建 | `start_thread` 写 `senvcfg.CBCFE=1`（S 态） |
| `y1/tools/cbotest.c` | 新建 | 板端判据工具（正/负对照 + SIGILL 自诊断） |
| `y1/tools/build_cbotest.sh` | 新建 | 交叉编译 + 冒烟（反汇编里必须出现 `cbo.flush`） |
| `sim/reglogs/p0_*` | 新建 | 基线/闸门/上板日志（gitignored） |
| `docs/reports/gpu-p0-zicbom.md` | 新建 | 收口报告（指纹 + 判据 + 结论） |

---

## Task 0：前置检查与基线快照

**Files:** 只写 `sim/reglogs/p0_baseline.txt`

- [ ] **Step 1: 确认工作区与进程状态**

```bash
cd /d/code/PDS/VexiiYeshenLinux
git status --porcelain=v1 | head -20
tasklist | grep -i -E "pds_shell|cdt_js" || echo "no PDS/cdt running"
```
Expected：只有别的会话的 WIP（`scripts/eth_memread.py`、`grab_cam.py` 等）；**没有** `pds_shell/cdt_js`。

- [ ] **Step 2: 记基线指纹**

```bash
{
  echo "core_md5=$(md5sum rtl/vexiiriscv/VexiiRiscv.v | cut -d' ' -f1)"
  echo "core_lines=$(wc -l < rtl/vexiiriscv/VexiiRiscv.v)"
  echo "sbit_ctp2=$(sha256sum sim/reglogs/pds_ctp2_p10.000/prj_tasks/pnr_1/generate_bitstream/yeshen_mini_board_top.sbit | cut -d' ' -f1)"
  echo "isa_str=$(grep -n 'ISA_STR' configs/rv32imac.sh)"
  echo "kernel_zicbom=$(grep -c ZICBOM sw/buildroot-external/boards/naxmini/linux/linux_raw.config)"
} | tee sim/reglogs/p0_baseline.txt
```
Expected（2026-10-31 本机实测）：`core_md5=81c1ea4bfeb0bc73bb2c235bf17edb52`、
`core_lines=29704`、`kernel_zicbom=0`。

---

## Task 1：改前证明生成链可复现

> 纪律：先证明“不改任何东西能复现出已提交的网表”，否则后面 md5 变化无法归因。

**Files:** 只读 + `gen_core.log`

- [ ] **Step 1: 用当前参数重生成**

```bash
cd /d/code/PDS/VexiiYeshenLinux && bash scripts/gen_core.sh
```
Expected：`gen_core: wrote .../VexiiRiscv.v (29704 lines)`，sbt rc=0。

- [ ] **Step 2: 比对 md5**

```bash
md5sum rtl/vexiiriscv/VexiiRiscv.v   # 应为 81c1ea4bfeb0bc73bb2c235bf17edb52
```
Expected：与 Step 0 一致。**不一致就停下**（环境漂移，先查 `gen_core.log` 与 JDK/sbt 版本），不要继续。

- [ ] **Step 3: 确认工作区无意外改动**

```bash
git status --porcelain=v1 rtl/vexiiriscv/VexiiRiscv.v   # 空
```

---

## Task 2：加 zicbom（一行）+ 确定性

**Files:**
- Modify: `scripts/gen_core.sh`（`GEN_ARGS` 里的 `--with-isa`）

- [ ] **Step 1: 改参数**

把
```bash
  --with-isa m,a,c,s,u
```
改成
```bash
  # 2026-10-31 GPU P0：CPU 需要 cbo.flush/clean/inval（上游 LsuL1 的 withCbm 实现）
  --with-isa m,a,c,s,u,zicbom
```

- [ ] **Step 2: 重生成两次**

```bash
cd /d/code/PDS/VexiiYeshenLinux
bash scripts/gen_core.sh && md5sum rtl/vexiiriscv/VexiiRiscv.v | tee /tmp/z1.txt
bash scripts/gen_core.sh && md5sum rtl/vexiiriscv/VexiiRiscv.v | tee /tmp/z2.txt
cmp /tmp/z1.txt /tmp/z2.txt && echo DETERMINISTIC
```
Expected：`DETERMINISTIC`；行数与基线相比变化（记录新值）。

- [ ] **Step 3: 确认 CBM 逻辑真的进了网表**

```bash
grep -c -i "cbm" rtl/vexiiriscv/VexiiRiscv.v
grep -o -i "cbm[A-Za-z_]*" rtl/vexiiriscv/VexiiRiscv.v | sort -u | head
```
Expected：计数 > 0（`LsuL1Plugin` 的 `CBM_REDO/askCbm/doCbm` 会变成信号名）。

- [ ] **Step 4: 提交**

```bash
git add scripts/gen_core.sh rtl/vexiiriscv/VexiiRiscv.v
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "feat(core): 启用 Zicbom（cbo.flush/clean/inval）—— GPU P0 前置"
```
（作者名以仓库既有 author 为准：`LiaoZiqi-GZFLS <LiaoZiqi-GZFLS@users.noreply.github.com>`。）

---

## Task 2b：CBO 放行位（固件 menvcfg + 内核补丁 senvcfg）

> **为什么必须有这一步**：核的 CBM 是带门控的（`LsuPlugin.scala:255-256`）——非 M 态查
> `menvcfg.CBCFE`，U 态再查 `senvcfg.CBCFE`，两位 `RegInit(0)`；本内核 5.14 没有 Zicbom
> 支持、`start_thread` 不碰 `senvcfg`，OpenSBI 也不写 `menvcfg`。没有这一步，`cbo.flush`
> 在用户态必 SIGILL。

**Files:**
- Modify: `sw/buildroot-external/boards/naxmini/opensbi/platform.c`
- Create: `sw/buildroot-external/patches/linux/0004-riscv-enable-user-zicbom.patch`

- [ ] **Step 1: OpenSBI 写 menvcfg（只写 M 自己的 CSR）**

在 `nax_early_init()` 的 `if (!cold_boot) return 0;` 之后加一次：

```c
static void nax_enable_cbo(void)
{
	unsigned long v;
	__asm__ volatile("csrrs %0, 0x30a, %1" : "=r"(v) : "r"(1UL << 6)); /* menvcfg.CBCFE */
}
```

- [ ] **Step 2: 内核补丁 0004（只写 senvcfg）**

`arch/riscv/kernel/process.c` 两处：文件头补 `#define CSR_SENVCFG 0x10a` /
`#define ENVCFG_CBCFE (1UL << 6)`（本树 `asm/csr.h` 还没有这两个名字），`start_thread()`
末尾加 `csr_write(CSR_SENVCFG, csr_read(CSR_SENVCFG) | ENVCFG_CBCFE);`。

- [ ] **Step 3: 补丁可应用性（本机已跑）**

```bash
MSYS_NO_PATHCONV=1 wsl bash /mnt/d/code/PDS/VexiiYeshenLinux/sim/reglogs/mk_kpatch.sh
```

Expected：`## == dry-run apply ==` 下一行 `checking file arch/riscv/kernel/process.c`（无 FAILED）。
若上游文件变了，按该脚本重生成，**不要手数 hunk 行号**。

- [ ] **Step 4: 重建固件+内核+镜像（WSL，别在 /mnt 下构建）**

```bash
MSYS_NO_PATHCONV=1 wsl bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && \
  REBUILD_PKGS="opensbi linux" bash scripts/build_images.sh'
```

Expected：`sw/images/fw_jump.bin` 与 `sw/images/Image` 的 md5 **都比重建前变**（记进报告）。
若 `fw_jump.bin` md5 没变 ⇒ 老坑：改用 `make opensbi-dirclean opensbi` 再 build（脚本注释已写明 `-rebuild` 不可靠）。

---

## Task 3：结构闸门 + 既有单测回归

**Files:** 只写日志

- [ ] **Step 1: 悬空/Xilinx/地址台账**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python3 y1/tools/check_dangling.py rtl/vexiiriscv/VexiiRiscv.v | tail -3
bash y1/tools/check_no_xilinx.sh rtl/vexiiriscv | tail -3
python3 scripts/check_addr_map.py | tail -3
```
Expected：三者均 PASS（exit 0）。`check_dangling` 若报新悬空 → 停下查（说明生成里出现了无定义的 BlackBox）。

- [ ] **Step 2: glue 侧既有单测（核网表不参与，只作回归）**

```bash
MSYS_NO_PATHCONV=1 wsl bash -lc 'cd /mnt/d/code/PDS/VexiiYeshenLinux && \
  bash sim/glue_pbus/run_unit.sh 2>&1 | tail -3 && \
  bash sim/glue_pbus/run_npu_unit.sh 2>&1 | tail -3 && \
  bash sim/glue_pbus/run_dma_pbus_unit.sh 2>&1 | tail -3 && \
  bash sim/memarb/run_unit.sh 2>&1 | tail -3'
```
Expected：四个装置都打印 `=== TEST PASSED ===`。

---

## Task 4：dev_map 记账（tag `gpu0`）

**Files:** 只写 `sim/reglogs/devmap_gpu0.log`

- [ ] **Step 1: 跑 dev_map（后台托管，勿用 nohup）**

```bash
cd /d/code/PDS/VexiiYeshenLinux
YESHENMINI_DEVMAP_TAG=gpu0 pds_shell.exe -file pds/run_devmap_yeshen.tcl \
  > sim/reglogs/devmap_gpu0.log 2>&1; echo rc=$?
```
Expected：rc=0；日志 `0 error`。

- [ ] **Step 2: 记账**

```bash
grep -a -A9 "Logic Utilization" sim/reglogs/devmap_gpu0.log | head -12
```
Expected：LUT 比 `ctp2` 的 88,083 增加（预算 **+1–3 K**）；DRM/APM/IO 不变。

---

## Task 5：PnR + 比特流（tag `gpu0`）

**Files:** 产物在 `sim/reglogs/pds_gpu0_p10.000/...`

- [ ] **Step 1: PnR（strategy 1，4 seed，后台）**

```bash
YESHENMINI_PNR_TAG=gpu0 YESHENMINI_STRATEGY=1 pds_shell.exe -file pds/run_pnr_yeshen.tcl \
  > sim/reglogs/pnr_gpu0.log 2>&1; echo rc=$?
```

- [ ] **Step 2: 判据**

```bash
R=sim/reglogs/pds_gpu0_p10.000/prj_tasks/pnr_1
grep -a -A2 "Design Summary" $R/report_timing/yeshen_mini_board_top.rtr | head -3
sha256sum $R/generate_bitstream/yeshen_mini_board_top.sbit
```
Expected：`All Constraints Met`（或记录 worst slack 与弧名）；比特流 9,188,552 B 级。

---

## Task 6：板端判据工具 `cbotest`

**Files:**
- Create: `y1/tools/cbotest.c`
- Create: `y1/tools/build_cbotest.sh`

- [ ] **Step 1: 写 `y1/tools/cbotest.c`**

```c
/* cbotest -- GPU P0 判据：CPU 写（可缓存堆）→ cbo.flush → 用 /dev/mem 直读 DDR 比对。
 *
 * 正例：fill(P1) → 逐 64 B cbo.flush → /dev/mem 读回 == P1   （POS=1）
 * 负例：fill(P2, 不 flush) → /dev/mem 读回 != P2              （NEG=1）
 * 两者都 1 才 PASS。若核没实现 Zicbom，第一条 cbo 就 SIGILL（退出码 132）。
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PAGE 4096UL
#define LEN  (8 * PAGE)            /* 32 KiB：大于 D$ 16 KiB，降低“整块恰好还在 cache”的概率 */

static inline void cbo_flush(void *p)
{
    __asm__ volatile("cbo.flush (%0)" :: "r"(p) : "memory");
}

static unsigned long long pa_of(void *p)
{
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    unsigned long vpn = (unsigned long)p / PAGE;
    unsigned long long e = 0;
    ssize_t n = pread(fd, &e, 8, (off_t)(vpn * 8));
    close(fd);
    if (n != 8 || !(e & (1ULL << 63))) return 0;      /* 页不存在 */
    return (e & ((1ULL << 55) - 1)) * PAGE + ((unsigned long)p % PAGE);
}

static void fill(uint8_t *b, size_t n, uint32_t seed)
{
    uint32_t x = seed ? seed : 1u;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        b[i] = (uint8_t)(x ^ (uint32_t)(i * 7));
    }
}

int main(int argc, char **argv)
{
    size_t len = LEN;
    uint32_t seed = (argc > 1) ? (uint32_t)strtoul(argv[1], NULL, 0) : 0x12345678u;

    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, PAGE, len) != 0 || !buf) {
        printf("CBO FAIL alloc\n"); return 2;
    }
    memset(buf, 0, len);                              /* 触页 */

    unsigned long long pa = pa_of(buf);
    if (!pa) { printf("CBO FAIL pagemap(need root)\n"); return 2; }

    int mfd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (mfd < 0) { printf("CBO FAIL /dev/mem\n"); return 2; }
    void *hw = mmap(NULL, len, PROT_READ, MAP_SHARED, mfd, (off_t)pa);
    if (hw == MAP_FAILED) { printf("CBO FAIL mmap\n"); return 2; }

    /* ---- 正例 ---- */
    fill(buf, len, seed);
    for (size_t off = 0; off < len; off += 64) cbo_flush(buf + off);
    __sync_synchronize();
    int pos = (memcmp(hw, buf, len) == 0);

    /* ---- 负例：换图案但不 flush，DDR 应仍是旧图案 ---- */
    fill(buf, len, seed ^ 0xA5A5A5A5u);
    __sync_synchronize();
    int neg = (memcmp(hw, buf, len) != 0);

    printf("CBO POS=%d NEG=%d LEN=%zu PA=0x%llx SEED=0x%08x\n",
           pos, neg, len, pa, seed);
    printf("CBO hw[0..15]=%02x%02x%02x%02x%02x%02x%02x%02x\n",
           ((uint8_t *)hw)[0], ((uint8_t *)hw)[1], ((uint8_t *)hw)[2], ((uint8_t *)hw)[3],
           ((uint8_t *)hw)[4], ((uint8_t *)hw)[5], ((uint8_t *)hw)[6], ((uint8_t *)hw)[7]);
    return (pos && neg) ? 0 : 1;
}
```

- [ ] **Step 2: 写 `y1/tools/build_cbotest.sh`**

```bash
#!/bin/bash
# 交叉编 cbotest（RV32、静态、带 zicbom），并做反汇编冒烟。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 9
CC=${CC:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-gcc}
OD=${OD:-$HOME/vexii-build/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-objdump}
OUT=y1/build/cbotest
mkdir -p y1/build
"$CC" -O2 -static -march=rv32imac_zicbom -mabi=ilp32 -mcmodel=medany \
      y1/tools/cbotest.c -o "$OUT" || { echo "!! compile failed"; exit 3; }
"$OD" -d "$OUT" | grep -c -E "cbo\.(flush|clean|inval)" | sed 's/^/cbo_insns=/'
ls -l "$OUT"; md5sum "$OUT"
```

- [ ] **Step 3: 编译并冒烟**

```bash
MSYS_NO_PATHCONV=1 wsl bash /mnt/d/code/PDS/VexiiYeshenLinux/y1/tools/build_cbotest.sh
```
Expected：`cbo_insns=` ≥ 1（实际会因循环里一处 + 展开出现多次）；产物 `y1/build/cbotest`。

- [ ] **Step 4: 提交**

```bash
git add y1/tools/cbotest.c y1/tools/build_cbotest.sh
GIT_AUTHOR_NAME="LiaoZiqi-GZFLS" GIT_AUTHOR_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
GIT_COMMITTER_NAME="LiaoZiqi-GZFLS" GIT_COMMITTER_EMAIL="LiaoZiqi-GZFLS@users.noreply.github.com" \
git commit -m "test(cbo): 板端 Zicbom 判据工具 cbotest（写→flush→/dev/mem 直读）"
```

---

## Task 7：上板验收（**需要用户给板窗口**）

**Files:** 日志 `sim/reglogs/p0_cbo_board.txt`

- [ ] **Step 0: 新卡（固件+内核都变了，不能复用旧卡）**

```bash
cd /d/code/PDS/VexiiYeshenLinux && IM=sw/images
python sim/mk_sd_image.py --out $IM/sd_gpu0.img \
  --entry 0x80000000=$IM/fw_jump.bin --entry 0x82000000=$IM/Image \
  --entry 0x82F80000=$IM/linux.dtb --entry 0x83000000=$IM/rootfs.cpio \
  --entry 0x81E00000=$IM/y1_payload.bin
sha256sum $IM/sd_gpu0.img
```

Expected：14,626,304 B 级、5 段 CRC 全打出来；`fw_jump.bin`/`Image` 的 md5 与旧卡（`sd_score_ctp.img` 的同地址段）不同，
`linux.dtb`/`y1_payload.bin` 逐字节相同（这正是"只动了固件+内核"的对照）。

- [ ] **Step 1: 烧 `gpu0` 并验启动**

```bash
cd /d/code/PDS/VexiiYeshenLinux
python -u scripts/flash_and_verify.py --tag gpu0 --no-net --secs 150 2>&1 | tail -15
```
Expected：`done bit = 1`，8 项启动 marker 全 PASS。

- [ ] **Step 2: 推送并运行 cbotest**

```bash
python -u - <<'PY'
import sys; sys.path.insert(0,'scripts'); import board_ssh
print(board_ssh.put(r'D:\code\PDS\VexiiYeshenLinux\y1\build\cbotest', '/tmp/cbotest'))
print(board_ssh.run_text('chmod 755 /tmp/cbotest && /tmp/cbotest 0x12345678; echo rc=$?', timeout=60)[1])
PY
```
Expected：`CBO POS=1 NEG=1 ... rc=0`。

- [ ] **Step 3: 读判据 + 换 seed 复跑**

```bash
python -u scripts/board_ssh.py '/tmp/cbotest 0xdeadbeef; echo rc=$?'
```
Expected：两次都 `POS=1 NEG=1`。
判据含义：`NEG=1` 就是负对照——**不 flush 的那次写，DDR 仍是旧图案**（所以能和 CPU 视角区分开）；
若 `NEG=0`，说明 cache 已自然驱逐、本判据失去区分度，按“失败分支”处理。

- [ ] **Step 4: 回归冒烟（同一次启动内）**

```bash
python -u scripts/board_ssh.py "dmesg | grep -E 'YGUI-(AUTOSTART|BOOT|PRESENT|TOUCH-SVC|FB-OK)' | head -5; devmem 0xF000749C 32; devmem 0xF000740C 32"
```
Expected：GUI 链齐全、`0x1`/`0x3`。

---

## Task 8：收口

**Files:**
- Create: `docs/reports/gpu-p0-zicbom.md`
- Modify: `docs/superpowers/specs/2026-10-30-simple-gpu-design.md` §9（回填实测）

- [ ] **Step 1: 写报告**（核 md5/行数、dev_map 增量、PnR 结论、bitstream sha、cbotest 输出原文）

- [ ] **Step 2: 回填 spec §9**：把“承重判据”改成实测结果；若失败，写清失败形态（SIGILL / POS=0）与退回 uncached arena 的决定。

- [ ] **Step 3: 提交 + push**

```bash
git add docs/reports/gpu-p0-zicbom.md docs/superpowers/specs/2026-10-30-simple-gpu-design.md
git commit -m "docs(gpu-p0): Zicbom 上板判据结果 + spec §9 回填"
git push origin master
```

---

## 失败分支（判据不过时怎么走）

| 现象 | 判定 | 处理 |
|---|---|---|
| `cbotest` 打印 `CBO SIGILL` / 退出码 132 | 放行位没生效 | 先查固件是否真换了（`fw_jump.bin` md5）+ 内核补丁是否进了 `Image`（`strings Image \| grep -c` 不可靠 ⇒ 用源码树 `git diff` + 重编日志）；再查 `menvcfg` 写入是否被 OpenSBI 的 `mstatus` 设置覆盖。**不要**改 RTL 去“放行” |
| `POS=0`（flush 后 DDR 仍是旧值） | CBM 未真正写回 | 查 `cbmCsr` 块长（是否 64 B）、是否需要在 flush 前后加 `fence`；用 `cbo.clean` 再试一次 |
| `NEG=0`（不 flush 也一致） | 判据无区分度（cache 已自然驱逐） | 缩短“写→读”间隔 / 增大缓冲到 > D\$；若始终 evict，改用 eth_memread 独立见证 |
| PnR 不收敛 | 与本次改动无关的概率低 | 记录 worst slack 与弧名，按 `ctp2` 的同一策略（strategy 1，多 seed）再跑 |

## 判据汇总（本条交付的“完成”定义）

1. `rtl/vexiiriscv/VexiiRiscv.v` 两次生成 md5 相同，且包含 CBM 信号；
2. `check_dangling` / `check_no_xilinx` / `check_addr_map` / 四个单测全 PASS；
3. dev_map 0 error，LUT 增量 ≤ 3 K；
4. PnR 出比特流（All Met 或记录 worst slack ≤ −0.05 且弧为已知 DDR PHY）；
5. 上板：`CBO POS=1 NEG=1`，且 GUI 启动链/KEY4/相机不受影响；`fw_jump.bin`/`Image` 均有新 md5。
