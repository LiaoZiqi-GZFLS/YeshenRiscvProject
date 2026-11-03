# probe_t21_plic.S -- Task 21 ①：PLIC 路径**装置级**验证（裸机探针）
#
# 背景（承重）：T20 只验了 CLINT（OpenSBI 到 banner）。PLIC（0xF0C0_0000）在网表里
#   **没有**被任何走通的镜像访问过 —— 我们平台 `sw/opensbi-platform/platform.c` 的
#   `nax_irqchip_init()` 是 `return 0`（OpenSBI 不碰 PLIC，平台侧没有 irqchip 驱动），
#   所以"OpenSBI 路径"在本设计里**根本不存在**。本探针做的是装置级验证。
#
# ★ 本版的关键纪律（v2）：**全部 MMIO 访问都在任何串口打印之前完成**，结果先存寄存器，
#   最后一次性打印。原因：装置的 pBus/核侧逐笔台账有"前 20000 笔"的实时打印上限，而
#   串口每打一个字符要轮询 LSR ~600 次（= 1200 笔 pBus 事件）⇒ 只要先打印，后面的
#   PLIC 访问就掉出台账窗口。MMIO 先行 ⇒ 台账**完整覆盖**每一笔 PLIC/CLINT 访问。
#
# Part A：PLIC 寄存器台账（写-回读对账）—— 证明这是**真的寄存器文件**而不是"译码命中"：
#   prio1  0xF0C0_0004  读初值 / 写 3 回读 / 写 1 回读     （priorityWidth=2 ⇒ 2bit 字段）
#   enable 0xF0C0_2000  ctx0（hart0 M 态）bit1 = 源 1      读初值 / 写 2 回读
#   thresh 0xF0E0_0000  ctx0                               读初值 / 写 3 回读
#   claim  0xF0E0_0004  ctx0                               读（无 pending ⇒ 期望 0）
#   pend   0xF0C0_1000                                     读（IER=0 ⇒ 期望 0）
# Part B：**中断投递**端到端（更强的一条）——
#   console IRQ（NaxMiniGlue.CONSOLE_IRQ_BIT=1）→ PLIC 源 1 → PLIC target0 → 核 MEIP。
#   打开 16550 的 IER.bit1（THRE 中断）⇒ 源 1 电平拉高 ⇒ PLIC pending ⇒ 核取外部中断
#   （mcause=0x8000_0000_0000_000B）⇒ 处理程序**读 claim 拿到源号 1** ⇒ 写回 claim 完成。
#
# 每个结果寄存器**先填哨兵 0xDEADBEEF**：若那条 load 被陷入跳过，打印出来的就是哨兵
#   （= 该访问真的错了），不会拿上一条的残值冒充。
#
# 跑法（必须 64bit 装置；BUS_BYTES=8）：
#   SOC_EXPECT='T21PLIC END' SOC_PROG='sim/probe_t21_plic.bin@0x80000000' \
#     SOC_MAX_CYC=20000000 TB_PBUS_TRACE=1 ./obj_dir_t21light/naxmini
#   （台账在日志的 [PBUS] / [CORE-PBUS-A] 两段；后者是**核侧** A 通道逐笔）

    .section .text.start, "ax"
    .globl _start
