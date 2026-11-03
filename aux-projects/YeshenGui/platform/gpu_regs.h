/* gpu_regs.h —— GPU 寄存器偏移与命令 op 的 C 侧镜像。
 * 唯一来源：VexiiYeshenLinux/rtl/gpu/gpu_regs.vh（改那边必须同步改这里；
 * 闸门 sim/gpu/check_gpu_regs.py 会逐项核对）。 */
#ifndef YESHEN_GPU_REGS_H
#define YESHEN_GPU_REGS_H

/* ---- CSR 窗内偏移（窗基址 0xF000_5000，掩码 0xFFFF_F000）---- */
#define GPU_ID          0x000
#define GPU_STATUS      0x004
#define GPU_IRQ_EN      0x008
#define GPU_IRQ_CLR     0x00C
#define GPU_CMD_DATA    0x010
#define GPU_CMD_PUSH    0x014
#define GPU_SEQ_DONE    0x018
#define GPU_FIFO_FREE   0x01C
#define GPU_SCISSOR0    0x020
#define GPU_SCISSOR1    0x024
#define GPU_FLIP        0x028
#define GPU_DBG         0x02C

#define GPU_ID_MAGIC    0x59475055u

/* ---- 命令 op ---- */
#define OP_NOP          0x01
#define OP_FILL         0x02
#define OP_BLIT         0x03
#define OP_GLYPH        0x04
#define OP_ROUND_FILL   0x05
#define OP_SET_SCISSOR  0x06
#define OP_FENCE        0x07
/* ---- P2a 3D ---- */
#define OP_CLEAR3D      0x10
#define OP_DRAW_TRIS    0x11
#define OP_COMPOSITE3D  0x12

/* ---- 固定 DDR 布局（2026-11-03：随内存 carve 搬到 DDR 顶端 0xBC00_0000..0xC000_0000）---- */
#define GPU_COLOR3D     0xBF000000u
#define GPU_Z3D         0xBF100000u
#define GPU_3D_W        640
#define GPU_3D_H        480

#endif /* YESHEN_GPU_REGS_H */
