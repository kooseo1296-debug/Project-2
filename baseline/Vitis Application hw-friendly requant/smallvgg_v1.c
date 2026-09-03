#include "smallvgg_v1.h"
#include "matmul_v1.h"
#include "model_data.h"
#include "xil_printf.h"

/*
 * Shift-only requantization experiment
 * ------------------------------------
 *
 * Conv1 input:
 *   normalized float -> signed INT8 quantization (preprocess only)
 *   preprocess exports inv(input_scale) as Q16 integer metadata
 *
 * After each ReLU layer:
 *   INT32 accumulator (+ bias converted to accumulator units)
 *   -> find positive max over the whole output tensor
 *   -> determine shift from max MSB so the result fits 0..127
 *   -> right shift every positive value
 *   -> use bit[shift-1] as the round-up bit
 *   -> saturate to 127
 *   -> pass this INT8 tensor directly to the next layer
 *
 * Example:
 *   max = 200 = 0b11001000
 *   MSB position = 7, signed-INT8 positive target MSB = 6
 *   shift = 1
 *
 *   x = 203 = 0b11001011
 *   base      = x >> 1 = 101
 *   round bit = bit[0] = 1
 *   result    = 102
 *
 * After preprocessing, all bias and scale tracking is integer-only.
 * inv_scale is carried as Q16 fixed-point metadata.
 */

#define SV_MAX_FEATURE_ELEMS  (32U * 32U * 32U)
#define SV_MAX_IM2COL_ELEMS   (1024U * 288U)
#define SV_MAX_GEMM_ELEMS     (1024U * 32U)
#define SV_MAX_BIAS_ELEMS     128U

/* Only the normalized RGB input needs a float feature buffer. */
static float g_input_float[3U * 32U * 32U];

/* Quantized activation ping-pong buffers, CHW layout. */
static s8 g_act_a[SV_MAX_FEATURE_ELEMS];
static s8 g_act_b[SV_MAX_FEATURE_ELEMS];

/* MatMul workspaces. */
static s8  g_im2col[SV_MAX_IM2COL_ELEMS];
static s32 g_gemm[SV_MAX_GEMM_ELEMS];
static s32 g_bias_int[SV_MAX_BIAS_ELEMS];

/* Final small tensors. */
static s8 g_gap_q[96];
static s8 g_fc1_q[128];

static s32 floor_to_s32(float x)
{
    s32 t = (s32)x;
    if (x < 0.0f && (float)t != x) t--;
    return t;
}

static s32 round_to_even_f32(float x)
{
    s32 base = floor_to_s32(x);
    float frac = x - (float)base;

    if (frac < 0.5f) return base;
    if (frac > 0.5f) return base + 1;
    return (base & 1) ? (base + 1) : base;
}

/*
 * Original baseline quantizer.
 * Used only for the normalized RGB input, which contains negative values.
 */
static u32 quantize_symmetric_int8_preprocess(
    const float *x,
    s8 *q,
    u32 n
)
{
    u32 i;
    float max_abs = 0.0f;
    float scale;
    float inv_scale;
    s32 inv_q;

    for (i = 0U; i < n; i++) {
        float a = (x[i] < 0.0f) ? -x[i] : x[i];
        if (a > max_abs) max_abs = a;
    }

    scale = (max_abs > 0.0f) ? (max_abs / 127.0f) : 1.0f;

    for (i = 0U; i < n; i++) {
        s32 v = round_to_even_f32(x[i] / scale);

        if (v > 127)  v = 127;
        if (v < -128) v = -128;

        q[i] = (s8)v;
    }

    /*
     * Floating point is allowed only inside preprocessing.
     * Export the reciprocal activation scale as Q16:
     *
     *   inv_scale_q16 ~= (1 / scale) * 2^16
     */
    inv_scale = 1.0f / scale;
    inv_q = round_to_even_f32(
        inv_scale * (float)MODEL_SCALE_ONE
    );

    if (inv_q < 1) inv_q = 1;
    return (u32)inv_q;
}

