# V2 PYNQ/Jupyter Live Camera Demo

## Purpose

This demo is the final functional I/O demonstration of the verified V2 end-to-end PL engine.

The quantitative accelerator result is established separately by the 1,000-image CIFAR-10 Vitis benchmark:

```text
Accuracy              : 915 / 1000 = 91.5%
End-to-end Vitis time : 5.004 ms / image
Target clock          : 125 MHz
```

Before using the webcam, the same known-good V2 bitstream, model parameters, preprocessing, and host protocol were ported to PYNQ/Jupyter and again reproduced exactly `915 / 1000 = 91.5%` on the embedded CIFAR-10 validation set.

The camera demo therefore focuses on demonstrating the physical input-to-result path rather than re-measuring dataset accuracy.

---

## Physical Setup

```text
USB webcam
    |
    | USB
    v
PYNQ-Z2 / Zynq-7020
    |
    | PYNQ Linux + Jupyter host
    | AXI4-Lite
    v
Custom V2 NPU in PL
    |
    v
Jupyter prediction display
```

The webcam is connected directly to the PYNQ-Z2 and captured through the Linux V4L2/OpenCV path.

For the recorded demonstration, several still images found through Google Image Search are displayed on a separate screen and physically shown to the webcam. The demo does **not** inject a downloaded/prerecorded video directly into the classifier.

Because the trained task is CIFAR-10 classification, the demonstration uses visual examples corresponding to CIFAR-10 classes where practical.

---

## Camera-to-NPU Pipeline

Each captured frame follows this path:

```text
webcam BGR frame
      |
      v
center square crop
      |
      v
resize to 32 x 32
      |
      v
BGR -> RGB
      |
      v
original CIFAR-10 channel normalization
      |
      v
global symmetric INT8 quantization
      |
      +--> reciprocal input scale Q16 -> parameter 530
      |
      v
R/G/B activation upload
      |
      v
V2 end-to-end PL inference
      |
      v
10 logits / predicted CIFAR-10 class
      |
      v
Jupyter display
```

The normalization constants and quantization procedure are the same as those used by the verified Vitis path.

---

## Verified V2 Host Protocol Used by the Demo

### Startup-only staging

The model is loaded once after programming the PL:

```text
INT8 weights
parameters 0..521 : bias_over_weight_scale Q16
parameters 522..529: reciprocal weight scales Q16
```

### Per frame

```text
1. capture frame
2. center crop / resize / RGB conversion
3. normalize and quantize
4. write image-dependent parameter 530
5. upload R channel
6. upload G channel
7. upload B channel
8. wait for end-to-end PL completion
9. consume 10 final logits
10. display predicted class
```

Parameter `530` contains the reciprocal input quantization scale in Q16. A full 32-bit parameter is sent through two writes to AXI offset `0x0C`:

```text
LOW  = {1'b0, ParamNumber[14:0], Value[15:0]}
HIGH = {1'b1, ParamNumber[14:0], Value[31:16]}
```

The R/G/B input consists of:

```text
3 x 32 x 32 = 3072 INT8 values
```

After the B channel is staged, the PL completes the remaining end-to-end CNN flow and exposes the ten FC2 logits through the result path.

---

## Jupyter Camera Handling

The final notebook keeps the webcam open continuously rather than opening and closing the V4L2 device for each inference.

A background capture thread stores the most recent camera frame while the main thread performs preprocessing, NPU inference, and display. This avoids making camera acquisition strictly serial with the inference loop and also avoids intermittent failures associated with repeatedly reopening the USB camera.

The live display may use a short prediction-history window to reduce visible class-label flicker. This smoothing is a UI feature only; it does not modify the NPU logits or the 1,000-image benchmark result.

---

## How to Interpret the Demo

The live recording demonstrates that the implemented system can perform:

```text
physical camera input
 -> PS preprocessing
 -> PS/PL input staging
 -> custom V2 FPGA NPU inference
 -> final result readback
 -> live Jupyter visualization
```

It should **not** be interpreted as a controlled accuracy measurement on arbitrary web images. CIFAR-10 is a 32x32 classification workload, whereas photographs displayed on a monitor and recaptured by a webcam introduce domain shift, resampling, perspective, display artifacts, and background content.

For the same reason, an incorrect prediction on an arbitrary camera frame is not directly comparable to the measured CIFAR-10 test-set accuracy.

---

## Performance Interpretation

Two different timing contexts are intentionally separated.

### Quantitative Vitis benchmark

```text
5.004 ms / image
~199.84 images/s equivalent benchmark throughput
```

This is the performance number used for the V1/V2 architecture comparison.

### Jupyter live-display loop

The visible camera-demo frame rate includes additional software/UI work such as:

- V4L2/OpenCV camera capture;
- Python preprocessing;
- Python MMIO operations;
- Jupyter image encoding and browser rendering;
- UI refresh overhead.

Therefore, the observed browser display FPS is **not reported as the NPU's hardware throughput**.

---

## Demo Recording

The final recording is named:

```text
Live_Demo_project2.mp4
```

The video is organized as a short project/demo introduction, physical setup, and camera-based classification demonstration.

The source images shown to the webcam were found through Google Image Search. Because those images are third-party material, this repository does not claim ownership of them and does not use the live-demo sequence as a dataset benchmark.

---

## Reproducibility Notes

The verified V2 hardware/software pair is the implementation that reproduced both:

```text
CIFAR-10 accuracy : 91.5%
Vitis latency     : 5.004 ms / image
```

The checked-in Vitis host files define the software-visible parameter protocol used by that build. Historical documentation describing per-image transfer of all 522 scaled biases belongs to an earlier V2 design stage and should not be used as the final runtime protocol.

For register-level details, see [`AXI4-Lite_Command.md`](AXI4-Lite_Command.md). For the quantitative development history, see [`Experiments.md`](Experiments.md).
