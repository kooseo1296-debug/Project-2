#ifndef PREPROCESS_V2_H
#define PREPROCESS_V2_H

#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Same input preprocessing as the verified 91.5% shift-requant V1 app:
 *   pixel/255
 *   -> fixed CIFAR-10 mean/std normalization
 *   -> global max_abs / 127 symmetric signed INT8 quantization
 *
 * Returns:
 *   inv_x_scale_q16 ~= round((1 / input_scale) * 2^16)
 *
 * That returned u32 is written as parameter 530 before this image is sent.
 */
u32 PreprocessV2_Image(
    const u8 img_chw[3U * 32U * 32U],
    s8 q_chw[3U * 32U * 32U]
);

#ifdef __cplusplus
}
#endif

#endif
