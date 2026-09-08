# AXI4-Lite Command Interface

The accelerator is controlled through a 32-bit AXI4-Lite interface between the Processing System (PS) and Programmable Logic (PL).

The interface is used as a **command interface**, rather than as a conventional set of persistent configuration registers.  
A PS-to-PL write command is accepted once by the AXI slave and converted into a one-clock `In_Valid` pulse for the accelerator controller.

---

# 1. Baseline — PS-Managed MatMul

The Baseline architecture uses the PS to explicitly manage:

- weight loading,
- activation loading,
- MatMul configuration,
- MatMul execution,
- Product Buffer read requests,
- result/status polling.

The PL primarily operates as a MatMul accelerator.

## Address Map

| Offset | Operation | Direction | Description |
|---:|---|---|---|
| `0x00` | RCODE | PL → PS | Read accelerator status / PB read response |
| `0x04` | Load Weight | PS → PL | Write weight data into the Weight Buffer |
| `0x08` | Load Activation | PS → PL | Write activation data into the Activation Buffer |
| `0x0C` | Configure / Execute | PS → PL | Configure and start MatMul |
| `0x10` | Read Product Buffer | PS → PL | Request Product Buffer data |

The Baseline therefore uses five AXI word slots.

```text
AWADDR[4:2]

000 -> 0x00
001 -> 0x04
010 -> 0x08
011 -> 0x0C
100 -> 0x10
```

---

## `0x04` — Load Weight

**Direction:** PS → PL

Writes one INT8 weight value into the Weight Buffer.

```verilog
{16'b_WBaddress, 8'b_colnum, 8'b_Data}
```

### Bit Field

