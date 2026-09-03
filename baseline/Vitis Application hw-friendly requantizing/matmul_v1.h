#ifndef MATMUL_V1_H
#define MATMUL_V1_H

#include "matmul_hw.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MATMUL_V1_PE_ROW        9U
#define MATMUL_V1_PE_COL        16U

/* Current Project 2 baseline BRAM configuration. */
#define MATMUL_V1_AB_DEPTH      1024U
#define MATMUL_V1_PB_DEPTH      4096U
#define MATMUL_V1_WB_DEPTH      16384U

#define MATMUL_V1_OK              0
#define MATMUL_V1_ERR_ARG        -10
#define MATMUL_V1_ERR_AB_SIZE    -11
#define MATMUL_V1_ERR_PB_SIZE    -12
#define MATMUL_V1_ERR_WB_SIZE    -13
#define MATMUL_V1_ERR_HW         -14

/*
 * Matrix layout used by this driver:
 *
 * A : row-major [S][IC]
 * W : row-major [IC][OC]
 * C : row-major [S][OC]
 *
 * WOffset is a Weight Buffer start address, not a Product Buffer offset.
 */

u32 MatMulV1_WeightFootprint(u16 ic, u16 oc);
u16 MatMulV1_MaxSChunk(u16 ic, u16 oc);

/*
 * Software-observed Execute -> DONE profiling.
 * This includes the AXI execute command issue and DONE polling/detection delay,
 * so it is slightly larger than an internal PL cycle counter would report.
 */
void MatMulV1_ProfileReset(void);
u64 MatMulV1_GetExecuteCycles(void);
u32 MatMulV1_GetExecuteCount(void);

int MatMulV1_LoadWeights(MatMulHw *hw, const s8 *w, u16 ic, u16 oc, u16 w_offset);

int MatMulV1_RunPreloaded(
    MatMulHw *hw,
    const s8 *a,
    s32 *c,
    u16 s,
    u16 ic,
    u16 oc,
    u16 w_offset,
    u32 timeout
);

int MatMulV1_Run(
    MatMulHw *hw,
    const s8 *a,
    const s8 *w,
    s32 *c,
    u16 s,
    u16 ic,
    u16 oc,
    u16 w_offset,
    u32 timeout
);

#ifdef __cplusplus
}
#endif

#endif
