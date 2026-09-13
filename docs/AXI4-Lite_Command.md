# AXI4-Lite Command Interface

The custom FPGA accelerator is controlled through a 32-bit AXI4-Lite interface between the Zynq Processing System (PS) and Programmable Logic (PL).

The PS is the AXI master and the custom NPU IP is the AXI slave.

The same physical interface is used by both V1 and V2, but the software-visible execution model changes substantially.

---

# 1. Baseline V1 — PS-Managed MatMul

The baseline PS explicitly manages:

- weight loading;
- activation loading;
- MatMul configuration;
- MatMul execution;
- Product Buffer read requests;
- result/status polling;
- layer-by-layer post-processing.

## Baseline Address Map

| Offset | Operation | Direction | Description |
|---:|---|---|---|
| `0x00` | RCODE | PL -> PS | status / Product Buffer response |
| `0x04` | Load Weight | PS -> PL | one INT8 weight |
| `0x08` | Load Activation | PS -> PL | one INT8 activation |
| `0x0C` | Configure / Execute | PS -> PL | MatMul configuration and execute |
| `0x10` | Read Product Buffer | PS -> PL | request one Product Buffer value |

---

# 2. Baseline `0x04` — Load Weight

```verilog
{WBaddress[15:0], Column[7:0], Data[7:0]}
```

---

# 3. Baseline `0x08` — Load Activation

```verilog
{ABaddress[15:0], Row[7:0], Data[7:0]}
```

---

# 4. Baseline `0x0C` — MatMul Configuration

Configure `S` and `IC`:

```verilog
{2'b00, S[14:0], IC[14:0]}
```

Configure `OC` and `WOffset`:

```verilog
{2'b01, OC[14:0], WOffset[14:0]}
```

Execute:

```verilog
{2'b10, 30'dX}
```

Typical flow:

```text
Write 0x0C : {00, S, IC}
Write 0x0C : {01, OC, WOffset}
Write 0x0C : {10, X}
Poll 0x00 until DONE
```

---

# 5. Baseline `0x10` — Product Buffer Read

```verilog
{PBaddress[15:0], Column[7:0], 8'd0}
```

The PS polls `0x00` until the requested Product Buffer data becomes valid.

---

# 6. Baseline `0x00` — RCODE

```verilog
{BUSY, DONE, PENDING, VALID, DATA[27:0]}
```

| Bit | Field | Description |
|---:|---|---|
| 31 | `BUSY` | MatMul active |
| 30 | `DONE` | MatMul complete |
| 29 | `PENDING` | PB read pending |
| 28 | `VALID` | PB data valid |
| 27:0 | `DATA` | Product Buffer result |

---

# 7. AXI4-Lite Slave Write Handling

AXI4-Lite write-address (`AW`) and write-data (`W`) channels are independent.

The slave must not assume `AWVALID` and `WVALID` arrive in the same cycle.

```text
AW handshake -> latch address
W handshake  -> latch data
address + data captured
        |
        v
generate one-cycle internal command pulse
        |
        v
generate AXI write response
```

One accepted AXI write must produce one accelerator command event.

---

# 8. V2 — End-to-End PL Inference

V2 keeps the same 32-bit AXI4-Lite connection but changes the software-visible flow.

```text
Startup:
    preload weights
    preload model-static parameters

Per image:
    write image-dependent input-scale parameter
    upload R/G/B input
    let PL execute Conv1 through FC2
    read 10 final logits
```

Intermediate feature maps remain inside the PL.

---

# 9. V2 Semantic Address Map

| Offset | Operation | Direction | V2 role |
|---:|---|---|---|
| `0x00` | RCODE / Logit | PL -> PS | status and FC2 logit readback |
| `0x04` | Load Weight | PS -> PL | startup INT8 weight preload |
| `0x08` | Load Activation | PS -> PL | per-image RGB INT8 input |
| `0x0C` | Parameter | PS -> PL | 32-bit parameter LOW/HIGH writes |

`0x10` Product Buffer readback is a V1 operation and is not part of normal V2 inference.

---

# 10. V2 `0x00` — RCODE / Logit Readback

The verified V2 convention is:

```verilog
{BUSY, DONE, Class[3:0], Logit[25:0]}
```

| Field | Width | Description |
|---|---:|---|
| `BUSY` | 1 | current V2 phase active |
| `DONE` | 1 | final FC2 result phase active |
| `Class` | 4 | class/logit index |
| `Logit` | 26 | signed FC2 logit |

The final prediction is:

```text
argmax(logit[0..9])
```

---

# 11. V2 `0x04` — Weight Preload

Weights are model-static and loaded once during startup.

```verilog
{WBaddress[15:0], Column[7:0], Data[7:0]}
```

