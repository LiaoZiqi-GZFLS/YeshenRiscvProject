# probe_console_imm.S -- Task 8 / V1 的**证据版**探针（最小指令面，判据与 probe_console.S 完全相同）
#
# 为什么需要它（Task 8 实测，2026-09-29）：
#   `sim/probe_console.S`（字符来自内存常量串 + `lbu` 逐字节取）跑到第 1 个字节就卡在
#   "紧跟 MMIO 写之后的一次 D$ 读"上（见那个文件头）。为了把**16550/pBus 通路**与
#   **核侧 D$/取指问题**分开，这里把字符改成**单条小立即数 `li` 直接装载**（不碰 DRAM、
#   不用大立即数、不用移位、不用循环计数器），循环体只剩
#   `lw LSR / andi / beqz / sb THR` 四种指令。
#
# 实测结果（`sim/reglogs/t8_diag_p3_unroll.log`，装置同 tb_naxmini.cpp）：
#   * 解出 **4 个逐字节正确**的帧：`N`(0x4E) `A`(0x41) `X`(0x58) `M`(0x4D)，
#     位周期自证 `min_low=min_high=864`（= 16*54）分毫不差；
#   * 期间 **1760 笔 LSR 读**全部被核取走，返回值逐笔正确（TX 空闲 0x60 / 发送中 0x00）；
#   * 第 5 个字节的轮询循环里核走进异常：`exceptionPort code=0`
#     (= INSTRUCTION_ADDRESS_MISALIGNED) `epc=0x80000096`（非指令边界），
#     而 `mtvec` 从未设置（复位值 0）+ 地址 0 不在内存 region ⇒ 核陷进无限陷阱循环而死。
#   ⇒ **16550 经 pBus 可达（V1 = 是）**；卡点是核侧取指/异常路径，不是外设。
#
# 已知的核侧症状（其它变体的对照，均见 sim/reglogs/）：
#   * 插入 64 字节 NOP 把 8 个块整体后移一行 ⇒ 变成解出 **5 个**字节后同样异常退出
#     （`t8_diag_p4_pad64.log`）⇒ 卡点随代码布局漂移，不随"第几个字节"固定；
#   * 用 `fence.i`(0x0000100F) 做前端序列化 ⇒ 直接被译成 ECALL（`code=9`）⇒ 不可用；
#   * `probe_console.S`（字符走内存）⇒ 第 1 个字节后卡在 D$ 读（`t8_pos_console.log`）。
#
# 编/跑法（与正式探针同一条流水线，只换 bin）：
#   riscv64-unknown-elf-as  -march=rv64imac_zicsr -mabi=lp64 -o /tmp/pci.o sim/probe_console_imm.S
#   riscv64-unknown-elf-ld  -T sim/probe_memmark.ld -o /tmp/pci.elf /tmp/pci.o
#   riscv64-unknown-elf-objcopy -O binary /tmp/pci.elf sim/probe_console_imm.bin
#   SOC_PROG=sim/probe_console_imm.bin ./obj_dir_naxmini/naxmini
    .section .text.start, "ax"
    .globl _start
    .macro POLL
3:  lw   t5, 0(t1)
    andi t5, t5, 0x20
    beqz t5, 3b
    .endm
_start:
    li   t0, 0xF0001
    slli t0, t0, 12          # t0 = THR = 0xF000_1000
    li   t1, 0xF0001
    slli t1, t1, 12
    addi t1, t1, 0x14        # t1 = LSR = 0xF000_1014
    li   t2, 0x80
    sw   t2, 0x0C(t0)        # LCR: DLAB=1
    li   t2, 54
    sw   t2, 0x00(t0)        # DLL = 54 ⇒ 位周期 16*54 = 864 拍
    sw   zero, 0x04(t0)      # DLM = 0
    li   t2, 3
    sw   t2, 0x0C(t0)        # LCR: 8N1、DLAB=0

    li   t4, 0x4E            # 'N'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x41            # 'A'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x58            # 'X'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x4D            # 'M'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x49            # 'I'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x4E            # 'N'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x49            # 'I'
    POLL
    sb   t4, 0(t0)
    li   t4, 0x0A            # '\n'
    POLL
    sb   t4, 0(t0)
1:  j    1b
