# CIFAR-10 Inference Model

## Overview

This project uses **Model 2**, a compact VGG-style convolutional neural network previously developed for CIFAR-10 classification.

Model 2 was selected as the target inference workload for the FPGA NPU implementation.  
The network consists of:

- 6 convolution layers
- ReLU activation after each convolution layer
- 3 max-pooling operations
- Global Average Pooling (GAP)
- 2 fully connected layers
- 10-class CIFAR-10 output

All convolution layers use a **3 × 3 kernel with padding = 1**.

The network input is a CIFAR-10 RGB image with a spatial resolution of:

```text
3 × 32 × 32
```

where the three input channels correspond to R, G, and B.

---

## Network Architecture

> **Architecture figure will be added here.**

Suggested structure for the figure:

```text
Input
3 × 32 × 32
      │
      ▼
Conv1: 3 → 32, 3×3
      │
     ReLU
      │
      ▼
Conv2: 32 → 32, 3×3
      │
     ReLU
      │
 MaxPool 2×2
      │
      ▼
Conv3: 32 → 64, 3×3
      │
     ReLU
      │
      ▼
Conv4: 64 → 64, 3×3
      │
     ReLU
      │
 MaxPool 2×2
      │
      ▼
Conv5: 64 → 96, 3×3
      │
     ReLU
      │
      ▼
Conv6: 96 → 96, 3×3
      │
     ReLU
      │
 MaxPool 2×2
      │
      ▼
Global Average Pooling
      │
      ▼
FC1: 96 → 128
      │
     ReLU
      │
      ▼
FC2: 128 → 10
      │
      ▼
CIFAR-10 logits
```

---

## Layer Dimensions

| Layer | Input Shape | Kernel | Output Shape |
|---|---|---|---|
| Conv1 | 3 × 32 × 32 | 3 × 3, 3 → 32 | 32 × 32 × 32 |
| Conv2 | 32 × 32 × 32 | 3 × 3, 32 → 32 | 32 × 32 × 32 |
| MaxPool1 | 32 × 32 × 32 | 2 × 2 | 32 × 16 × 16 |
| Conv3 | 32 × 16 × 16 | 3 × 3, 32 → 64 | 64 × 16 × 16 |
| Conv4 | 64 × 16 × 16 | 3 × 3, 64 → 64 | 64 × 16 × 16 |
| MaxPool2 | 64 × 16 × 16 | 2 × 2 | 64 × 8 × 8 |
| Conv5 | 64 × 8 × 8 | 3 × 3, 64 → 96 | 96 × 8 × 8 |
| Conv6 | 96 × 8 × 8 | 3 × 3, 96 → 96 | 96 × 8 × 8 |
| MaxPool3 | 96 × 8 × 8 | 2 × 2 | 96 × 4 × 4 |
| GAP | 96 × 4 × 4 | — | 96 |
| FC1 | 96 | — | 128 |
| FC2 | 128 | — | 10 |

---

## Convolution-to-Matrix-Multiplication Mapping

The NPU implements convolution using matrix multiplication.

For a convolution layer,

```text
Cin  = number of input channels
Cout = number of output channels
KH   = kernel height
KW   = kernel width
```

The GEMM inner dimension is:

```text
K = Cin × KH × KW
```

Since every convolution in Model 2 uses a 3 × 3 kernel,

```text
K = 9 × Cin
```

If the output feature map contains `S = Hout × Wout` spatial positions, the convolution can be represented as:

```text
Activation Matrix : S × K
Weight Matrix     : K × Cout

                 ↓

Output Matrix     : S × Cout
```

The output matrix is subsequently reconstructed into a feature map with shape:

```text
Cout × Hout × Wout
```

---

## Convolution GEMM Dimensions

### Conv1

```text
Cin  = 3
Cout = 32
S    = 32 × 32 = 1024
K    = 3 × 3 × 3 = 27
```

Therefore:

```text
Activation : 1024 × 27
Weight     :   27 × 32
Output     : 1024 × 32
```

The output is reconstructed as:

```text
32 × 32 × 32
```

---

### Conv2

```text
Cin  = 32
Cout = 32
S    = 32 × 32 = 1024
K    = 32 × 9 = 288
```

```text
Activation : 1024 × 288
Weight     :  288 × 32
Output     : 1024 × 32
```

After Conv2, a 2 × 2 max-pooling operation reduces the spatial resolution:

```text
32 × 32 → 16 × 16
```

---

### Conv3

```text
Cin  = 32
Cout = 64
S    = 16 × 16 = 256
K    = 32 × 9 = 288
```

```text
Activation : 256 × 288
Weight     : 288 × 64
Output     : 256 × 64
```

---

### Conv4

```text
Cin  = 64
Cout = 64
S    = 16 × 16 = 256
K    = 64 × 9 = 576
```

```text
Activation : 256 × 576
Weight     : 576 × 64
Output     : 256 × 64
```

After Conv4:

```text
16 × 16 → 8 × 8
```

---

### Conv5

```text
Cin  = 64
Cout = 96
S    = 8 × 8 = 64
K    = 64 × 9 = 576
```

```text
Activation : 64 × 576
Weight     : 576 × 96
Output     : 64 × 96
```

---

### Conv6

