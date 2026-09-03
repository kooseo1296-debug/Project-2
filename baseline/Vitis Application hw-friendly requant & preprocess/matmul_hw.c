#include "matmul_hw.h"
#include "xil_io.h"

static s32 MatMulHw_DecodeRcodeData(u32 rcode)
{
    u32 raw = rcode & MATMUL_RCODE_DATA_MASK;
    if (raw & MATMUL_RCODE_DATA_SIGN) raw |= 0xF0000000U;
    return (s32)raw;
}

void MatMulHw_Init(MatMulHw *hw, UINTPTR base_address)
{
    if (hw != 0) hw->BaseAddress = base_address;
}

void MatMulHw_WriteWeight(MatMulHw *hw, u16 wb_addr, u8 col, s8 data)
{
    u32 cmd = ((u32)wb_addr << 16) | ((u32)col << 8) | (u8)data;
    Xil_Out32(hw->BaseAddress + MATMUL_REG_LOAD_W, cmd);
}

void MatMulHw_WriteActivation(MatMulHw *hw, u16 ab_addr, u8 row, s8 data)
{
    u32 cmd = ((u32)ab_addr << 16) | ((u32)row << 8) | (u8)data;
    Xil_Out32(hw->BaseAddress + MATMUL_REG_LOAD_A, cmd);
}

void MatMulHw_ConfigSIC(MatMulHw *hw, u16 s, u16 ic)
{
    u32 cmd = ((u32)(s & 0x7FFFU) << 15) | (u32)(ic & 0x7FFFU);
    Xil_Out32(hw->BaseAddress + MATMUL_REG_CONFIG, cmd);
}

void MatMulHw_ConfigOCWOffset(MatMulHw *hw, u16 oc, u16 w_offset)
{
    u32 cmd = (1U << 30) | ((u32)(oc & 0x7FFFU) << 15) | (u32)(w_offset & 0x7FFFU);
    Xil_Out32(hw->BaseAddress + MATMUL_REG_CONFIG, cmd);
}

void MatMulHw_Execute(MatMulHw *hw)
{
    Xil_Out32(hw->BaseAddress + MATMUL_REG_CONFIG, 2U << 30);
}

u32 MatMulHw_GetRcode(const MatMulHw *hw)
{
    return Xil_In32(hw->BaseAddress + MATMUL_REG_RCODE);
}

int MatMulHw_WaitDone(const MatMulHw *hw, u32 timeout)
{
    while (timeout != 0U) {
        u32 rcode = MatMulHw_GetRcode(hw);
        if ((rcode & MATMUL_RCODE_DONE) && !(rcode & MATMUL_RCODE_BUSY)) return MATMUL_HW_OK;
        timeout--;
    }
    return MATMUL_HW_ERR_TIMEOUT;
}

void MatMulHw_RequestProduct(MatMulHw *hw, u16 pb_addr, u8 col)
{
    u32 cmd = ((u32)pb_addr << 16) | ((u32)col << 8);
    Xil_Out32(hw->BaseAddress + MATMUL_REG_READ_PB, cmd);
}

int MatMulHw_ReadProduct(MatMulHw *hw, u16 pb_addr, u8 col, s32 *value, u32 timeout)
{
    if (hw == 0 || value == 0 || col >= 16U) return MATMUL_HW_ERR_ARG;

    MatMulHw_RequestProduct(hw, pb_addr, col);

    while (timeout != 0U) {
        u32 rcode = MatMulHw_GetRcode(hw);
        if (rcode & MATMUL_RCODE_VALID) {
            *value = MatMulHw_DecodeRcodeData(rcode);
            return MATMUL_HW_OK;
        }
        timeout--;
    }

    return MATMUL_HW_ERR_TIMEOUT;
}