static void normalize_input(const u8 *img, float *dst)
{
    u32 c;
    u32 hw;

    for (c = 0U; c < 3U; c++) {
        for (hw = 0U; hw < 32U * 32U; hw++) {
            u32 idx = c * 32U * 32U + hw;
            float x = (float)img[idx] / 255.0f;
            dst[idx] = (x - g_normalize_mean[c]) / g_normalize_std[c];
        }
    }
}

static u32 im2col_chw_3x3_pad1(
    const s8 *x,
    u16 c,
    u16 h,
    u16 w,
    s8 *col
)
{
    u16 oh;
    u16 ow;
    u16 ch;
    u16 kh;
    u16 kw;
    u32 out = 0U;

    for (oh = 0U; oh < h; oh++) {
        for (ow = 0U; ow < w; ow++) {
            for (ch = 0U; ch < c; ch++) {
                for (kh = 0U; kh < 3U; kh++) {
                    for (kw = 0U; kw < 3U; kw++) {
                        int ih = (int)oh + (int)kh - 1;
                        int iw = (int)ow + (int)kw - 1;
                        s8 v = 0;

                        if (ih >= 0 &&
                            ih < (int)h &&
                            iw >= 0 &&
                            iw < (int)w) {
                            v = x[((u32)ch * h + (u32)ih) * w + (u32)iw];
                        }

                        col[out++] = v;
                    }
                }
            }
        }
    }

    return out;
}

/*
 * Return the MSB bit position of v.
 * v=1 -> 0, v=2..3 -> 1, v=128..255 -> 7.
 */
static u8 msb_position_u32(u32 v)
{
    u8 pos = 0U;

    while (v > 1U) {
        v >>= 1U;
        pos++;
    }

    return pos;
}

/*
 * Positive signed INT8 uses bits [6:0], i.e. maximum 127.
 *
 * max <= 127:
 *     shift = 0
 *
 * max = 128..255:
 *     MSB=7 -> shift=1
 *
 * max = 256..511:
 *     MSB=8 -> shift=2
 *
 * etc.
 */
static u8 choose_requant_shift(u32 max_positive)
{
    u8 msb;

    if (max_positive <= 127U) return 0U;

    msb = msb_position_u32(max_positive);
    return (u8)(msb - 6U);
}

/*
 * Shift + round-up using exactly the highest discarded bit.
 *
 * For shift > 0:
 *     base      = x >> shift
 *     round_bit = bit[shift-1]
 *     q         = base + round_bit
 *
 * Lower discarded bits do not alter the decision.
 */
static s8 requant_positive_roundup(s32 x, u8 shift)
{
    u32 ux;
    u32 q;

    if (x <= 0) return 0;

    ux = (u32)x;

    if (shift == 0U) {
        q = ux;
    } else {
        u32 round_bit = (ux >> (shift - 1U)) & 1U;
        q = (ux >> shift) + round_bit;
    }

    if (q > 127U) q = 127U;
    return (s8)q;
}

static u64 round_shift_even_u64(u64 value, u32 shift)
{
    u64 q;
    u64 rem;
    u64 half;
    u64 mask;

    if (shift == 0U) return value;

    q = value >> shift;
    mask = (1ULL << shift) - 1ULL;
    rem = value & mask;
    half = 1ULL << (shift - 1U);

    if (rem > half ||
        (rem == half && (q & 1ULL))) {
        q++;
    }

    return q;
}

static s64 round_shift_even_s64(s64 value, u32 shift)
{
    u64 mag;
    u64 q;

    if (value < 0) {
        mag = (u64)(-value);
        q = round_shift_even_u64(mag, shift);
        return -(s64)q;
    }

    q = round_shift_even_u64((u64)value, shift);
    return (s64)q;
}

/*
 * bias_over_ws_q16 is generated offline:
 *
 *   bias_over_ws_q16 ~= (bias / weight_scale) * 2^16
 *
 * inv_x_scale_q16 is produced by preprocessing and then propagated
 * only with integer arithmetic:
 *
 *   inv_x_scale_q16 ~= (1 / x_scale) * 2^16
 *
 * Therefore:
 *
 *   bias_int ~= bias / (x_scale * weight_scale)
 *            ~= bias_over_ws_q16 * inv_x_scale_q16 / 2^32
 */
