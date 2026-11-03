/* generated: 12 output dequant params (scale,zp) */
/* 由 y1/tools/gen_deq_header.py 生成 —— 请勿手改（改标定口径就重跑脚本并入库）。
 *
 * 顺序 = yunet_post.OUT_NAMES = cls_8,cls_16,cls_32,obj_8,obj_16,obj_32,
 *                              bbox_8,bbox_16,bbox_32,kps_8,kps_16,kps_32
 * 口径 = 冻结 quant_ref affine（零值纳入）+ y1_caliber.apply_sigmoid_fix（Q3.4/Q0.7）；
 *        标定输入 = yunet_post.synth_noface()（确定性，可复现）。
 * 反量化（与 quant_ptq.dequant 同式）：x = (q - zp) * scale   —— 注意是减 zp，不是加。
 */
#ifndef Y1_DEQ_H
#define Y1_DEQ_H

#define Y1_DEQ_N 12

/* 标定输入：scale=1 zp=-128（仅供溯源；板内输入是 q = x - 128，同口径） */
static const char *DEQ_NAME[Y1_DEQ_N] = {
    "cls_8",
    "cls_16",
    "cls_32",
    "obj_8",
    "obj_16",
    "obj_32",
    "bbox_8",
    "bbox_16",
    "bbox_32",
    "kps_8",
    "kps_16",
    "kps_32",
};

static const float DEQ_SCALE[Y1_DEQ_N] = {
    0.00787401575f,            /* cls_8 */
    0.00787401575f,            /* cls_16 */
    0.00787401575f,            /* cls_32 */
    0.00787401575f,            /* obj_8 */
    0.00787401575f,            /* obj_16 */
    0.00787401575f,            /* obj_32 */
    0.0136472069f,            /* bbox_8 */
    0.00574952364f,            /* bbox_16 */
    0.0204735952f,            /* bbox_32 */
    0.031484041f,            /* kps_8 */
    0.00452927941f,            /* kps_16 */
    0.0402174202f,            /* kps_32 */
};

static const int DEQ_ZP[Y1_DEQ_N] = {
    0,     /* cls_8 */
    0,     /* cls_16 */
    0,     /* cls_32 */
    0,     /* obj_8 */
    0,     /* obj_16 */
    0,     /* obj_32 */
    -71,   /* bbox_8 */
    -29,   /* bbox_16 */
    -18,   /* bbox_32 */
    -10,   /* kps_8 */
    -117,  /* kps_16 */
    -4,    /* kps_32 */
};

#endif /* Y1_DEQ_H */