_start:
    li   sp, 0x80010000          # 装置不设 sp：自己给一段（DRAM 内、探针镜像之外）
    # ---- 16550 初始化（DLL=54 ⇒ P=16*54=864，与 tb 解码器同源）----
    li   t0, 0xF0001000
    li   t1, 0x80
    sw   t1, 0x0C(t0)            # LCR: DLAB=1
    li   t1, 54
    sw   t1, 0x00(t0)            # DLL = 54
    sw   zero, 0x04(t0)          # DLM = 0
    li   t1, 3
    sw   t1, 0x0C(t0)            # LCR: 8N1 / DLAB=0

    la   t1, trap_handler
    csrw mtvec, t1
    li   s0, 0                   # 最近一次 mcause
    li   s1, 0                   # 最近一次 mtval
    li   s2, 0                   # 最近一次 mepc
    li   s3, 0                   # 外部中断次数
    li   s4, 0                   # claim 读回值
    li   s5, 0                   # 非中断异常次数
    li   s6,  0xDEADBEEF
    li   s7,  0xDEADBEEF
    li   s8,  0xDEADBEEF
    li   s9,  0xDEADBEEF
    li   s10, 0xDEADBEEF
    li   s11, 0xDEADBEEF
    li   a2,  0xDEADBEEF
    li   a3,  0xDEADBEEF
    li   a4,  0xDEADBEEF
    li   a5,  0xDEADBEEF

    # ================= Part A：PLIC 寄存器（全部在打印之前）=================
    li   t0, 0xF0C00004          # prio[1]
    lw   s6, 0(t0)               # p1r0
    li   t1, 3
    sw   t1, 0(t0)
    lw   s7, 0(t0)               # p1w3r
    li   t1, 1
    sw   t1, 0(t0)
    lw   s8, 0(t0)               # p1w1r

    li   t0, 0xF0C02000          # enable ctx0
    lw   s9, 0(t0)               # enr0
    li   t1, 2                   # bit1 = 源 1
    sw   t1, 0(t0)
    lw   s10, 0(t0)              # enw2r

    li   t0, 0xF0E00000          # threshold ctx0
    lw   s11, 0(t0)              # thr0
    li   t1, 3
    sw   t1, 0(t0)
    lw   a2, 0(t0)               # thw3r

    li   t0, 0xF0E00004          # claim ctx0（此刻无源使能 ⇒ 期望 0）
    lw   a3, 0(t0)               # clm0

    li   t0, 0xF0C01000          # pending
    lw   a4, 0(t0)               # pnd0

    # ================= Part B：中断投递 + claim（也在打印之前）=================
    #   ⚠️ 16550 的寄存器号 = addr[4:2]（reg-shift=2、4 字节步距）：
    #      THR/DLL=+0x00  IER/DLM=+0x04  IIR=+0x08  LCR=+0x0C  MCR=+0x10  LSR=+0x14
    #      ⇒ **IER 在 0xF000_1004**（不是 +0x10；+0x10 是 MCR）。v1 探针在这里写错过一次，
    #        症状 = pending 恒 0、中断永远不来（本轮已修，并把 IIR/LSR 也读回来留证）。
    #   先给**全部源**（id 0..30，地址 0xF0C0_0000+4*i）写优先级 3、把 ctx0 的 enable 全开 ⇒
    #   不依赖"console 到底挂哪个 id"这一假设，claim 读回什么 id 就是什么 id。
    li   t3, 0xF0C00000
    li   t4, 31
    li   t1, 3
3:  sw   t1, 0(t3)
    addi t3, t3, 4
    addi t4, t4, -1
    bnez t4, 3b
    li   t0, 0xF0C02000
    li   t1, -1
    sw   t1, 0(t0)               # enable ctx0 = 全 1（32 个源）
    li   t0, 0xF0E00000
    sw   zero, 0(t0)             # threshold ctx0 = 0（3 > 0 ⇒ 可投递）
    li   t0, 0xF0001004
    li   t1, 2
    sw   t1, 0(t0)               # 16550 IER.bit1 = THRE 中断使能 ⇒ console IRQ 拉高
    li   t0, 0xF0001014
    lw   a6, 0(t0)               # LSR（+0x14）
    li   t0, 0xF0001008
    lw   a7, 0(t0)               # IIR（+0x08）：[0]=0 表示"有中断挂起"
    li   t0, 0xF0C01000
    lw   a5, 0(t0)               # pnd1（期望非 0：某一位 = console 那个源）

    li   t1, 0x800
    csrs mie, t1                 # MEIE = bit11
    li   t1, 0x8
    csrs mstatus, t1             # mstatus.MIE

    li   t2, 200000              # 有界等待（中断不来也要能收尾）
1:  bnez s3, 2f
    addi t2, t2, -1
    bnez t2, 1b
2:  li   t1, 0x8
    csrc mstatus, t1             # 关中断
    li   t0, 0xF0001004
    sw   zero, 0(t0)             # IER=0 ⇒ console IRQ 拉低（去断言）
    addi sp, sp, -16             # 借 0(sp) 存 pnd2（打印助手只往 sp 以下压栈，不会踩）
    li   t0, 0xF0C01000
    lw   t1, 0(t0)
    sd   t1, 0(sp)               # pnd2（claim 完成 + 源拉低之后 ⇒ 期望 0）

    # ================= 打印（此后才有串口轮询）=================
    la   a0, m_hdr
    call puts
    mv   a1, s6
    la   a0, l_p1r0
    call show
    mv   a1, s7
    la   a0, l_p1w3r
    call show
    mv   a1, s8
    la   a0, l_p1w1r
    call show
    mv   a1, s9
    la   a0, l_enr0
    call show
    mv   a1, s10
    la   a0, l_enw2r
    call show
    mv   a1, s11
    la   a0, l_thr0
    call show
    mv   a1, a2
    la   a0, l_thw3r
    call show
    mv   a1, a3
    la   a0, l_clm0
    call show
    mv   a1, a4
    la   a0, l_pnd0
    call show
    la   a0, m_irq
    call puts
    mv   a1, a5
    la   a0, l_pnd1
    call show
    mv   a1, a6
    la   a0, l_lsr1
    call show
    mv   a1, a7
    la   a0, l_iir1
    call show
    mv   a1, s3
    la   a0, l_extn
    call show
    mv   a1, s0
    la   a0, l_extc
    call show
    mv   a1, s4
    la   a0, l_clm1
    call show
    ld   a1, 0(sp)
    la   a0, l_pnd2
    call show
    mv   a1, s5
    la   a0, l_exc
    call show
    mv   a1, s1
    la   a0, l_tval
    call show
    mv   a1, s2
    la   a0, l_epc
    call show
    la   a0, m_end
    call puts