static void make_bias_int_q16(
    const s32 *bias_over_ws_q16,
    s32 *bias_int,
    u16 count,
    u32 inv_x_scale_q16
)
{
    u16 i;

    for (i = 0U; i < count; i++) {
        s64 prod =
            (s64)bias_over_ws_q16[i] *
            (s64)inv_x_scale_q16;

        s64 v = round_shift_even_s64(
            prod,
            2U * MODEL_SCALE_Q
        );

        if (v > 2147483647LL) v = 2147483647LL;
        if (v < -2147483648LL) v = -2147483648LL;

        bias_int[i] = (s32)v;
    }
}

/*
 * If:
 *
 *   y_scale = x_scale * weight_scale * 2^shift
 *
 * then:
 *
 *   1/y_scale =
 *       (1/x_scale) * (1/weight_scale) / 2^shift
 *
 * All values are Q16 fixed-point integers.
 */
static u32 update_inv_scale_q16(
    u32 inv_x_scale_q16,
    u32 inv_weight_scale_q16,
    u8 shift
)
{
    u64 prod =
        (u64)inv_x_scale_q16 *
        (u64)inv_weight_scale_q16;

    u64 v = round_shift_even_u64(
        prod,
        MODEL_SCALE_Q + (u32)shift
    );

    if (v == 0ULL) v = 1ULL;
    if (v > 0xFFFFFFFFULL) v = 0xFFFFFFFFULL;

    return (u32)v;
}

/*
 * ReLU + find max directly in the integer accumulator domain.
 *
 * g_gemm layout is [S][OC].
 * Bias is added in the same integer unit as g_gemm.
 * The post-bias/ReLU integer is written back into g_gemm.
 */
static u32 prepare_relu_accumulator(
    s32 *acc,
    u32 s,
    u16 oc,
    const s32 *bias_int
)
{
    u32 sample;
    u16 out_ch;
    u32 max_positive = 0U;

    for (sample = 0U; sample < s; sample++) {
        for (out_ch = 0U; out_ch < oc; out_ch++) {
            u32 idx = sample * oc + out_ch;
            s32 v = acc[idx] + bias_int[out_ch];

            if (v < 0) v = 0;
            acc[idx] = v;

            if ((u32)v > max_positive) {
                max_positive = (u32)v;
            }
        }
    }

    return max_positive;
}

/*
 * Convert [S][OC] accumulator layout to CHW INT8 output while applying
 * the selected global shift to the whole layer output tensor.
 */
static void requant_acc_to_chw(
    const s32 *acc,
    s8 *y,
    u16 cout,
    u16 h,
    u16 w,
    u8 shift
)
{
    u16 oh;
    u16 ow;
    u16 oc;

    for (oh = 0U; oh < h; oh++) {
        for (ow = 0U; ow < w; ow++) {
            u32 sample = (u32)oh * w + ow;

            for (oc = 0U; oc < cout; oc++) {
                s32 v = acc[sample * cout + oc];
                y[((u32)oc * h + oh) * w + ow] =
                    requant_positive_roundup(v, shift);
            }
        }
    }
}

/*
 * MaxPool is exact in quantized domain because every value in the tensor
 * has the same positive scale.
 */
static void maxpool2x2_chw_q(
    const s8 *x,
    s8 *y,
    u16 c,
    u16 h,
    u16 w
)
{
    u16 oh_max = h / 2U;
    u16 ow_max = w / 2U;
    u16 ch;
    u16 oh;
    u16 ow;

    for (ch = 0U; ch < c; ch++) {
        for (oh = 0U; oh < oh_max; oh++) {
            for (ow = 0U; ow < ow_max; ow++) {
                u16 ih = oh * 2U;
                u16 iw = ow * 2U;
                s8 m;
                s8 v;

                m = x[((u32)ch * h + ih) * w + iw];

                v = x[((u32)ch * h + ih) * w + (iw + 1U)];
                if (v > m) m = v;

                v = x[((u32)ch * h + (ih + 1U)) * w + iw];
                if (v > m) m = v;

                v = x[((u32)ch * h + (ih + 1U)) * w + (iw + 1U)];
                if (v > m) m = v;

                y[((u32)ch * oh_max + oh) * ow_max + ow] = m;
            }
        }
    }
}

