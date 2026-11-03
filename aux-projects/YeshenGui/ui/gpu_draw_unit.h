/* gpu_draw_unit.h —— LVGL 9.2 自定义 draw unit：把实心矩形交给硬件 GPU。
 *
 * 只在 `YESHEN_GUI_GPU_UNIT` 构建里启用；配 `LV_DISPLAY_RENDER_MODE_DIRECT`
 * 使用（LVGL 直接画进全屏帧存，GPU 也写同一块）。
 */
#ifndef YESHEN_GPU_DRAW_UNIT_H
#define YESHEN_GPU_DRAW_UNIT_H

#include <stdint.h>
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 注册 GPU draw unit。
 *   fb      : DIRECT 模式的帧存（LVGL 的 draw_buf 就是它）
 *   w/h     : 屏幕尺寸（像素）
 *   fb_phys : 帧存物理地址（板端 0xBE00_0000；主机 0 —— 由 gpu 库按绑定模拟）
 * 返回 0 = 成功；-1 = 没有 GPU / 帧存不可直写。 */
int gpu_draw_unit_init(uint16_t *fb, int w, int h, uint32_t fb_phys);

/* 一帧结束：把已排队的 GPU 命令排干（FENCE）。
 * 返回 0 = 完成；-1 = 超时（调用方决定是否降级）。 */
int gpu_draw_unit_finish_frame(void);

/* 统计（判据/日志用）：接管的 FILL 任务数与像素数。 */
void gpu_draw_unit_stats(uint32_t *tasks, uint32_t *pixels);

/* 把一张 RGB565 图像**按物理地址直接绑定**成 BLIT 源（零拷贝）。
 *   img      : 该图像的描述符（后续必须一直用同一个指针，缓存按指针索引）
 *   phys     : 像素数据的物理地址（例如 GPU 的 3D 颜色缓冲 0xBF00_0000）
 *   stride_px: 行跨（像素）
 * 典型用途：3D 引擎把画面直接画进 GPU_COLOR3D，桌面再把它当普通图像显示，
 * 既不每帧 memcpy 进 arena，也不会读到缓存里的旧内容。 */
void gpu_draw_unit_bind_image(const lv_image_dsc_t *img, uint32_t phys, int stride_px);

/* 图像内容在原地变了：把 `img->data` 重新拷进它已绑定的 GPU 源（arena）。
 * 图像缓存按 `src` 指针只拷一次，canvas 这类每帧重画的源必须在改完像素后调用它，
 * 否则屏幕会一直显示第一帧。只对经 img_ensure 拷进 arena 的图像有效（bind_image
 * 的零拷贝源由调用方自己写）。未注册（还没画过）时是 no-op。 */
void gpu_draw_unit_touch(const lv_image_dsc_t *img);

#ifdef __cplusplus
}
#endif

#endif /* YESHEN_GPU_DRAW_UNIT_H */
