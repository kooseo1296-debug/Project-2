# Project 2: End-to-End FPGA NPU with Column-Level Zero-Skipping

## Overview

This project investigates how the execution structure of an FPGA-based neural processing unit (NPU) affects inference latency and hardware efficiency.

The project is motivated by the live-demo implementation of our previous FPGA NPU, where frequent data transfers and software intervention between the Processing System (PS) and Programmable Logic (PL) contributed substantially to end-to-end inference time.
[watch live demo video](https://drive.google.com/drive/folders/1PVky3DpYcxO1PA3LiZYOdY6wQItQFhgZ?dmr=1&ec=wgc-drive-hero-goto)
The primary goal of this project is therefore to reduce inference time while maintaining a common hardware platform and PS–PL interface.

Three NPU engines are implemented and evaluated:

1. **Baseline Engine** — PS-managed inference with frequent PS–PL communication
2. **v2: End-to-End Engine** — complete CNN inference is executed inside the PL
3. **v3: Zero-Skip Engine** — end-to-end PL inference with column-level activation zero-skipping

The main evaluation metrics are:

- Maximum operating frequency (`Fmax`)
- Cycles per image
- Inference time per image

Secondary metrics include:

- LUT utilization
- Flip-Flop utilization
- BRAM utilization
- DSP utilization
- Power consumption

---

## Motivation

The previous NPU implementation successfully demonstrated CIFAR-10 inference on FPGA hardware, but the live-demo pipeline required substantial interaction between the PS and PL during inference.

In the baseline execution flow, the PL performs matrix-multiplication operations while the PS manages the higher-level inference procedure. Intermediate results therefore cross the PS–PL boundary repeatedly.

Conceptually:

```text
Input
  ↓
 PS
  ↓
PL Matrix Multiplication
  ↓
 PS
  ↓
Next-Layer Scheduling
  ↓
PL Matrix Multiplication
  ↓
 ...
  ↓
Classification
```

This project investigates whether moving the complete inference process into the PL can reduce communication overhead and end-to-end inference latency.

---

## Experimental Platform

All three engines use the same system-level platform.

```text
Platform        : PYNQ-Z2 / Zynq-7020
Target workload : CIFAR-10 Model 2
Compute array   : 9 × 16 systolic array
PS–PL interface : 32-bit AXI4-Lite
Block Design    : Fixed across all engines
AXI protocol    : Fixed across all engines
```

Keeping the platform and external interface unchanged allows the effects of execution restructuring and zero-skipping to be evaluated independently.

---

# Engine 1 — Baseline

## PS-Managed Inference

The baseline engine follows the execution model derived from the previous NPU implementation.

The PS is responsible for executing the CNN at the network level, while the PL operates primarily as a matrix-multiplication accelerator.

```text
                 PS
                  │
       Matrix / layer scheduling
                  │
          Activation / Weight
                  ↓
         32-bit AXI4-Lite
                  ↓
        +------------------+
        |        PL        |
        |                  |
        | Activation Buffer|
        | Weight Buffer    |
        |       ↓          |
        |    9 × 16 SA     |
        |       ↓          |
        | Product Buffer   |
        +--------+---------+
                 │
          Product Matrix
                 ↓
                 PS
                 │
        Schedule next work
                 ↓
                ...
```

Intermediate results are repeatedly transferred between the PS and PL during inference.

### Expected Characteristics

- Low PL control complexity
- Lower hardware-resource overhead
- Frequent PS intervention
- High PS–PL communication overhead
- Higher end-to-end inference latency

---

# Engine 2 — End-to-End PL Inference

The second engine moves network-level inference execution into the PL.

After model data and an input image are provided, the PL autonomously executes the complete inference pipeline and returns only the final inference result.

```text
                 PS
                  │
           Input / Weights
                  │
               START
                  ↓
         32-bit AXI4-Lite
                  ↓
+----------------------------------+
|                PL                |
|                                  |
|         NPU Controller           |
|               ↓                  |
|       Activation Buffer          |
|               ↓                  |
|           9 × 16 SA              |
|               ↓                  |
|     Activation / Pooling         |
|               ↓                  |
|     Intermediate Features        |
|               ↓                  |
|          Next Layer              |
|               ↓                  |
|              ...                 |
|               ↓                  |
|       Classification Result      |
+----------------+-----------------+
                 │
                 ↓
                 PS
```

Intermediate feature data remains inside the PL instead of repeatedly returning to the PS.

The main hypothesis is:

> Reducing PS–PL data movement and PS intervention will reduce cycles per image and end-to-end inference latency at the cost of additional PL control and buffering resources.

---

## Engine 1 vs. Engine 2

The first experiment evaluates the effect of moving end-to-end inference execution from the PS to the PL.

| Metric | Baseline | End-to-End |
|---|---:|---:|
| Fmax | TBD | TBD |
| Cycles / image | TBD | TBD |
| Time / image | TBD | TBD |
| LUT | TBD | TBD |
| FF | TBD | TBD |
| BRAM | TBD | TBD |
| DSP | TBD | TBD |
| Power | TBD | TBD |

### Primary Metrics

The main performance metrics are:

```text
Fmax
Cycles / image
Time / image
```

`Cycles/image` measures architectural execution efficiency independently of clock frequency, while `Fmax` captures the timing cost of the additional PL logic.

Inference time is evaluated from:

```text
Time/image = Cycles/image / Operating Frequency
```

### Secondary Metrics

Resource utilization and power consumption are used to quantify the hardware cost of moving inference control into the PL.

---

# Engine 3 — Column-Level Zero-Skipping

The third engine extends the end-to-end architecture with activation zero-skipping.

A fixed large tile-level zero-skipping scheme is not used because the activation dimensions of the target CNN do not map cleanly to a single tile geometry across all layers.

Instead, this project applies **column-level zero-skipping**.

For each scheduled activation column, the engine determines whether all activation elements in that column are zero.

```text
Activation Column

[a0]
[a1]
[a2]
[a3]
[...]
[an]

       ↓

Are all elements zero?

     /       \
   YES        NO
    │          │
    ↓          ↓
  SKIP      Execute
            SA operation
```

If all elements belonging to the column are zero, the corresponding systolic-array computation is skipped.

Conceptually:

```text
Column Address
      ↓
Activation Column
      ↓
Zero Detection
    /      \
 ZERO     NON-ZERO
  │           │
  ↓           ↓
Next       Send to
Address    9×16 SA
```

The objective is to exploit activation sparsity to reduce unnecessary computation.

---

## Engine 2 vs. Engine 3

The second experiment evaluates whether column-level zero-skipping can reduce execution cost without changing the overall NPU interface.

| Metric | End-to-End | Zero-Skip |
|---|---:|---:|
| Fmax | TBD | TBD |
| Cycles / image | TBD | TBD |
| Time / image | TBD | TBD |
| LUT | TBD | TBD |
| FF | TBD | TBD |
| BRAM | TBD | TBD |
| DSP | TBD | TBD |
| Power | TBD | TBD |

Particular attention is given to:

```text
Activation sparsity
        ↓
Skippable columns
        ↓
Skipped SA operations
        ↓
Cycle reduction
        ↓
Power / energy reduction
```

In addition to average inference latency, zero-column frequency will be profiled for each CNN layer to determine where zero-skipping provides the largest benefit.

---

# Research Questions

This project focuses on two primary questions:

### RQ1 — PS–PL Execution Partition

How much can end-to-end inference latency be reduced by retaining intermediate inference operations inside the PL instead of repeatedly transferring intermediate data between the PS and PL?

### RQ2 — Activation Sparsity

How much additional execution and energy reduction can be achieved by skipping systolic-array operations associated with all-zero activation columns?

---

# Evaluation Methodology

The three engines are evaluated under a common implementation environment.

```text
                 Engine 1
               PS-managed
                    │
                    │
                    ▼
                 Engine 2
              End-to-End PL
                    │
                    │
                    ▼
                 Engine 3
             + Column Zero-Skip
```

The comparison is intentionally incremental:

```text
Engine 1 → Engine 2
Effect of reducing PS–PL communication

Engine 2 → Engine 3
Effect of exploiting activation sparsity
```

This allows the performance contribution and hardware cost of each optimization to be evaluated separately.
