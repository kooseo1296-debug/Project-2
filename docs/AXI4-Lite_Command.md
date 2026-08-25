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

# 4. V2 — End-to-End PL Inference (Planned)

> **Note:** The V2 command format is still subject to change while the final Activation Buffer organization is being determined.

V2 moves CNN scheduling from the PS into the PL.

The intended PS responsibilities are reduced to:

- loading weights,
- loading the input image,
- issuing an execution command,
- reading the final inference result.

Intermediate MatMul configuration and Product Buffer readback are removed from the normal software-visible inference flow.

## Planned Address Map

| Offset | Operation | Direction | Description |
|---:|---|---|---|
| `0x00` | Read Result | PL → PS | Read CNN status and final inference result |
| `0x04` | Load Weight | PS → PL | Load weight data |
| `0x08` | Load Input | PS → PL | Load RGB input data |
| `0x0C` | Execute | PS → PL | Start end-to-end CNN inference |

---

## `0x00` — Read Result

**Direction:** PL → PS

Planned format:

```verilog
{BUSY, DONE, 4'b_Class, 26'b_Value}
```

### Bit Field

```text
31      30 29        26 25                           0
+-------+--+------------+-----------------------------+
| BUSY  |DONE|  Class    |            Value            |
| 1 bit |1bit|  4 bits   |           26 bits           |
+-------+--+------------+-----------------------------+
```

| Field | Width | Description |
|---|---:|---|
| `BUSY` | 1 bit | CNN inference is active |
| `DONE` | 1 bit | CNN inference has completed |
| `Class` | 4 bits | Predicted CIFAR-10 class |
| `Value` | 26 bits | Output value associated with the prediction |

---

## `0x04` — Load Weight

**Direction:** PS → PL

Planned format:

```verilog
{20'b_WBaddress, 4'b_colnum, 8'b_Data}
```

| Field | Width | Description |
|---|---:|---|
| `WBaddress` | 20 bits | Weight Buffer address |
| `colnum` | 4 bits | Target column |
| `Data` | 8 bits | INT8 weight value |

---

## `0x08` — Load Input

**Direction:** PS → PL

Planned format:

```verilog
{20'b_ABaddress, 4'b_RGB, 8'b_Data}
```

| Field | Width | Description |
|---|---:|---|
| `ABaddress` | 20 bits | Activation Buffer address |
| `RGB` | 4 bits | RGB channel identifier |
| `Data` | 8 bits | INT8 input value |

For a CIFAR-10 image:

```text
32 × 32 × 3
= 1024 spatial positions × 3 channels
= 3072 INT8 input values
```

The final mapping of these 3072 values depends on the V2 Activation Buffer organization.

---

## `0x0C` — Execute

**Direction:** PS → PL

A write to address `0x0C` triggers CNN execution.

The write payload itself is ignored.

```verilog
{32'bX}
```

The intended software-visible flow is:

```text
Load weights
     ↓
Load RGB input
     ↓
Write 0x0C
     ↓
End-to-end CNN inference in PL
     ↓
Read final result from 0x00
```

---
