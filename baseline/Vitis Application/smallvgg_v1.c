#include "smallvgg_v1.h"
#include "matmul_v1.h"
#include "model_data.h"
#include "xil_printf.h"

#define SV_MAX_FEATURE_ELEMS  (32U * 32U * 32U)
#define SV_MAX_Q_ELEMS        SV_MAX_FEATURE_ELEMS
#define SV_MAX_IM2COL_ELEMS   (1024U * 288U)
#define SV_MAX_GEMM_ELEMS     (1024U * 32U)

static float g_feature_a[SV_MAX_FEATURE_ELEMS];
static float g_feature_b[SV_MAX_FEATURE_ELEMS];
static s8 g_q_feature[SV_MAX_Q_ELEMS];
static s8 g_im2col[SV_MAX_IM2COL_ELEMS];
static s32 g_gemm[SV_MAX_GEMM_ELEMS];
static float g_gap[96];
static float g_fc1[128];

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

static float quantize_symmetric_int8(const float *x, s8 *q, u32 n)
{
    u32 i;
    float max_abs = 0.0f;
    float scale;

    for (i = 0U; i < n; i++) {
        float a = (x[i] < 0.0f) ? -x[i] : x[i];
        if (a > max_abs) max_abs = a;
    }

    scale = (max_abs > 0.0f) ? (max_abs / 127.0f) : 1.0f;

    for (i = 0U; i < n; i++) {
        s32 v = round_to_even_f32(x[i] / scale);
        if (v > 127) v = 127;
        if (v < -128) v = -128;
        q[i] = (s8)v;
    }

    return scale;
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

static u32 im2col_chw_3x3_pad1(const s8 *x, u16 c, u16 h, u16 w, s8 *col)
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

                        if (ih >= 0 && ih < (int)h && iw >= 0 && iw < (int)w) {
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

static void maxpool2x2_chw(const float *x, float *y, u16 c, u16 h, u16 w)
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
                float m = x[((u32)ch * h + ih) * w + iw];
                float v;

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

static void global_average_pool_chw(const float *x, float *y, u16 c, u16 h, u16 w)
{
    u16 ch;
    u32 spatial = (u32)h * w;

    for (ch = 0U; ch < c; ch++) {
        u32 i;
        float sum = 0.0f;
        const float *p = x + (u32)ch * spatial;

        for (i = 0U; i < spatial; i++) sum += p[i];
        y[ch] = sum / (float)spatial;
    }
}

static int run_conv(
    SmallVGGV1 *net,
    const float *x,
    float *y,
    u16 cin,
    u16 cout,
    u16 h,
    u16 w,
    const float *bias,
    float w_scale,
    u16 w_offset,
    int verbose,
    const char *name
)
{
    u32 x_elems = (u32)cin * h * w;
    u32 s = (u32)h * w;
    u32 k = (u32)cin * 9U;
    u32 out_elems = s * cout;
    float x_scale;
    float out_scale;
    u32 col_count;
    u16 oh;
    u16 ow;
    u16 oc;
    int status;

    if (x_elems > SV_MAX_Q_ELEMS || s * k > SV_MAX_IM2COL_ELEMS || out_elems > SV_MAX_GEMM_ELEMS) return SMALLVGG_V1_ERR_ARG;

    if (verbose) {
        xil_printf("[%s] S=%d K=%d OC=%d S_chunk=%d\r\n",
                   name, (int)s, (int)k, (int)cout, (int)MatMulV1_MaxSChunk((u16)k, cout));
    }

    x_scale = quantize_symmetric_int8(x, g_q_feature, x_elems);
    col_count = im2col_chw_3x3_pad1(g_q_feature, cin, h, w, g_im2col);
    if (col_count != s * k) return SMALLVGG_V1_ERR_ARG;

    status = MatMulV1_RunPreloaded(net->hw, g_im2col, g_gemm, (u16)s, (u16)k, cout, w_offset, MODEL_MATMUL_TIMEOUT);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    out_scale = x_scale * w_scale;

    for (oh = 0U; oh < h; oh++) {
        for (ow = 0U; ow < w; ow++) {
            u32 sample = (u32)oh * w + ow;

            for (oc = 0U; oc < cout; oc++) {
                float v = (float)g_gemm[sample * cout + oc] * out_scale + bias[oc];
                if (v < 0.0f) v = 0.0f;
                y[((u32)oc * h + oh) * w + ow] = v;
            }
        }
    }

    return SMALLVGG_V1_OK;
}

static int run_fc(
    SmallVGGV1 *net,
    const float *x,
    float *y,
    u16 ic,
    u16 oc,
    const float *bias,
    float w_scale,
    u16 w_offset,
    int relu,
    int verbose,
    const char *name
)
{
    float x_scale;
    float out_scale;
    u16 i;
    int status;

    if (ic > SV_MAX_Q_ELEMS || oc > SV_MAX_GEMM_ELEMS) return SMALLVGG_V1_ERR_ARG;

    if (verbose) {
        xil_printf("[%s] S=1 K=%d OC=%d\r\n", name, (int)ic, (int)oc);
    }

    x_scale = quantize_symmetric_int8(x, g_q_feature, ic);

    status = MatMulV1_RunPreloaded(net->hw, g_q_feature, g_gemm, 1U, ic, oc, w_offset, MODEL_MATMUL_TIMEOUT);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    out_scale = x_scale * w_scale;

    for (i = 0U; i < oc; i++) {
        float v = (float)g_gemm[i] * out_scale + bias[i];
        if (relu && v < 0.0f) v = 0.0f;
        y[i] = v;
    }

    return SMALLVGG_V1_OK;
}

int SmallVGGV1_Init(SmallVGGV1 *net, MatMulHw *hw)
{
    u32 off = 0U;

    if (net == 0 || hw == 0) return SMALLVGG_V1_ERR_ARG;

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

    if (off > MATMUL_V1_WB_DEPTH) return SMALLVGG_V1_ERR_WEIGHT_FIT;
    return SMALLVGG_V1_OK;
}

int SmallVGGV1_PreloadWeights(SmallVGGV1 *net)
{
    int status;

    if (net == 0 || net->hw == 0) return SMALLVGG_V1_ERR_ARG;

    status = MatMulV1_LoadWeights(net->hw, g_w0_conv1, 27U, 32U, net->wmap.w0_conv1);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w1_conv2, 288U, 32U, net->wmap.w1_conv2);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w2_conv3, 288U, 64U, net->wmap.w2_conv3);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w3_conv4, 576U, 64U, net->wmap.w3_conv4);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w4_conv5, 576U, 96U, net->wmap.w4_conv5);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w5_conv6, 864U, 96U, net->wmap.w5_conv6);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w6_fc1, 96U, 128U, net->wmap.w6_fc1);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    status = MatMulV1_LoadWeights(net->hw, g_w7_fc2, 128U, 10U, net->wmap.w7_fc2);
    if (status != MATMUL_V1_OK) return SMALLVGG_V1_ERR_MATMUL;

    return SMALLVGG_V1_OK;
}

