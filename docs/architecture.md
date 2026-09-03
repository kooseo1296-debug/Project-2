# Baseline Architecture

This document describes the **Baseline (V1) architecture** of the FPGA
MatMul accelerator used in this project.

The Baseline is intentionally designed as a **PS-managed inference
architecture**. The Processing System (PS) performs CNN-level data
preparation, scheduling, and intermediate processing, while the
Programmable Logic (PL) is primarily responsible for tiled matrix
multiplication.

The architecture is described from two levels:

1. the system-level PS–PL integration on the Zynq-7020;
2. the internal architecture of the custom MatMul accelerator.

---

# 1. System Overview

## 1.1 PS–PL System Integration

The Baseline is implemented on the **PYNQ-Z2**, which contains a
Xilinx Zynq-7020 SoC.

The ARM Cortex-A9 Processing System controls the custom NPU IP through
a 32-bit AXI4-Lite interface.

<img width="1632" height="727" alt="image" src="https://github.com/user-attachments/assets/883aed24-5edc-4efc-b496-d091d77a2fe3" />

The system-level communication path is:

```text
ARM Cortex-A9
     │
     │ M_AXI_GP0
     ▼
AXI SmartConnect
     │
     │ 32-bit AXI4-Lite
     ▼
Custom NPU IP
     │
     ▼
Baseline MatMul Engine
```

The Processing System acts as the **AXI master**, while the custom NPU
IP acts as the **AXI slave**.

`FCLK_CLK0` from the Zynq Processing System provides the clock used by
the AXI interconnect and the custom PL accelerator. The corresponding
reset is distributed through the Processor System Reset block.

The custom NPU IP contains the Activation Buffer, Weight Buffer,
Product Buffer, controller, systolic array, and associated datapath
logic.

The same system-level Block Design and PS–PL interface are intended to
be maintained across the V1, V2, and V3 engines. Architectural changes
are therefore concentrated inside the custom NPU IP rather than in the
external PS–PL interconnect.

---

## 1.2 Processing System (PS)

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

Therefore, intermediate feature maps are repeatedly transferred between
the PS and PL.

This behavior is intentional. The Baseline provides a reference
architecture for evaluating the benefit of moving CNN scheduling and
intermediate processing into the PL in later versions.

---

## 1.3 Programmable Logic (PL)

The PL is responsible for executing the configured tiled matrix
multiplication.

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
3. performs MAC operations using the 9 × 16 weight-stationary
   systolic array;
4. accumulates partial sums across K tiles when required;
5. stores the final product tiles in the Product Buffer;
6. asserts completion status for the PS.

---

# 2. Baseline NPU Architecture

The custom NPU IP shown in the Vivado Block Design contains the
Baseline MatMul accelerator shown below.

<img alt="Baseline NPU Architecture"
src="https://github.com/user-attachments/assets/7b82b2bb-ee0e-44e4-917d-90a83bf4f7ef" />

At the system level, the complete accelerator is exposed to the PS as
a single AXI4-Lite slave IP.

Internally, the accelerator consists of:

- Controller;
- Activation Buffer;
- Weight Buffer;
- Input Loader;
- 9 × 16 weight-stationary systolic array;
- Product Loader;
- Product Buffer;
- pipeline and timing-alignment logic.

The PS communicates with the controller through the AXI slave
interface. The controller then coordinates the internal buffers and
datapath to execute the requested tiled matrix multiplication.

The following sections describe each component in detail.

---

# 3. AXI4-Lite Interface

The PS communicates with the accelerator through a 32-bit AXI4-Lite
interface.

The PS acts as the **AXI master**, while the custom accelerator IP acts
as the **AXI slave**.

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

# 4. MatMul Configuration

A matrix multiplication is represented as:

```text
A[S × IC] × W[IC × OC] = P[S × OC]
```

The controller receives four main configuration parameters.

## `S`

`S` is the number of rows in the activation matrix.

For convolution, it corresponds to the number of output spatial
positions after `im2col`.

## `IC`

`IC` is the GEMM K dimension.

For a 3 × 3 convolution:

```text
IC = Cin × 3 × 3
```

## `OC`

`OC` is the number of output columns of the matrix multiplication.

For convolution, this corresponds to the number of output channels.

## `WOffset`

`WOffset` specifies the starting address of the current layer's weights
in the Weight Buffer.

---

# 5. Controller

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

The controller does not use a separate encoded FSM. Execution is
controlled using phase flags and counters for weight loading,
activation streaming, and final-output waiting.

The controller is therefore responsible for most of the global
scheduling and address-generation logic in the Baseline accelerator.

---

# 6. Activation Buffer

The Activation Buffer is organized into **9 banks**, matching the
9 rows of the systolic array.

One buffer address therefore provides a 9-element activation vector in
parallel.

