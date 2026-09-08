#include <stdio.h>
#include "platform.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"

#include "npu_v2_hw.h"
#include "preprocess_v2.h"
#include "model_data.h"

#if defined(XPAR_MYIP_0_BASEADDR)
#define NPU_BASEADDR XPAR_MYIP_0_BASEADDR
#elif defined(XPAR_MYIP_0_S00_AXI_BASEADDR)
#define NPU_BASEADDR XPAR_MYIP_0_S00_AXI_BASEADDR
#else
#error "NPU AXI base address macro not found in xparameters.h"
#endif

#ifndef XPAR_GLOBAL_TIMER_BASEADDR
#error "XPAR_GLOBAL_TIMER_BASEADDR not found in xparameters.h"
#endif

#define GLOBAL_TIMER_BASEADDR  XPAR_GLOBAL_TIMER_BASEADDR
#define GTIMER_LOW_REG         (GLOBAL_TIMER_BASEADDR + 0x00U)
#define GTIMER_HIGH_REG        (GLOBAL_TIMER_BASEADDR + 0x04U)
#define GTIMER_CONTROL_REG     (GLOBAL_TIMER_BASEADDR + 0x08U)

#if defined(XPAR_CPU_CORE_CLOCK_FREQ_HZ)
#define CPU_CLOCK_FREQ_HZ      XPAR_CPU_CORE_CLOCK_FREQ_HZ
#elif defined(XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ)
#define CPU_CLOCK_FREQ_HZ      XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ
#elif defined(XPAR_PS7_CORTEXA9_0_CPU_CLK_FREQ_HZ)
#define CPU_CLOCK_FREQ_HZ      XPAR_PS7_CORTEXA9_0_CPU_CLK_FREQ_HZ
#else
#error "CPU clock frequency macro not found in xparameters.h"
#endif

#define GLOBAL_TIMER_FREQ_HZ   (CPU_CLOCK_FREQ_HZ / 2U)
#define PROGRESS_INTERVAL      100U

static NpuV2Hw g_hw;
static s8 g_input_q[MODEL_IMG_SIZE];
static s32 g_scores[10];

static inline u64 Get_Global_Time(void)
{
    u32 low_val = Xil_In32(GTIMER_LOW_REG);
    u32 high_val = Xil_In32(GTIMER_HIGH_REG);
    return ((u64)high_val << 32) | (u64)low_val;
}

static inline u64 cycles_to_us_u64(u64 cycles)
{
    return (cycles * 1000000ULL) / (u64)GLOBAL_TIMER_FREQ_HZ;
}

static void print_ms_from_cycles(const char *name, u64 cycles)
{
    u64 us = cycles_to_us_u64(cycles);
    xil_printf("%s: %d.%03d ms\r\n",
               name,
               (int)(us / 1000ULL),
               (int)(us % 1000ULL));
}

static void print_percent_2(const char *name, u32 num, u32 den)
{
    u32 hundredths;

    if (den == 0U) {
        xil_printf("%s: N/A\r\n", name);
        return;
    }

    hundredths = (u32)(((u64)num * 10000ULL + den / 2U) / den);

    xil_printf("%s: %d/%d = %d.%02d%%\r\n",
               name,
               (int)num,
               (int)den,
               (int)(hundredths / 100U),
               (int)(hundredths % 100U));
}

