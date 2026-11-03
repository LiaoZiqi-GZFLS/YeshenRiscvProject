/* gpu.h —— 2D GPU 的命令封装（板端 MMIO / 主机模拟同一套 API）。
 *
 * 唯一来源的寄存器与 op 定义在 gpu_regs.h（镜像 VexiiYeshenLinux/rtl/gpu/gpu_regs.vh）。
 * 命令参数顺序与 `rtl/gpu/gpu_2d.v` 的 S_DEC 逐条对齐（nwords 不含命令头）：
 *   FILL       (7) : dst, stride_px, x, y, w, h, color
 *   ROUND_FILL (8) : dst, stride_px, x, y, w, h, radius, color
 *   SET_SCISSOR(4) : x0, y0, x1, y1        （右下**开**区间）
 *   BLIT      (13) : src, src_stride_px, fmt, sx, sy, w, h, dst, dst_stride_px,
 *                    dx, dy, blend, alpha
 *   GLYPH     (12) : src(A8), src_stride_px, sx, sy, w, h, dst, dst_stride_px,
 *                    dx, dy, fg, alpha
 *   FENCE      (1) : seq
 *
 * 地址是**物理地址**（板端 GPU 直接读写 DDR）；主机侧用 gpu_host_bind() 把物理区
 * 绑到一段可写内存上做同语义模拟（LVGL 预览 / 单元测试用）。
 */
#ifndef YESHEN_GPU_H
#define YESHEN_GPU_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int      present;      /* 1 = 硬件在位（ID == magic） */
    uint32_t ops;          /* 已提交命令数 */
    uint32_t fences;       /* 已完成的 FENCE 数 */
    uint32_t errors;       /* 超时 / 状态错误 */
    uint32_t last_op;      /* DBG[15:0] */
    uint32_t last_cycles;  /* DBG[31:16]（单位：256 周期） */
} gpu_stats_t;

int  gpu_init(void);
void gpu_shutdown(void);
int  gpu_present(void);

int  gpu_fill(uint32_t dst, int stride_px, int x, int y, int w, int h, uint16_t color);
int  gpu_round_fill(uint32_t dst, int stride_px, int x, int y, int w, int h,
                    int radius, uint16_t color);
int  gpu_set_scissor(int x0, int y0, int x1, int y1);
int  gpu_blit(uint32_t src, int src_stride_px, int fmt, int sx, int sy, int w, int h,
              uint32_t dst, int dst_stride_px, int dx, int dy, int blend, int alpha);
int  gpu_glyph(uint32_t src, int src_stride_px, int sx, int sy, int w, int h,
               uint32_t dst, int dst_stride_px, int dx, int dy, uint16_t fg, int alpha);

/* ---- 3D（P2a）----
 * 固定几何：颜色缓冲 GPU_COLOR3D 640×480（stride 640）、Z 缓冲 GPU_Z3D 同尺寸。
 * CLEAR3D(2)       : color, z
 * DRAW_TRIS(8)     : tri_addr(物理), count, w, h, color_base, color_stride, z_base, z_stride
 *                    三角形记录 48 B：w0={v0y,v0x} … w4={zmode,dzdy}
 * COMPOSITE3D(8)   : src_base, src_stride, dst_base, dst_stride, w, h, dst_x, dst_y
 * 约束：DRAW_TRIS 的 w/h 必须是 32 的倍数；COMPOSITE3D 的 w % 64 == 0、dst_x % 4 == 0。
 * 主机（UI_HOST）构建不支持 3D（返回 -1）。 */
int  gpu_clear3d(uint16_t color, uint16_t z);
int  gpu_draw_tris(uint32_t tri_phys, int count);
int  gpu_composite3d(uint32_t dst, int dst_stride_px, int dx, int dy);

/* 推 FENCE 并等到它完成（返回该 seq；<0 = 超时） */
int  gpu_fence(void);
/* 请求下一次读帧起点切 bank，并等 flip_pending 清零（返回 0 / -1 超时） */
int  gpu_flip(void);
/* 只登记 FLIP（不等 vsync）—— UI 每帧末尾用它，避免卡在等帧起点 */
int  gpu_flip_async(void);

/* P0 接缝：把 CPU 写过、GPU 要读的区间刷出 D-cache。
 * 板端在 CPU 支持 Zicbom 时发 cbo.flush；否则 no-op（调用方必须用非缓存映射）。 */
void gpu_mem_sync(const void *p, size_t len);

const gpu_stats_t *gpu_stats(void);

/* ---- 固定物理区 arena（GPU 能直接读的源缓冲）----
 * 板端 = DDR 0xBF20_0000 起的 4 MiB（/dev/mem + O_SYNC ⇒ CPU 写完 GPU 立刻可见，
 * **不需要** cbo.flush）；主机 = malloc 4 MiB 并 gpu_host_bind。
 * LVGL 的图像/字体在堆上只有虚拟地址 ⇒ 想走硬件就先复制进 arena。 */
#define GPU_ARENA_PHYS  0xBF200000u
/* ★ 2026-11-01：1 MiB → 4 MiB。桌面壁纸就是一张 1024x600 RGB565 = 1.17 MiB 的图，
 *   原来的 1 MiB 装不下 ⇒ 它每帧退回软件绘制（实测整屏刷新只有 ~1.5 fps）。
 *   ★ 2026-11-03：随内存 carve 搬到 DDR 顶端，物理区 0xBF20_0000..0xBF5F_FFFF
 *   （carve 0xBC00_0000..0xC000_0000 内；与相机 bank / GUI bank / 3D 缓冲都不重叠）。 */
#define GPU_ARENA_SIZE  (4u * 1024u * 1024u)

int   gpu_arena_init(void);
void *gpu_arena_alloc(size_t len, uint32_t *phys);   /* 4B 对齐；满了返回 NULL */
void  gpu_arena_reset(void);

/* ---- 主机侧专用（板端编译成空操作）---- */
void gpu_host_bind(uint32_t phys, void *mem, size_t len);
void gpu_host_unbind_all(void);

#endif /* YESHEN_GPU_H */
