# V2 PYNQ/Jupyter Live Camera Demo

This directory contains the PYNQ/Jupyter live-camera demonstration for the verified **V2 end-to-end FPGA CNN accelerator**.

The demo shows the complete physical path:

```text
USB webcam
   -> PYNQ-Z2 host software
   -> V2 FPGA NPU
   -> CIFAR-10 prediction
   -> live Jupyter display
```

The live demo is intentionally reported separately from the controlled 1,000-image Vitis benchmark because the two measurements include different overheads.

---

# 1. Files

Main notebook:

```text
V2_Final_Live_Camera_Demo_Single.ipynb
```

Recorded demo:

```text
Live_Demo_project2.mp4
```

Repository links:

- [Jupyter Notebook](../../../v2/v2_live_demo/V2_Final_Live_Camera_Demo_Single.ipynb)
- [Recorded Demo](../../../v2/v2_live_demo/Live_Demo_project2.mp4)

---

# 2. Hardware

| Item | Configuration |
|---|---|
| FPGA board | PYNQ-Z2 |
| SoC | Xilinx Zynq-7020 |
| Accelerator | Project 2 V2 end-to-end CNN NPU |
| NPU clock | 125 MHz |
| Compute array | 9 x 16 weight-stationary systolic array |
| Processing elements | 144 INT8 PEs |
| Host interface | 32-bit AXI4-Lite |
| NPU base address | `0x40000000` |
| Camera | HCAM01L USB webcam |

The USB webcam is connected directly to the PYNQ-Z2 Linux system.

---

# 3. Model

The accelerator runs the Project 2 CIFAR-10 Model 2 network:

```text
Input 3 x 32 x 32
  -> Conv1  3 -> 32
  -> Conv2 32 -> 32 -> MaxPool
  -> Conv3 32 -> 64
  -> Conv4 64 -> 64 -> MaxPool
  -> Conv5 64 -> 96
  -> Conv6 96 -> 96 -> MaxPool
  -> GAP
  -> FC1 96 -> 128
  -> FC2 128 -> 10
```

CIFAR-10 classes:

```text
airplane
automobile
bird
cat
deer
dog
frog
horse
ship
truck
```

---

# 4. Live-Demo Pipeline

```text
HCAM01L USB Webcam
        |
        v
OpenCV / V4L2 frame capture
        |
        v
center crop
        |
        v
resize to 32 x 32
        |
        v
BGR -> RGB
        |
        v
CIFAR-10 mean/std normalization
        |
        v
global signed INT8 input quantization
        |
        +-- inv_input_scale_q16 -> parameter 530
        |
        v
upload R -> G -> B through AXI4-Lite
        |
        v
V2 FPGA NPU
Conv1 -> ... -> FC2
        |
        v
10 signed logits
        |
        v
argmax
        |
        v
live Jupyter display
```

---

# 5. Preprocessing

After crop, resize, and RGB conversion:

```text
x = pixel / 255
x_norm = (x - mean) / std
```

using:

```text
mean = (0.4914, 0.4822, 0.4465)
std  = (0.2470, 0.2435, 0.2616)
```

The complete normalized tensor is then quantized with one global signed-symmetric scale:

```text
max_abs = max(abs(x_norm))
input_scale = max_abs / 127
q = round_to_even(x_norm / input_scale)
q = clip(q, -128, 127)
```

The reciprocal input scale is converted to Q16:

```text
inv_input_scale_q16
    ~= round((1 / input_scale) * 2^16)
```

and written as parameter 530.

---

# 6. Verified V2 Host Protocol

## Startup Once

```text
all INT8 model weights

parameters 0..521
    bias_over_ws_q16

parameters 522..529
    inv_weight_scale_q16
```

These values are model-static.

## Per Image

```text
parameter 530
    inv_input_scale_q16

R channel
    1024 INT8 values

G channel
    1024 INT8 values

B channel
    1024 INT8 values
```

The PL then executes Conv1 through FC2 and the host reads the ten final FC2 logits.

---

# 7. 32-bit Parameter Encoding

A complete 32-bit parameter is transferred through `0x0C` using two AXI4-Lite writes:

```text
LOW  = {0, ParamNumber[14:0], Value[15:0]}
HIGH = {1, ParamNumber[14:0], Value[31:16]}
```

Verified parameter map:

```text
0..521   : bias_over_ws_q16
522..529 : inv_weight_scale_q16
530      : inv_input_scale_q16
```

