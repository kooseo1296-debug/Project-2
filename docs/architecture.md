# Baseline Architecture

This document describes the **Baseline (V1) architecture** of the FPGA MatMul accelerator used in this project.

The Baseline is intentionally designed as a **PS-managed inference architecture**. The Processing System (PS) performs CNN-level data preparation and scheduling, while the Programmable Logic (PL) is responsible for tiled matrix multiplication.

<img alt="image" src="https://github.com/user-attachments/assets/2303bd4a-1c91-4001-9170-45995c5e09ee" />

---

## 1. System Overview

### Processing System (PS)

For each convolution or fully connected layer, the PS:

- prepares the input data required by the next matrix multiplication;
- performs convolution-specific preprocessing such as `im2col`;
- performs layer-level post-processing in software when required;
- requantizes intermediate results before they are used by the next layer;
- loads activation data into the Activation Buffer;
- loads weight data into the Weight Buffer;
- configures the matrix dimensions and weight-buffer offset;
- starts the MatMul engine;
- polls the PL status;
- reads the resulting product matrix from the Product Buffer.

Therefore, intermediate feature maps are repeatedly transferred between the PS and PL.

This behavior is intentional: the Baseline provides a reference architecture for evaluating the benefit of moving CNN scheduling and intermediate processing into the PL in later versions.

### Programmable Logic (PL)

The PL is responsible for executing the configured tiled matrix multiplication.

The PL receives:

- weight data;
- activation data;
- `S`;
- `IC`;
- `OC`;
- `WOffset`;
- an execute command.

The MatMul engine then:

1. loads the required weight tile;
2. streams the corresponding activation tile;
3. performs the MAC operations using the 9 × 16 weight-stationary systolic array;
4. accumulates partial sums across K tiles when required;
5. stores the final product tiles in the Product Buffer;
6. asserts completion status for the PS.

---

## 2. AXI4-Lite Interface

The PS communicates with the accelerator through a 32-bit AXI4-Lite interface.

The PS acts as the **AXI master**, while the custom accelerator IP acts as the **AXI slave**.

The Baseline command interface uses the following offsets:

| Offset | Command | Direction | Description |
|---:|---|---|---|
| `0x00` | Response | PL → PS | Returns accelerator status and Product Buffer readback data |
| `0x04` | Load Weight | PS → PL | Writes one INT8 weight value to the Weight Buffer |
| `0x08` | Load Activation | PS → PL | Writes one INT8 activation value to the Activation Buffer |
| `0x0C` | Configure / Execute | PS → PL | Configures `S`, `IC`, `OC`, `WOffset`, and starts MatMul |
| `0x10` | Read Product Buffer | PS → PL | Requests one Product Buffer value |

The response code has the format:

```verilog
{BUSY, DONE, PENDING, VALID, DATA[27:0]}
```

where:

- `BUSY` indicates that the MatMul engine is currently executing;
- `DONE` indicates that the configured MatMul operation has completed;
- `PENDING` indicates that a Product Buffer read request is being processed;
- `VALID` indicates that the returned Product Buffer data is valid.

The Baseline uses **polling** rather than interrupts.

---

## 3. MatMul Configuration

A matrix multiplication is represented as:

$A_{S \times IC} W_{IC \times OC} = P_{S \times OC}$

The controller receives four main configuration parameters.

### `S`

`S` is the number of rows in the activation matrix.

For convolution, it corresponds to the number of output spatial positions after `im2col`.

### `IC`

`IC` is the GEMM K dimension.

For a 3 × 3 convolution:

$IC = C_{in} \times 3 \times 3$

### `OC`

`OC` is the number of output columns of the matrix multiplication.

For convolution, this corresponds to the number of output channels.

### `WOffset`

`WOffset` specifies the starting address of the current layer's weights in the Weight Buffer.

---

## 4. Controller

The controller manages the complete tiled MatMul execution.

Its main responsibilities are:

- decoding AXI commands;
- storing the current MatMul configuration;
- generating Activation Buffer, Weight Buffer, and Product Buffer addresses;
- controlling K-dimension tiling;
- controlling output-column tiling;
- generating the active-column mask for partial output tiles;
- loading weights into the systolic array;
- streaming activation vectors;
- requesting previous partial sums from the Product Buffer;
- detecting the final output transaction;
- generating `BUSY`, `DONE`, `PENDING`, and `VALID`.

The controller does not use a separate encoded FSM. Execution is controlled using phase flags and counters for weight loading, activation streaming, and final-output waiting.

---

## 5. Activation Buffer

The Activation Buffer is organized into **9 banks**, matching the 9 rows of the systolic array.

One buffer address therefore provides a 9-element activation vector in parallel.

For:

$A_{S \times IC}$

the activation matrix is divided into K tiles of width 9.

Conceptually:

```text
K tile 0 : address 0       ~ S-1
K tile 1 : address S       ~ 2S-1
K tile 2 : address 2S      ~ 3S-1
...
```

If `IC` is not a multiple of 9, the final activation tile is zero-padded.

This allows the same 9-row datapath to be used for every K tile without special handling in the processing elements.

---

## 6. Weight Buffer

The Weight Buffer is organized into **16 banks**, matching the 16 systolic-array columns.

