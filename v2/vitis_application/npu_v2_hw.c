#include "npu_v2_hw.h"
#include "model_data.h"
#include "xil_io.h"

/* Fixed WB bases used by the V2 controller. */
#define WBASE_CONV1  0U
#define WBASE_CONV2  54U
#define WBASE_CONV3  630U
#define WBASE_CONV4  1782U
#define WBASE_CONV5  4086U
#define WBASE_CONV6  7542U
#define WBASE_FC1    12726U
#define WBASE_FC2    13518U

static u16 ceil_div_u16(u16 x, u16 d)
{
    return (u16)(((u32)x + (u32)d - 1U) / (u32)d);
}

static u32 weight_footprint(u16 k, u16 oc)
{
    return (u32)ceil_div_u16(k, NPU_V2_PE_ROW) *
           (u32)ceil_div_u16(oc, NPU_V2_PE_COL) *
           NPU_V2_PE_ROW;
}

static void write_weight(NpuV2Hw *hw, u16 wb_addr, u8 col, s8 data)
{
    u32 cmd = ((u32)wb_addr << 16) |
              ((u32)col << 8) |
              (u32)(u8)data;
    Xil_Out32(hw->BaseAddress + NPU_V2_REG_LOAD_W, cmd);
}

static void write_activation(NpuV2Hw *hw, u16 addr, u8 color, s8 data)
{
    u32 cmd = ((u32)addr << 16) |
              ((u32)color << 8) |
              (u32)(u8)data;
    Xil_Out32(hw->BaseAddress + NPU_V2_REG_LOAD_A, cmd);
}

static int load_weight_matrix(
    NpuV2Hw *hw,
    const s8 *w,
    u16 k,
    u16 oc,
    u16 w_offset
)
{
    u16 k_tiles;
    u16 oc_tiles;
    u16 kt;
    u16 oct;
    u8 row;
    u8 col;
    u32 tile_index = 0U;
    u32 footprint;

    if (hw == 0 || w == 0 || k == 0U || oc == 0U)
        return NPU_V2_ERR_ARG;

    footprint = weight_footprint(k, oc);
    if ((u32)w_offset + footprint > NPU_V2_WB_DEPTH)
        return NPU_V2_ERR_WEIGHT_FIT;

    k_tiles = ceil_div_u16(k, NPU_V2_PE_ROW);
    oc_tiles = ceil_div_u16(oc, NPU_V2_PE_COL);

    /* Same verified V1 packing: K tile outer, OC tile inner. */
    for (kt = 0U; kt < k_tiles; kt++) {
        for (oct = 0U; oct < oc_tiles; oct++) {
            u16 tile_base = (u16)((u32)w_offset +
                                  tile_index * NPU_V2_PE_ROW);

            for (row = 0U; row < NPU_V2_PE_ROW; row++) {
                u16 kk = (u16)((u32)kt * NPU_V2_PE_ROW + row);
                u16 wb_addr = (u16)((u32)tile_base + row);

                for (col = 0U; col < NPU_V2_PE_COL; col++) {
                    u16 out_col = (u16)((u32)oct * NPU_V2_PE_COL + col);
                    s8 value = 0;

                    if (kk < k && out_col < oc)
                        value = w[(u32)kk * (u32)oc + (u32)out_col];

                    write_weight(hw, wb_addr, col, value);
                }
            }
            tile_index++;
        }
    }

    return NPU_V2_OK;
}

void NpuV2_Init(NpuV2Hw *hw, UINTPTR base_address)
{
    if (hw != 0)
        hw->BaseAddress = base_address;
}

u32 NpuV2_GetRcode(const NpuV2Hw *hw)
{
    if (hw == 0)
        return 0U;
    return Xil_In32(hw->BaseAddress + NPU_V2_REG_RCODE);
}

