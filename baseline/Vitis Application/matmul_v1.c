#include "matmul_v1.h"
#include "xparameters.h"
#include "xil_io.h"

#ifndef XPAR_GLOBAL_TIMER_BASEADDR
#error "XPAR_GLOBAL_TIMER_BASEADDR not found in xparameters.h"
#endif

#define MATMUL_V1_GTIMER_LOW   (XPAR_GLOBAL_TIMER_BASEADDR + 0x00U)
#define MATMUL_V1_GTIMER_HIGH  (XPAR_GLOBAL_TIMER_BASEADDR + 0x04U)

static u64 g_matmul_v1_execute_cycles = 0ULL;
static u32 g_matmul_v1_execute_count = 0U;

static u64 MatMulV1_GetGlobalTime(void)
{
    u32 low_val = Xil_In32(MATMUL_V1_GTIMER_LOW);
    u32 high_val = Xil_In32(MATMUL_V1_GTIMER_HIGH);
    return ((u64)high_val << 32) | (u64)low_val;
}

void MatMulV1_ProfileReset(void)
{
    g_matmul_v1_execute_cycles = 0ULL;
    g_matmul_v1_execute_count = 0U;
}

u64 MatMulV1_GetExecuteCycles(void)
{
    return g_matmul_v1_execute_cycles;
}

u32 MatMulV1_GetExecuteCount(void)
{
    return g_matmul_v1_execute_count;
}


static u16 ceil_div_u16(u16 x, u16 d)
{
    return (u16)(((u32)x + (u32)d - 1U) / (u32)d);
}

u32 MatMulV1_WeightFootprint(u16 ic, u16 oc)
{
    u32 k_tiles;
    u32 oc_tiles;

    if (ic == 0U || oc == 0U) return 0U;

    k_tiles = (u32)ceil_div_u16(ic, MATMUL_V1_PE_ROW);
    oc_tiles = (u32)ceil_div_u16(oc, MATMUL_V1_PE_COL);
    return k_tiles * oc_tiles * MATMUL_V1_PE_ROW;
}

u16 MatMulV1_MaxSChunk(u16 ic, u16 oc)
{
    u32 k_tiles;
    u32 oc_tiles;
    u32 max_by_ab;
    u32 max_by_pb;
    u32 max_s;

    if (ic == 0U || oc == 0U) return 0U;

    k_tiles = (u32)ceil_div_u16(ic, MATMUL_V1_PE_ROW);
    oc_tiles = (u32)ceil_div_u16(oc, MATMUL_V1_PE_COL);

    max_by_ab = MATMUL_V1_AB_DEPTH / k_tiles;
    max_by_pb = MATMUL_V1_PB_DEPTH / oc_tiles;
    max_s = (max_by_ab < max_by_pb) ? max_by_ab : max_by_pb;

    if (max_s > 0x7FFFU) max_s = 0x7FFFU;
    return (u16)max_s;
}

static int MatMulV1_LoadActivations(MatMulHw *hw, const s8 *a, u16 s, u16 ic)
{
    u16 k_tiles;
    u16 kt;
    u16 sample;
    u8 row;

    if (hw == 0 || a == 0 || s == 0U || ic == 0U) return MATMUL_V1_ERR_ARG;

    k_tiles = ceil_div_u16(ic, MATMUL_V1_PE_ROW);
    if ((u32)k_tiles * (u32)s > MATMUL_V1_AB_DEPTH) return MATMUL_V1_ERR_AB_SIZE;

    for (kt = 0U; kt < k_tiles; kt++) {
        for (sample = 0U; sample < s; sample++) {
            u16 ab_addr = (u16)((u32)kt * (u32)s + (u32)sample);

            for (row = 0U; row < MATMUL_V1_PE_ROW; row++) {
                u16 k = (u16)((u32)kt * MATMUL_V1_PE_ROW + row);
                s8 value = 0;

                if (k < ic) value = a[(u32)sample * (u32)ic + (u32)k];
                MatMulHw_WriteActivation(hw, ab_addr, row, value);
            }
        }
    }

    return MATMUL_V1_OK;
}

int MatMulV1_LoadWeights(MatMulHw *hw, const s8 *w, u16 ic, u16 oc, u16 w_offset)
{
    u16 k_tiles;
    u16 oc_tiles;
    u16 kt;
    u16 oct;
    u8 row;
    u8 col;
    u32 tile_index = 0U;
    u32 footprint;

    if (hw == 0 || w == 0 || ic == 0U || oc == 0U) return MATMUL_V1_ERR_ARG;

    footprint = MatMulV1_WeightFootprint(ic, oc);
    if ((u32)w_offset + footprint > MATMUL_V1_WB_DEPTH) return MATMUL_V1_ERR_WB_SIZE;

    k_tiles = ceil_div_u16(ic, MATMUL_V1_PE_ROW);
    oc_tiles = ceil_div_u16(oc, MATMUL_V1_PE_COL);

    for (kt = 0U; kt < k_tiles; kt++) {
        for (oct = 0U; oct < oc_tiles; oct++) {
            u16 tile_base = (u16)((u32)w_offset + tile_index * MATMUL_V1_PE_ROW);

            for (row = 0U; row < MATMUL_V1_PE_ROW; row++) {
                u16 k = (u16)((u32)kt * MATMUL_V1_PE_ROW + row);
                u16 wb_addr = (u16)((u32)tile_base + row);

                for (col = 0U; col < MATMUL_V1_PE_COL; col++) {
                    u16 out_col = (u16)((u32)oct * MATMUL_V1_PE_COL + col);
                    s8 value = 0;

                    if (k < ic && out_col < oc) value = w[(u32)k * (u32)oc + (u32)out_col];
                    MatMulHw_WriteWeight(hw, wb_addr, col, value);
                }
            }

            tile_index++;
        }
    }

    return MATMUL_V1_OK;
}