/*
 * GAP for the final 4x4 map.
 *
 * Input is 0..127. Sum range is 0..2032.
 * Divide by 16 using >>4 and use bit[3] as the round-up bit.
 * The activation scale does not change.
 */
static void global_average_pool_4x4_q(
    const s8 *x,
    s8 *y,
    u16 c
)
{
    u16 ch;

    for (ch = 0U; ch < c; ch++) {
        u32 i;
        u32 sum = 0U;
        u32 q;
        u32 round_bit;
        const s8 *p = x + (u32)ch * 16U;

        for (i = 0U; i < 16U; i++) {
            sum += (u32)(u8)p[i];
        }

        round_bit = (sum >> 3U) & 1U;
        q = (sum >> 4U) + round_bit;

        if (q > 127U) q = 127U;
        y[ch] = (s8)q;
    }
}

/*
 * Run a convolution whose input is already quantized INT8 with known scale.
 *
 * No input requantization occurs here.
 */
static int run_conv_q(
    SmallVGGV1 *net,
    const s8 *x_q,
    u32 inv_x_scale_q16,
    s8 *y_q,
    u32 *inv_y_scale_q16,
    u16 cin,
    u16 cout,
    u16 h,
    u16 w,
    const s32 *bias_over_ws_q16,
    u32 inv_weight_scale_q16,
    u16 w_offset,
    int verbose,
    const char *name
)
{
    u32 s = (u32)h * w;
    u32 k = (u32)cin * 9U;
    u32 out_elems = s * cout;
    u32 col_count;
    u32 max_positive;
    u8 shift;
    int status;

    if (s * k > SV_MAX_IM2COL_ELEMS ||
        out_elems > SV_MAX_GEMM_ELEMS ||
        cout > SV_MAX_BIAS_ELEMS) {
        return SMALLVGG_V1_ERR_ARG;
    }

    if (verbose) {
        xil_printf("[%s] S=%d K=%d OC=%d S_chunk=%d\r\n",
                   name,
                   (int)s,
                   (int)k,
                   (int)cout,
                   (int)MatMulV1_MaxSChunk((u16)k, cout));
    }

    col_count = im2col_chw_3x3_pad1(
        x_q,
        cin,
        h,
        w,
        g_im2col
    );

    if (col_count != s * k) {
        return SMALLVGG_V1_ERR_ARG;
    }

    status = MatMulV1_RunPreloaded(
        net->hw,
        g_im2col,
        g_gemm,
        (u16)s,
        (u16)k,
        cout,
        w_offset,
        MODEL_MATMUL_TIMEOUT
    );

    if (status != MATMUL_V1_OK) {
        return SMALLVGG_V1_ERR_MATMUL;
    }

    make_bias_int_q16(
        bias_over_ws_q16,
        g_bias_int,
        cout,
        inv_x_scale_q16
    );

    max_positive = prepare_relu_accumulator(
        g_gemm,
        s,
        cout,
        g_bias_int
    );

    shift = choose_requant_shift(max_positive);

    requant_acc_to_chw(
        g_gemm,
        y_q,
        cout,
        h,
        w,
        shift
    );

    *inv_y_scale_q16 = update_inv_scale_q16(
        inv_x_scale_q16,
        inv_weight_scale_q16,
        shift
    );

    if (verbose) {
        xil_printf("[%s] max_acc=%d shift=%d round_bit=%d\r\n",
                   name,
                   (int)max_positive,
                   (int)shift,
                   (shift == 0U) ? -1 : (int)shift - 1);
    }

    return SMALLVGG_V1_OK;
}

/*
 * FC1: INT8 input -> INT32 accumulator -> bias -> ReLU
 *      -> max-based shift/round-up -> INT8 output.
 */
