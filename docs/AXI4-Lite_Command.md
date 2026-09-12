# AXI4-Lite Command Interface

This document records the software-visible command interface for the Project-2 accelerators.

The Baseline (V1) and End-to-End (V2) engines use the same 32-bit AXI4-Lite PS-PL connection, but the command semantics differ substantially. The V2 section below describes the **verified host protocol used by the Vitis application/XSA pair that produced 91.5% accuracy and 5.004 ms/image**.

---

# 1. Baseline (V1) — PS-Managed MatMul

V1 uses the PS to explicitly manage weight loading, activation loading, MatMul configuration/execution, Product Buffer reads, and status polling.

## V1 Address Map

| Offset | Operation | Direction | Description |
|---:|---|---|---|
| `0x00` | RCODE | PL -> PS | status / PB response |
| `0x04` | Load Weight | PS -> PL | one INT8 weight |
| `0x08` | Load Activation | PS -> PL | one INT8 activation |
| `0x0C` | Configure / Execute | PS -> PL | MatMul configuration/start |
| `0x10` | Read Product Buffer | PS -> PL | PB read request |

### `0x04` — Weight

```text
{WB_Address[15:0], Column[7:0], Data[7:0]}
```

### `0x08` — Activation

```text
{AB_Address[15:0], Row[7:0], Data[7:0]}
```

### `0x0C` — Baseline MatMul Commands

```text
00 : {2'b00, S[14:0],  IC[14:0]}
01 : {2'b01, OC[14:0], WOffset[14:0]}
10 : execute
```

Typical sequence:

```text
load activation
 -> configure S / IC
 -> configure OC / WOffset
 -> execute MatMul
 -> poll BUSY / DONE
 -> request Product Buffer data
 -> read Product Buffer data
 -> PS post-processing
 -> repeat
```

The detailed V1 implementation is retained in the baseline source tree; the remainder of this document focuses on the final V2 protocol.

---

# 2. V2 — Verified End-to-End PL Protocol

V2 no longer exposes layer-by-layer MatMul execution to software. After startup model staging and per-image input staging, the PL schedules Conv1 through FC2 internally.

## V2 Address Map

| Offset | Operation | Direction | V2 role |
|---:|---|---|---|
| `0x00` | RCODE / Result | PL -> PS | BUSY, DONE, class/logit readback |
| `0x04` | Load Weight | PS -> PL | model-static INT8 weight preload |
| `0x08` | Load Activation | PS -> PL | RGB INT8 input upload |
| `0x0C` | Parameter | PS -> PL | 32-bit parameter transfer |

The NPU AXI base address in the verified design is `0x40000000`.

---

## 2.1 `0x00` — RCODE / Final Logits

The verified V2 convention is:

```text
{BUSY, DONE, Class[3:0], Logit[25:0]}
```

```text
31      30 29        26 25                           0
+-------+--+------------+-----------------------------+
| BUSY  |DONE|   Class    |            Logit           |
+-------+--+------------+-----------------------------+
```

`Logit[25:0]` is interpreted as a signed 26-bit value.

After the final layer completes, software preserves the **first RCODE read that observes `DONE`**, because that same read already contains the first logit. Nine further accepted result reads return the remaining class/logit entries.

---

## 2.2 `0x04` — Weight Preload

Weights are model-static and are loaded once at startup.

```text
{WB_Address[15:0], Column[7:0], Data[7:0]}
```

The host uses K-tile-major / output-channel-tile-minor packing for the 9x16 systolic array.

Verified layer weight-buffer bases:

| Layer | Base |
|---|---:|
| Conv1 | 0 |
| Conv2 | 54 |
| Conv3 | 630 |
| Conv4 | 1782 |
| Conv5 | 4086 |
| Conv6 | 7542 |
| FC1 | 12726 |
| FC2 | 13518 |

See [`tiling_logic.md`](tiling_logic.md) for mapping details.

---

## 2.3 `0x08` — RGB Activation Upload

The PS performs CIFAR-10 normalization and global INT8 quantization before upload.

Each image contains:

```text
3 x 32 x 32 = 3072 INT8 values
```

The command packing is:

```text
{AB_Address[15:0], Channel[7:0], Data[7:0]}
```

with channel identifiers corresponding to the R/G/B input channels.

The verified host sequence is:

```text
R channel: 1024 writes
G channel: 1024 writes
B channel: 1024 writes
```

Unlike V1, later feature maps are not returned to the PS between layers.

---

## 2.4 `0x0C` — Full 32-bit Parameter Protocol

The final verified implementation transfers one 32-bit parameter using **two AXI writes**.

### LOW half

```text
{1'b0, ParamNumber[14:0], Value[15:0]}
```

### HIGH half

```text
{1'b1, ParamNumber[14:0], Value[31:16]}
```

The LOW write stages the lower 16 bits; the HIGH write supplies the upper 16 bits and completes the parameter transfer.

### Parameter Map

| Parameter | Meaning | Lifetime |
|---|---|---|
| `0..521` | signed `bias_over_weight_scale` Q16 | startup |
| `522..529` | reciprocal weight scale Q16 for Conv1..FC2 | startup |
| `530` | reciprocal input activation scale Q16 | per image |

The 522 bias entries correspond to:

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

**Important:** parameters `0..529` are loaded once during model preload. They are **not** transferred again for every image in the verified V2 host path. Only parameter `530` is image-dependent.

This supersedes the earlier experimental V2 description in which 522 activation-scale-dependent bias values were prepared and transferred per image.

---

# 3. Verified V2 Startup Flow

```text
Program PL
   |
   v
Preload all model weights through 0x04
   |
   v
Preload params 0..521 through 0x0C
   |
   v
Preload params 522..529 through 0x0C
   |
   v
Ready for image inference
```

Weight preload and parameter `0..529` staging are startup costs and are excluded from steady-state per-image payload traffic.

---

# 4. Verified V2 Per-Image Flow

```text
PS preprocessing
   |
   +--> normalized / quantized RGB INT8
   `--> reciprocal input scale Q16

write param 530 LOW
write param 530 HIGH
        |
        v
upload R (1024)
        |
        v
upload G (1024)
        |
        v
upload B (1024)
        |
        v
PL executes end-to-end CNN
        |
        v
poll DONE
        |
        v
consume 10 class/logit results
```

The bare-metal Vitis host waits for the R/G processing handshake before G and similarly between G and B. In PYNQ/Jupyter, the BUSY-high pulse can be shorter than Python MMIO polling latency; the validated notebook therefore uses a short guard interval after R/G and waits for the interface to be non-BUSY before sending the next channel.

That Jupyter workaround does not change the NPU arithmetic or the software-visible data format.

---

# 5. Fixed Per-Image Payload Count

For the final verified V2 protocol:

```text
Param 530      :    2 AXI writes
RGB input      : 3072 AXI writes
Final logits   :   10 AXI reads
--------------------------------
Fixed payload  : 3084 word accesses / image
```

The V1 architectural payload count used in this project is:

```text
im2col activation LOAD : 637,920
Product Buffer READ    : 110,730
--------------------------------
Total                  : 748,650 / image
```

Thus, using the same fixed-payload counting convention:

```text
3084 / 748650 ~= 0.00412
```

or roughly a **99.59% reduction** in fixed payload transfers.

These numbers deliberately exclude variable status-poll reads and AXI protocol-level channel handshakes. They are software-visible payload-access counts for architectural comparison.

---

# 6. V1 vs. V2 Software-Visible Flow

```text
V1

PS
 |-- load layer activation / im2col
 |-- configure MatMul
 |-- execute
 |-- poll
 |-- read Product Buffer
 |-- post-process / requantize
 `-- repeat for each layer/tile


V2

Startup:
PS -- weights + params 0..529 --> PL

Per image:
PS -- param 530 -------------> PL
PS -- R/G/B input -----------> PL
                                |
                                | Conv1 ... FC2 internally
                                v
PS <-- 10 logits ------------ PL
```

The primary V2 gain is therefore the elimination of repeated PS-managed layer execution and intermediate feature-map traffic while retaining the same basic AXI4-Lite system integration.

---

# 7. Source-of-Truth Note

The final V2 protocol above is based on the checked-in `v2/vitis_application/npu_v2_hw.h` / `.c` host implementation and the matching hardware export used for the verified `91.5% / 5.004 ms` result.

Project development included earlier bias-handling experiments. Documentation or RTL snapshots that describe per-image loading of all 522 scaled biases represent those intermediate stages and should not be used to infer the final verified host protocol without checking the matching build provenance.