```text
Cin  = 96
Cout = 96
S    = 8 × 8 = 64
K    = 96 × 9 = 864
```

```text
Activation : 64 × 864
Weight     : 864 × 96
Output     : 64 × 96
```

Conv6 has the largest GEMM inner dimension among the convolution layers.

After Conv6:

```text
96 × 8 × 8
      ↓
MaxPool
      ↓
96 × 4 × 4
```

---

## Fully Connected Layers

Global Average Pooling reduces each 4 × 4 channel into a single value:

```text
96 × 4 × 4
      ↓ GAP
1 × 96
```

### FC1

```text
Activation :   1 × 96
Weight     :  96 × 128
Output     :   1 × 128
```

A ReLU operation is applied after FC1.

### FC2

```text
Activation :   1 × 128
Weight     : 128 × 10
Output     :   1 × 10
```

The 10 output values correspond to the CIFAR-10 class logits.

---

## GEMM Summary

| Layer | Activation Matrix | Weight Matrix | Output Matrix |
|---|---:|---:|---:|
| Conv1 | 1024 × 27 | 27 × 32 | 1024 × 32 |
| Conv2 | 1024 × 288 | 288 × 32 | 1024 × 32 |
| Conv3 | 256 × 288 | 288 × 64 | 256 × 64 |
| Conv4 | 256 × 576 | 576 × 64 | 256 × 64 |
| Conv5 | 64 × 576 | 576 × 96 | 64 × 96 |
| Conv6 | 64 × 864 | 864 × 96 | 64 × 96 |
| FC1 | 1 × 96 | 96 × 128 | 1 × 128 |
| FC2 | 1 × 128 | 128 × 10 | 1 × 10 |

---

## Mapping to the 9 × 16 Systolic Array

The hardware uses a **9 × 16 systolic array**.

The dimensions were selected to match the structure of the target convolution workload.

### 9 PE Rows

All convolution layers use 3 × 3 kernels.

Therefore:

```text
3 × 3 = 9 kernel elements
```

The 9-row dimension can process the nine kernel elements associated with one input channel.

Since:

```text
K = 9 × Cin
```

the K dimension can be processed one input channel at a time.

For example, Conv6 has:

```text
Cin = 96
K   = 864 = 9 × 96
```

and therefore requires 96 input-channel accumulation steps.

### 16 PE Columns

The 16-column dimension processes 16 output channels in parallel.

The convolutional output-channel dimensions of Model 2 are:

```text
32
32
64
64
96
96
```

All of them are exact multiples of 16.

Therefore:

| Layer | Cout | 16-Channel Tiles |
|---|---:|---:|
| Conv1 | 32 | 2 |
| Conv2 | 32 | 2 |
| Conv3 | 64 | 4 |
| Conv4 | 64 | 4 |
| Conv5 | 96 | 6 |
| Conv6 | 96 | 6 |

This avoids partially occupied output-channel tiles in all six convolution layers.

The fully connected layers do not share the same 3 × 3 convolution structure and therefore require partial-row or partial-column handling for their final tiles.

---

## Accumulator Width

The largest accumulation depth occurs in Conv6:

```text
K = 96 × 3 × 3
  = 864
```

For signed INT8 operands, the largest positive product is:

```text
(-128) × (-128) = 16384
```

The worst-case positive accumulation is therefore:

```text
16384 × 864
= 14,155,776
```

A signed 25-bit accumulator provides the range:

```text
-16,777,216 ~ 16,777,215
```

and is therefore sufficient for the convolution MAC accumulation of Model 2.

The effect of bias addition and subsequent numerical processing is handled separately from this MAC-width analysis.

---

## ReLU

ReLU is applied after each convolution layer and after FC1.

```text
ReLU(x) = max(0, x)
```

In hardware, ReLU can be implemented using the sign bit of the signed result:

```text
Negative result → 0
Positive result → pass through
```

This requires very little additional logic compared with the matrix-multiplication datapath.

---

## Input Preprocessing

The original CIFAR-10 input consists of unsigned 8-bit RGB pixels:

```text
R, G, B = 0 ~ 255
```

The existing Model 2 inference flow performs input normalization before executing the CNN.

For Project 2, input preprocessing is performed by the **Processing System (PS)** before the input activation data is transferred to the NPU.

The intended system boundary is therefore:

```text
Raw CIFAR-10 Image
        │
        ▼
PS Input Preprocessing
        │
        ▼
NPU Input Activation
        │
        ▼
PL CNN Inference
        │
        ▼
10-Class Output
```

Keeping input preprocessing on the PS avoids adding preprocessing-specific hardware to the PL and allows the NPU optimization study to focus on CNN inference execution.

The same preprocessing procedure will be used for all compared NPU engines.

---

## Role in Project 2

Model 2 is kept fixed throughout the architectural comparison.

The target model, trained parameters, input dataset, and basic arithmetic configuration are treated as controlled conditions.

The project instead evaluates the effect of changing the NPU execution architecture:

```text
Engine 1
PS-Managed Inference

        ↓

Engine 2
End-to-End PL Inference

        ↓

Engine 3
End-to-End PL Inference
+ Column-Level Zero-Skipping
```

Using the same inference model across all three engines allows changes in execution cycles, latency, resource utilization, and power consumption to be attributed to the hardware architecture rather than to differences in the neural network workload.
