# npu_v2_jupyter.py
# Jupyter/PYNQ host driver for Project-2 V2.
# Mirrors the current GitHub Vitis flow:
#   startup: weights + params 0..529
#   per image: param 530 + R/G/B upload + DONE/logit reads

from pathlib import Path
import re
import time
import threading
import zipfile
import shutil

import numpy as np

try:
    from pynq import Overlay, MMIO
except ImportError:
    Overlay = None
    MMIO = None


# AXI-Lite register map
REG_RCODE  = 0x00
REG_LOAD_W = 0x04
REG_LOAD_A = 0x08
REG_PARAM  = 0x0C

RCODE_BUSY        = 1 << 31
RCODE_DONE        = 1 << 30
RCODE_CLASS_SHIFT = 26
RCODE_CLASS_MASK  = 0xF << RCODE_CLASS_SHIFT
RCODE_LOGIT_MASK  = 0x03FFFFFF
RCODE_LOGIT_SIGN  = 0x02000000

PE_ROW   = 9
PE_COL   = 16
WB_DEPTH = 16384

PARAM_BIAS_FIRST      = 0
PARAM_BIAS_LAST       = 521
PARAM_IWS_CONV1       = 522
PARAM_IWS_CONV2       = 523
PARAM_IWS_CONV3       = 524
PARAM_IWS_CONV4       = 525
PARAM_IWS_CONV5       = 526
PARAM_IWS_CONV6       = 527
PARAM_IWS_FC1         = 528
PARAM_IWS_FC2         = 529
PARAM_INV_INPUT_SCALE = 530
PARAM_MAX             = 530

MODEL_SCALE_ONE = 1 << 16

WEIGHT_SPECS = [
    ("g_w0_conv1", 27,  32,   0),
    ("g_w1_conv2", 288, 32,  54),
    ("g_w2_conv3", 288, 64, 630),
    ("g_w3_conv4", 576, 64, 1782),
    ("g_w4_conv5", 576, 96, 4086),
    ("g_w5_conv6", 864, 96, 7542),
    ("g_w6_fc1",    96, 128, 12726),
    ("g_w7_fc2",   128,  10, 13518),
]

BIAS_SPECS = [
    ("g_bow0_conv1_q16",   0,  32),
    ("g_bow1_conv2_q16",  32,  32),
    ("g_bow2_conv3_q16",  64,  64),
    ("g_bow3_conv4_q16", 128,  64),
    ("g_bow4_conv5_q16", 192,  96),
    ("g_bow5_conv6_q16", 288,  96),
    ("g_bow6_fc1_q16",   384, 128),
    ("g_bow7_fc2_q16",   512,  10),
]

IWS_SPECS = [
    ("g_iws0_conv1_q16", PARAM_IWS_CONV1),
    ("g_iws1_conv2_q16", PARAM_IWS_CONV2),
    ("g_iws2_conv3_q16", PARAM_IWS_CONV3),
    ("g_iws3_conv4_q16", PARAM_IWS_CONV4),
    ("g_iws4_conv5_q16", PARAM_IWS_CONV5),
    ("g_iws5_conv6_q16", PARAM_IWS_CONV6),
    ("g_iws6_fc1_q16",   PARAM_IWS_FC1),
    ("g_iws7_fc2_q16",   PARAM_IWS_FC2),
]

DEFAULT_CLASSES = np.array(
    ["airplane", "automobile", "bird", "cat", "deer",
     "dog", "frog", "horse", "ship", "truck"]
)


def _strip_c_numeric_suffix(token):
    token = token.strip()
    token = re.sub(r'(?i)(?<=\d)[uUlLfF]+$', '', token)
    return token


def _find_initializer(text, name):
    # Match "... name[...]= {" and return the body inside braces.
    pat = re.compile(r'\b' + re.escape(name) + r'\s*\[[^\]]*\]\s*=\s*\{', re.M)
    m = pat.search(text)
    if not m:
        raise KeyError("Array initializer not found: %s" % name)
    start = m.end()
    end = text.find("};", start)
    if end < 0:
        raise ValueError("Unterminated initializer: %s" % name)
    return text[start:end]


