# Project 2: End-to-End FPGA NPU with Activation Row-Level Zero-Skipping

## Overview

This project investigates how the execution structure of an FPGA-based neural processing unit (NPU) affects CIFAR-10 inference latency, PS-PL communication, hardware cost, and practical live-demo behavior.

The work extends a previous PYNQ-Z2 FPGA NPU in which the Programmable Logic (PL) primarily accelerated tiled matrix multiplication while convolution scheduling, `im2col`, post-processing, requantization, and repeated intermediate-data movement were managed by the Processing System (PS).

Project 2 reorganizes that execution model so that the complete CNN from Conv1 through FC2 can execute inside the PL after the input image and required scale metadata are staged.

The project roadmap is:

1. **Baseline Engine (V1)** — PS-managed inference; PL primarily executes tiled MatMul.
2. **End-to-End Engine (V2)** — Conv1 through FC2 are scheduled and executed inside the PL.
3. **Zero-Skip Engine (V3)** — V2 extended with **activation row-level ZeroSkip**.

V1 and V2 are implemented and evaluated on PYNQ-Z2.  
The V2 PYNQ/Jupyter live-camera demonstration is also complete.  
V3 is the next architectural step.

---

## Live Demo

The verified V2 accelerator has been integrated into a camera-driven PYNQ/Jupyter demonstration.