Verified Weight Buffer bases:

```text
Conv1 :     0
Conv2 :    54
Conv3 :   630
Conv4 :  1782
Conv5 :  4086
Conv6 :  7542
FC1   : 12726
FC2   : 13518
```

---

# 12. V2 `0x08` — RGB Activation Upload

Each image contains:

```text
3 x 32 x 32 = 3072 INT8 values
```

Packing:

```verilog
{ABaddress[15:0], Color[7:0], Data[7:0]}
```

Color encoding:

```text
0 : R
1 : G
2 : B
```

Each channel uses addresses `0..1023`.

---

# 13. V2 `0x0C` — 32-bit Parameter Protocol

Every V2 parameter is transferred through two AXI4-Lite writes:

```verilog
LOW  = {1'b0, ParamNumber[14:0], Value[15:0]}
HIGH = {1'b1, ParamNumber[14:0], Value[31:16]}
```

The LOW write carries bits `[15:0]` and the HIGH write carries bits `[31:16]`.

---

# 14. Verified V2 Parameter Map

| Parameter | Meaning | Lifetime |
|---:|---|---|
| `0..521` | `bias_over_ws_q16` | startup/model-static |
| `522` | Conv1 `inv_weight_scale_q16` | startup/model-static |
| `523` | Conv2 `inv_weight_scale_q16` | startup/model-static |
| `524` | Conv3 `inv_weight_scale_q16` | startup/model-static |
| `525` | Conv4 `inv_weight_scale_q16` | startup/model-static |
| `526` | Conv5 `inv_weight_scale_q16` | startup/model-static |
| `527` | Conv6 `inv_weight_scale_q16` | startup/model-static |
| `528` | FC1 `inv_weight_scale_q16` | startup/model-static |
| `529` | FC2 `inv_weight_scale_q16` | startup/model-static |
| `530` | `inv_input_scale_q16` | per image |

Bias ordering:

```text
Conv1 :   0..31
Conv2 :  32..63
Conv3 :  64..127
Conv4 : 128..191
Conv5 : 192..287
Conv6 : 288..383
FC1   : 384..511
FC2   : 512..521
```

Parameters 0..529 are written during model preload. Parameter 530 is image-dependent.

---

# 15. V2 Startup Sequence

```text
1. Initialize NPU base address
2. Preload all INT8 weights through 0x04
3. Preload parameters 0..521 through 0x0C
4. Preload parameters 522..529 through 0x0C
5. Enter per-image inference loop
```

---

# 16. V2 Per-Image Sequence

```text
1. Wait for BUSY = 0

2. Write parameter 530
   -> LOW write
   -> HIGH write

3. Upload R channel
   -> 1024 writes to 0x08

4. Synchronize with channel-processing state

5. Upload G channel
   -> 1024 writes to 0x08

6. Synchronize with channel-processing state

7. Upload B channel
   -> 1024 writes to 0x08

8. Poll 0x00 until DONE

9. Preserve the first DONE-containing RCODE

10. Read nine additional RCODE values

11. Reconstruct all ten logits and perform argmax
```

---

# 17. Important Logit-Readback Behavior

The first RCODE read that observes `DONE=1` already contains one valid class/logit pair.

Correct behavior:

```text
poll until DONE
consume that same read as logit #1
read nine additional results
```

Discarding the first DONE-containing read loses one output value.

---

# 18. Vitis vs. PYNQ/Jupyter Host Timing

The bare-metal Vitis driver can observe short intermediate `BUSY=1` phases after R and G channel uploads.

Python MMIO polling is slower, so the Jupyter driver can miss these short pulses.

The final Jupyter host sequence uses:

```text
send R
short guard interval
wait for BUSY = 0

send G
short guard interval
wait for BUSY = 0

send B
poll DONE directly
```

This is a host-software adaptation and does not change the RTL register map.

---

# 19. Communication Reduction

## V1

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 / image
```

## V2

```text
Parameter 530 LOW/HIGH :    2 writes
RGB input              : 3072 writes
Final logits           :   10 reads
--------------------------------
Total                  : 3084 / image
```

Status polling is excluded from both architectural payload counts.

V2 reduces the dominant steady-state payload metric by approximately 99.59%.

---

# 20. Software-Visible Flow Comparison

```text
V1
PS -> load im2col -> execute MatMul -> read PB -> post-process -> repeat
```

```text
V2
Startup: PS -> weights + params 0..529 -> PL
Per image: PS -> param 530 + R/G/B -> PL -> Conv1 ... FC2 -> 10 logits -> PS
```

The primary V2 benefit is the removal of layer-by-layer software-visible transactions while retaining the same AXI4-Lite system integration.