def _parse_int_array(text, name, dtype):
    body = _find_initializer(text, name)
    toks = re.findall(r'[-+]?(?:0[xX][0-9a-fA-F]+|\d+)(?:[uUlL]+)?', body)
    vals = [int(_strip_c_numeric_suffix(t), 0) for t in toks]
    return np.asarray(vals, dtype=dtype)


def _parse_float_array(text, name):
    body = _find_initializer(text, name)
    toks = re.findall(
        r'[-+]?(?:(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?)(?:[fF])?',
        body
    )
    vals = [float(_strip_c_numeric_suffix(t)) for t in toks]
    return np.asarray(vals, dtype=np.float32)


def _parse_string_array(text, name):
    body = _find_initializer(text, name)
    vals = re.findall(r'"([^"]*)"', body)
    return np.asarray(vals)


def _parse_scalar_int(text, name):
    pat = re.compile(r'\b' + re.escape(name) + r'\s*=\s*([^;]+);', re.M)
    m = pat.search(text)
    if not m:
        raise KeyError("Scalar not found: %s" % name)
    expr = _strip_c_numeric_suffix(m.group(1).strip())
    return int(expr, 0)


def build_model_npz(model_c_path, out_npz_path="v2_model.npz", verbose=True):
    """Extract only runtime model constants from the large Vitis model_data.c.

    Test images/labels are intentionally NOT copied into the NPZ because
    the Jupyter live demo uses webcam frames.
    """
    model_c_path = Path(model_c_path)
    out_npz_path = Path(out_npz_path)
    text = model_c_path.read_text(encoding="utf-8", errors="ignore")

    data = {}
    data["g_normalize_mean"] = _parse_float_array(text, "g_normalize_mean")
    data["g_normalize_std"] = _parse_float_array(text, "g_normalize_std")
    try:
        data["g_classes"] = _parse_string_array(text, "g_classes")
    except Exception:
        data["g_classes"] = DEFAULT_CLASSES

    for name, k, oc, base in WEIGHT_SPECS:
        arr = _parse_int_array(text, name, np.int8)
        expected = k * oc
        if arr.size != expected:
            raise ValueError("%s: expected %d values, found %d" %
                             (name, expected, arr.size))
        data[name] = arr

    for name, base, count in BIAS_SPECS:
        arr = _parse_int_array(text, name, np.int32)
        if arr.size != count:
            raise ValueError("%s: expected %d values, found %d" %
                             (name, count, arr.size))
        data[name] = arr

    for name, param in IWS_SPECS:
        data[name] = np.asarray(_parse_scalar_int(text, name), dtype=np.uint32)

    np.savez(out_npz_path, **data)

    if verbose:
        weight_count = sum(data[name].size for name, _, _, _ in WEIGHT_SPECS)
        print("Created:", out_npz_path)
        print("Runtime weights:", weight_count, "INT8 values")
        print("Bias params:", sum(count for _, _, count in BIAS_SPECS))
        print("Mean:", data["g_normalize_mean"])
        print("Std :", data["g_normalize_std"])
        print("Classes:", data["g_classes"].tolist())

    return out_npz_path