3:  j    3b

# ---------------------------------------------------------------------------
# 陷入处理：只记不打印（保持栈无关）
#   mcause MSB=1 ⇒ 中断：读 claim / 写 claim 完成 / 先给源去断言
#   否则 ⇒ 异常：跳过本条（探针全部 4 字节指令），记 cause/tval/epc
# ---------------------------------------------------------------------------
    .align 4
trap_handler:
    csrr s0, mcause
    csrr s1, mtval
    csrr s2, mepc
    blt  s0, zero, 9f
    addi s2, s2, 4
    csrw mepc, s2
    addi s5, s5, 1
    mret
9:  li   t0, 0xF0001004
    sw   zero, 0(t0)             # ★ 先给源去断言（IER=0；+0x04 才是 IER）
    li   t0, 0xF0E00004
    lw   s4, 0(t0)               # claim ⇒ 期望 = console 那个源 id
    sw   s4, 0(t0)               # complete（写回 claim 值）
    addi s3, s3, 1
    li   t1, 8                   # 保险丝：万一源没被拉低，别把整轮跑成中断风暴
    blt  s3, t1, 8f
    li   t0, 0xF0C02000
    sw   zero, 0(t0)             # 关掉 ctx0 的全部 enable
8:  mret

# ---------------------------------------------------------------------------
# 输出助手（只用 t0..t6 / a0 / a1）
# ---------------------------------------------------------------------------
putc:                            # a0 = 字符
    li   t2, 0xF0001014
1:  lw   t3, 0(t2)
    andi t3, t3, 0x20
    beqz t3, 1b
    li   t2, 0xF0001000
    sw   a0, 0(t2)
    ret

puts:                            # a0 = 以 0 结尾的串
    mv   t0, a0
1:  lbu  t1, 0(t0)
    beqz t1, 2f
    mv   a0, t1
    addi sp, sp, -16
    sd   ra, 0(sp)
    call putc
    ld   ra, 0(sp)
    addi sp, sp, 16
    addi t0, t0, 1
    j    1b
2:  ret

puthex32:                        # a0 = 值 ⇒ 8 个十六进制字符
    mv   t4, a0
    li   t5, 8
1:  srli t6, t4, 28
    andi t6, t6, 0xF
    li   t2, 10
    blt  t6, t2, 2f
    addi t6, t6, 0x57            # 'a' - 10
    j    3f
2:  addi t6, t6, 0x30            # '0'
3:  addi sp, sp, -16
    sd   ra, 8(sp)
    sd   t4, 0(sp)
    mv   a0, t6
    call putc
    ld   t4, 0(sp)
    ld   ra, 8(sp)
    addi sp, sp, 16
    slli t4, t4, 4
    addi t5, t5, -1
    bnez t5, 1b
    ret

show:                            # a0 = 标签串，a1 = 值 ⇒ "<label>=0x<hex>\n"
    addi sp, sp, -32
    sd   ra, 24(sp)
    sd   a1, 16(sp)
    call puts
    la   t0, s_eq
    mv   a0, t0
    call puts
    ld   a0, 16(sp)
    call puthex32
    la   a0, s_nl
    call puts
    ld   ra, 24(sp)
    addi sp, sp, 32
    ret

# ---------------------------------------------------------------------------
    .align 3
m_hdr:  .asciz "T21 PLIC PROBE\n"
m_irq:  .asciz "-- irq test --\n"
m_end:  .asciz "T21PLIC END\n"
s_eq:   .asciz "=0x"
s_nl:   .asciz "\n"
l_p1r0: .asciz "p1r0"
l_p1w3r:.asciz "p1w3r"
l_p1w1r:.asciz "p1w1r"
l_enr0: .asciz "enr0"
l_enw2r:.asciz "enw2r"
l_thr0: .asciz "thr0"
l_thw3r:.asciz "thw3r"
l_clm0: .asciz "clm0"
l_pnd0: .asciz "pnd0"
l_pnd1: .asciz "pnd1"
l_lsr1: .asciz "lsr1"
l_iir1: .asciz "iir1"
l_pnd2: .asciz "pnd2"
l_extn: .asciz "extn"
l_extc: .asciz "extc"
l_clm1: .asciz "clm1"
l_exc:  .asciz "exc"
l_tval: .asciz "tval"
l_epc:  .asciz "epc"
    .size _start, .-_start
