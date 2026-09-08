#include "preprocess_v2.h"
#include "model_data.h"

#define INPUT_ELEMS (3U * 32U * 32U)

static float g_input_float[INPUT_ELEMS];

static s32 floor_to_s32(float x)
{
    s32 t = (s32)x;
    if (x < 0.0f && (float)t != x)
        t--;
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

u32 PreprocessV2_Image(
    const u8 img_chw[INPUT_ELEMS],
    s8 q_chw[INPUT_ELEMS]
)
{
    u32 c;
    u32 hw;
    u32 i;
    float max_abs = 0.0f;
    float scale;
    float inv_scale;
    s32 inv_q;

    if (img_chw == 0 || q_chw == 0)
        return MODEL_SCALE_ONE;

    /* Original trained-model normalization. */
    for (c = 0U; c < 3U; c++) {
        for (hw = 0U; hw < 1024U; hw++) {
            u32 idx = c * 1024U + hw;
            float x = (float)img_chw[idx] / 255.0f;
            g_input_float[idx] =
                (x - g_normalize_mean[c]) / g_normalize_std[c];
        }
    }

    /* One global signed-symmetric input scale over all 3072 values. */
    for (i = 0U; i < INPUT_ELEMS; i++) {
        float a = (g_input_float[i] < 0.0f) ?
                  -g_input_float[i] : g_input_float[i];
        if (a > max_abs)
            max_abs = a;
    }

    scale = (max_abs > 0.0f) ? (max_abs / 127.0f) : 1.0f;

    for (i = 0U; i < INPUT_ELEMS; i++) {
        s32 v = round_to_even_f32(g_input_float[i] / scale);

        if (v > 127)  v = 127;
        if (v < -128) v = -128;
        q_chw[i] = (s8)v;
    }

    /* Q16 reciprocal metadata for RTL scale tracking. */
    inv_scale = 1.0f / scale;
    inv_q = round_to_even_f32(inv_scale * (float)MODEL_SCALE_ONE);

    if (inv_q < 1)
        inv_q = 1;

    return (u32)inv_q;
}
