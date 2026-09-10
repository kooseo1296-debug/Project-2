# Known-good V2 validation bundle

Use this bundle before the webcam demo.

Files:
- `v2_known_good.bit` / `v2_known_good.hwh`: extracted directly from the uploaded XSA that produced 91.5% Vitis accuracy.
- `v2_known_good_full.npz`: exact uploaded model_data.c converted to NumPy, including all 1000 embedded CIFAR test images/labels.
- `npu_v2_jupyter_known_good.py`: Jupyter driver with a 1 ms R/G channel guard plus embedded-test validation.
- `V2_Known_Good_Validation.ipynb`: run in order.

The first 20 CIFAR labels are:
3,8,8,0,6,6,1,6,3,1,0,9,5,7,9,8,5,7,8,6

Therefore, if the Jupyter path predicts cat for nearly all of these, it is definitely a host/MMIO sequencing problem rather than webcam domain shift.