static int run_fc_relu_q(
    SmallVGGV1 *net,
    const s8 *x_q,
    u32 inv_x_scale_q16,
    s8 *y_q,
    u32 *inv_y_scale_q16,
    u16 ic,
    u16 oc,
    const s32 *bias_over_ws_q16,
    u32 inv_weight_scale_q16,
    u16 w_offset,
    int verbose,
    const char *name
)
{
    u32 max_positive;
    u8 shift;
    u16 i;
    int status;

    if (ic > SV_MAX_FEATURE_ELEMS ||
        oc > SV_MAX_GEMM_ELEMS ||
        oc > SV_MAX_BIAS_ELEMS) {
        return SMALLVGG_V1_ERR_ARG;
    }

    if (verbose) {
        xil_printf("[%s] S=1 K=%d OC=%d\r\n",
                   name,
                   (int)ic,
                   (int)oc);
    }

    status = MatMulV1_RunPreloaded(
        net->hw,
        x_q,
        g_gemm,
        1U,
        ic,
        oc,
        w_offset,
        MODEL_MATMUL_TIMEOUT
    );

    if (status != MATMUL_V1_OK) {
        return SMALLVGG_V1_ERR_MATMUL;
    }

    make_bias_int_q16(
        bias_over_ws_q16,
        g_bias_int,
        oc,
        inv_x_scale_q16
    );

    max_positive = 0U;

    for (i = 0U; i < oc; i++) {
        s32 v = g_gemm[i] + g_bias_int[i];

        if (v < 0) v = 0;
        g_gemm[i] = v;

        if ((u32)v > max_positive) {
            max_positive = (u32)v;
        }
    }

    shift = choose_requant_shift(max_positive);

    for (i = 0U; i < oc; i++) {
        y_q[i] = requant_positive_roundup(
            g_gemm[i],
            shift
        );
    }

    *inv_y_scale_q16 = update_inv_scale_q16(
        inv_x_scale_q16,
        inv_weight_scale_q16,
        shift
    );

    if (verbose) {
        xil_printf("[%s] max_acc=%d shift=%d round_bit=%d\r\n",
                   name,
                   (int)max_positive,
                   (int)shift,
                   (shift == 0U) ? -1 : (int)shift - 1);
    }

    return SMALLVGG_V1_OK;
}

/*
 * FC2 is the final layer.
 *
 * All 10 outputs share the same positive accumulator scale, so:
 *
 *   argmax((acc + bias_int) * scale)
 *     == argmax(acc + bias_int)
 *
 * No floating-point logits are needed.
 */
static int run_fc_scores_q(
    SmallVGGV1 *net,
    const s8 *x_q,
    u32 inv_x_scale_q16,
    s32 *scores,
    u16 ic,
    u16 oc,
    const s32 *bias_over_ws_q16,
    u16 w_offset,
    int verbose,
    const char *name
)
{
    u16 i;
    int status;

    if (ic > SV_MAX_FEATURE_ELEMS ||
        oc > SV_MAX_GEMM_ELEMS ||
        oc > SV_MAX_BIAS_ELEMS) {
        return SMALLVGG_V1_ERR_ARG;
    }

    if (verbose) {
        xil_printf("[%s] S=1 K=%d OC=%d\r\n",
                   name,
                   (int)ic,
                   (int)oc);
    }

    status = MatMulV1_RunPreloaded(
        net->hw,
        x_q,
        g_gemm,
        1U,
        ic,
        oc,
        w_offset,
        MODEL_MATMUL_TIMEOUT
    );

    if (status != MATMUL_V1_OK) {
        return SMALLVGG_V1_ERR_MATMUL;
    }

    make_bias_int_q16(
        bias_over_ws_q16,
        g_bias_int,
        oc,
        inv_x_scale_q16
    );

    for (i = 0U; i < oc; i++) {
        scores[i] = g_gemm[i] + g_bias_int[i];
    }

    return SMALLVGG_V1_OK;
}