```text
31                16 15              8 7                0
+-------------------+------------------+------------------+
|    WB Address     |      Column      |       Data       |
|      16 bits      |      8 bits      |      8 bits      |
+-------------------+------------------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `WBaddress` | 16 bits | Weight Buffer address |
| `colnum` | 8 bits | Target Weight Buffer column |
| `Data` | 8 bits | INT8 weight value |

---

## `0x08` — Load Activation

**Direction:** PS → PL

Writes one INT8 activation value into the Activation Buffer.

```verilog
{16'b_ABaddress, 8'b_rownum, 8'b_Data}
```

### Bit Field

```text
31                16 15              8 7                0
+-------------------+------------------+------------------+
|    AB Address     |       Row        |       Data       |
|      16 bits      |      8 bits      |      8 bits      |
+-------------------+------------------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `ABaddress` | 16 bits | Activation Buffer address |
| `rownum` | 8 bits | Target Activation Buffer row |
| `Data` | 8 bits | INT8 activation value |

---

## `0x0C` — Configure / Execute

**Direction:** PS → PL

The Baseline uses multiple writes to `0x0C` to configure and execute one MatMul operation.

Bits `[31:30]` specify the command type.

### `2'b00` — Configure `S` and `IC`

```verilog
{2'b00, 15'b_S, 15'b_IC}
```

```text
31  30 29                 15 14                   0
+------+--------------------+----------------------+
|  00  |         S          |          IC          |
|2 bits|      15 bits       |       15 bits        |
+------+--------------------+----------------------+
```

- `S`: number of input rows / spatial positions
- `IC`: GEMM K dimension

For CNN convolution,

```text
IC = Cin × Kernel_H × Kernel_W
```

and the current design uses a `3 × 3` kernel, so:

```text
IC = Cin × 9
```

---

### `2'b01` — Configure `OC` and Weight Offset

```verilog
{2'b01, 15'b_OC, 15'b_WOffset}
```

```text
31  30 29                 15 14                   0
+------+--------------------+----------------------+
|  01  |         OC         |      WOffset         |
|2 bits|      15 bits       |       15 bits        |
+------+--------------------+----------------------+
```

- `OC`: output-channel count
- `WOffset`: Weight Buffer offset

---

### `2'b10` — Execute MatMul

```verilog
{2'b10, 30'dX}
```

```text
31  30 29                                         0
+------+-------------------------------------------+
|  10  |                 Don't Care                |
|2 bits|                  30 bits                  |
+------+-------------------------------------------+
```

Receiving this command starts MatMul using the previously configured values.

### Typical Sequence

```text
Write 0x0C : {00, S, IC}
        ↓
Write 0x0C : {01, OC, WOffset}
        ↓
Write 0x0C : {10, X}
        ↓
Execute MatMul
```

---

## `0x10` — Read Product Buffer

**Direction:** PS → PL

Requests one value from the Product Buffer.

```verilog
{16'b_PBaddress, 8'b_colnum, 8'd0}
```

### Bit Field

```text
31                16 15              8 7                0
+-------------------+------------------+------------------+
|    PB Address     |      Column      |        0         |
|      16 bits      |      8 bits      |      8 bits      |
+-------------------+------------------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `PBaddress` | 16 bits | Product Buffer address |
| `colnum` | 8 bits | Target Product Buffer column |
| Reserved | 8 bits | Set to `0` |

The Product Buffer request and response are asynchronous from the software point of view.

After issuing the request, the PS polls `0x00` until the requested PB data becomes valid.

---

## `0x00` — RCODE

**Direction:** PL → PS

`0x00` is a read-only response/status register.

```verilog
{BUSY, DONE, PENDING, VALID, DATA[27:0]}
```

### Bit Field

```text
31      30       29         28 27                    0
+-------+--------+----------+-----+--------------------+
| BUSY  |  DONE  | PENDING  |VALID|        DATA        |
| 1 bit | 1 bit  |  1 bit   |1 bit|      28 bits       |
+-------+--------+----------+-----+--------------------+
```

| Bit | Field | Description |
|---:|---|---|
| 31 | `BUSY` | MatMul execution is active |
| 30 | `DONE` | MatMul execution has completed |
| 29 | `PENDING` | Product Buffer read request is pending |
| 28 | `VALID` | Requested Product Buffer data is valid |
| 27:0 | `DATA` | Returned Product Buffer data |

### RCODE States

| BUSY | DONE | PENDING | VALID | Meaning |
|---:|---:|---:|---:|---|
| 1 | 0 | 0 | 0 | MatMul executing |
| 0 | 1 | 0 | 0 | MatMul completed |
| 0 | 1 | 1 | 0 | Product Buffer read pending |
| 0 | 1 | 0 | 1 | Product Buffer read data valid |

`PENDING` and `VALID` are **sticky states**, not one-cycle pulses.

When a Product Buffer read request is issued:

```text
PENDING = 1
VALID   = 0
```

When the requested data arrives:

```text
PENDING = 0
VALID   = 1
DATA    = requested Psum
```

Reading `0x00` does **not** clear or advance the controller state.

---

## Baseline Transaction Flow

A typical Baseline inference step is:

```text
PS
 │
 ├── 0x04 : Load weights
 │
 ├── 0x08 : Load activations
 │
 ├── 0x0C : Configure S / IC
 │
 ├── 0x0C : Configure OC / WOffset
 │
 ├── 0x0C : Execute MatMul
 │
 ├── 0x00 : Poll BUSY / DONE
 │
 ├── 0x10 : Request Product Buffer data
 │
 └── 0x00 : Poll PENDING / VALID and read DATA
```

This sequence is repeated as required by the PS-managed CNN inference flow.

---

# 2. AXI4-Lite Write Handling

The AXI4-Lite write-address (`AW`) and write-data (`W`) channels are independent.

The slave therefore must **not** assume that `AWVALID` and `WVALID` arrive in the same clock cycle.

The intended implementation is:

```text
AW handshake
     ↓
Latch write address

W handshake
     ↓
Latch write data

Address captured && Data captured
     ↓
Generate In_Valid for 1 clock
     ↓
Send In_Offset + In_Instruction to MatMul
     ↓
Generate AXI write response
```

The accelerator command interface receives:

```text
In_Valid
In_Offset
In_Instruction
```

`In_Valid` must be asserted for exactly one clock when a new PS-to-PL AXI command is accepted.

This prevents the same command from being executed multiple times while AXI register values remain stable for multiple cycles.

---

# 3. AXI4-Lite Read Handling

The PS reads the current RCODE using:

```c
Xil_In32(BASE_ADDR + 0x00);
```

The AXI slave returns the current:

```verilog
MatMul_Rcode
```

The RCODE value should be latched when the AXI read transaction begins so that `RDATA` remains stable if `RVALID` is stalled.

Reading RCODE must not modify accelerator state.

---

---

# 4. V2 - End-to-End PL Inference

V2 keeps the same 32-bit AXI4-Lite slave connection but changes the
software-visible execution model.

The PS no longer configures every individual MatMul operation or reads the
Product Buffer between CNN layers. Instead, the PS stages the per-image
parameters/input, starts the V2 engine, and reads the final FC2 logits.

The implemented workflow reported for V2 is:

```text
Startup:
    preload weights

Per image:
    prepare / load 522 scaled bias values
    load 3 x 32 x 32 RGB activation values
    start end-to-end PL inference
    wait for DONE
    read 10 logits
```

Intermediate feature-map transfers are removed from the normal V2 inference
path.

## V2 Semantic Address Map

| Offset | Operation | Direction | V2 role |
|---:|---|---|---|
| `0x00` | RCODE / Result | PL -> PS | status and final logit readback |
| `0x04` | Load Weight | PS -> PL | model-static INT8 weight preload |
| `0x08` | Load Activation | PS -> PL | preprocessed RGB INT8 input upload |
| `0x0C` | Parameter / Control | PS -> PL | V2 bias/control path and execution control |

`0x10` Product Buffer readback is a Baseline operation and is not part of the
normal V2 layer-by-layer inference flow.

---

## `0x00` - V2 RCODE / Logit Readback

The V2 result path uses the status bits plus a class/logit payload.

The implemented V2 software convention is:

```verilog
{BUSY, DONE, Class[3:0], Logit[25:0]}
```

```text
31      30 29        26 25                           0
+-------+--+------------+-----------------------------+
| BUSY  |DONE|  Class    |            Logit            |
| 1 bit |1bit|  4 bits   |           26 bits           |
+-------+--+------------+-----------------------------+
```

| Field | Width | Description |
|---|---:|---|
| `BUSY` | 1 bit | V2 inference/control path is active |
| `DONE` | 1 bit | end-to-end CNN inference has completed |
| `Class` | 4 bits | CIFAR-10 logit/class index |
| `Logit` | 26 bits | signed logit payload |

The Vitis application waits for `DONE` and then consumes the 10 FC2 logits.
The final class is obtained from the maximum logit.

---

## `0x04` - V2 Weight Preload

Weights remain model-static and are loaded once during startup.

V2 reuses the same logical write packing as the Baseline weight path:

```verilog
{16'b_WBaddress, 8'b_colnum, 8'b_Data}
```

The 9 x 16 tiled packing and Weight Buffer layout are described in
[`tiling_logic.md`](tiling_logic.md).

Weight preload time is kept separate from the per-image inference timing.

---

## `0x08` - V2 RGB Activation Upload

The PS performs the original CIFAR-10 normalization and INT8 input
quantization, then uploads the complete image:

```text
3 x 32 x 32 = 3072 INT8 values
```

The V2 activation write convention retains an address/channel/data form:

```verilog
{16'b_ABaddress, 8'b_channel, 8'b_Data}
```

where the channel field identifies the RGB input stream used by the V2 input
path.

Unlike V1, the PS does not materialize and upload every later layer's im2col
matrix. Those later activations remain inside the PL.

---

## `0x0C` - V2 Scaled-Bias / Control Path

Bias handling changed during V2 development.

The accepted V2 implementation does **not** rely on the earlier draft in this
document that described a simple execute-only `0x0C` register. The research
report shows that the final verified flow prepares activation-scale-dependent
bias values on the PS and transfers 522 scaled Q32 bias values for each image.

The number 522 is the sum of all Conv/FC output-channel biases:

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

Conceptually, the bias must be represented in the current accumulator domain:

```text
bias_acc ~= bias_real / (activation_scale x weight_scale)
```

The Product Loader / partial-sum path then injects the selected bias into the
corresponding accumulation inside the PL.

### Important interface note

The professor-report PDF records the **semantic behavior** and the final
`522 writes/image` communication count, but it does not contain the final
bit-level `0x0C` bias encoding. Therefore, the earlier planned half-write
parameter encoding should not be treated as the final public register map.

The exact field packing should be copied from the final checked-in RTL/Vitis
helper when that source is frozen. This document intentionally avoids
inventing a bitfield that is not supported by the report.

---

## V2 Start / Execute Behavior

After the per-image bias and RGB input have been staged, the V2 control path
starts the end-to-end inference sequence.

Once started, the PL performs:

```text
Conv1
 -> Conv2 -> MaxPool1
 -> Conv3
 -> Conv4 -> MaxPool2
 -> Conv5
 -> Conv6 -> MaxPool3
 -> GAP
 -> FC1
 -> FC2
```

without normal PS intervention between layers.

The PS polls the V2 status until completion and then reads the final logits.

---

# 5. Communication Reduction: V1 vs. V2

The research report counts the dominant payload transfers as follows.

## V1

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 / image
```

## V2

```text
Scaled bias writes :  522
RGB input writes   : 3072
Final logit reads  :   10
------------------------
Total              : 3604 / image
```

Therefore:

```text
3604 / 748650 = 0.004814
```

V2 retains only about `0.4814%` of the Baseline payload-transfer count, a
reduction of approximately `99.52%`.

These counts are **payload-transfer counts used for the architectural
comparison**. They do not include every AXI protocol handshake or every status
poll performed by software.

---

# 6. V1 vs. V2 Software-Visible Flow

```text
V1

PS
 |-- load activation / im2col data
 |-- configure S / IC
 |-- configure OC / WOffset
 |-- execute one MatMul
 |-- poll DONE
 |-- request PB data
 |-- read PB data
 |-- post-process / requantize
 `-- repeat


V2

Startup:
PS -- preload weights --> PL

Per image:
PS -- load scaled bias --> PL
PS -- load RGB input --> PL
PS -- start -----------> PL
                         |
                         | Conv1 ... FC2 internally
                         v
PS <-- 10 logits ------- PL
```

The main V2 benefit is therefore not a different AXI transport technology. It
is the elimination of most software-visible layer transactions while keeping
the same basic AXI4-Lite system integration.