A full weight tile therefore has size:

$9 \times 16$

Each weight tile occupies 9 addresses across 16 banks.

The weight-loading path contains pipeline stages between the controller, synchronous BRAM, and systolic array. These stages align weight data with the corresponding weight-enable and row-ID control signals.

During weight loading, the controller selects the current 9 × 16 tile and loads its nine rows into the weight-stationary PE array.

Once loaded, the weights remain stationary while activation vectors are streamed through the array.

---

## 7. 9 × 16 Weight-Stationary Systolic Array

The core computation engine is a **9 × 16 weight-stationary systolic array**.

It contains:

$9 \times 16 = 144$

processing elements.

Each PE performs an INT8 multiply-accumulate operation:

```verilog
Psum_Out <= Data_I_In * Data_W_Buf + Psum_In;
```

Weights are stored locally in the PEs during the weight-loading phase.

Activation values propagate horizontally across the array, while partial sums and associated metadata propagate through the processing pipeline.

The accumulated product uses a signed 25-bit partial-sum datapath.

---

## 8. Input Loader and Timing Alignment

The Activation Buffer is synchronous memory, so its read data does not arrive in the same cycle as the controller request.

The Input Loader delays and aligns the activation data before it enters the systolic array.

Additional row-dependent timing alignment is used so that the activation wavefront reaches the correct PE at the correct clock cycle.

Similar pipeline modules are used on the weight, control, and product paths to keep data, addresses, valid signals, and partial sums aligned.

The small pipeline blocks shown in the architecture diagram represent these timing-alignment modules.

---

## 9. Product Buffer and Partial-Sum Feedback

The Product Buffer stores the outputs generated by the systolic array.

It is organized into **16 banks**, corresponding to the 16 output columns of the systolic array.

For one output-column tile, `S` Product Buffer addresses are used.

Conceptually:

```text
OC tile 0 : address 0       ~ S-1
OC tile 1 : address S       ~ 2S-1
OC tile 2 : address 2S      ~ 3S-1
...
```

When the K dimension requires multiple tiles, the first K tile starts with a zero partial sum.

For later K tiles, the previously stored partial sum is read from the Product Buffer and returned to the systolic array through the Product Loader.

Therefore:

```text
First K tile:
    Psum input = 0

Later K tiles:
    Psum input = previous Product Buffer value
```

This allows the accelerator to accumulate multiple K tiles into the same final output tile.

---

## 10. Baseline Layer Execution Flow

A typical convolution or fully connected layer is executed as follows:

```text
PS
 │
 ├─ Prepare / preprocess activation data
 ├─ Requantize input if required
 ├─ Load weights
 ├─ Load activations
 ├─ Configure S and IC
 ├─ Configure OC and WOffset
 └─ Execute
        │
        ▼
PL MatMul
 │
 ├─ Load weight tile
 ├─ Stream activation tile
 ├─ Execute 9 × 16 systolic-array MACs
 ├─ Accumulate partial sums across K tiles
 └─ Store final products in Product Buffer
        │
        ▼
PS
 │
 ├─ Read Product Buffer
 ├─ Perform layer-specific post-processing
 ├─ Requantize for the next layer
 └─ Prepare the next MatMul input
```

The PL accelerates the matrix multiplication itself, while the PS remains responsible for CNN-level orchestration.

---

## 11. Role of the Baseline

The Baseline is intentionally PS-managed.

Its purpose is not to minimize PS–PL communication, but to provide a controlled reference architecture.

The main limitation is that intermediate results repeatedly cross the PS–PL boundary:

```text
PS preprocessing
    ↓
PL MatMul
    ↓
PS post-processing / requantization
    ↓
PL MatMul
    ↓
...
```

This creates:

- repeated AXI transactions;
- repeated Product Buffer readback;
- repeated PS intervention;
- communication overhead between CNN layers.

The later V2 architecture will move CNN scheduling and intermediate processing into the PL while preserving the same basic MatMul computation structure as much as possible.

This makes the Baseline a direct reference point for measuring the benefit of end-to-end PL execution.

---

## 12. Baseline Architecture Summary

The Baseline can be summarized as:

```text
PS
 │
 │ AXI4-Lite
 ▼
Controller
 │
 ├──────────────► Weight Buffer ──► Weight pipeline ──┐
 │                                                   │
 ├──────────────► Activation Buffer ─► Input Loader ─┤
 │                                                   ▼
 ├──────────────────────────────► 9 × 16 Weight-Stationary
 │                                Systolic Array
 │                                      │
 │                                      ▼
 │                                Product Buffer
 │                                      │
 └──────────── Product readback ◄───────┘
```

Key characteristics:

- **PS-managed CNN execution**
- **PL-based tiled matrix multiplication**
- **9 × 16 weight-stationary systolic array**
- **INT8 activation and weight datapath**
- **25-bit signed partial-sum datapath**
- **9-bank Activation Buffer**
- **16-bank Weight Buffer**
- **16-bank Product Buffer**
- **K-dimension zero-padding**
- **output-column valid masking**
- **Product Buffer partial-sum feedback**
- **AXI4-Lite polling-based control**
- **intermediate result transfer back to the PS between layers**