int NpuV2_WriteParam32(NpuV2Hw *hw, u16 param_number, u32 value)
{
    u32 low_cmd;
    u32 high_cmd;

    if (hw == 0 || param_number > NPU_V2_PARAM_MAX)
        return NPU_V2_ERR_ARG;

    /*
     * LOW : {1'b0, ParamNumber[14:0], Value[15:0]}
     * HIGH: {1'b1, ParamNumber[14:0], Value[31:16]}
     *
     * For signed s32 bias constants the cast to u32 preserves the exact
     * two's-complement bit pattern across the two writes.
     */
    low_cmd = ((u32)(param_number & 0x7FFFU) << 16) |
              (value & 0x0000FFFFU);

    high_cmd = 0x80000000U |
               ((u32)(param_number & 0x7FFFU) << 16) |
               ((value >> 16) & 0x0000FFFFU);

    Xil_Out32(hw->BaseAddress + NPU_V2_REG_PARAM, low_cmd);
    Xil_Out32(hw->BaseAddress + NPU_V2_REG_PARAM, high_cmd);

    return NPU_V2_OK;
}

static int load_bias_block(
    NpuV2Hw *hw,
    u16 base_param,
    const s32 *values,
    u16 count
)
{
    u16 i;

    if (hw == 0 || values == 0)
        return NPU_V2_ERR_ARG;

    for (i = 0U; i < count; i++) {
        int status = NpuV2_WriteParam32(
            hw,
            (u16)(base_param + i),
            (u32)values[i]
        );
        if (status != NPU_V2_OK)
            return status;
    }

    return NPU_V2_OK;
}

int NpuV2_PreloadModel(NpuV2Hw *hw)
{
    int status;

    if (hw == 0)
        return NPU_V2_ERR_ARG;

    /* ---------- INT8 weights: startup once ---------- */
    status = load_weight_matrix(hw, g_w0_conv1, 27U, 32U, WBASE_CONV1);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w1_conv2, 288U, 32U, WBASE_CONV2);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w2_conv3, 288U, 64U, WBASE_CONV3);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w3_conv4, 576U, 64U, WBASE_CONV4);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w4_conv5, 576U, 96U, WBASE_CONV5);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w5_conv6, 864U, 96U, WBASE_CONV6);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w6_fc1, 96U, 128U, WBASE_FC1);
    if (status != NPU_V2_OK) return status;

    status = load_weight_matrix(hw, g_w7_fc2, 128U, 10U, WBASE_FC2);
    if (status != NPU_V2_OK) return status;

    /*
     * ---------- parameters 0..521: bias_over_ws_q16 ----------
     * Flat ordering expected by RTL:
     *   Conv1 0..31
     *   Conv2 32..63
     *   Conv3 64..127
     *   Conv4 128..191
     *   Conv5 192..287
     *   Conv6 288..383
     *   FC1   384..511
     *   FC2   512..521
     */
    status = load_bias_block(hw,   0U, g_bow0_conv1_q16,  32U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw,  32U, g_bow1_conv2_q16,  32U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw,  64U, g_bow2_conv3_q16,  64U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw, 128U, g_bow3_conv4_q16,  64U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw, 192U, g_bow4_conv5_q16,  96U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw, 288U, g_bow5_conv6_q16,  96U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw, 384U, g_bow6_fc1_q16,   128U);
    if (status != NPU_V2_OK) return status;
    status = load_bias_block(hw, 512U, g_bow7_fc2_q16,    10U);
    if (status != NPU_V2_OK) return status;

    /* ---------- parameters 522..529: reciprocal weight scales Q16 ---------- */
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV1, g_iws0_conv1_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV2, g_iws1_conv2_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV3, g_iws2_conv3_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV4, g_iws3_conv4_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV5, g_iws4_conv5_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_CONV6, g_iws5_conv6_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_FC1,   g_iws6_fc1_q16);
    if (status != NPU_V2_OK) return status;
    status = NpuV2_WriteParam32(hw, NPU_V2_PARAM_IWS_FC2,   g_iws7_fc2_q16);
    if (status != NPU_V2_OK) return status;

    /* Parameter 530 is intentionally image-dependent and is not preloaded. */
    return NPU_V2_OK;
}

static int wait_busy_value(const NpuV2Hw *hw, int want_busy, u32 timeout)
{
    while (timeout != 0U) {
        u32 rcode = NpuV2_GetRcode(hw);
        int busy = ((rcode & NPU_V2_RCODE_BUSY) != 0U);
        if (busy == want_busy)
            return NPU_V2_OK;
        timeout--;
    }
    return NPU_V2_ERR_TIMEOUT;
}

