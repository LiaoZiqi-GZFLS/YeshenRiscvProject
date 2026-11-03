/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2019 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 *   Nick Kossifidis <mick@ics.forth.gr>
 */

/*
 * ===========================================================================
 * Task 22（M2-b）：NaxYeshenLinux / NaxMiniSoC 的 OpenSBI 平台（out-of-tree）
 *                  —— **OpenSBI v1.6（设备驱动模型）版**
 *
 * 为什么有第二个版本：platform.c 是**跟着 OpenSBI 版本走**的。
 *   · `attic/opensbi08-platform/platform.c`   = OpenSBI **v0.8** 的老接口版
 *     （`sbi_platform_operations` 里的 console_putc/console_getc/ipi_send/system_reset…），
 *     它只存在于 ≤ v0.8（v0.9 起删 pmp_region_count、加 domains_init；v1.x 整族换成驱动）。
 *   · 本文件 = 换成 buildroot **2025.02.18**（自带 **OpenSBI 1.6**）之后的版本。
 *     模板/依据：OpenSBI v1.6 自带的 `platform/template/`（官方最小 out-of-tree 例子）、
 *     `include/sbi/sbi_platform.h`、`lib/utils/serial/uart8250.c`、
 *     `lib/utils/ipi/aclint_mswi.c`、`lib/utils/timer/aclint_mtimer.c`（逐字读过字段名）。
 *
 * ---------------------------------------------------------------------------
 * ★ 契约（与 Task 9 / M1 / 台账四处一致，**一个字节都没改**）：
 *   · console = `0xF000_1000` 的 ns16550a：reg-shift=2、reg-width=1（8 位寄存器）、
 *     in_freq=100MHz、baud=115200（⇒ bdiv=(100e6+8*115200)/(16*115200)=54，与 tb 的
 *     `SOC_BAUD_DIV=54` 同源）。
 *   · CLINT = `0xF001_0000`（msip / mtimecmp / mtime 全在这一段）。
 *   · 三个 FW_*（FW_TEXT_START=0x80000000 / FW_JUMP_ADDR=0x82000000 /
 *     FW_JUMP_FDT_ADDR=0x82F80000）**在 `config.mk` 里原样保留**，由同目录
 *     `objects.mk` 用 `-include $(platform_src_dir)/config.mk` 拉进来（v1.6 的 Makefile
 *     不再自动 include 平台的 config.mk，这是本版本移植必需的一步）。
 *   · PLATFORM_RISCV_XLEN=64 / ABI=lp64 / ISA=rv64imac_zicsr_zifencei（同样在 config.mk）。
 *   · hart_count = 1（NaxSocMini 只有 naxes_0）。
 *
 * ---------------------------------------------------------------------------
 * ★ 老（v0.8）→ 新（v1.6）到底差在哪（逐条对着 1.6 的头文件/驱动源码核过）：
 *
 *  1) **console：从 platform_ops 里搬走，改成设备注册**。
 *     v0.8：`.console_putc = uart8250_putc` / `.console_getc = uart8250_getc`，
 *           并且 platform 自己 `uart8250_init(base, freq, baud, shift, width)`（5 参）。
 *     v1.6：`struct sbi_platform_operations` **根本没有** console_* 字段；
 *           `uart8250_init(base, in_freq, baudrate, reg_shift, reg_width, reg_offset)`
 *           **多一个 reg_offset 参数**，并且它自己最后调
 *           `sbi_console_set_device(&uart8250_console)`（`lib/utils/serial/uart8250.c`）
 *           + `sbi_domain_root_add_memrange(base, PAGE_SIZE, …)` 把 UART 那一页加进 root domain。
 *           ⇒ 我们在 `early_init` 里调一次 `uart8250_init(...)` 就等于老版的 console_init。
 *     ★ 顺带一个行为差异（对判据是好事）：1.6 在 console 设备注册**之前**的打印会先塞进
 *       `console_early_fifo`（256B），`sbi_console_set_device()` 时再 flush
 *       （`lib/sbi/sbi_console.c` 的 nputs/sbi_console_set_device）。banner 的打印发生在
 *       `init_coldboot()` 里 `sbi_platform_early_init()` **之后**，所以 banner 一定会出来。
 *
 *  2) **IPI / timer：也从 platform_ops 里搬走，改成 driver + `*_cold_init()`**。
 *     v0.8：`struct clint_data` + `clint_cold_ipi_init/clint_warm_ipi_init/clint_ipi_send/
 *           clint_ipi_clear/clint_timer_value/clint_timer_event_start/…` 一大串字段。
 *     v1.6：`include/sbi_utils/sys/clint.h` **已删除**，换成 ACLINT 两个驱动：
 *           `lib/utils/ipi/aclint_mswi.c`（msip）与 `lib/utils/timer/aclint_mtimer.c`（mtime/mtimecmp）。
 *           平台只留 `.ipi_init` / `.timer_init` 两个钩子，里面各调一次
 *           `aclint_mswi_cold_init()` / `aclint_mtimer_cold_init()`；两个驱动内部会
 *           `sbi_ipi_set_device()` / `sbi_timer_set_device()`（已逐行核实）。
 *           ⇒ ipi_send / ipi_clear / timer_value / timer_event_* 这些字段在 1.6 里**不存在**，
 *             一个字都不用我们写。
 *     ★ ACLINT 把 CLINT 拆成两段（`include/sbi_utils/{ipi/aclint_mswi,timer/aclint_mtimer}.h`）：
 *         MSWI   : CLINT + 0x0000（`CLINT_MSWI_OFFSET`），size 0x4000；
 *         MTIMER : mtimecmp = CLINT + 0x4000（`CLINT_MTIMER_OFFSET`）+ 0x0000，
 *                  mtime    = CLINT + 0x4000 + 0x7ff8（`ACLINT_DEFAULT_MTIME_OFFSET`）
 *                           = CLINT + 0xBFF8。
 *       这正是 SiFive CLINT 的标准布局，**与我们 SoC 的 TilelinkClint 逐笔对上**
 *       （`rtl/NaxSocMini.v` 的 `module TilelinkClint`：`16'h0000`=msip、
 *        `16'h4000/16'h4004`=mtimecmp 低/高、`16'hbff8/16'hbffc`=mtime 低/高）
 *       ⇒ 硬件地址契约不变，只是软件侧换了个驱动。
 *       mtime_freq 取 100MHz（= DTS 的 timebase-frequency = soc_clk）。
 *
 *  3) **system_reset 字段没了**：v0.8 里我们那个 `nax_system_reset(){return 0;}`（本 SoC 没有
 *     复位控制器）在 1.6 里**直接删掉**即可 —— 1.6 的复位是 `sbi_system_reset` 设备模型，
 *     平台什么都不注册就等于"没有复位设备"，语义与老版一致（不会凭空多出复位能力）。
 *
 *  4) **struct sbi_platform 字段变了**（`include/sbi/sbi_platform.h`，逐字核对）：
 *     · `name` 从 `const char *` 变成 **`char name[64]`**（`.name = "NaxRiscv"` 照样能初始化）；
 *     · **新增必填 `.heap_size`**：0 会让 `sbi_heap_init()` 直接返回 EINVAL ⇒ `sbi_hart_hang()`
 *       （`lib/sbi/sbi_heap.c` 里 `if (!scratch->fw_heap_size || …) return SBI_EINVAL;`）。
 *       取官方宏 `SBI_PLATFORM_DEFAULT_HEAP_SIZE(1)` = 0x8000+0x1000 = 36KB（= template 的取法）；
 *     · `hart_stack_size` 用 `SBI_PLATFORM_DEFAULT_HART_STACK_SIZE`（1.6 版 = 8192，老版是 4096）；
 *     · `features` 只有 `SBI_PLATFORM_HAS_MFAULTS_DELEGATION` 这一位了（老版的
 *       `SBI_PLATFORM_HAS_TIMER_VALUE` 已删除）⇒ 直接用 `SBI_PLATFORM_DEFAULT_FEATURES`；
 *     · `hart_index2id` 留 NULL = 恒等映射（hart_index = hart_id，hart_count=1 时无歧义）；
 *     · PMP 不再由平台数（老版有 `pmp_region_count/pmp_region_*`），1.6 由 domain 机制自算。
 *
 *  5) **构建方式变了**（不是在 C 里，但不写下来会被下一个版本坑）：1.6 每个平台目录必须带
 *     `Kconfig`（声明 `PLATFORM_xxx` 并 select 驱动）+ `configs/defconfig`（可以为空）+ `objects.mk`；
 *     老的 `config.mk` 已**不再被 Makefile 自动 include**（见 `objects.mk` 里的说明）。
 * ===========================================================================
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_const.h>
#include <sbi/sbi_platform.h>
#include <sbi_utils/ipi/aclint_mswi.h>
#include <sbi_utils/serial/uart8250.h>
#include <sbi_utils/timer/aclint_mtimer.h>

/* clang-format off */