- [Watch the V2 Live Camera Demo](https://drive.google.com/file/d/1bns6vxbrneyFb1yLkzVsFXlarAnewryC/view?usp=drive_link)
- [Open the Live-Demo Notebook](v2/v2_live_demo/V2_Final_Live_Camera_Demo_Single.ipynb)
- [Live-Demo Setup and Usage](v2/v2_live_demo/README.md)

The live path is:

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
V2 FPGA NPU
Conv1 -> ... -> FC2
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
| Current live-demo throughput | ~5 FPS | complete camera/Jupyter/display path |

The ~5 FPS live-demo rate is therefore **not** interpreted as RTL-only NPU throughput.

---

## Headline Result

The implemented V2 engine reduces measured end-to-end inference latency from `338.03 ms/image` to `5.004 ms/image` while maintaining nearly the same CIFAR-10 accuracy.

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

The Vitis result is well below the `33.3 ms/frame` compute budget corresponding to 30 FPS.

Camera capture, Python/Jupyter execution, rendering, and display are outside that controlled benchmark and are measured separately in the live-demo path.

> The energy values use Vivado implementation power estimates multiplied by measured end-to-end inference latency. They are system-level estimates, not direct NPU-only board-power measurements.

---

## Motivation

The original Jupyter-based live-demo pipeline of the earlier PS-managed accelerator required very long per-image execution in the demonstration environment.

The primary problem was not the systolic-array MAC itself. Repeated software intervention and PS-PL data movement were required around every weighted layer.

For a controlled comparison, the V1 baseline was re-measured in Vitis:

```text
V1 end-to-end inference : 338.029 ms / image
PL MatMul execute       :   5.803 ms / image
Other PS / transfer     : 332.226 ms / image
```

The V1 execution structure repeatedly performs:

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

The main V1-to-V2 research question is therefore:

> How much end-to-end latency can be removed by keeping CNN scheduling and intermediate feature processing inside the PL?

---

## Target Model

Project 2 uses the same CIFAR-10 Model 2 workload throughout the V1/V2 comparison:

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

All convolution layers use:

```text
Kernel  : 3 x 3
Stride  : 1
Padding : 1
```

For detailed numerical behavior, see:

[Inference Model Documentation](docs/inference_model.md)

---

## Common Hardware Platform

```text
Platform        : PYNQ-Z2 / Zynq-7020
Target workload : CIFAR-10 Model 2
Compute array   : 9 x 16 weight-stationary systolic array
Processing PEs  : 144
PS-PL interface : 32-bit AXI4-Lite
Vivado          : 2025.2.1
Vitis           : 2025.2
Target clock    : 125 MHz
NPU base address: 0x40000000
```

System-level connection:

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

The PS is the AXI master and the custom NPU is the AXI slave.

Polling is used instead of interrupts.

For additional details:

- [Architecture](docs/architecture.md)
- [AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)
- [Tiling and Buffer Mapping](docs/tiling_logic.md)
- [Experimental Results](docs/Experiments.md)

---

# Engine 1 — Baseline

## PS-Managed Inference

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

### V1 Communication Cost

The dominant steady-state payload operations per image are:

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 transactions / image
```

This architectural payload metric excludes status polling and other small control operations.

### V1 Result

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

V2 keeps the same 9 x 16 systolic array, Weight Buffer, Activation Buffer, Product Buffer, AXI4-Lite system, and basic tiling concept.

The main change is that network scheduling and intermediate post-processing are moved into the PL.

After the original image is normalized and quantized on the PS, the PL executes Conv1 through FC2 without returning intermediate feature maps to the PS.

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
|                                                  |
| Conv / MatMul -> Bias -> ReLU -> Requant        |
|        |                         |               |
|        +------ Product Buffer <--+               |
|                    |                             |
|               Next layer                        |
|                    |                             |
|                   ...                            |
|                    |                             |
|               GAP -> FC1 -> FC2                  |
+--------------------+-----------------------------+
                     |
                     +---- 10 logits -> PS
```

---

## V2 Numerical Decisions

Hardware-oriented arithmetic changes were checked before being committed to RTL.

| Configuration | Accuracy | Decision |
|---|---:|---|
| V1 reference | 91.9% | baseline |
| Original normalization + shift-based requantization | 91.5% | adopted |
| Simplified normalization + shift-based requantization | 10.9% | rejected |

Therefore:

- the original CIFAR-10 mean/std normalization remains on the PS;
- the initial input tensor is globally quantized to signed INT8;
- intermediate requantization uses shift + rounding in the PL;
- ReLU executes in the PL;
- max pooling executes in the PL;
- GAP executes in the PL;
- FC1 and FC2 execute in the PL;
- final FC2 logits are returned to the PS.

---

## Shift-Based Requantization

The hardware-friendly operation is conceptually:

```text
q = round(x / 2^shift)
```

The shift is selected from the output activation range.

The result is then rounded and saturated into the target INT8 domain.

For GAP, 16 spatial values are accumulated and division by 16 is implemented using a 4-bit right shift plus rounding.

---

## Verified V2 Parameter Protocol

The final verified implementation separates model-static parameters from one image-dependent input-scale parameter.

At startup, the host preloads:

```text
Parameters   0..521 : bias_over_ws_q16
Parameters 522..529 : inv_weight_scale_q16
```

The 522 bias-related entries correspond to:

```text
Conv1 :  32
Conv2 :  32
Conv3 :  64
Conv4 :  64
Conv5 :  96
Conv6 :  96
FC1   : 128
FC2   :  10
----------------
Total : 522
```

For each image, the host writes only:

```text
Parameter 530 : inv_input_scale_q16
```

A complete 32-bit parameter is transferred through `0x0C` using two AXI4-Lite writes:

```text
LOW  = {0, ParamNumber[14:0], Value[15:0]}
HIGH = {1, ParamNumber[14:0], Value[31:16]}
```

This is the protocol used by both the verified V2 Vitis application and the final Jupyter live-demo driver.

---

## V2 Startup and Per-Image Workflow

```text
Startup once:
    0. Preload all INT8 weights
    1. Preload parameters 0..521: bias_over_ws_q16
    2. Preload parameters 522..529: inv_weight_scale_q16

Per image:
    1. Normalize and globally quantize the RGB image
    2. Write parameter 530: inv_input_scale_q16
    3. Upload R, G, B INT8 channels
       1024 + 1024 + 1024 = 3072 values
    4. Execute Conv1 through FC2 inside the PL
    5. Read 10 final logits
```

The steady-state per-image logical payload is:

```text
Input-scale parameter :    1
RGB activation values : 3072
Final logits          :   10
----------------------------
Total                 : 3083 logical values / image
```

Because parameter 530 uses LOW/HIGH half-writes, the corresponding payload-transaction count is:

```text
Parameter-530 writes  :    2
RGB activation writes : 3072
Final logit reads     :   10
----------------------------
Total                 : 3084 transactions / image
```

Status polling is excluded from this payload metric.

---

## V2 RTL Functional Partition

The V2 implementation distributes network-level scheduling and post-processing across several blocks.

### `Ctrl`

- layer sequencing;
- convolution scheduling;
- pooling / GAP control;
- scale-related control;
- address generation.

### `sa_to_pb`

- ReLU;
- activation magnitude / shift-candidate tracking.

### `Biggest`

- layer-wide maximum shift selection.

### `ctrl_to_pb`

- shift-based requantization;
- rounding;
- saturation;
- max-pooling processing;
- result steering.

### Product Loader / Product Buffer Feedback

- K-tile partial-sum reuse;
- intermediate-feature reuse;
- accumulation-domain data injection.

Detailed behavior is documented in:

[Architecture Documentation](docs/architecture.md)

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

The central observation is that V2 accepts moderate LUT/LUTRAM/FF overhead while preserving the same BRAM and DSP footprint and removing almost all layer-by-layer PS-PL traffic.

At `5.004 ms/image`, the controlled benchmark corresponds to approximately:

```text
199.84 images/s
```

or approximately:

```text
67.55x
```

the V1 end-to-end throughput.

---

# V2 Live Camera Demo

The same verified V2 accelerator was integrated into PYNQ Linux/Jupyter using the HCAM01L USB webcam.

Before live-camera use, the Jupyter path was validated against the same 1,000-image test set and reproduced:

```text
Accuracy : 915 / 1000 = 91.5%
```

The final live-camera path currently runs at approximately:

```text
~5 FPS
```

This figure includes:

- camera capture;
- center crop;
- resize;
- BGR-to-RGB conversion;
- input preprocessing;
- Python/Jupyter runtime behavior;
- host-FPGA interaction;
- result rendering;
- display updates.

It is therefore intentionally reported separately from the `5.004 ms/image` Vitis benchmark.

See:

[V2 Live Camera Demo Documentation](v2/v2_live_demo/README.md)

---

# Engine 3 — Activation Row-Level Zero-Skipping

V3 will extend the verified V2 engine with activation row-level ZeroSkip.

The intended principle is:

```text
Scheduled activation row
          |
          v
    Zero detection
       /      \
 all zero    non-zero
    |            |
    v            v
  skip      execute SA work
```

The exact skip granularity and controller protocol will be documented from the implemented V3 RTL.

The V2-to-V3 evaluation will include:

- activation sparsity;
- zero-row frequency;
- skipped systolic-array work;
- cycle reduction;
- latency reduction;
- LUT / FF overhead;
- timing impact;
- power impact;
- estimated energy impact;
- classification accuracy.

---

# Research Questions

## RQ1 — PS-PL Execution Partition

How much end-to-end inference latency can be reduced by moving CNN scheduling and intermediate processing from the PS into the PL?

## RQ2 — Communication Overhead

How much steady-state PS-PL payload traffic can be removed by eliminating layer-by-layer activation uploads and Product Buffer readback?

## RQ3 — Activation Sparsity

How much additional execution reduction can V3 obtain by skipping work associated with all-zero activation rows?

---

# Current Status

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
  USB webcam -> V2 FPGA NPU -> live prediction
  ~5 FPS observed application/display throughput
        |
        v
V3 Activation Row-Level ZeroSkip
  [NEXT]
```

The immediate Project 2 next step is to implement and evaluate V3 using the validated V2 engine as the reference.

---

# Repository Documentation

- [Inference Model](docs/inference_model.md)
- [Architecture](docs/architecture.md)
- [Matrix Tiling and Buffer Mapping](docs/tiling_logic.md)
- [AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)
- [Experimental Results](docs/Experiments.md)
- [V2 Live Camera Demo](v2/v2_live_demo/README.md)