def extract_overlay_from_xsa(xsa_path, output_prefix="npu_v2", verbose=True):
    """Extract one .bit and one .hwh from a Vivado XSA and rename them equally.

    PYNQ expects the .bit and .hwh to share the same basename.
    """
    xsa_path = Path(xsa_path)
    prefix = Path(output_prefix)
    bit_out = prefix.with_suffix(".bit")
    hwh_out = prefix.with_suffix(".hwh")

    with zipfile.ZipFile(str(xsa_path), "r") as zf:
        names = zf.namelist()
        bits = [n for n in names if n.lower().endswith(".bit")]
        hwhs = [n for n in names if n.lower().endswith(".hwh")]

        if not bits:
            raise FileNotFoundError(
                "No .bit found inside XSA. Re-export hardware with bitstream included."
            )
        if not hwhs:
            raise FileNotFoundError(
                "No .hwh found inside XSA. Export/copy the matching HWH separately."
            )

        # Prefer wrapper/design names when multiple files exist.
        def score(name):
            s = name.lower()
            return (("wrapper" in s) * 2 + ("design_2" in s), -len(s))

        bit_name = sorted(bits, key=score, reverse=True)[0]
        hwh_name = sorted(hwhs, key=score, reverse=True)[0]

        with zf.open(bit_name) as src, open(bit_out, "wb") as dst:
            shutil.copyfileobj(src, dst)
        with zf.open(hwh_name) as src, open(hwh_out, "wb") as dst:
            shutil.copyfileobj(src, dst)

    if verbose:
        print("BIT:", bit_name, "->", bit_out)
        print("HWH:", hwh_name, "->", hwh_out)

    return bit_out, hwh_out


def preprocess_rgb_u8(rgb, mean, std):
    """RGB uint8 HxWx3 -> CHW INT8 and per-image reciprocal scale Q16."""
    if rgb.shape != (32, 32, 3):
        raise ValueError("Expected RGB image shape (32, 32, 3), got %r" %
                         (rgb.shape,))

    x = rgb.astype(np.float32) / np.float32(255.0)
    x = (x - np.asarray(mean, dtype=np.float32).reshape(1, 1, 3)) / \
        np.asarray(std, dtype=np.float32).reshape(1, 1, 3)
    chw = np.transpose(x, (2, 0, 1))

    max_abs = float(np.max(np.abs(chw)))
    scale = (max_abs / 127.0) if max_abs > 0.0 else 1.0

    # np.rint is round-to-nearest-even, matching preprocess_v2.c.
    q = np.rint(chw / np.float32(scale))
    q = np.clip(q, -128, 127).astype(np.int8)

    inv_q = int(np.rint((1.0 / scale) * MODEL_SCALE_ONE))
    if inv_q < 1:
        inv_q = 1

    return np.ascontiguousarray(q), inv_q & 0xFFFFFFFF



def preprocess_chw_u8(img_chw, mean, std):
    """Exact-shape equivalent of Vitis PreprocessV2_Image for CHW uint8."""
    img = np.asarray(img_chw, dtype=np.uint8)
    if img.shape == (3072,):
        img = img.reshape(3, 32, 32)
    if img.shape != (3, 32, 32):
        raise ValueError("Expected CHW uint8 shape (3,32,32).")

    # Keep arithmetic in float32 to track the C 'float' path closely.
    x = img.astype(np.float32) / np.float32(255.0)
    mean = np.asarray(mean, dtype=np.float32).reshape(3, 1, 1)
    std = np.asarray(std, dtype=np.float32).reshape(3, 1, 1)
    x = (x - mean) / std

    max_abs = np.max(np.abs(x)).astype(np.float32)
    if float(max_abs) > 0.0:
        scale = np.float32(max_abs / np.float32(127.0))
    else:
        scale = np.float32(1.0)

    # np.rint is round-to-nearest-even.
    q = np.rint(x / scale)
    q = np.clip(q, -128, 127).astype(np.int8)

    inv_scale = np.float32(np.float32(1.0) / scale)
    inv_q = int(np.rint(np.float32(inv_scale * np.float32(MODEL_SCALE_ONE))))
    if inv_q < 1:
        inv_q = 1
    return np.ascontiguousarray(q), inv_q & 0xFFFFFFFF


def center_crop_resize_rgb(frame_bgr, cv2):
    """Webcam BGR frame -> center-cropped 32x32 RGB uint8."""
    h, w = frame_bgr.shape[:2]
    side = min(h, w)
    y0 = (h - side) // 2
    x0 = (w - side) // 2
    crop = frame_bgr[y0:y0 + side, x0:x0 + side]
    small_bgr = cv2.resize(crop, (32, 32), interpolation=cv2.INTER_AREA)
    return cv2.cvtColor(small_bgr, cv2.COLOR_BGR2RGB)


