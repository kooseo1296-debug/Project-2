#ifndef MODEL_DATA_H
#define MODEL_DATA_H

#include "xil_types.h"

#define MODEL_MATMUL_TIMEOUT 10000000U
#define MODEL_N_TEST 1000U
#define MODEL_IMG_SIZE (3U * 32U * 32U)
#define MODEL_SCALE_Q 16U
#define MODEL_SCALE_ONE (1U << MODEL_SCALE_Q)

extern const float g_normalize_mean[3];
extern const float g_normalize_std[3];
extern const char * const g_classes[10];

extern const s8 g_w0_conv1[864];
extern const s32 g_bow0_conv1_q16[32];
extern const u32 g_iws0_conv1_q16;

extern const s8 g_w1_conv2[9216];
extern const s32 g_bow1_conv2_q16[32];
extern const u32 g_iws1_conv2_q16;

extern const s8 g_w2_conv3[18432];
extern const s32 g_bow2_conv3_q16[64];
extern const u32 g_iws2_conv3_q16;

extern const s8 g_w3_conv4[36864];
extern const s32 g_bow3_conv4_q16[64];
extern const u32 g_iws3_conv4_q16;

extern const s8 g_w4_conv5[55296];
extern const s32 g_bow4_conv5_q16[96];
extern const u32 g_iws4_conv5_q16;

extern const s8 g_w5_conv6[82944];
extern const s32 g_bow5_conv6_q16[96];
extern const u32 g_iws5_conv6_q16;

extern const s8 g_w6_fc1[12288];
extern const s32 g_bow6_fc1_q16[128];
extern const u32 g_iws6_fc1_q16;

extern const s8 g_w7_fc2[1280];
extern const s32 g_bow7_fc2_q16[10];
extern const u32 g_iws7_fc2_q16;

extern const u8 g_test_images_chw[MODEL_N_TEST * MODEL_IMG_SIZE];
extern const u8 g_test_labels[MODEL_N_TEST];

#endif
