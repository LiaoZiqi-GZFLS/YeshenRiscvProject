# probe_console.S -- Task 8 / V1 探针：16550 到底能不能被 CPU 访问到（**正式探针**）
#
# 判据（由 sim/tb_naxmini.cpp 从**串口线上**解码，不看任何 tb 内部记账）：
#   在 uart_txd 上解出 "NAXMINI\n" ⇒ console="NAXMINI"（线上 8 帧 = 7 字母 + LF）。
#
# 做法：依次往 ns16550a 的 THR 写 "NAXMINI\n"，**每字节写前轮询 LSR 的 THRE(bit5)**。
#   这是 OpenSBI `uart8250_putc` 的同一条路径（`lib/utils/serial/uart8250.c`），
#   所以它同时验：① 外设窗口经 fabric 走到了 pBus；② 我们的胶合块解码正确；③ 16550 的
#   读（LSR）与写（THR）双向都通；④ TX 移位器真的把字节按 8N1 推到了线上。
#
# ---------------------------------------------------------------------------
# ⚠️ 实测结论（2026-09-29，Task 8）——**本探针只跑到第 1 个字节就卡住，且卡点不在 16550**：
#
#   `sim/reglogs/t8_pos_console.log`：'N' 被**逐位正确**解出（`frame=1 byte=0x4E 'N'`，
#   `min_low=min_high=864` = 位周期 16*54 分毫不差），随后 CPU 停在紧跟 `sb THR` 的那条
#   `lbu t4,0(t3)`（D$ 读**正在执行的代码行**那一行）上，一拍也不动了（AXI/MMIO 全静默）。
#
#   把"从内存取字符"换成"用小立即数直接装载"（见 `sim/probe_console_imm.S`，判据完全相同）
#   之后，同一装置能连续解出 **4 个逐字节正确**的帧（`NAXM`），再往后 CPU 走进一条
#   **异常路径**：`DecoderPlugin.setup.exceptionPort` 报 `code=0`
#   （= `INSTRUCTION_ADDRESS_MISALIGNED`）`epc=0x80000096`——一个**非指令边界**的地址；
#   由于本探针**没设过 `mtvec`（复位值 0）**、而地址 0 不在本 SoC 的内存 region 里
#   （region 只有 `0x8000_0000+512MB`），核随即陷进"取 0 号地址"的**无限陷阱循环**而死。
#
#   ⇒ 这两个卡点都是**核侧/取指侧**的问题，与 16550、pBus 解码、外设 region 声明**无关**：
#     证据 = LSR 读回值逐笔正确（空闲 0x60 / 发送中 0x00，共 1760 笔全部被核取走）、
#     4 笔 THR 写全部正确落到线上。**V1 的答案是"可达"**（详见 `docs/探针记录.md` M0-a2 行）。
#
#   本文件保持 spec/plan 的原始写法（字符来自内存常量串、轮询 THRE），作为**忠实实现**；
#   `sim/probe_console_imm.S` 是同一判据下的**证据版**（最小指令面，走得更远）。
# ---------------------------------------------------------------------------
#
# 寄存器偏移（以 `src/peripheral/Uart16550.scala` 为准，`switch(awaddr(4,2))`）：
#   reg 0 = RBR/THR/DLL  ⇒ 字节偏移 0x00     reg 3 = LCR       ⇒ 0x0C
#   reg 1 = IER/DLM      ⇒ 0x04               reg 5 = LSR       ⇒ 0x14  ← THRE 在 bit5
#   即 YeshenCore DTS 声明的 `reg-shift=2`（每寄存器 4 字节）。**0x14 就是 LSR**，不是 0x50。
#
# 数据标记安全：本探针**只写 MMIO（0xF000_1000）**，一字节 DRAM 都不写 ⇒ 天然不会出现
#   "数据落在正在执行的代码行上"那个坑（sim/probe_memmark.S 文件头记的就是它）。
#   常量串放在 `.text.start` 段内（链接脚本 sim/probe_memmark.ld 把该段定在 0x8000_0000），
#   `la` 取到的是只读地址 ⇒ 代码与常量都在 0x8000_0000 段。
#
# 波特率：显式配 bdiv=54（100MHz 下 115200，与 NaxMiniGlue 的 uartLoader 同档）
#   ⇒ 位周期 = 16*bdiv = 864 拍（tb 的解码器 P 必须取同一个数）。
#   ⚠️ 不配的话 bdiv=0，RTL 会退化成"每 4 拍一位"（`Uart16550.scala` 的 rxTickDiv=0），
#     那虽然也能出字符，但**偏离真实运行点**，且验证不到 DLL/DLM 通路。
#
# 编法（WSL）：
#   riscv64-unknown-elf-as  -march=rv64imac_zicsr -mabi=lp64 -o /tmp/pc.o sim/probe_console.S
#   riscv64-unknown-elf-ld  -T sim/probe_memmark.ld -o /tmp/pc.elf /tmp/pc.o
#   riscv64-unknown-elf-objcopy -O binary /tmp/pc.elf sim/probe_console.bin
# 跑法（见 sim/reglogs/t8_pos_console.log / t8_neg_pbusar.log）：
#   SOC_PROG=sim/probe_console.bin ./obj_dir_naxmini/naxmini
    .section .text.start, "ax"
    .globl _start
_start:
    # ---- 地址构造：0xF000_1000 不能直接 `li`（64bit 下 0xF0001000 的符号扩展有歧义，
    #      会变成 0xFFFF_FFFF_F000_1000 ⇒ 外设 region 的 32bit 比较就落空了）。
    #      用 `li 0xF0001` + `slli 12` 保证得到**零扩展**的精确 0xF000_1000。
    li   t0, 0xF0001
    slli t0, t0, 12          # t0 = THR/RBR/DLL  = 0xF000_1000
    li   t1, 0xF0001
    slli t1, t1, 12
    addi t1, t1, 0x14        # t1 = LSR          = 0xF000_1014

    # ---- 配 8N1 + bdiv=54（DLL/DLM 在 DLAB=1 时才可写）----
    li   t2, 0x80            # LCR: DLAB=1
    sw   t2, 0x0C(t0)
    li   t2, 54
    sw   t2, 0x00(t0)        # DLL = 54  ⇒ 位周期 16*54 = 864 拍
    sw   zero, 0x04(t0)      # DLM = 0
    li   t2, 3               # LCR: 8bit / 1 stop / no parity、DLAB=0
    sw   t2, 0x0C(t0)

    # ---- 逐字节：轮询 THRE(bit5) 再写 THR ----
    la   t3, msg
1:  lbu  t4, 0(t3)
    beqz t4, 2f              # .asciz 的 NUL 收尾
3:  lw   t5, 0(t1)           # 读 LSR
    andi t5, t5, 0x20        # THRE
    beqz t5, 3b              # 不等就自旋
    sb   t4, 0(t0)           # 写 THR ⇒ 推一帧 8N1
    addi t3, t3, 1
    j    1b
2:  j    2b                  # 发完停住（tb 收满判据即退出）
    .size _start, .-_start

# 常量串与代码同段（0x8000_0000 起）⇒ 不依赖任何 .rodata 放置
msg: .asciz "NAXMINI\n"