int main(void)
{
    u64 t_model0;
    u64 t_model1;
    u64 t_img0;
    u64 t_img1;
    u64 t_pre0;
    u64 t_pre1;
    u64 t_pl0;
    u64 t_pl1;
    u64 infer_cycles = 0ULL;
    u64 preprocess_cycles = 0ULL;
    u64 pl_cycles = 0ULL;
    u32 correct = 0U;
    u32 i;
    int status;

    init_platform();
    Xil_Out32(GTIMER_CONTROL_REG, 0x1U);

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf(" Project 2 V2 Q16/Q32 full test set\r\n");
    xil_printf("========================================\r\n");
    xil_printf("NPU base address: 0x%08x\r\n", (u32)NPU_BASEADDR);
    xil_printf("N_TEST: %d\r\n", (int)MODEL_N_TEST);
    xil_printf("0x0C: LOW/HIGH two-write 32-bit parameter protocol\r\n");
    xil_printf("Startup params: 0..529, per-image param: 530\r\n");
    xil_printf("Preprocess: verified 91.5%% normalization + INT8 quantization\r\n");

    NpuV2_Init(&g_hw, (UINTPTR)NPU_BASEADDR);

    xil_printf("\r\n>>> Preloading weights + parameters 0..529...\r\n");

    t_model0 = Get_Global_Time();
    status = NpuV2_PreloadModel(&g_hw);
    t_model1 = Get_Global_Time();

    if (status != NPU_V2_OK) {
        xil_printf("[FAIL] Model preload: %d\r\n", status);
        cleanup_platform();
        return status;
    }

    print_ms_from_cycles("Model preload", t_model1 - t_model0);

    xil_printf("\r\n>>> Running all images...\r\n");

    for (i = 0U; i < MODEL_N_TEST; i++) {
        const u8 *img = &g_test_images_chw[i * MODEL_IMG_SIZE];
        u8 label = g_test_labels[i];
        u8 pred;
        u32 inv_input_scale_q16;

        t_img0 = Get_Global_Time();

        /* PS preprocessing; returns parameter 530 for THIS image. */
        t_pre0 = t_img0;
        inv_input_scale_q16 = PreprocessV2_Image(img, g_input_q);
        t_pre1 = Get_Global_Time();
        preprocess_cycles += (t_pre1 - t_pre0);

        /*
         * Includes:
         *   parameter 530 LOW/HIGH writes
         *   R/G/B upload
         *   full PL Conv1..FC2 inference
         *   DONE polling + 10 logits
         */
        t_pl0 = t_pre1;
        status = NpuV2_RunImage(
            &g_hw,
            g_input_q,
            inv_input_scale_q16,
            g_scores,
            NPU_V2_DEFAULT_TIMEOUT
        );
        t_pl1 = Get_Global_Time();
        pl_cycles += (t_pl1 - t_pl0);

        t_img1 = t_pl1;
        infer_cycles += (t_img1 - t_img0);

        if (status != NPU_V2_OK) {
            xil_printf("[FAIL] image %d: RunImage=%d RCODE=0x%08x\r\n",
                       (int)i,
                       status,
                       (u32)NpuV2_GetRcode(&g_hw));
            cleanup_platform();
            return status;
        }

        pred = NpuV2_Argmax(g_scores);
        if (pred == label)
            correct++;

        if (((i + 1U) % PROGRESS_INTERVAL) == 0U ||
            (i + 1U) == MODEL_N_TEST) {
            xil_printf("%d/%d\r\n", (int)(i + 1U), (int)MODEL_N_TEST);
        }
    }

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf(" FULL DATASET RESULT\r\n");
    xil_printf("========================================\r\n");
    print_percent_2("Accuracy", correct, MODEL_N_TEST);

    xil_printf("\r\nEnd-to-end V2\r\n");
    print_ms_from_cycles("Inference total", infer_cycles);
    print_ms_from_cycles("Average / image",
                         infer_cycles / (u64)MODEL_N_TEST);

    xil_printf("\r\nPS preprocessing\r\n");
    print_ms_from_cycles("Preprocess total", preprocess_cycles);
    print_ms_from_cycles("Preprocess average / image",
                         preprocess_cycles / (u64)MODEL_N_TEST);

    xil_printf("\r\nParameter530 + RGB upload + PL inference + logits\r\n");
    print_ms_from_cycles("PL path total", pl_cycles);
    print_ms_from_cycles("PL path average / image",
                         pl_cycles / (u64)MODEL_N_TEST);

    xil_printf("\r\nStartup\r\n");
    print_ms_from_cycles("Model preload", t_model1 - t_model0);
    print_ms_from_cycles("Cold-start total",
                         (t_model1 - t_model0) + infer_cycles);

    cleanup_platform();
    return 0;
}
