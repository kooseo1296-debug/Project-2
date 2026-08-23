# AXI4-Lite Command Interface

The NPU is controlled through a 32-bit AXI4-Lite interface between the Processing System (PS) and Programmable Logic (PL).

The Baseline and V2 architectures use the same register offsets, but the role of each command changes as more inference control is moved from the PS to the PL.

---

## 1. Baseline

In the Baseline architecture, the PS explicitly manages weight/input transfer, matrix-multiplication configuration, execution, and Product Buffer readback.

### Command Summary

| Offset | Command | Direction | Description |
|---:|---|---|---|
| `0x00` | Read Data | PS → PL | Request data from the Product Buffer |
| `0x04` | Load Weight | PS → PL | Write weight data into the Weight Buffer |
| `0x08` | Load Input | PS → PL | Write input data into the Activation Buffer |
| `0x0C` | Execution | PS → PL | Configure and execute matrix multiplication |
| `0x00` | Response | PL → PS | Return status and requested Product Buffer data |

---

### `0x00` — Read Data

**Direction:** PS → PL

Requests a value from the Product Buffer.

```verilog
{20'b_PBaddress, 4'b_colnum, 8'd0}
```

#### Bit Field

```text
31                    12 11       8 7                0
+-----------------------+-----------+------------------+
|      PB Address       |  Column   |        0         |
|       20 bits         |  4 bits   |      8 bits      |
+-----------------------+-----------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `PBaddress` | 20 bits | Product Buffer address |
| `colnum` | 4 bits | Target column |
| Reserved | 8 bits | Fixed to `0` |

---

### `0x04` — Load Weight

**Direction:** PS → PL

Writes an INT8 weight value into the Weight Buffer.

```verilog
{20'b_WBaddress, 4'b_colnum, 8'b_Data}
```

#### Bit Field

```text
31                    12 11       8 7                0
+-----------------------+-----------+------------------+
|      WB Address       |  Column   |       Data       |
|       20 bits         |  4 bits   |      8 bits      |
+-----------------------+-----------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `WBaddress` | 20 bits | Weight Buffer address |
| `colnum` | 4 bits | Target column |
| `Data` | 8 bits | Weight data |

---

### `0x08` — Load Input

**Direction:** PS → PL

Writes an INT8 input value into the Activation Buffer.

```verilog
{20'b_ABaddress, 4'b_rownum, 8'b_Data}
```

#### Bit Field

```text
31                    12 11       8 7                0
+-----------------------+-----------+------------------+
|      AB Address       |    Row    |       Data       |
|       20 bits         |  4 bits   |      8 bits      |
+-----------------------+-----------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `ABaddress` | 20 bits | Activation Buffer address |
| `rownum` | 4 bits | Target row |
| `Data` | 8 bits | Input activation data |

---

### `0x0C` — Execution

**Direction:** PS → PL

The Baseline architecture uses multiple writes to `0x0C` to configure and start a matrix-multiplication operation.

Bits `[31:30]` identify the type of execution command.

#### `2'b00` — Set `S` and `IC`

```verilog
{2'b00, 15'b_S_Val, 15'b_IC_Val}
```

```text
31  30 29                 15 14                   0
+------+--------------------+----------------------+
|  00  |       S_Val        |        IC_Val        |
|2 bits|      15 bits       |       15 bits        |
+------+--------------------+----------------------+
```

#### `2'b01` — Set `OC` and Weight Offset

```verilog
{2'b01, 15'b_OC_Val, 15'b_WOffset_Val}
```

```text
31  30 29                 15 14                   0
+------+--------------------+----------------------+
|  01  |       OC_Val       |     WOffset_Val      |
|2 bits|      15 bits       |       15 bits        |
+------+--------------------+----------------------+
```

#### `2'b10` — Execute MatMul

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

When the controller receives this command, matrix multiplication starts using the previously configured parameters.

Typical sequence:

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

### `0x00` — Response

**Direction:** PL → PS

The PS reads offset `0x00` to obtain accelerator status and Product Buffer readback data.

```verilog
{1'b_BUSY, 1'b_DONE, 30'b_OTHER}
```

#### Bit Field

```text
31     30 29                                      0
+--------+-----------------------------------------+
| BUSY |DONE|                OTHER                 |
| 1 bit|1 bit|               30 bits               |
+--------+-----------------------------------------+
```

| Field | Width | Description |
|---|---:|---|
| `BUSY` | 1 bit | Accelerator busy state |
| `DONE` | 1 bit | Operation completion state |
| `OTHER` | 30 bits | Response payload |

When

```verilog
{BUSY, DONE} == 2'b01
```

the `OTHER` field contains the Product Buffer read response.

#### Read Address Response

```verilog
{2'b10, 16'b_PBaddress, 4'b_colnum, 8'dX}
```

```text
29  28 27                12 11       8 7          0
+------+-------------------+-----------+------------+
|  10  |    PB Address     |  Column   |     X      |
|2 bits|      16 bits      |  4 bits   |   8 bits   |
+------+-------------------+-----------+------------+
```

#### Read Data Response

```verilog
{2'b01, 28'b_Data}
```

```text
29  28 27                                           0
+------+---------------------------------------------+
|  01  |                    Data                     |
|2 bits|                   28 bits                   |
+------+---------------------------------------------+
```

---

## 2. V2 — End-to-End PL Inference

In V2, CNN execution and scheduling are moved into the PL.

The PS is mainly responsible for:

1. loading weights,
2. loading RGB input data,
3. issuing the execution command,
4. reading the final inference result.

Intermediate MatMul configuration and Product Buffer readback used in the Baseline are removed from normal inference operation.

### Command Summary

| Offset | Command | Direction | Description |
|---:|---|---|---|
| `0x00` | Read Result | PL → PS | Return inference status and final result |
| `0x04` | Load Weight | PS → PL | Write weight data into the Weight Buffer |
| `0x08` | Load Input | PS → PL | Write RGB input data into the Activation Buffer |
| `0x0C` | Execute | PS → PL | Start end-to-end CNN inference |

---

### `0x00` — Read Result

**Direction:** PL → PS

Returns the accelerator state and final inference result.

```verilog
{1'b_BUSY, 1'b_DONE, 4'b_Class, 26'b_Value}
```

#### Bit Field

```text
31     30 29        26 25                           0
+--------+-------------+-----------------------------+
| BUSY |DONE|   Class   |            Value            |
| 1 bit|1 bit|  4 bits |           26 bits           |
+--------+-------------+-----------------------------+
```

| Field | Width | Description |
|---|---:|---|
| `BUSY` | 1 bit | Inference is currently running |
| `DONE` | 1 bit | Inference has completed |
| `Class` | 4 bits | Predicted class |
| `Value` | 26 bits | Output value associated with the result |

---

### `0x04` — Load Weight

**Direction:** PS → PL

The weight-loading command remains identical to the Baseline architecture.

```verilog
{20'b_WBaddress, 4'b_colnum, 8'b_Data}
```

#### Bit Field

```text
31                    12 11       8 7                0
+-----------------------+-----------+------------------+
|      WB Address       |  Column   |       Data       |
|       20 bits         |  4 bits   |      8 bits      |
+-----------------------+-----------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `WBaddress` | 20 bits | Weight Buffer address |
| `colnum` | 4 bits | Target column |
| `Data` | 8 bits | Weight data |

---

### `0x08` — Load Input

**Direction:** PS → PL

Loads RGB input data into the Activation Buffer.

```verilog
{20'b_ABaddress, 4'b_RGB, 8'b_Data}
```

#### Bit Field

```text
31                    12 11       8 7                0
+-----------------------+-----------+------------------+
|      AB Address       |    RGB    |       Data       |
|       20 bits         |  4 bits   |      8 bits      |
+-----------------------+-----------+------------------+
```

| Field | Width | Description |
|---|---:|---|
| `ABaddress` | 20 bits | Activation Buffer address |
| `RGB` | 4 bits | RGB channel information |
| `Data` | 8 bits | INT8 input data |

For a `32 × 32 × 3` CIFAR-10 image:

```text
32 × 32 × 3
= 1024 × 3
= 3072 input values
```

The PS transfers a total of 3072 input values corresponding to the R, G, and B channels.

---

### `0x0C` — Execute

**Direction:** PS → PL

A write transaction to offset `0x0C` immediately triggers end-to-end CNN inference.

The 32-bit write payload itself is ignored.

```verilog
{32'bX}
```

Execution sequence:

```text
Load Weights
     ↓
Load 3072 RGB Input Values
     ↓
Write 0x0C
     ↓
Execute End-to-End CNN in PL
     ↓
Read Final Result from 0x00
```

---

## 3. Baseline vs. V2

| Feature | Baseline | V2 |
|---|---|---|
| Weight loading | PS controlled | PS controlled |
| Input loading | PS controlled | PS controlled |
| Input metadata | Row number | RGB channel |
| MatMul parameters | Explicitly sent by PS | Managed internally by PL |
| Execution | Individual MatMul | End-to-end CNN |
| Product Buffer readback | Required | Not required during normal inference |
| Final result | Product Buffer data | Class + Value |
| PS intervention | High | Reduced |
| PL responsibility | Mainly MatMul execution | End-to-end CNN inference |

The main architectural difference between the Baseline and V2 is the **execution partition between the PS and PL**.

In the Baseline, the PS explicitly configures and manages individual matrix-multiplication operations.

In V2, the PS loads the required weights and RGB input data and then issues a single execution command. The PL controller manages the remaining CNN inference flow internally.