static int MatMulV1_ReadProducts(MatMulHw *hw, s32 *c, u16 s, u16 oc, u32 timeout)
{
    u16 oc_tiles;
    u16 oct;
    u16 sample;
    u8 col;

    if (hw == 0 || c == 0 || s == 0U || oc == 0U) return MATMUL_V1_ERR_ARG;

    oc_tiles = ceil_div_u16(oc, MATMUL_V1_PE_COL);
    if ((u32)oc_tiles * (u32)s > MATMUL_V1_PB_DEPTH) return MATMUL_V1_ERR_PB_SIZE;

    for (oct = 0U; oct < oc_tiles; oct++) {
        for (sample = 0U; sample < s; sample++) {
            u16 pb_addr = (u16)((u32)oct * (u32)s + (u32)sample);

            for (col = 0U; col < MATMUL_V1_PE_COL; col++) {
                u16 out_col = (u16)((u32)oct * MATMUL_V1_PE_COL + col);
                s32 value;
                int status;

                if (out_col >= oc) break;

                status = MatMulHw_ReadProduct(hw, pb_addr, col, &value, timeout);
                if (status != MATMUL_HW_OK) return MATMUL_V1_ERR_HW;

                c[(u32)sample * (u32)oc + (u32)out_col] = value;
            }
        }
    }

    return MATMUL_V1_OK;
}

static int MatMulV1_RunOneChunk(
    MatMulHw *hw,
    const s8 *a,
    s32 *c,
    u16 s,
    u16 ic,
    u16 oc,
    u16 w_offset,
    u32 timeout
)
{
    int status;

    status = MatMulV1_LoadActivations(hw, a, s, ic);
    if (status != MATMUL_V1_OK) return status;

    MatMulHw_ConfigSIC(hw, s, ic);
    MatMulHw_ConfigOCWOffset(hw, oc, w_offset);

    {
        u64 t0 = MatMulV1_GetGlobalTime();
        u64 t1;

        MatMulHw_Execute(hw);
        status = MatMulHw_WaitDone(hw, timeout);

        t1 = MatMulV1_GetGlobalTime();
        g_matmul_v1_execute_cycles += (t1 - t0);
        g_matmul_v1_execute_count++;
    }

    if (status != MATMUL_HW_OK) return MATMUL_V1_ERR_HW;

    return MatMulV1_ReadProducts(hw, c, s, oc, timeout);
}

int MatMulV1_RunPreloaded(
    MatMulHw *hw,
    const s8 *a,
    s32 *c,
    u16 s,
    u16 ic,
    u16 oc,
    u16 w_offset,
    u32 timeout
)
{
    u16 max_chunk;
    u16 done = 0U;

    if (hw == 0 || a == 0 || c == 0 || s == 0U || ic == 0U || oc == 0U) return MATMUL_V1_ERR_ARG;
    if ((u32)w_offset + MatMulV1_WeightFootprint(ic, oc) > MATMUL_V1_WB_DEPTH) return MATMUL_V1_ERR_WB_SIZE;

    max_chunk = MatMulV1_MaxSChunk(ic, oc);
    if (max_chunk == 0U) {
        u32 k_tiles = (u32)ceil_div_u16(ic, MATMUL_V1_PE_ROW);
        u32 oc_tiles = (u32)ceil_div_u16(oc, MATMUL_V1_PE_COL);
        if (k_tiles > MATMUL_V1_AB_DEPTH) return MATMUL_V1_ERR_AB_SIZE;
        if (oc_tiles > MATMUL_V1_PB_DEPTH) return MATMUL_V1_ERR_PB_SIZE;
        return MATMUL_V1_ERR_ARG;
    }

    while (done < s) {
        u16 remaining = (u16)(s - done);
        u16 chunk = (remaining < max_chunk) ? remaining : max_chunk;
        int status = MatMulV1_RunOneChunk(
            hw,
            a + (u32)done * (u32)ic,
            c + (u32)done * (u32)oc,
            chunk,
            ic,
            oc,
            w_offset,
            timeout
        );

        if (status != MATMUL_V1_OK) return status;
        done = (u16)(done + chunk);
    }

    return MATMUL_V1_OK;
}

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
)
{
    int status;

    if (hw == 0 || a == 0 || w == 0 || c == 0) return MATMUL_V1_ERR_ARG;

    status = MatMulV1_LoadWeights(hw, w, ic, oc, w_offset);
    if (status != MATMUL_V1_OK) return status;

    return MatMulV1_RunPreloaded(hw, a, c, s, ic, oc, w_offset, timeout);
}
