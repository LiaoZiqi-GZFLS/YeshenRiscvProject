# probe_console_pack.S -- Task 8 Step B 诊断探针 E2：**8 字节全部走 I$ 前两条 64B 行**
#
# 动机（实测，见 sim/reglogs/t8_stepA2_imm.log / t8_stepA_imm_full.log）：
#   `probe_console_imm.S` 的 8 个块共 ~200 字节，跨 3 条 64B 行（line0/line1/line2）。
#   核执行到 **第 5 个字节的轮询循环（0x80000080 = line2 的第一个字节）** 时前端跑飞：
#   fetchPC 出现 0x80000080 → 0x80000086 → 0x8000008E → 0x80000096（**全都不是指令边界**），
#   随后核在 PC=0x80000096 上执行出一条**按 2 字节错位解出来的垃圾指令**
#   `lb x0, 0x7F1(t1)`（= 镜像里 0x96 处的窗口 `0x7F130003`）⇒ 访问 0xF000_1805，
#   与 pBus 上实测到的最后几笔 AR（0xF0001304/0xF0001304/0xF0001805）**逐字节吻合**。
#
# 本探针把"8 个块"压成"1 个块 + 循环"，使**全部代码落在 line0/line1（<128B）**：
#   判据与正式探针完全相同（线上解出 "NAXMINI\n"，8 帧），只是字符来源换成一条 64bit 立即数
#   常数（"NAXMINI\n" 小端打包 = 0x0A494E494D58414E），循环里 `srli` 逐字节右移。
#   ⇒ 若它能过、而 imm 版只能出 4 帧，则"卡点 = 第 3 条 I$ 行"这条因果就坐实了。
#
# 跑法：SOC_PROG=sim/probe_console_pack.bin ./obj_dir_pbus/naxmini
    .section .text.start, "ax"
    .globl _start
_start:
    li   t0, 0xF0001
    slli t0, t0, 12          # t0 = THR = 0xF000_1000
    li   t1, 0xF0001
    slli t1, t1, 12
    addi t1, t1, 0x14        # t1 = LSR = 0xF000_1014

    li   t2, 0x80
    sw   t2, 0x0C(t0)        # LCR: DLAB=1
    li   t2, 54
    sw   t2, 0x00(t0)        # DLL = 54
    sw   zero, 0x04(t0)      # DLM = 0
    li   t2, 3
    sw   t2, 0x0C(t0)        # LCR: 8N1、DLAB=0

    li   t4, 0x4D58414E      # 低 32bit = 'N','A','X','M'
    li   t5, 0x0A494E49      # 高 32bit = 'I','N','I','\n'
    slli t5, t5, 32
    or   t4, t4, t5          # t4 = 0x0A49_4E49_4D58_414E
    li   t6, 8               # 8 个字节
1:  lw   t5, 0(t1)           # 轮询 LSR
    andi t5, t5, 0x20        # THRE
    beqz t5, 1b
    sb   t4, 0(t0)           # 写 THR（低字节）
    srli t4, t4, 8
    addi t6, t6, -1
    bnez t6, 1b
2:  j    2b
    .size _start, .-_start