#define NAX_HART_COUNT			1
#define NAX_HART_STACK_SIZE		SBI_PLATFORM_DEFAULT_HART_STACK_SIZE
#define NAX_HEAP_SIZE			SBI_PLATFORM_DEFAULT_HEAP_SIZE(NAX_HART_COUNT)

/* 外设基址（与 scripts/check_addr_map.py 的台账一致） */
#define NAX_CONSOLE_BASE	0xF0001000	/* ns16550a, reg-shift=2 */
#define NAX_CONSOLE_FREQ	100000000	/* soc_clk 名义 100MHz */
#define NAX_CONSOLE_BAUD	115200
#define NAX_CONSOLE_SHIFT	2
#define NAX_CONSOLE_WIDTH	1		/* 8 位寄存器（见 Uart16550.scala 的 addr(4,2)） */
#define NAX_CONSOLE_OFFSET	0		/* 1.6 新增参数：寄存器窗相对 base 的偏移 */

#define NAX_CLINT_ADDR		0xF0010000
#define NAX_MTIME_FREQ		100000000	/* = DTS timebase-frequency = soc_clk */

/* ACLINT 拆分（与 TilelinkClint 的寄存器布局逐笔对应）*/
#define NAX_ACLINT_MSWI_ADDR	(NAX_CLINT_ADDR + CLINT_MSWI_OFFSET)	/* +0x0000 */
#define NAX_ACLINT_MTIMER_ADDR	(NAX_CLINT_ADDR + CLINT_MTIMER_OFFSET)	/* +0x4000 */

