#ifndef SMALLVGG_V1_H
#define SMALLVGG_V1_H

#include "xil_types.h"
#include "matmul_hw.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SMALLVGG_V1_OK                 0
#define SMALLVGG_V1_ERR_ARG          -100
#define SMALLVGG_V1_ERR_WEIGHT_FIT   -101
#define SMALLVGG_V1_ERR_MATMUL       -102

#define SMALLVGG_NUM_CLASSES           10U

typedef struct {
    u16 w0_conv1;
    u16 w1_conv2;
    u16 w2_conv3;
    u16 w3_conv4;
    u16 w4_conv5;
    u16 w5_conv6;
    u16 w6_fc1;
    u16 w7_fc2;
    u16 end;
} SmallVGGV1WeightMap;

typedef struct {
    MatMulHw *hw;
    SmallVGGV1WeightMap wmap;
} SmallVGGV1;

int SmallVGGV1_Init(SmallVGGV1 *net, MatMulHw *hw);
int SmallVGGV1_PreloadWeights(SmallVGGV1 *net);
int SmallVGGV1_Run(SmallVGGV1 *net, const u8 img_chw[3 * 32 * 32], float logits[10], int verbose);
u8 SmallVGGV1_Argmax(const float logits[10]);

#ifdef __cplusplus
}
#endif

#endif