class NpuV2(object):
    def __init__(self, overlay=None, bitfile=None, ip_name="myip_0",
                 base_addr=None, addr_range=0x1000):
        if MMIO is None:
            raise ImportError("pynq package is required on the PYNQ board.")

        self.overlay = overlay
        if self.overlay is None and bitfile is not None:
            if Overlay is None:
                raise ImportError("pynq.Overlay is unavailable.")
            self.overlay = Overlay(str(bitfile), download=True)

        resolved_name = None
        if self.overlay is not None and hasattr(self.overlay, "ip_dict"):
            ip_dict = self.overlay.ip_dict
            if ip_name in ip_dict:
                resolved_name = ip_name
            else:
                # Prefer an IP name containing "myip"; otherwise allow one
                # non-PS IP if the design is minimal.
                myips = [n for n in ip_dict if "myip" in n.lower()]
                if len(myips) == 1:
                    resolved_name = myips[0]

            if resolved_name is not None:
                meta = ip_dict[resolved_name]
                phys = meta.get("phys_addr", meta.get("base_address"))
                rng = meta.get("addr_range", addr_range)
                if isinstance(phys, str):
                    phys = int(phys, 0)
                if isinstance(rng, str):
                    rng = int(rng, 0)
                self.mmio = MMIO(int(phys), int(rng))
                self.base_addr = int(phys)
                self.ip_name = resolved_name
            elif base_addr is None:
                raise KeyError(
                    "NPU IP not auto-detected. overlay.ip_dict keys: %s. "
                    "Pass ip_name=... or base_addr=0x40000000." %
                    list(ip_dict.keys())
                )
            else:
                self.mmio = MMIO(int(base_addr), int(addr_range))
                self.base_addr = int(base_addr)
                self.ip_name = None
        else:
            if base_addr is None:
                raise ValueError("Pass an Overlay/bitfile or explicit base_addr.")
            self.mmio = MMIO(int(base_addr), int(addr_range))
            self.base_addr = int(base_addr)
            self.ip_name = None

        # Direct uint32 view saves Python method-call overhead for repeated
        # AXI-Lite accesses while preserving one physical store per assignment.
        self._regs = self.mmio.array
        self.model = None
        self.mean = None
        self.std = None
        self.classes = DEFAULT_CLASSES.copy()
        self.preloaded = False

    def _wr(self, offset, value):
        self._regs[offset >> 2] = np.uint32(int(value) & 0xFFFFFFFF)

    def _rd(self, offset):
        return int(self._regs[offset >> 2])

    def get_rcode(self):
        return self._rd(REG_RCODE)

    def write_param32(self, param_number, value):
        if param_number < 0 or param_number > PARAM_MAX:
            raise ValueError("param_number out of range: %d" % param_number)

        value = int(value) & 0xFFFFFFFF
        p = int(param_number) & 0x7FFF
        low_cmd = (p << 16) | (value & 0xFFFF)
        high_cmd = 0x80000000 | (p << 16) | ((value >> 16) & 0xFFFF)
        self._wr(REG_PARAM, low_cmd)
        self._wr(REG_PARAM, high_cmd)

    def _write_weight(self, wb_addr, col, data):
        cmd = (int(wb_addr) << 16) | (int(col) << 8) | (int(data) & 0xFF)
        self._wr(REG_LOAD_W, cmd)

    def _write_activation(self, addr, color, data):
        cmd = (int(addr) << 16) | (int(color) << 8) | (int(data) & 0xFF)
        self._wr(REG_LOAD_A, cmd)

    @staticmethod
    def _ceil_div(x, d):
        return (int(x) + int(d) - 1) // int(d)

    def _load_weight_matrix(self, w, k, oc, w_offset):
        w = np.asarray(w, dtype=np.int8).reshape(-1)
        if w.size != int(k) * int(oc):
            raise ValueError("Weight size mismatch: got %d, expected %d" %
                             (w.size, int(k) * int(oc)))

        k_tiles = self._ceil_div(k, PE_ROW)
        oc_tiles = self._ceil_div(oc, PE_COL)
        footprint = k_tiles * oc_tiles * PE_ROW
        if int(w_offset) + footprint > WB_DEPTH:
            raise ValueError("Weight-buffer footprint exceeds WB depth.")

        tile_index = 0
        for kt in range(k_tiles):
            for oct_ in range(oc_tiles):
                tile_base = int(w_offset) + tile_index * PE_ROW

                for row in range(PE_ROW):
                    kk = kt * PE_ROW + row
                    wb_addr = tile_base + row

                    for col in range(PE_COL):
                        out_col = oct_ * PE_COL + col
                        value = 0
                        if kk < k and out_col < oc:
                            value = int(w[kk * oc + out_col])
                        self._write_weight(wb_addr, col, value)

                tile_index += 1

    def load_model_npz(self, npz_path):
        self.model = np.load(str(npz_path), allow_pickle=False)
        self.mean = np.asarray(self.model["g_normalize_mean"], dtype=np.float32)
        self.std = np.asarray(self.model["g_normalize_std"], dtype=np.float32)
        if "g_classes" in self.model.files:
            self.classes = np.asarray(self.model["g_classes"])
        return self

    def preload_model(self, progress=True):
        if self.model is None:
            raise RuntimeError("Call load_model_npz() first.")

        t0 = time.perf_counter()

        # Startup INT8 weights
        for idx, (name, k, oc, base) in enumerate(WEIGHT_SPECS):
            if progress:
                print("Loading weight %-14s (%d/%d)" %
                      (name, idx + 1, len(WEIGHT_SPECS)))
            self._load_weight_matrix(self.model[name], k, oc, base)

        # Startup params 0..521: signed bias_over_ws_q16
        for name, base, count in BIAS_SPECS:
            vals = np.asarray(self.model[name], dtype=np.int32).reshape(-1)
            for i in range(count):
                self.write_param32(base + i, int(vals[i]) & 0xFFFFFFFF)

        # Startup params 522..529: reciprocal weight scales Q16
        for name, param in IWS_SPECS:
            value = int(np.asarray(self.model[name]).reshape(()))
            self.write_param32(param, value)

        self.preloaded = True
        dt = time.perf_counter() - t0
        if progress:
            print("Model preload complete: %.3f s" % dt)
        return dt

    def _wait_busy(self, want_busy, timeout_s):
        deadline = time.perf_counter() + float(timeout_s)
        while time.perf_counter() < deadline:
            rcode = self.get_rcode()
            busy = bool(rcode & RCODE_BUSY)
            if busy == bool(want_busy):
                return rcode
        raise TimeoutError("Timeout waiting BUSY=%d, RCODE=0x%08X" %
                           (1 if want_busy else 0, self.get_rcode()))

    def _send_channel(self, x, color):
        x = np.asarray(x, dtype=np.int8).reshape(-1)
        if x.size != 1024:
            raise ValueError("Channel must contain exactly 1024 values.")
        for addr in range(1024):
            self._write_activation(addr, color, int(x[addr]))

    @staticmethod
    def _decode_logit26(rcode):
        raw = int(rcode) & RCODE_LOGIT_MASK
        if raw & RCODE_LOGIT_SIGN:
            raw |= 0xFC000000
        # Convert uint32 bit pattern to signed int32 without deprecated casts.
        if raw & 0x80000000:
            raw -= 1 << 32
        return int(raw)

    @staticmethod
    def _consume_logit(rcode, scores, seen):
        cls = (int(rcode) & RCODE_CLASS_MASK) >> RCODE_CLASS_SHIFT
        if cls >= 10:
            raise RuntimeError("Protocol error: class=%d" % cls)
        bit = 1 << cls
        if seen & bit:
            raise RuntimeError("Protocol error: duplicate class=%d" % cls)
        scores[cls] = NpuV2._decode_logit26(rcode)
        return seen | bit

    def run_image(self, q_chw, inv_input_scale_q16, timeout_s=1.0, channel_guard_s=0.001):
        if not self.preloaded:
            raise RuntimeError("Call preload_model() before run_image().")

        q = np.asarray(q_chw, dtype=np.int8)
        if q.shape == (3, 32, 32):
            q = q.reshape(3, 1024)
        elif q.shape == (3072,):
            q = q.reshape(3, 1024)
        elif q.shape != (3, 1024):
            raise ValueError("Expected q shape (3,32,32), (3,1024), or (3072,).")

        # Previous image must have returned to non-BUSY.
        self._wait_busy(False, timeout_s)

        # Image-dependent param 530.
        self.write_param32(PARAM_INV_INPUT_SCALE, inv_input_scale_q16)

        # R -> G -> B.
        #
        # On the bare-metal Vitis host, BUSY=1 can be polled fast enough.
        # In Python/Jupyter, that BUSY-high interval can be shorter than one
        # Python MMIO polling round-trip, so requiring observation of BUSY=1
        # causes false timeouts.
        #
        # After each complete R/G channel write, give the PL enough time to
        # consume the channel, then only require that it has returned READY
        # (BUSY=0) before sending the next channel.
        self._send_channel(q[0], 0)
        if channel_guard_s:
            time.sleep(float(channel_guard_s))
        self._wait_busy(False, timeout_s)

        self._send_channel(q[1], 1)
        if channel_guard_s:
            time.sleep(float(channel_guard_s))
        self._wait_busy(False, timeout_s)

        # After B, the network runs through the remaining layers.
        # Do not require Python to observe the BUSY rising edge; wait for DONE.
        self._send_channel(q[2], 2)

        # Preserve the FIRST read that sees DONE: it already contains logit #1.
        deadline = time.perf_counter() + float(timeout_s)
        first = None
        while time.perf_counter() < deadline:
            rcode = self.get_rcode()
            if rcode & RCODE_DONE:
                first = rcode
                break
        if first is None:
            raise TimeoutError("Timeout waiting DONE, RCODE=0x%08X" %
                               self.get_rcode())

        scores = np.zeros(10, dtype=np.int32)
        seen = 0
        seen = self._consume_logit(first, scores, seen)

        for _ in range(1, 10):
            rcode = self.get_rcode()
            if not (rcode & RCODE_DONE):
                raise RuntimeError(
                    "Protocol error: DONE deasserted while reading logits."
                )
            seen = self._consume_logit(rcode, scores, seen)

        if seen != 0x03FF:
            raise RuntimeError("Protocol error: seen mask=0x%04X" % seen)

        return scores

    def infer_rgb32(self, rgb32, timeout_s=1.0):
        if self.mean is None or self.std is None:
            raise RuntimeError("Model mean/std unavailable. load_model_npz() first.")
        q, inv_q = preprocess_rgb_u8(rgb32, self.mean, self.std)
        t0 = time.perf_counter()
        scores = self.run_image(q, inv_q, timeout_s=timeout_s)
        dt = time.perf_counter() - t0
        pred = int(np.argmax(scores))
        return pred, scores, q, inv_q, dt

    def infer_chw_u8(self, img_chw, timeout_s=1.0, channel_guard_s=0.001):
        if self.mean is None or self.std is None:
            raise RuntimeError("Model mean/std unavailable. load_model_npz() first.")
        q, inv_q = preprocess_chw_u8(img_chw, self.mean, self.std)
        t0 = time.perf_counter()
        scores = self.run_image(q, inv_q, timeout_s=timeout_s,
                                channel_guard_s=channel_guard_s)
        dt = time.perf_counter() - t0
        pred = int(np.argmax(scores))
        return pred, scores, q, inv_q, dt

    def validate_embedded_testset(self, count=20, start=0, timeout_s=1.0,
                                  channel_guard_s=0.001, progress=True):
        if self.model is None:
            raise RuntimeError("Call load_model_npz() first.")
        if "g_test_images_chw" not in self.model.files or \
           "g_test_labels" not in self.model.files:
            raise RuntimeError("NPZ does not contain embedded test images/labels.")

        imgs = self.model["g_test_images_chw"]
        labels = self.model["g_test_labels"]
        start = int(start)
        count = int(count)
        end = min(start + count, len(labels))

        rows = []
        correct = 0
        t0 = time.perf_counter()
        for idx in range(start, end):
            pred, scores, q, inv_q, dt = self.infer_chw_u8(
                imgs[idx], timeout_s=timeout_s,
                channel_guard_s=channel_guard_s
            )
            label = int(labels[idx])
            correct += int(pred == label)
            rows.append((idx, label, pred, float(dt*1000.0),
                         int(scores[pred]), int(inv_q)))
            if progress:
                print("%4d label=%-10s pred=%-10s %s  %.2f ms" %
                      (idx, str(self.classes[label]), str(self.classes[pred]),
                       "OK" if pred == label else "MISS", dt*1000.0))

        elapsed = time.perf_counter() - t0
        return {
            "start": start,
            "count": end-start,
            "correct": correct,
            "accuracy": correct / max(1, end-start),
            "elapsed_s": elapsed,
            "avg_ms": elapsed * 1000.0 / max(1, end-start),
            "rows": rows,
        }

    def benchmark(self, q_chw, inv_q, runs=50, warmup=3, timeout_s=1.0):
        for _ in range(int(warmup)):
            self.run_image(q_chw, inv_q, timeout_s=timeout_s)

        ts = []
        for _ in range(int(runs)):
            t0 = time.perf_counter()
            self.run_image(q_chw, inv_q, timeout_s=timeout_s)
            ts.append(time.perf_counter() - t0)

        arr = np.asarray(ts, dtype=np.float64) * 1000.0
        return {
            "runs": int(runs),
            "mean_ms": float(arr.mean()),
            "median_ms": float(np.median(arr)),
            "min_ms": float(arr.min()),
            "max_ms": float(arr.max()),
            "fps_from_mean": float(1000.0 / arr.mean()),
        }


