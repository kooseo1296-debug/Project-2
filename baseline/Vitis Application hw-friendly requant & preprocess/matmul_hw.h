#ifndef MATMUL_HW_H
#define MATMUL_HW_H

#include "xil_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MATMUL_REG_RCODE        0x00U
#define MATMUL_REG_LOAD_W       0x04U
#define MATMUL_REG_LOAD_A       0x08U
#define MATMUL_REG_CONFIG       0x0CU
#define MATMUL_REG_READ_PB      0x10U

#define MATMUL_RCODE_BUSY       (1U << 31)
#define MATMUL_RCODE_DONE       (1U << 30)
#define MATMUL_RCODE_PENDING    (1U << 29)
#define MATMUL_RCODE_VALID      (1U << 28)
#define MATMUL_RCODE_DATA_MASK  0x0FFFFFFFU
#define MATMUL_RCODE_DATA_SIGN  0x08000000U

#define MATMUL_HW_OK             0
#define MATMUL_HW_ERR_TIMEOUT   -1
#define MATMUL_HW_ERR_ARG       -2

typedef struct {
    UINTPTR BaseAddress;
} MatMulHw;

void MatMulHw_Init(MatMulHw *hw, UINTPTR base_address);

void MatMulHw_WriteWeight(MatMulHw *hw, u16 wb_addr, u8 col, s8 data);
void MatMulHw_WriteActivation(MatMulHw *hw, u16 ab_addr, u8 row, s8 data);

void MatMulHw_ConfigSIC(MatMulHw *hw, u16 s, u16 ic);
void MatMulHw_ConfigOCWOffset(MatMulHw *hw, u16 oc, u16 w_offset);
void MatMulHw_Execute(MatMulHw *hw);

u32 MatMulHw_GetRcode(const MatMulHw *hw);
int MatMulHw_WaitDone(const MatMulHw *hw, u32 timeout);

void MatMulHw_RequestProduct(MatMulHw *hw, u16 pb_addr, u8 col);
int MatMulHw_ReadProduct(MatMulHw *hw, u16 pb_addr, u8 col, s32 *value, u32 timeout);

#ifdef __cplusplus
}
#endif

#endif