For:

```text
A[S × IC]
```

the activation matrix is divided into K tiles of width 9.

Conceptually:

```text
K tile 0 : address 0       ~ S-1
K tile 1 : address S       ~ 2S-1
K tile 2 : address 2S      ~ 3S-1
...
```

If `IC` is not a multiple of 9, the final activation tile is
zero-padded.

This allows the same 9-row datapath to be used for every K tile without
special handling in the processing elements.

The detailed activation mapping and tiling scheme is described in
[Tiling and Buffer Mapping](tiling_logic.md).

---

# 7. Weight Buffer

The Weight Buffer is organized into **16 banks**, matching the
16 systolic-array columns.

A full weight tile therefore has size:

```text
9 × 16
```

Each weight tile occupies 9 addresses across 16 banks.

The weight-loading path contains pipeline stages between the
controller, synchronous BRAM, and systolic array. These stages align
weight data with the corresponding weight-enable and row-ID control
signals.

During weight loading, the controller selects the current 9 × 16 tile
and loads its nine rows into the weight-stationary PE array.

Once loaded, the weights remain stationary while activation vectors
are streamed through the array.

The detailed Weight Buffer mapping is described in
[Tiling and Buffer Mapping](tiling_logic.md).

---

# 8. 9 × 16 Weight-Stationary Systolic Array

The core computation engine is a **9 × 16 weight-stationary systolic
array**.

It contains:

```text
9 × 16 = 144 processing elements
```

Each PE performs an INT8 multiply-accumulate operation:

```verilog
Psum_Out <= Data_I_In * Data_W_Buf + Psum_In;
```

Weights are stored locally in the PEs during the weight-loading phase.

Activation values propagate horizontally across the array, while
partial sums and associated metadata propagate through the processing
pipeline.

The accumulated product uses a signed 25-bit partial-sum datapath.

Conceptually:

```text
                 Output columns
          ─────────────────────────►

        ┌────┬────┬────┬───────┬────┐
A[0] ──►│ PE │ PE │ PE │  ...  │ PE │
        ├────┼────┼────┼───────┼────┤
A[1] ──►│ PE │ PE │ PE │  ...  │ PE │
        ├────┼────┼────┼───────┼────┤
  ...   │ .. │ .. │ .. │       │ .. │
        ├────┼────┼────┼───────┼────┤
A[8] ──►│ PE │ PE │ PE │  ...  │ PE │
        └────┴────┴────┴───────┴────┘

          9 rows × 16 columns
```

The 9-row dimension determines the K-tile width, while the 16-column
dimension determines the number of output channels that can be
processed in parallel.

---

# 9. Input Loader and Timing Alignment

The Activation Buffer is synchronous memory, so its read data does not
arrive in the same cycle as the controller request.

The Input Loader delays and aligns the activation data before it enters
the systolic array.

Additional row-dependent timing alignment is used so that the
activation wavefront reaches the correct PE at the correct clock cycle.

Similar pipeline modules are used on the weight, control, and product
paths to keep:

- data;
- addresses;
- valid signals;
- enable signals;
- partial sums

aligned with each other.

The small pipeline blocks shown in the architecture diagram represent
these timing-alignment modules.

---

# 10. Product Buffer and Partial-Sum Feedback

The Product Buffer stores the outputs generated by the systolic array.

It is organized into **16 banks**, corresponding to the 16 output
columns of the systolic array.

For one output-column tile, `S` Product Buffer addresses are used.

Conceptually:

```text
OC tile 0 : address 0       ~ S-1
OC tile 1 : address S       ~ 2S-1
OC tile 2 : address 2S      ~ 3S-1
...
```

When the K dimension requires multiple tiles, the first K tile starts
with a zero partial sum.

For later K tiles, the previously stored partial sum is read from the
Product Buffer and returned to the systolic array through the Product
Loader.

Therefore:

```text
First K tile:
    Psum input = 0

Later K tiles:
    Psum input = previous Product Buffer value
```

The feedback path can be summarized as:

```text
                    ┌───────────────────────┐
                    │                       │
                    ▼                       │
Activation ──► Systolic Array ──► Product Buffer
                    ▲                       │
                    │                       │
                    └──── Product Loader ◄──┘
```

This allows the accelerator to accumulate multiple K tiles into the
same final output tile.

---

# 11. Tiled MatMul Execution

The 9 × 16 physical array cannot necessarily process an entire matrix
multiplication in one pass.

The matrix multiplication:

```text
A[S × IC] × W[IC × OC]
```

is therefore decomposed along two dimensions.

## K-Dimension Tiling

The `IC` dimension is divided into groups of 9:

```text
K tile width = 9
```

If:

```text
IC > 9
```