class LatestFrameCamera(object):
    """Continuously capture frames so USB camera acquisition overlaps inference."""
    def __init__(self, index=0, width=640, height=480, fps=30):
        import cv2
        self.cv2 = cv2
        self.cap = cv2.VideoCapture(int(index), cv2.CAP_V4L2)
        if not self.cap.isOpened():
            raise RuntimeError("Could not open /dev/video%d" % int(index))

        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, int(width))
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, int(height))
        self.cap.set(cv2.CAP_PROP_FPS, float(fps))

        self._lock = threading.Lock()
        self._frame = None
        self._seq = -1
        self._running = True
        self._thread = threading.Thread(target=self._loop)
        self._thread.daemon = True
        self._thread.start()

    def _loop(self):
        while self._running:
            ok, frame = self.cap.read()
            if ok:
                with self._lock:
                    self._frame = frame
                    self._seq += 1

    def read_latest(self, after_seq=None, timeout_s=1.0):
        deadline = time.perf_counter() + float(timeout_s)
        while time.perf_counter() < deadline:
            with self._lock:
                if self._frame is not None:
                    if after_seq is None or self._seq != after_seq:
                        return self._frame.copy(), self._seq
            time.sleep(0.001)
        raise TimeoutError("No new camera frame within %.2f s" % timeout_s)

    def info(self):
        cv2 = self.cv2
        return {
            "width": self.cap.get(cv2.CAP_PROP_FRAME_WIDTH),
            "height": self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT),
            "fps": self.cap.get(cv2.CAP_PROP_FPS),
            "fourcc": int(self.cap.get(cv2.CAP_PROP_FOURCC)),
        }

    def close(self):
        self._running = False
        if self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self.cap.release()