Only parameter 530 is image-dependent.

---

# 8. Python/PYNQ Synchronization Note

The Vitis bare-metal driver can observe short `BUSY=1` phases during intermediate RGB-channel handling.

Python MMIO polling is slower, so the Jupyter driver can miss these short BUSY pulses.

The final host-side sequence therefore uses:

```text
send R
short guard
wait for BUSY = 0

send G
short guard
wait for BUSY = 0

send B
poll DONE
```

This is a host-software adaptation and does not change the RTL protocol.

The first RCODE read that observes `DONE=1` already contains one valid class/logit pair, so that value is preserved before the remaining nine logits are read.

---

# 9. Camera Handling

The camera is exposed through Linux V4L2 using `/dev/video*`.

The demo uses a persistent camera object rather than reopening the device for every frame.

A background reader keeps the newest available frame:

```text
camera thread
    |
    | continuously capture
    v
latest frame slot
    ^
    |
inference/display loop
```

This allows capture to proceed independently of the visible inference/display loop.

---

# 10. Running the Demo

Typical notebook sequence:

```text
1. Restore embedded hardware/model assets
2. Define the V2 host driver
3. Program the FPGA PL
4. Preload model weights
5. Preload parameters 0..529
6. Optionally run the embedded validation test
7. Open the USB camera
8. Test one frame
9. Start the continuous live-demo loop
10. Interrupt the Jupyter kernel to stop
11. Close the camera
```

If camera capture fails, verify the available `/dev/video*` nodes and ensure another process is not holding the device.

---

# 11. Functional Validation

Vitis result:

```text
Accuracy : 915 / 1000 = 91.5%
```

The PYNQ/Jupyter path reproduced:

```text
Accuracy : 915 / 1000 = 91.5%
```

The exact agreement validates the live-demo host path before camera-domain inputs are introduced.

The cross-check covers:

- FPGA programming;
- model preload;
- parameter preload;
- parameter 530 generation;
- input preprocessing;
- RGB upload;
- PL inference;
- final logit readback.

---

# 12. Controlled Vitis Performance

The verified 1,000-image Vitis benchmark reported:

```text
Average end-to-end time : 5.004 ms / image
```

Breakdown:

```text
PS preprocessing
    ~1.033 ms / image

parameter 530
+ RGB input staging
+ PL inference
+ final logits
    ~3.971 ms / image
```

The one-time model preload is excluded from steady-state per-image timing.

---

# 13. Live-Demo Throughput

The final camera/Jupyter demonstration showed approximately:

```text
~5 FPS
```

This value represents the complete application/display throughput in the current Jupyter demo environment.

It is not equivalent to the Vitis `5.004 ms/image` benchmark because the live path additionally includes:

- USB camera acquisition;
- camera-thread scheduling;
- crop / resize;
- BGR-to-RGB conversion;
- Python/Jupyter execution;
- host MMIO interaction;
- rendering;
- display updates.

No claim is made that ~5 FPS represents RTL-only NPU latency.

---

# 14. Project-Scope Implication

The live demo showed that the practical application-level frame rate is no longer primarily controlled by the NPU MAC time.

```text
Controlled V2 benchmark : 5.004 ms / image
Live Jupyter demo        : ~5 FPS (~200 ms / displayed frame)
```

These are different measurement scopes, so they should not be directly converted into a hardware speedup estimate. However, the large gap indicates that shaving a few additional milliseconds from the MAC path would not materially change the current live-demo FPS.

For this reason, the planned ZeroSkip extension was not implemented as part of Project 2. The project is concluded at V2.

Further live-video optimization should profile the complete host/runtime/display path.

---

# 15. Measurement Summary

| Measurement | Result | Meaning |
|---|---:|---|
| V2 CIFAR-10 accuracy | 91.5% | controlled 1,000-image test |
| Vitis end-to-end latency | 5.004 ms/image | controlled benchmark |
| PYNQ/Jupyter validation accuracy | 91.5% | host-path cross-check |
| Live-demo throughput | ~5 FPS | complete camera/Jupyter/display path |

---

# 16. Related Documentation

- [Project Overview](../../README.md)
- [Inference Model](../../docs/inference_model.md)
- [NPU Architecture](../../docs/architecture.md)
- [AXI4-Lite Command Interface](../../docs/AXI4-Lite_Command.md)
- [Experimental Results](../../docs/Experiments.md)
- [V2 Vitis Application](../../../v2/vitis_application/)