static void send_channel(NpuV2Hw *hw, const s8 *x, u8 color)
{
    u16 addr;
    for (addr = 0U; addr < 1024U; addr++)
        write_activation(hw, addr, color, x[addr]);
}

static s32 decode_logit26(u32 rcode)
{
    u32 raw = rcode & NPU_V2_RCODE_LOGIT_MASK;
    if ((raw & NPU_V2_RCODE_LOGIT_SIGN) != 0U)
        raw |= 0xFC000000U;
    return (s32)raw;
}

static int consume_logit(u32 rcode, s32 scores[10], u16 *seen_mask)
{
    u8 cls = (u8)((rcode & NPU_V2_RCODE_CLASS_MASK) >>
                  NPU_V2_RCODE_CLASS_SHIFT);

    if (cls >= 10U)
        return NPU_V2_ERR_PROTOCOL;

    if (((*seen_mask) & (u16)(1U << cls)) != 0U)
        return NPU_V2_ERR_PROTOCOL;

    scores[cls] = decode_logit26(rcode);
    *seen_mask = (u16)((*seen_mask) | (u16)(1U << cls));
    return NPU_V2_OK;
}

int NpuV2_RunImage(
    NpuV2Hw *hw,
    const s8 q_chw[3U * 32U * 32U],
    u32 inv_input_scale_q16,
    s32 scores[10],
    u32 timeout
)
{
    const s8 *r;
    const s8 *g;
    const s8 *b;
    u32 rcode;
    u32 t;
    u16 seen = 0U;
    u8 i;
    int status;

    if (hw == 0 || q_chw == 0 || scores == 0 || timeout == 0U)
        return NPU_V2_ERR_ARG;

    r = q_chw;
    g = q_chw + 1024U;
    b = q_chw + 2048U;

    /* Previous image must have returned to non-BUSY before parameter 530. */
    status = wait_busy_value(hw, 0, timeout);
    if (status != NPU_V2_OK) return status;

    /* Image-dependent Q16 initial reciprocal activation scale. */
    status = NpuV2_WriteParam32(
        hw,
        NPU_V2_PARAM_INV_INPUT_SCALE,
        inv_input_scale_q16
    );
    if (status != NPU_V2_OK) return status;

    /* Existing activation path: R -> G -> B. */
    send_channel(hw, r, 0U);
    status = wait_busy_value(hw, 1, timeout);
    if (status != NPU_V2_OK) return status;
    status = wait_busy_value(hw, 0, timeout);
    if (status != NPU_V2_OK) return status;

    send_channel(hw, g, 1U);
    status = wait_busy_value(hw, 1, timeout);
    if (status != NPU_V2_OK) return status;
    status = wait_busy_value(hw, 0, timeout);
    if (status != NPU_V2_OK) return status;

    send_channel(hw, b, 2U);
    status = wait_busy_value(hw, 1, timeout);
    if (status != NPU_V2_OK) return status;

    /*
     * Poll DONE. The first read that observes DONE already contains one valid
     * class/logit pair and advances the RTL result index, so preserve it.
     */
    t = timeout;
    while (1) {
        if (t == 0U)
            return NPU_V2_ERR_TIMEOUT;

        rcode = NpuV2_GetRcode(hw);
        if ((rcode & NPU_V2_RCODE_DONE) != 0U)
            break;
        t--;
    }

    status = consume_logit(rcode, scores, &seen);
    if (status != NPU_V2_OK) return status;

    for (i = 1U; i < 10U; i++) {
        rcode = NpuV2_GetRcode(hw);
        if ((rcode & NPU_V2_RCODE_DONE) == 0U)
            return NPU_V2_ERR_PROTOCOL;

        status = consume_logit(rcode, scores, &seen);
        if (status != NPU_V2_OK) return status;
    }

    if (seen != 0x03FFU)
        return NPU_V2_ERR_PROTOCOL;

    return NPU_V2_OK;
}

u8 NpuV2_Argmax(const s32 scores[10])
{
    u8 best = 0U;
    u8 i;

    for (i = 1U; i < 10U; i++) {
        if (scores[i] > scores[best])
            best = i;
    }
    return best;
}