multiple K tiles are processed and accumulated through the Product
Buffer feedback path.

## Output-Column Tiling

The `OC` dimension is divided into groups of 16:

```text
OC tile width = 16
```

If:

```text
OC > 16
```

multiple output-column tiles are executed sequentially.

Therefore, the physical 9 × 16 array is reused across both dimensions.

Conceptually:

```text
for each OC tile:
    for each K tile:

        load 9 × 16 weight tile

        stream activation vectors

        if first K tile:
            Psum = 0
        else:
            Psum = Product Buffer feedback

        execute systolic array

    store completed output tile
```

Detailed examples of the matrix-to-buffer mapping and tiling order are
provided in [Tiling and Buffer Mapping](tiling_logic.md).

---

# 12. Baseline Layer Execution Flow

A typical convolution or fully connected layer is executed as follows:

```text
PS
 │
 ├─ Prepare / preprocess activation data
 ├─ Perform im2col for convolution
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
 ├─ Prepare the next MatMul input
 └─ Start the next MatMul operation
```

The PL accelerates the matrix multiplication itself, while the PS
remains responsible for CNN-level orchestration.

As a result, a complete CNN inference requires repeated PS–PL
interaction.

---

# 13. Role of the Baseline

The Baseline is intentionally PS-managed.

Its purpose is not to minimize PS–PL communication, but to provide a
controlled reference architecture.

The main limitation is that intermediate results repeatedly cross the
PS–PL boundary:

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
- repeated software-side layer scheduling;
- communication overhead between CNN layers.

The Baseline therefore provides the reference point for the V2
architecture.

V2 will retain the same fundamental matrix-multiplication datapath as
much as possible while moving network-level scheduling and
intermediate processing into the PL.

Conceptually:

```text
V1

PS
 │
 ├── layer scheduling
 ├── intermediate processing
 ├── requantization
 │
 ▼
PL MatMul
 │
 ▼
PS
 │
 ▼
PL MatMul
 │
 ▼
...


V2 target

PS
 │
 ├── input preprocessing
 └── START
       │
       ▼
┌──────────────────────────────┐
│              PL              │
│                              │
│ CNN scheduling               │
│      ↓                       │
│ MatMul                       │
│      ↓                       │
│ ReLU / Requantization        │
│      ↓                       │
│ Pooling / Feedback           │
│      ↓                       │
│ Next Layer                   │
│      ↓                       │
│ ...                          │
│      ↓                       │
│ Classification               │
└──────────────┬───────────────┘
               │
               ▼
              PS
```

This makes the Baseline a direct reference point for measuring the
benefit of end-to-end PL execution.

---

# 14. Baseline Architecture Summary

The complete system can be viewed at two abstraction levels.

## System Level

```text
PYNQ-Z2 / Zynq-7020

┌───────────────────────┐
│ Processing System     │
│ ARM Cortex-A9         │
└──────────┬────────────┘
           │
           │ M_AXI_GP0
           ▼
┌───────────────────────┐
│ AXI SmartConnect      │
└──────────┬────────────┘
           │
           │ AXI4-Lite
           ▼
┌───────────────────────┐
│ Custom NPU IP         │
│ Programmable Logic    │
└───────────────────────┘
```

## Accelerator Level

```text
PS
 │
 │ AXI4-Lite
 ▼
Controller
 │
 ├──────────────► Weight Buffer
 │                       │
 │                       ▼
 │                Weight Pipeline
 │                       │
 │                       │
 ├──► Activation Buffer  │
 │          │            │
 │          ▼            │
 │     Input Loader      │
 │          │            │
 │          └──────┬─────┘
 │                 ▼
 │        9 × 16 Weight-Stationary
 │           Systolic Array
 │                 │
 │                 ▼
 │          Product Buffer
 │                 │
 │                 ├────► PS Readback
 │                 │
 │                 ▼
 └────────── Product Loader
                   │
                   └────► Psum Feedback
```

Key characteristics of the Baseline are:

- **PYNQ-Z2 / Zynq-7020 platform**
- **32-bit AXI4-Lite PS–PL interface**
- **PS-managed CNN execution**
- **PL-based tiled matrix multiplication**
- **9 × 16 weight-stationary systolic array**
- **144 INT8 MAC processing elements**
- **25-bit signed partial-sum datapath**
- **9-bank Activation Buffer**
- **16-bank Weight Buffer**
- **16-bank Product Buffer**
- **K-dimension tiling with zero-padding**
- **16-column output tiling**
- **output-column valid masking**
- **Product Buffer partial-sum feedback**
- **AXI4-Lite polling-based control**
- **intermediate result transfer back to the PS between layers**

The system-level PS–PL interface is maintained as the common platform
for the later V2 and V3 engines, while the internal NPU execution
architecture is progressively modified.
