#ifndef NPU_V2_HW_H
#define NPU_V2_HW_H

#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* AXI-Lite register map. */
#define NPU_V2_REG_RCODE       0x00U
#define NPU_V2_REG_LOAD_W      0x04U
#define NPU_V2_REG_LOAD_A      0x08U
#define NPU_V2_REG_PARAM       0x0CU

/* RCODE = {BUSY, DONE, Class[3:0], Logit[25:0]} */
#define NPU_V2_RCODE_BUSY          (1U << 31)
#define NPU_V2_RCODE_DONE          (1U << 30)
#define NPU_V2_RCODE_CLASS_SHIFT   26U
#define NPU_V2_RCODE_CLASS_MASK    (0xFU << NPU_V2_RCODE_CLASS_SHIFT)
#define NPU_V2_RCODE_LOGIT_MASK    0x03FFFFFFU
#define NPU_V2_RCODE_LOGIT_SIGN    0x02000000U

#define NPU_V2_PE_ROW          9U
#define NPU_V2_PE_COL          16U
#define NPU_V2_WB_DEPTH        16384U

/*
 * 0x0C parameter map.
 * Every parameter is a full 32-bit value transferred in TWO AXI writes:
 *
 *   LOW  = {1'b0, ParamNumber[14:0], Value[15:0]}
 *   HIGH = {1'b1, ParamNumber[14:0], Value[31:16]}
 */
#define NPU_V2_PARAM_BIAS_FIRST      0U
#define NPU_V2_PARAM_BIAS_LAST       521U
#define NPU_V2_PARAM_IWS_CONV1       522U
#define NPU_V2_PARAM_IWS_CONV2       523U
#define NPU_V2_PARAM_IWS_CONV3       524U
#define NPU_V2_PARAM_IWS_CONV4       525U
#define NPU_V2_PARAM_IWS_CONV5       526U
#define NPU_V2_PARAM_IWS_CONV6       527U
#define NPU_V2_PARAM_IWS_FC1         528U
#define NPU_V2_PARAM_IWS_FC2         529U
#define NPU_V2_PARAM_INV_INPUT_SCALE 530U
#define NPU_V2_PARAM_MAX             530U

#define NPU_V2_OK               0
#define NPU_V2_ERR_ARG         -1
#define NPU_V2_ERR_TIMEOUT     -2
#define NPU_V2_ERR_PROTOCOL    -3
#define NPU_V2_ERR_WEIGHT_FIT  -4

#define NPU_V2_DEFAULT_TIMEOUT  50000000U

typedef struct {
    UINTPTR BaseAddress;
} NpuV2Hw;

void NpuV2_Init(NpuV2Hw *hw, UINTPTR base_address);
u32 NpuV2_GetRcode(const NpuV2Hw *hw);

/* Write one complete 32-bit Q16/Q32 parameter through 0x0C. */
int NpuV2_WriteParam32(NpuV2Hw *hw, u16 param_number, u32 value);

/*
 * Startup operation:
 *   - preload all INT8 weights
 *   - preload parameter 0..521  : signed bias_over_ws_q16
 *   - preload parameter 522..529: inv_weight_scale_q16
 * Parameter 530 is NOT written here because it is image-dependent.
 */
int NpuV2_PreloadModel(NpuV2Hw *hw);

/*
 * One image:
 *   1) write parameter 530 = initial inv_x_scale_q16
 *   2) send R/G/B through the existing activation path
 *   3) wait DONE and read 10 signed FC2 logits
 */
int NpuV2_RunImage(
    NpuV2Hw *hw,
    const s8 q_chw[3U * 32U * 32U],
    u32 inv_input_scale_q16,
    s32 scores[10],
    u32 timeout
);

u8 NpuV2_Argmax(const s32 scores[10]);

#ifdef __cplusplus
}
#endif

#endif
