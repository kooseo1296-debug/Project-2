# Project 2: End-to-End FPGA NPU with Activation Row-Level Zero-Skipping

## Overview

Project 2 investigates how the execution partition of an FPGA neural processing unit (NPU) affects CIFAR-10 inference latency, PS-PL communication, and hardware cost.

The project starts from a PS-managed baseline in which the Programmable Logic (PL) mainly accelerates tiled matrix multiplication, then moves the full CNN execution flow into the PL. The final roadmap is:

1. **V1 Baseline** — PS-managed CNN execution; PL primarily performs tiled MatMul.
2. **V2 End-to-End PL Engine** — Conv1 through FC2 are scheduled and executed in the PL after input/model metadata staging.
3. **V3 Zero-Skip Engine** — V2 extended with activation row-level ZeroSkip.

V1 and V2 are implemented and evaluated on PYNQ-Z2. V2 has also been validated with a USB-camera live demo in Jupyter. V3 is the next architectural step.

---

## Headline Result

The verified V2 implementation reduces measured end-to-end Vitis inference latency from `338.03 ms/image` to `5.004 ms/image` while preserving nearly the same CIFAR-10 accuracy.

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

The `5.004 ms/image` result is the **Vitis benchmark path** and includes per-image input-scale metadata, RGB upload, end-to-end PL inference, DONE polling, and final-logit readback. It should not be confused with browser/Jupyter display FPS.

> Energy values are derived from Vivado implementation power estimates multiplied by measured inference latency. They are system-level estimates, not direct NPU-only board-power measurements.

---

## Target Model

The same CIFAR-10 Model 2 workload is used for the V1/V2 comparison:

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

See [Inference Model Documentation](docs/inference_model.md) for the layer shapes and numerical flow.

---

## Common Hardware Platform

```text
Platform        : PYNQ-Z2 / Zynq-7020
Dataset         : CIFAR-10
Compute array   : 9 x 16 weight-stationary systolic array
Processing PEs  : 144
PS-PL interface : 32-bit AXI4-Lite
Vivado          : 2025.2.1
Vitis           : 2025.2
Target clock    : 125 MHz
```

The Zynq PS communicates with the custom NPU through:

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

The current interface is command-oriented and polling-based.

---

# V1 — PS-Managed Baseline

V1 uses the PL as a tiled matrix-multiplication accelerator while the PS remains responsible for network-level execution.

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

Measured V1 result:

```text
Accuracy              : 919 / 1000 = 91.90%
End-to-end time       : 338.029 ms / image
PL execute subtotal   :   5.803 ms / image
Target clock          : 125 MHz, met
Estimated on-chip Pwr : 1.675 W
Estimated energy/img  : 566.199 mJ
```