int SmallVGGV1_Init(SmallVGGV1 *net, MatMulHw *hw)
{
    u32 off = 0U;

    if (net == 0 || hw == 0) {
        return SMALLVGG_V1_ERR_ARG;
    }

    net->hw = hw;

    net->wmap.w0_conv1 = (u16)off;
    off += MatMulV1_WeightFootprint(27U, 32U);

    net->wmap.w1_conv2 = (u16)off;
    off += MatMulV1_WeightFootprint(288U, 32U);

    net->wmap.w2_conv3 = (u16)off;
    off += MatMulV1_WeightFootprint(288U, 64U);

    net->wmap.w3_conv4 = (u16)off;
    off += MatMulV1_WeightFootprint(576U, 64U);

    net->wmap.w4_conv5 = (u16)off;
    off += MatMulV1_WeightFootprint(576U, 96U);

    net->wmap.w5_conv6 = (u16)off;
    off += MatMulV1_WeightFootprint(864U, 96U);

    net->wmap.w6_fc1 = (u16)off;
    off += MatMulV1_WeightFootprint(96U, 128U);

    net->wmap.w7_fc2 = (u16)off;
    off += MatMulV1_WeightFootprint(128U, 10U);

    net->wmap.end = (u16)off;

    if (off > MATMUL_V1_WB_DEPTH) {
        return SMALLVGG_V1_ERR_WEIGHT_FIT;
    }

    return SMALLVGG_V1_OK;
}

int SmallVGGV1_PreloadWeights(SmallVGGV1 *net)
{
    int status;

    if (net == 0 || net->hw == 0) {
        return SMALLVGG_V1_ERR_ARG;
    }

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w0_conv1,
        27U,
        32U,
        net->wmap.w0_conv1
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w1_conv2,
        288U,
        32U,
        net->wmap.w1_conv2
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w2_conv3,
        288U,
        64U,
        net->wmap.w2_conv3
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w3_conv4,
        576U,
        64U,
        net->wmap.w3_conv4
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w4_conv5,
        576U,
        96U,
        net->wmap.w4_conv5
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w5_conv6,
        864U,
        96U,
        net->wmap.w5_conv6
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w6_fc1,
        96U,
        128U,
        net->wmap.w6_fc1
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(
        net->hw,
        g_w7_fc2,
        128U,
        10U,
        net->wmap.w7_fc2
    );
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    return SMALLVGG_V1_OK;
}

