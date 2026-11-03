// gpu_regs.vh —— GPU 寄存器偏移与命令 op 的**唯一来源**。
// C 侧镜像：YeshenGui/platform/gpu_regs.h（逐字对应；改这里必须同步改那边，有闸门脚本核对）。
// 规格：docs/superpowers/specs/2026-10-30-simple-gpu-design.md §4.1/§4.2

// ---- CSR 窗内偏移（窗基址 0xF000_5000，掩码 0xFFFF_F000）----
`define GPU_ID          12'h000   // RO  magic 0x59475055("YGPU") | version | caps
`define GPU_STATUS      12'h004   // RO  [0]busy [7:4]fifo_used [8]err [15:8]errcode [16]flip_pending [17]flip_toggle
`define GPU_IRQ_EN      12'h008   // RW  v1 恒 0（不接 PLIC）
`define GPU_IRQ_CLR     12'h00C   // WO
`define GPU_CMD_DATA    12'h010   // WO  推一个命令字（不触发）
`define GPU_CMD_PUSH    12'h014   // WO  推最后一个字并触发
`define GPU_SEQ_DONE    12'h018   // RO  已完成命令序号（16 位）
`define GPU_FIFO_FREE   12'h01C   // RO  空闲项数
`define GPU_SCISSOR0    12'h020   // RW  {x0[15:0], y0[15:0]}（低 16 位 = x0）
`define GPU_SCISSOR1    12'h024   // RW  {x1[15:0], y1[15:0]}（右下开区间）
`define GPU_FLIP        12'h028   // RW  写 1 请求下一帧起点切 bank；读回 pending
`define GPU_DBG         12'h02C   // RO  [15:0] 最近 op | [31:16] 最近耗时（周期/256）

`define GPU_ID_MAGIC    32'h5947_5055

// ---- 命令 op（命令字 = {op[7:0], nwords[7:0], flags[15:0]}）----
`define OP_NOP          8'h01
`define OP_FILL         8'h02
`define OP_BLIT         8'h03
`define OP_GLYPH        8'h04
`define OP_ROUND_FILL   8'h05
`define OP_SET_SCISSOR  8'h06
`define OP_FENCE        8'h07
`define OP_CLEAR3D      8'h10
`define OP_DRAW_TRIS    8'h11
`define OP_COMPOSITE3D  8'h12

// ---- 固定 DDR 布局（v1 不做可编程基址）----
`define GPU_GUI_BANK1   32'h9220_0000   // GUI 后备帧存（GUI 读窗 +2 MiB 内）
`define GPU_COLOR3D     32'h9300_0000   // 3D 颜色缓冲 640x480 RGB565（P2a）
`define GPU_Z3D         32'h9310_0000   // 3D 深度缓冲 640x480 U16（P2a）
`define GPU_ARENA       32'h9320_0000   // 顶点/动态缓冲 arena（1 MiB）