The dominant fixed payload-transfer count used in the baseline study is:

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 payload transfers / image
```

Status polling and protocol bookkeeping are not included in this payload count.

---

# V2 — End-to-End PL Inference

V2 keeps the same 9x16 systolic array and 32-bit AXI4-Lite platform, but moves CNN scheduling and intermediate feature processing into the PL.

After the original RGB input is staged, intermediate feature maps stay inside the PL through Conv1 -> FC2. The PS no longer reads and rewrites intermediate Product Buffer data between layers.

## Verified V2 Runtime Protocol

The final verified Vitis/XSA pair uses a full 32-bit parameter path at AXI offset `0x0C`.

### Startup

- preload all INT8 weights;
- preload parameters `0..521`: signed `bias_over_weight_scale` values in Q16;
- preload parameters `522..529`: reciprocal weight scales in Q16.

### Per image

1. normalize and globally quantize the `3x32x32` RGB image on the PS;
2. write parameter `530`, the image-dependent reciprocal input scale in Q16;
3. upload the R, G, and B channels (`3072` INT8 activation values total);
4. allow the PL to execute Conv1 through FC2;
5. poll `DONE` and read 10 final logits.

A full 32-bit parameter is transferred in two writes:

```text
LOW  = {1'b0, ParamNumber[14:0], Value[15:0]}
HIGH = {1'b1, ParamNumber[14:0], Value[31:16]}
```

Therefore, the fixed per-image payload traffic of the verified V2 host path is:

```text
Param 530   :    2 AXI writes
RGB input   : 3072 AXI writes
Final logits:   10 AXI reads
------------------------------
Fixed total : 3084 AXI word accesses / image
```

This count intentionally excludes variable status-poll reads. Model weights and parameters `0..529` are startup-only traffic and are not reloaded for each image.

Compared with the V1 payload count of 748,650, this corresponds to roughly a **99.59% reduction in fixed payload transfers**.

## V2 Numerical Decisions

| Configuration | Accuracy | Decision |
|---|---:|---|
| V1 reference | 91.9% | baseline |
| Original normalization + shift-based requantization | 91.5% | adopted |
| Shift-based requantization + simplified normalization | 10.9% | rejected |

The accepted design therefore retains the trained-model CIFAR-10 normalization on the PS while implementing the internal CNN dataflow and hardware-friendly post-processing in the PL.

For the 4x4 GAP output, division by 16 is implemented as a 4-bit right shift with rounding.

---

## V2 Result

```text
Accuracy              : 915 / 1000 = 91.50%
End-to-end Vitis time : 5.004 ms / image
Equivalent throughput : 199.84 images/s
Target clock          : 125 MHz, met
Estimated energy/img  : 8.582 mJ
```

The same known-good bitstream/model/host protocol was subsequently ported to PYNQ/Jupyter and reproduced the same `915 / 1000 = 91.5%` result before the live-camera test.

---

# Live Camera Demo

A final V2 functional demo was run on PYNQ Linux/Jupyter with a USB webcam connected directly to the PYNQ-Z2.

The demo flow is:

```text
Google image shown on monitor
          |
          v
USB webcam connected to PYNQ-Z2
          |
          v
center crop + resize to 32x32
BGR -> RGB
CIFAR-10 normalization
INT8 quantization + param 530
          |
          v
V2 PL NPU inference
          |
          v
class/logit result displayed in Jupyter
```

The recording uses several still images found through Google Image Search and physically presents them to the webcam. It does **not** feed a prerecorded video directly into the model.

This is a **qualitative live-I/O demonstration**, not a replacement for the 1,000-image CIFAR-10 accuracy benchmark. The browser/Jupyter live-display rate is also not used as the accelerator-throughput result because Python MMIO, webcam capture, image conversion, JPEG/browser rendering, and UI updates are included in that loop.

See [Live Demo Documentation](docs/live_demo.md).

---

# V1 vs. V2 Summary

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
| Fixed payload transfers / image | 748,650 | 3,084 | about -99.59% |

The main V1-to-V2 result is that moving network execution and intermediate feature processing into the PL removes the layer-by-layer PS intervention that dominated the V1 end-to-end path.

---

# V3 — Activation Row-Level Zero-Skipping

The next architectural step extends the verified V2 engine with activation row-level ZeroSkip.

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

Planned V2-to-V3 evaluation includes:

- activation sparsity / all-zero row frequency;
- skipped systolic-array work;
- cycle and latency reduction;
- LUT/FF overhead;
- timing impact;
- power / energy impact.

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
  USB webcam -> live PL inference -> Jupyter display
        |
        v
V3 Activation Row-Level ZeroSkip
  [NEXT]
```

---

# Repository Notes

The known-good V2 Vitis application and hardware export are under `v2/vitis_application/`. The verified software-visible interface is defined by the matching Vitis host files and XSA used for the `91.5% / 5.004 ms` result.

Some documentation files preserve intermediate design experiments and may describe earlier bias-handling approaches. Those historical experiments should not be interpreted as the final per-image runtime protocol; the verified protocol is summarized above and in the checked-in Vitis host implementation.

---

# Documentation

- [Live Camera Demo](docs/live_demo.md)
- [Inference Model](docs/inference_model.md)
- [Architecture](docs/architecture.md)
- [Matrix Tiling and Buffer Mapping](docs/tiling_logic.md)
- [AXI4-Lite Command Interface](docs/AXI4-Lite_Command.md)
- [Experimental Results](docs/Experiments.md)