/* clang-format on */

static struct aclint_mswi_data mswi = {
	.addr		= NAX_ACLINT_MSWI_ADDR,
	.size		= ACLINT_MSWI_SIZE,
	.first_hartid	= 0,
	.hart_count	= NAX_HART_COUNT,
};

static struct aclint_mtimer_data mtimer = {
	.mtime_freq	= NAX_MTIME_FREQ,
	.mtime_addr	= NAX_ACLINT_MTIMER_ADDR + ACLINT_DEFAULT_MTIME_OFFSET,
	.mtime_size	= ACLINT_DEFAULT_MTIME_SIZE,
	.mtimecmp_addr	= NAX_ACLINT_MTIMER_ADDR + ACLINT_DEFAULT_MTIMECMP_OFFSET,
	.mtimecmp_size	= ACLINT_DEFAULT_MTIMECMP_SIZE,
	.first_hartid	= 0,
	.hart_count	= NAX_HART_COUNT,
	.has_64bit_mmio	= true,	/* NaxRiscv 的 CLINT 支持 64 位 MMIO（unburstify）*/
};

static int nax_early_init(bool cold_boot)
{
	if (!cold_boot)
		return 0;

	/* 真 16550：驱动内部会 sbi_console_set_device()（= 老版 console_init 的职责）*/
	return uart8250_init(NAX_CONSOLE_BASE, NAX_CONSOLE_FREQ, NAX_CONSOLE_BAUD,
			     NAX_CONSOLE_SHIFT, NAX_CONSOLE_WIDTH,
			     NAX_CONSOLE_OFFSET);
}

static int nax_final_init(bool cold_boot)
{
	return 0;
}

static int nax_irqchip_init(void)
{
	/* 本 SoC 的 PLIC 由 Linux 驱动配；OpenSBI 不注册任何 irqchip（老版同义）*/
	return 0;
}

static int nax_ipi_init(void)
{
	/* 驱动内部 sbi_ipi_set_device()；老版的 clint_cold_ipi_init/warm 已合并到这里 */
	return aclint_mswi_cold_init(&mswi);
}

static int nax_timer_init(void)
{
	/* 驱动内部 sbi_timer_set_device()；第二个参数 reference=NULL（无 time delta 参考）*/
	return aclint_mtimer_cold_init(&mtimer, NULL);
}

const struct sbi_platform_operations platform_ops = {
	.early_init		= nax_early_init,
	.final_init		= nax_final_init,
	.irqchip_init		= nax_irqchip_init,
	.ipi_init		= nax_ipi_init,
	.timer_init		= nax_timer_init
};

const struct sbi_platform platform = {
	.opensbi_version	= OPENSBI_VERSION,
	.platform_version	= SBI_PLATFORM_VERSION(0x0, 0x01),
	.name			= "NaxRiscv",
	.features		= SBI_PLATFORM_DEFAULT_FEATURES,
	.hart_count		= NAX_HART_COUNT,
	.hart_stack_size	= NAX_HART_STACK_SIZE,
	.heap_size		= NAX_HEAP_SIZE,
	.platform_ops_addr	= (unsigned long)&platform_ops
};
