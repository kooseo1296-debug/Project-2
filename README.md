# Project 2: End-to-End FPGA NPU with Reduced PS-PL Communication

## Overview

This project investigates how the execution partition between the Processing System (PS) and Programmable Logic (PL) affects end-to-end CNN inference latency, PS-PL communication overhead, hardware cost, and practical live-camera performance on PYNQ-Z2.

The previous FPGA NPU accelerated tiled matrix multiplication in the PL, but convolution scheduling, `im2col`, post-processing, requantization, and repeated intermediate-data movement were managed by the PS. Project 2 reorganizes that execution model so that the complete CNN from Conv1 through FC2 executes inside the PL after input preprocessing and the required scale metadata are staged.

Two engines were implemented and evaluated:

1. **Baseline Engine (V1)** — PS-managed inference; PL primarily executes tiled MatMul.
2. **End-to-End Engine (V2)** — Conv1 through FC2 are scheduled and executed inside the PL.

The project is concluded at V2 after full-dataset validation and a PYNQ/Jupyter USB-camera live demonstration.

---

## Live Demo

- [Watch the V2 Live Camera Demo](https://drive.google.com/file/d/1bns6vxbrneyFb1yLkzVsFXlarAnewryC/view?usp=drive_link)
- [Open the Live-Demo Notebook](../v2/v2_live_demo/V2_Final_Live_Camera_Demo_Single.ipynb)
- [Live-Demo Documentation](v2/v2_live_demo/README.md)

```text
HCAM01L USB webcam
        |
        v
PYNQ Linux / OpenCV
        |
        v
center crop + resize to 32 x 32
        |
        v
BGR -> RGB
        |
        v
CIFAR-10 mean/std normalization
        |
        v
global signed INT8 input quantization
        |
        v
AXI4-Lite input staging
        |
        v
V2 FPGA NPU: Conv1 -> ... -> FC2
        |
        v
10 logits / predicted class
        |
        v
Jupyter live display
```

The controlled benchmark and the live-camera demonstration measure different scopes:

| Measurement | Result | Scope |
|---|---:|---|
| CIFAR-10 accuracy | 91.5% | 1,000-image validation |
| Vitis end-to-end latency | 5.004 ms/image | preprocessing + host staging + PL inference + logits |
| Live-demo throughput | ~5 FPS | complete camera/Jupyter/display path |

The ~5 FPS result is therefore **not** interpreted as RTL-only NPU throughput.

---

## Headline Result

| Metric | V1 Baseline | V2 End-to-End | Change |
|---|---:|---:|---:|
| Accuracy | 91.90% | 91.50% | -0.40%p |
| Time / image | 338.03 ms | 5.004 ms | -98.52% |
| Equivalent benchmark throughput | 2.96 img/s | 199.84 img/s | 67.55x |
| Estimated energy / image | 566.199 mJ | 8.582 mJ | -98.48% |
| LUT | 3,060 | 4,477 | +46.31% |
| LUTRAM | 560 | 1,042 | +86.07% |
| FF | 6,175 | 7,649 | +23.87% |
| BRAM | 116.5 | 116.5 | unchanged |
| DSP | 144 | 144 | unchanged |
| 125 MHz setup slack | +0.041 ns | +0.119 ns | both meet timing |

The Vitis result is well below the `33.3 ms/frame` compute budget corresponding to 30 FPS. Camera capture, Python/Jupyter execution, rendering, and display are outside that controlled benchmark and are measured separately.

> Energy values use Vivado implementation power estimates multiplied by measured end-to-end inference latency. They are system-level estimates, not direct NPU-only board-power measurements.

---

## Motivation

For the V1 baseline:

```text
End-to-end inference : 338.029 ms / image
PL MatMul execute     :   5.803 ms / image
Other PS / transfer   : 332.226 ms / image
```

The baseline repeatedly performs:

```text
PS: im2col / layer processing
        |
        v
PS -> PL activation load
        |
        v
PL: tiled MatMul
        |
        v
PL -> PS Product Buffer readback
        |
        v
PS: ReLU / pooling / requantization / next-layer preparation
        |
        v
repeat
```

The main research question was:

> How much end-to-end latency can be removed by keeping CNN scheduling and intermediate feature processing inside the PL?

---

## Target Model

```text
Input 3 x 32 x 32
  -> Conv1  3 -> 32
  -> Conv2 32 -> 32 -> MaxPool
  -> Conv3 32 -> 64
  -> Conv4 64 -> 64 -> MaxPool
  -> Conv5 64 -> 96
  -> Conv6 96 -> 96 -> MaxPool
  -> GAP
  -> FC1 96 -> 128
  -> FC2 128 -> 10
```

All convolution layers use `3 x 3`, stride 1, padding 1.

See [Inference Model Documentation](docs/inference_model.md).

---

## Common Hardware Platform

```text
Platform         : PYNQ-Z2 / Zynq-7020
Target workload  : CIFAR-10 Model 2
Compute array    : 9 x 16 weight-stationary systolic array
Processing PEs   : 144
PS-PL interface  : 32-bit AXI4-Lite
Vivado           : 2025.2.1
Vitis            : 2025.2
Target clock     : 125 MHz
NPU base address : 0x40000000
```

```text
ARM Cortex-A9
     |
     | M_AXI_GP0
     v
AXI SmartConnect
     |
     | 32-bit AXI4-Lite
     v
Custom NPU IP
```

---

# Engine 1 — Baseline

V1 uses the PL as a tiled matrix-multiplication accelerator while the PS remains responsible for network-level execution.

```text
Startup
  -> Preload weights

Per image
  -> Normalize / quantize input
  -> Prepare im2col activation
  -> Load activation
  -> Configure S / IC / OC / WOffset
  -> Execute MatMul
  -> Read Product Buffer
  -> PS post-processing / requantization
  -> Repeat for the next layer
```

Dominant payload operations:

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 transactions / image
```

Result:

```text
Accuracy              : 919 / 1000 = 91.90%
End-to-end time       : 338.029 ms / image
PL execute subtotal   :   5.803 ms / image
Target clock          : 125 MHz, met
Estimated on-chip Pwr : 1.675 W
Estimated energy/img  : 566.199 mJ
```

---

# Engine 2 — End-to-End PL Inference

V2 keeps the same 9 x 16 systolic array, buffers, AXI4-Lite system, and tiling concept, but moves CNN scheduling and intermediate post-processing into the PL.

```text
PS
 |
 | input normalization / quantization
 | write image-dependent input-scale metadata
 | upload 3072 INT8 RGB values
 |
 v
+--------------------------------------------------+
|                       PL                         |
| Conv / MatMul -> Bias -> ReLU -> Requant        |
|        |                         |               |
|        +------ Product Buffer <--+               |
|                    |                             |
|               Next layer ...                    |
|                    |                             |
|               GAP -> FC1 -> FC2                  |
+--------------------+-----------------------------+
                     |
                     +---- 10 logits -> PS
```

### Numerical decisions

| Configuration | Accuracy | Decision |
|---|---:|---|
| V1 reference | 91.9% | baseline |
| Original normalization + shift-based requantization | 91.5% | adopted |
| Simplified normalization + shift-based requantization | 10.9% | rejected |

### Verified V2 parameter protocol

```text
Startup:
Parameters   0..521 : bias_over_ws_q16
Parameters 522..529 : inv_weight_scale_q16

Per image:
Parameter         530: inv_input_scale_q16
```

A complete 32-bit parameter is transferred through `0x0C` using two AXI4-Lite writes:

```text
LOW  = {0, ParamNumber[14:0], Value[15:0]}
HIGH = {1, ParamNumber[14:0], Value[31:16]}
```

Per-image steady-state payload:

```text
Parameter-530 writes  :    2
RGB activation writes : 3072
Final logit reads     :   10
----------------------------
Total                 : 3084 transactions / image
```

Status polling is excluded from this payload metric.

---

# V1 vs. V2

| Metric | V1 | V2 | Relative Change |
|---|---:|---:|---:|
| LUT | 3,060 | 4,477 | +46.31% |
| LUTRAM | 560 | 1,042 | +86.07% |
| FF | 6,175 | 7,649 | +23.87% |
| BRAM | 116.5 | 116.5 | 0% |
| DSP | 144 | 144 | 0% |
| Accuracy | 91.90% | 91.50% | -0.40%p |
| Time / image | 338.03 ms | 5.004 ms | -98.52% |
| Estimated energy / image | 566.199 mJ | 8.582 mJ | -98.48% |
| Steady-state payload transactions / image | 748,650 | 3,084 | -99.59% |

At `5.004 ms/image`, the controlled benchmark corresponds to approximately `199.84 images/s`, or `67.55x` the V1 end-to-end throughput.

---

# Scope Decision and Project Conclusion

An activation row-level ZeroSkip extension was initially considered as a possible next architectural stage.

However, the completed V2 live-camera demonstration revealed that application-level throughput is no longer primarily limited by NPU MAC execution time.

```text
Controlled V2 benchmark : 5.004 ms / image
Live PYNQ/Jupyter demo   : ~5 FPS (~200 ms / displayed frame)
```

These measurements have different scopes and should **not** be directly converted into an RTL speedup estimate. Nevertheless, the large gap shows that reducing a few additional milliseconds of MAC execution would not materially change the current application-level live-demo FPS.

For this reason, ZeroSkip was not implemented as part of Project 2.

Project 2 is concluded at V2 after demonstrating:

- end-to-end Conv1-to-FC2 execution inside the PL;
- 91.5% CIFAR-10 validation accuracy;
- 5.004 ms/image controlled Vitis latency;
- 67.55x speedup over the V1 PS-managed baseline;
- approximately 99.59% reduction in the steady-state payload-transaction metric;
- successful 1,000-image PYNQ/Jupyter cross-validation;
- successful USB-camera live inference on PYNQ-Z2.

Further improvement of practical live-video throughput would require profiling and optimizing the full host/runtime/display pipeline rather than focusing only on additional MAC-cycle reduction.

---

# Final Status

```text
V1 Baseline
  [DONE]
  91.9%
  338.03 ms/image
        |
        v
V2 End-to-End PL
  [DONE]
  91.5%
  5.004 ms/image
  125 MHz timing met
        |
        v
V2 PYNQ/Jupyter Live Camera Demo
  [DONE]
  HCAM01L -> PYNQ-Z2 -> V2 NPU
  ~5 FPS application/display throughput
        |
        v
PROJECT 2 COMPLETE
```

---

# Documentation

- [Inference Model](docs/inference_model.md)
- [Architecture](docs/architecture.md)
- [Matrix Tiling and Buffer Mapping](../docs/tiling_logic.md)
- [AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)
- [Experimental Results](docs/Experiments.md)
- [V2 Live Camera Demo](v2/v2_live_demo/README.md)
