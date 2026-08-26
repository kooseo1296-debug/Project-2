#ifndef MODEL_DATA_H
#define MODEL_DATA_H

#include "xil_types.h"

#define MODEL_MATMUL_TIMEOUT 10000000U
#define MODEL_N_TEST 1000U
#define MODEL_IMG_SIZE (3U * 32U * 32U)

extern const float g_normalize_mean[3];
extern const float g_normalize_std[3];
extern const char * const g_classes[10];

extern const s8 g_w0_conv1[864];
extern const float g_b0_conv1[32];
extern const float g_ws0_conv1;

extern const s8 g_w1_conv2[9216];
extern const float g_b1_conv2[32];
extern const float g_ws1_conv2;

extern const s8 g_w2_conv3[18432];
extern const float g_b2_conv3[64];
extern const float g_ws2_conv3;

extern const s8 g_w3_conv4[36864];
extern const float g_b3_conv4[64];
extern const float g_ws3_conv4;

extern const s8 g_w4_conv5[55296];
extern const float g_b4_conv5[96];
extern const float g_ws4_conv5;

extern const s8 g_w5_conv6[82944];
extern const float g_b5_conv6[96];
extern const float g_ws5_conv6;

extern const s8 g_w6_fc1[12288];
extern const float g_b6_fc1[128];
extern const float g_ws6_fc1;

extern const s8 g_w7_fc2[1280];
extern const float g_b7_fc2[10];
extern const float g_ws7_fc2;

extern const u8 g_test_images_chw[MODEL_N_TEST * MODEL_IMG_SIZE];
extern const u8 g_test_labels[MODEL_N_TEST];

#endif