int SmallVGGV1_Run(SmallVGGV1 *net, const u8 img_chw[3 * 32 * 32], float logits[10], int verbose)
{
    int status;

    if (net == 0 || net->hw == 0 || img_chw == 0 || logits == 0) return SMALLVGG_V1_ERR_ARG;

    normalize_input(img_chw, g_feature_a);

    status = run_conv(net, g_feature_a, g_feature_b, 3U, 32U, 32U, 32U,
                      g_b0_conv1, g_ws0_conv1, net->wmap.w0_conv1, verbose, "conv1");
    if (status != SMALLVGG_V1_OK) return status;

    status = run_conv(net, g_feature_b, g_feature_a, 32U, 32U, 32U, 32U,
                      g_b1_conv2, g_ws1_conv2, net->wmap.w1_conv2, verbose, "conv2");
    if (status != SMALLVGG_V1_OK) return status;

    maxpool2x2_chw(g_feature_a, g_feature_b, 32U, 32U, 32U);
    if (verbose) xil_printf("[pool1] 32x16x16\r\n");

    status = run_conv(net, g_feature_b, g_feature_a, 32U, 64U, 16U, 16U,
                      g_b2_conv3, g_ws2_conv3, net->wmap.w2_conv3, verbose, "conv3");
    if (status != SMALLVGG_V1_OK) return status;

    status = run_conv(net, g_feature_a, g_feature_b, 64U, 64U, 16U, 16U,
                      g_b3_conv4, g_ws3_conv4, net->wmap.w3_conv4, verbose, "conv4");
    if (status != SMALLVGG_V1_OK) return status;

    maxpool2x2_chw(g_feature_b, g_feature_a, 64U, 16U, 16U);
    if (verbose) xil_printf("[pool2] 64x8x8\r\n");

    status = run_conv(net, g_feature_a, g_feature_b, 64U, 96U, 8U, 8U,
                      g_b4_conv5, g_ws4_conv5, net->wmap.w4_conv5, verbose, "conv5");
    if (status != SMALLVGG_V1_OK) return status;

    status = run_conv(net, g_feature_b, g_feature_a, 96U, 96U, 8U, 8U,
                      g_b5_conv6, g_ws5_conv6, net->wmap.w5_conv6, verbose, "conv6");
    if (status != SMALLVGG_V1_OK) return status;

    maxpool2x2_chw(g_feature_a, g_feature_b, 96U, 8U, 8U);
    if (verbose) xil_printf("[pool3] 96x4x4\r\n");

    global_average_pool_chw(g_feature_b, g_gap, 96U, 4U, 4U);
    if (verbose) xil_printf("[gap] 96\r\n");

    status = run_fc(net, g_gap, g_fc1, 96U, 128U,
                    g_b6_fc1, g_ws6_fc1, net->wmap.w6_fc1, 1, verbose, "fc1");
    if (status != SMALLVGG_V1_OK) return status;

    status = run_fc(net, g_fc1, logits, 128U, 10U,
                    g_b7_fc2, g_ws7_fc2, net->wmap.w7_fc2, 0, verbose, "fc2");
    if (status != SMALLVGG_V1_OK) return status;

    return SMALLVGG_V1_OK;
}

u8 SmallVGGV1_Argmax(const float logits[10])
{
    u8 i;
    u8 best = 0U;

    for (i = 1U; i < 10U; i++) {
        if (logits[i] > logits[best]) best = i;
    }

    return best;
}