int SmallVGGV1_Run(
    SmallVGGV1 *net,
    const u8 img_chw[3 * 32 * 32],
    s32 scores[10],
    int verbose
)
{
    u32 inv_scale_a_q16;
    u32 inv_scale_b_q16;
    int status;

    if (net == 0 ||
        net->hw == 0 ||
        img_chw == 0 ||
        scores == 0) {
        return SMALLVGG_V1_ERR_ARG;
    }

    /*
     * Only the network input uses the original arbitrary symmetric scale.
     * This is required because normalized RGB contains negative values.
     */
    normalize_input(
        img_chw,
        g_input_float
    );

    inv_scale_a_q16 = quantize_symmetric_int8_preprocess(
        g_input_float,
        g_act_a,
        3U * 32U * 32U
    );

    if (verbose) {
        xil_printf("[input] original signed symmetric quantization\r\n");
    }

    /*
     * Conv1:
     * qA -> qB
     */
    status = run_conv_q(
        net,
        g_act_a,
        inv_scale_a_q16,
        g_act_b,
        &inv_scale_b_q16,
        3U,
        32U,
        32U,
        32U,
        g_bow0_conv1_q16,
        g_iws0_conv1_q16,
        net->wmap.w0_conv1,
        verbose,
        "conv1"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Conv2:
     * qB -> qA
     */
    status = run_conv_q(
        net,
        g_act_b,
        inv_scale_b_q16,
        g_act_a,
        &inv_scale_a_q16,
        32U,
        32U,
        32U,
        32U,
        g_bow1_conv2_q16,
        g_iws1_conv2_q16,
        net->wmap.w1_conv2,
        verbose,
        "conv2"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Pool1:
     * qA 32x32x32 -> qB 32x16x16
     * Scale is unchanged.
     */
    maxpool2x2_chw_q(
        g_act_a,
        g_act_b,
        32U,
        32U,
        32U
    );
    inv_scale_b_q16 = inv_scale_a_q16;

    if (verbose) {
        xil_printf("[pool1] 32x16x16\r\n");
    }

    /*
     * Conv3:
     * qB -> qA
     */
    status = run_conv_q(
        net,
        g_act_b,
        inv_scale_b_q16,
        g_act_a,
        &inv_scale_a_q16,
        32U,
        64U,
        16U,
        16U,
        g_bow2_conv3_q16,
        g_iws2_conv3_q16,
        net->wmap.w2_conv3,
        verbose,
        "conv3"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Conv4:
     * qA -> qB
     */
    status = run_conv_q(
        net,
        g_act_a,
        inv_scale_a_q16,
        g_act_b,
        &inv_scale_b_q16,
        64U,
        64U,
        16U,
        16U,
        g_bow3_conv4_q16,
        g_iws3_conv4_q16,
        net->wmap.w3_conv4,
        verbose,
        "conv4"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Pool2:
     * qB 64x16x16 -> qA 64x8x8
     */
    maxpool2x2_chw_q(
        g_act_b,
        g_act_a,
        64U,
        16U,
        16U
    );
    inv_scale_a_q16 = inv_scale_b_q16;

    if (verbose) {
        xil_printf("[pool2] 64x8x8\r\n");
    }

    /*
     * Conv5:
     * qA -> qB
     */
    status = run_conv_q(
        net,
        g_act_a,
        inv_scale_a_q16,
        g_act_b,
        &inv_scale_b_q16,
        64U,
        96U,
        8U,
        8U,
        g_bow4_conv5_q16,
        g_iws4_conv5_q16,
        net->wmap.w4_conv5,
        verbose,
        "conv5"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Conv6:
     * qB -> qA
     */
    status = run_conv_q(
        net,
        g_act_b,
        inv_scale_b_q16,
        g_act_a,
        &inv_scale_a_q16,
        96U,
        96U,
        8U,
        8U,
        g_bow5_conv6_q16,
        g_iws5_conv6_q16,
        net->wmap.w5_conv6,
        verbose,
        "conv6"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * Pool3:
     * qA 96x8x8 -> qB 96x4x4
     */
    maxpool2x2_chw_q(
        g_act_a,
        g_act_b,
        96U,
        8U,
        8U
    );
    inv_scale_b_q16 = inv_scale_a_q16;

    if (verbose) {
        xil_printf("[pool3] 96x4x4\r\n");
    }

    /*
     * GAP:
     * qB 96x4x4 -> g_gap_q[96]
     * Division by 16 is itself implemented as shift + round-up.
     * Scale is unchanged.
     */
    global_average_pool_4x4_q(
        g_act_b,
        g_gap_q,
        96U
    );

    if (verbose) {
        xil_printf("[gap] 96\r\n");
    }

    /*
     * FC1 + ReLU + shift requant:
     * g_gap_q -> g_fc1_q
     */
    status = run_fc_relu_q(
        net,
        g_gap_q,
        inv_scale_b_q16,
        g_fc1_q,
        &inv_scale_a_q16,
        96U,
        128U,
        g_bow6_fc1_q16,
        g_iws6_fc1_q16,
        net->wmap.w6_fc1,
        verbose,
        "fc1"
    );
    if (status != SMALLVGG_V1_OK) return status;

    /*
     * FC2:
     * final logits, no output requantization.
     */
    status = run_fc_scores_q(
        net,
        g_fc1_q,
        inv_scale_a_q16,
        scores,
        128U,
        10U,
        g_bow7_fc2_q16,
        net->wmap.w7_fc2,
        verbose,
        "fc2"
    );
    if (status != SMALLVGG_V1_OK) return status;

    return SMALLVGG_V1_OK;
}

u8 SmallVGGV1_Argmax(const s32 scores[10])
{
    u8 i;
    u8 best = 0U;

    for (i = 1U; i < 10U; i++) {
        if (scores[i] > scores[best]) {
            best = i;
        }
    }

    return best;
}
