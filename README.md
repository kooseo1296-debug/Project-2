# Project 2: End-to-End FPGA NPU with Activation Row-Level Zero-Skipping

## Overview

This project investigates how the execution structure of an FPGA-based neural processing unit (NPU) affects CIFAR-10 inference latency, communication overhead, and hardware cost.

The work is motivated by the live-demo implementation of our previous FPGA NPU, where the matrix multiplication itself was accelerated in the Programmable Logic (PL), but convolution scheduling, `im2col`, post-processing, requantization, and repeated intermediate-data movement were still managed by the Processing System (PS).

[Watch Live Demo Video](https://drive.google.com/file/d/1lzkIqhfIcX4UrQ2W33rvNfDzw1MxMoIF/view?usp=drive_link)

The practical target of Project 2 is to make the CIFAR-10 inference pipeline fast enough for real-time video inference. A 30 FPS target corresponds to approximately `33.3 ms/frame`.

Three engines are used as the project roadmap:

1. **Baseline Engine (V1)** - PS-managed inference; PL primarily executes tiled MatMul.
2. **End-to-End Engine (V2)** - Conv1 through FC2 are scheduled and executed inside the PL after per-image parameter/input staging.
3. **Zero-Skip Engine (V3)** - V2 extended with **activation row-level ZeroSkip**.

V1 and V2 have now both been implemented and evaluated on PYNQ-Z2. V3 is the next architectural step.

---

## Headline Result

The implemented V2 engine reduces end-to-end inference latency from `338.03 ms/image` to `5.004 ms/image` while maintaining nearly the same CIFAR-10 accuracy.

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

The measured V2 inference interval is well below the `33.3 ms/frame` compute budget corresponding to 30 FPS. The final camera-to-display Live Demo FPS still needs to be measured separately because camera capture, image conversion, display, and other I/O overhead are outside this benchmark.

> The energy values above use Vivado implementation power estimates multiplied by the measured inference latency. They are system-level estimates, not direct NPU-only board-power measurements.

---

## Motivation

The original Jupyter-based live-demo pipeline required roughly **80 s per image** in the demonstration environment. Project 2 therefore set a practical target of reaching a compute budget compatible with **30 FPS** video inference.

For controlled architecture comparison, the software stack was moved to Vitis and the V1 baseline was re-measured. The V1 Vitis pipeline was functionally correct but still spent most of its end-to-end time outside the PL MatMul execution itself.

For the V1 baseline, the measured average times were:

```text
End-to-end inference : 338.029 ms / image
PL MatMul execute     :   5.803 ms / image
Other PS / transfer   : 332.226 ms / image
```

The baseline inference flow repeatedly performs:

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
repeat for the next weighted layer
```

This makes PS-PL data movement and software intervention a dominant part of total latency even though the MatMul accelerator itself is much faster.

The main V1-to-V2 research question is therefore:

> How much end-to-end latency can be removed by keeping CNN layer execution and intermediate feature processing inside the PL?

---

## Target Model

Project 2 uses the same CIFAR-10 Model 2 workload throughout the V1/V2 comparison:

```text
Input 3x32x32
  -> Conv1  3->32
  -> Conv2 32->32 -> MaxPool
  -> Conv3 32->64
  -> Conv4 64->64 -> MaxPool
  -> Conv5 64->96
  -> Conv6 96->96 -> MaxPool
  -> GAP
  -> FC1 96->128
  -> FC2 128->10
```

All convolution layers use `3x3`, stride 1, padding 1.

For detailed layer shapes and numerical operations, see:

[Inference Model Documentation](docs/inference_model.md)

---

## Common Hardware Platform

All engines use the same system-level platform so that the architectural comparison remains controlled.

```text
Platform        : PYNQ-Z2 / Zynq-7020
Target workload : CIFAR-10 Model 2
Compute array   : 9 x 16 weight-stationary systolic array
Processing PEs  : 144
PS-PL interface : 32-bit AXI4-Lite
Block Design    : fixed across V1/V2/V3
Vivado          : 2025.2.1
Vitis           : 2025.2
Target clock    : 125 MHz
```

The Zynq PS communicates with the custom NPU IP through:

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

The PS is the AXI master and the NPU is the AXI slave. Polling is used instead of interrupts.

For the system and internal RTL organization, see:

[Architecture Documentation](docs/architecture.md)

For the command interface, see:

[AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)

For matrix mapping and tiling, see:

[Tiling and Buffer Mapping](docs/tiling_logic.md)

---

# Engine 1 - Baseline

## PS-Managed Inference

V1 uses the PL as a tiled matrix-multiplication accelerator while the PS remains responsible for network-level execution.

The startup / per-image flow is:

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
  -> repeat for the next layer
```

### Baseline Data-Transfer Cost

The research report counts the dominant payload transfers per image as:

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 handshakes / image
```

These counts are used as the communication baseline for V2. They represent the large payload-transfer operations and do not attempt to count every AXI protocol event such as status polling.

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

# Engine 2 - End-to-End PL Inference

V2 keeps the same 9x16 systolic array, Weight Buffer, Activation Buffer, Product Buffer, AXI4-Lite system, and overall tiling concept, but moves CNN scheduling and intermediate operations into the PL.

After per-image input and bias parameters are staged, the PL executes Conv1 through FC2 without returning intermediate feature maps to the PS.

```text
PS
 |
 | original input normalization / quantization
 | per-image scaled-bias preparation
 |
 +---- 522 scaled bias values
 +---- 3072 RGB activation values
 |
 v
+--------------------------------------------------+
|                       PL                         |
|                                                  |
|  Conv / MatMul -> ReLU -> Requant -> Pool       |
|       |                             |            |
|       +------ Product Buffer <------+            |
|                    |                             |
|               Next Layer                         |
|                    |                             |
|                   ...                            |
|                    |                             |
|               GAP -> FC1 -> FC2                  |
+--------------------+-----------------------------+
                     |
                     +---- 10 logits -> PS
```

## V2 Numerical Decisions

Before committing the arithmetic to RTL, hardware-oriented numerical changes were tested in Vitis.

| Configuration | Accuracy | Decision |
|---|---:|---|
| V1 reference | 91.9% | baseline |
| Original normalization + shift-based requantization | 91.5% | adopted |
| Shift-based requantization + simplified normalization | 10.9% | rejected |

Therefore:

- original CIFAR-10 normalization remains on the PS;
- intermediate requantization uses shift + rounding in the PL;
- max pooling and GAP are executed in the PL;
- bias is injected into the accumulator path in the PL;
- final FC2 logits are returned to the PS.

## Shift-Based Requantization

The hardware-friendly operation is conceptually:

```text
q = round(x / 2^shift)
```

and is implemented using a right shift plus a rounding bit, followed by saturation to the target INT8 range.

For the 4x4 GAP output, 16 spatial values are accumulated and division by 16 is implemented by a 4-bit right shift with rounding.

## Bias Handling Decision

An early approach attempted to preload INT32 bias and rescale it inside the PL as the activation scale changed. That version produced only:

```text
Accuracy : 103 / 1000 = 10.3%
```

The accepted implementation instead prepares activation-scale-dependent bias values on the PS and loads **522 scaled Q32 bias values per image** before inference.

This preserves the 91.5% V2 reference accuracy while still removing the much larger layer-by-layer activation/readback traffic of V1.

## V2 Per-Image Workflow

```text
Startup:
    0. Preload weights

Per image:
    1. Prepare and load scaled bias
    2. Load preprocessed RGB activation
    3. Execute end-to-end PL inference
    4. Read 10 final logits
```

The corresponding dominant payload-transfer count is:

```text
Scaled bias :  522
RGB input   : 3072
Final logits:   10
-------------------
Total       : 3604 handshakes / image
```

Compared with the V1 count of 748,650, V2 uses only:

```text
3604 / 748650 = 0.004814
```

of the baseline payload-transfer count, corresponding to a reduction of approximately **99.52%**.

## V2 RTL Functional Partition

The V2 implementation distributes post-processing instead of placing all additional functionality in one centralized combinational controller path.

- `Ctrl`
  - network/layer scheduling
  - GAP and pooling control
  - bias/requantization control
- `sa_to_pb`
  - ReLU
  - local maximum / shift tracking
- `Biggest`
  - receives shift candidates and determines the layer-wide maximum shift requirement
- `ctrl_to_pb`
  - shift-based requantization
  - max pooling
  - bias transport toward the Product Loader
- `Product Loader`
  - provides the appropriate bias/partial-sum input for the systolic accumulation path

Detailed datapath behavior is documented in [Architecture Documentation](docs/architecture.md).

---

# V1 vs. V2

The V1-to-V2 comparison isolates the cost and benefit of moving network execution into the PL while keeping the basic compute array and external platform fixed.

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
| Payload handshakes / image | 748,650 | 3,604 | -99.52% |

The central observation is that V2 accepts moderate LUT/LUTRAM/FF overhead while preserving the same BRAM and DSP footprint and removing most of the PS-PL communication that dominated V1 latency.

At `5.004 ms/image`, the benchmark corresponds to approximately `199.84 images/s`, or about `67.55x` the V1 end-to-end throughput.

---

# Engine 3 - Activation Row-Level Zero-Skipping

The next step is V3, which extends the verified V2 engine with activation row-level ZeroSkip.

The earlier project draft described the V3 direction as column-level zero-skipping. After the V2 research review, the planned direction is now **activation row-level ZeroSkip**.

The exact skip granularity and controller protocol are not frozen yet. The intended principle is:

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

The V2 engine remains the reference for evaluating the additional cycle reduction and hardware overhead introduced by V3.

The planned V2-to-V3 evaluation will include:

- activation sparsity / zero-row frequency;
- skipped SA work;
- cycle reduction;
- latency reduction;
- LUT/FF overhead;
- timing impact;
- power / energy impact.

---

# Research Questions

### RQ1 - PS-PL Execution Partition

How much end-to-end inference latency can be reduced by moving CNN scheduling and intermediate processing from the PS into the PL?

### RQ2 - Communication Overhead

How much of the V1 latency is associated with repeated activation loading and Product Buffer readback, and how much can the communication count be reduced by V2?

### RQ3 - Activation Sparsity

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
V2 Vitis Live Demo
  [NEXT]
        |
        v
V3 Activation Row-Level ZeroSkip
  [NEXT]
```

Immediate next steps are:

1. build the V2 Vitis Live Demo and record a demonstration video;
2. measure camera-to-result / camera-to-display behavior separately from the embedded 1,000-image benchmark;
3. design and evaluate V3 activation row-level ZeroSkip.

Project 3 is expected to move to a different inference task, such as speech recognition or object/image detection, after Project 2 is completed.

---

# Documentation

- [Inference Model](docs/inference_model.md)
- [Architecture](docs/architecture.md)
- [Matrix Tiling and Buffer Mapping](docs/tiling_logic.md)
- [AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)
- [Experimental Results](docs/Experiments.md)
