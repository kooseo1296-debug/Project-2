/******************************************************************************
* Copyright (C) 2023 Advanced Micro Devices, Inc. All Rights Reserved.
* SPDX-License-Identifier: MIT
******************************************************************************/
/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include <stdio.h>
#include "platform.h"
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"

#include "matmul_hw.h"
#include "matmul_v1.h"
#include "smallvgg_v1.h"
#include "model_data.h"

#if defined(XPAR_MYIP_0_BASEADDR)
#define MATMUL_BASEADDR XPAR_MYIP_0_BASEADDR
#elif defined(XPAR_MYIP_0_S00_AXI_BASEADDR)
#define MATMUL_BASEADDR XPAR_MYIP_0_S00_AXI_BASEADDR
#else
#error "MatMul AXI base address macro not found in xparameters.h"
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

static MatMulHw g_hw;
static SmallVGGV1 g_net;
static s32 g_scores[SMALLVGG_NUM_CLASSES];

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
    u32 ms_whole = (u32)(us / 1000ULL);
    u32 ms_frac = (u32)(us % 1000ULL);

    xil_printf("%s: %d.%03d ms\r\n",
               name,
               (int)ms_whole,
               (int)ms_frac);
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
    u64 t_w0;
    u64 t_w1;
    u64 t_img0;
    u64 t_img1;
    u64 infer_cycles = 0ULL;
    u64 pl_execute_cycles;
    u64 non_execute_cycles;
    u64 avg_infer_cycles;
    u64 avg_pl_cycles;
    u32 pl_execute_count;
    u32 correct = 0U;
    u32 i;
    int status;

    init_platform();
    Xil_Out32(GTIMER_CONTROL_REG, 0x1U);

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf(" Project 2 V1 SmallVGG full test set\r\n");
    xil_printf("========================================\r\n");
    xil_printf("MatMul base address: 0x%08x\r\n", (u32)MATMUL_BASEADDR);
    xil_printf("N_TEST: %d\r\n", (int)MODEL_N_TEST);

    MatMulHw_Init(&g_hw, (UINTPTR)MATMUL_BASEADDR);

    status = SmallVGGV1_Init(&g_net, &g_hw);
    if (status != SMALLVGG_V1_OK) {
        xil_printf("[FAIL] SmallVGGV1_Init: %d\r\n", status);
        cleanup_platform();
        return status;
    }

    xil_printf("WB used: %d / %d addresses\r\n",
               (int)g_net.wmap.end,
               (int)MATMUL_V1_WB_DEPTH);

    xil_printf("\r\n>>> Preloading all weights...\r\n");

    t_w0 = Get_Global_Time();
    status = SmallVGGV1_PreloadWeights(&g_net);
    t_w1 = Get_Global_Time();

    if (status != SMALLVGG_V1_OK) {
        xil_printf("[FAIL] Weight preload: %d\r\n", status);
        cleanup_platform();
        return status;
    }

    print_ms_from_cycles("Weight preload", t_w1 - t_w0);

    xil_printf("\r\n>>> Running all images...\r\n");

    MatMulV1_ProfileReset();

    for (i = 0U; i < MODEL_N_TEST; i++) {
        const u8 *img = &g_test_images_chw[i * MODEL_IMG_SIZE];
        u8 label = g_test_labels[i];
        u8 pred;

        /*
         * End-to-end inference timing for this image.
         * Progress UART output occurs after t_img1 and is not included.
         */
        t_img0 = Get_Global_Time();

        status = SmallVGGV1_Run(
            &g_net,
            img,
            g_scores,
            0
        );

        t_img1 = Get_Global_Time();
        infer_cycles += (t_img1 - t_img0);

        if (status != SMALLVGG_V1_OK) {
            xil_printf("[FAIL] image %d: SmallVGGV1_Run=%d\r\n",
                       (int)i,
                       status);
            cleanup_platform();
            return status;
        }

        pred = SmallVGGV1_Argmax(g_scores);
        if (pred == label) correct++;

        if (((i + 1U) % PROGRESS_INTERVAL) == 0U ||
            (i + 1U) == MODEL_N_TEST) {
            xil_printf("%d/%d\r\n", (int)(i + 1U), (int)MODEL_N_TEST);
        }
    }

    pl_execute_cycles = MatMulV1_GetExecuteCycles();
    pl_execute_count = MatMulV1_GetExecuteCount();

    avg_infer_cycles = infer_cycles / (u64)MODEL_N_TEST;
    avg_pl_cycles = pl_execute_cycles / (u64)MODEL_N_TEST;

    if (infer_cycles >= pl_execute_cycles) {
        non_execute_cycles = infer_cycles - pl_execute_cycles;
    } else {
        non_execute_cycles = 0ULL;
    }

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf(" FULL DATASET RESULT\r\n");
    xil_printf("========================================\r\n");

    print_percent_2("Accuracy", correct, MODEL_N_TEST);

    xil_printf("\r\nEnd-to-end V1\r\n");
    print_ms_from_cycles("Inference total", infer_cycles);
    print_ms_from_cycles("Average / image", avg_infer_cycles);

    xil_printf("\r\nMatMul Execute -> DONE\r\n");
    print_ms_from_cycles("PL execute total", pl_execute_cycles);
    print_ms_from_cycles("PL execute average / image", avg_pl_cycles);
    xil_printf("MatMul execute calls: %d\r\n", (int)pl_execute_count);

    xil_printf("\r\nEverything outside Execute -> DONE\r\n");
    print_ms_from_cycles("Non-execute total", non_execute_cycles);
    print_ms_from_cycles("Non-execute average / image",
                         non_execute_cycles / (u64)MODEL_N_TEST);

    xil_printf("\r\nStartup\r\n");
    print_ms_from_cycles("Weight preload", t_w1 - t_w0);
    print_ms_from_cycles("Cold-start total",
                         (t_w1 - t_w0) + infer_cycles);

    xil_printf("\r\nNOTE: Execute -> DONE is measured from the PS Global Timer.\r\n");
    xil_printf("It includes execute-command issue and DONE polling/detection delay.\r\n");
    xil_printf("An RTL-internal cycle counter would be needed for exact PL-only cycles.\r\n");

    cleanup_platform();
    return 0;
}
