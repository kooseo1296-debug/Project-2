# Tiling and Buffer Mapping

This document describes how matrix operations are mapped onto the
9 × 16 weight-stationary systolic array and how activation and weight
data are organized in the on-chip buffers.

The same mapping is used as the basic execution mechanism for
convolution layers after the convolution is transformed into a matrix
multiplication.

---

## 1. Matrix Multiplication Model

The accelerator computes matrix multiplication in the following form:

```text
A [S × K] × W [K × OC] = C [S × OC]
```

where:

- `S` is the number of activation vectors to process.
- `K` is the reduction dimension.
- `OC` is the number of output channels.
- `A` is the activation matrix.
- `W` is the weight matrix.
- `C` is the output matrix.

For a convolution layer, the dimensions can be interpreted as:

```text
S  = number of output spatial positions
K  = Cin × Kh × Kw
OC = number of output channels
```

The physical systolic array contains:

```text
9 × 16 Processing Elements
```

Therefore, the hardware parallelism is:

```text
K_TILE  = 9
OC_TILE = 16
```

A single systolic-array configuration operates on up to 9 elements
along the reduction dimension and 16 output channels in parallel.

Larger matrix operations are decomposed into multiple tiles.

---

# 2. Activation Buffer Mapping

![Activation Buffer Mapping](images/activation_buffer_mapping.png)

The Activation Buffer is organized as **9 independent banks**.

The 9 banks correspond to the 9 elements of the `K` dimension that
can be supplied to the systolic array in parallel.

Consider an activation matrix:

```text
            K dimension
        ──────────────────►

        A11 A12 A13 A14 ...
        A21 A22 A23 A24 ...
A =     A31 A32 A33 A34 ...
         :   :   :   :
```

The activation matrix is mapped across the banks as:

```text
Bank 0 : A11  A21  A31  ...
Bank 1 : A12  A22  A32  ...
Bank 2 : A13  A23  A33  ...
  :
Bank 8 : A19  A29  A39  ...
```

Equivalently:

```text
Activation Buffer

            Address →
         0     1     2    ...

Bank 0  A11   A21   A31   ...
Bank 1  A12   A22   A32   ...
Bank 2  A13   A23   A33   ...
  :
Bank 8  A19   A29   A39   ...
```

Thus, reading the same address from all 9 banks produces one
9-element activation vector:

```text
Address 0:

[A11, A12, A13, ... , A19]
```

and the next address produces:

```text
Address 1:

[A21, A22, A23, ... , A29]
```

This organization matches the 9-element input width of the systolic
array and avoids serially reading the individual elements required for
one activation vector.

In other words, the buffer layout is determined by the physical
parallelism of the systolic array rather than by simply storing the
matrix in a conventional linear row-major representation.

---

# 3. Weight Buffer Mapping

![Weight Buffer Mapping](images/weight_buffer_mapping.png)

The Weight Buffer is organized as **16 banks**.

Each bank corresponds to one column of the 9 × 16 systolic array and
therefore to one output channel within the current `OC` tile.

For a weight matrix:

```text
             OC dimension
        ───────────────────►

        W11 W12 W13 ...
W =     W21 W22 W23 ...
         :   :   :
```

the buffer mapping is:

```text
Bank 0        Bank 1        Bank 2
  W11           W12           W13
  W21           W22           W23
   :             :             :
  W91           W92           W93
```

Therefore:

```text
Weight Buffer

           Bank →
        0      1      2          ... 15

Addr 0  W11    W12    W13        ... W1,16
Addr 1  W21    W22    W23        ... W2,16
Addr 2  W31    W32    W33        ... W3,16
  :
Addr 8  W91    W92    W93        ... W9,16
```

A complete physical weight tile therefore contains:

```text
9 × 16 = 144 weights
```

which corresponds exactly to the 144 processing elements in the
systolic array.

The two buffers therefore use different banking directions:

| Buffer | Number of Banks | Parallel Dimension |
|---|---:|---|
| Activation Buffer | 9 | K |
| Weight Buffer | 16 | OC |

This organization directly reflects the 9 × 16 geometry of the
systolic array.

---

# 4. Weight-Stationary Execution

![Tile Execution](images/tile_execution.png)

The systolic array uses a **weight-stationary dataflow**.

For a given weight tile, weights are loaded into the processing
elements and remain stationary while activation vectors are supplied
to the array.

Conceptually, a 9-element activation vector:

```text
[A(s,k+0), A(s,k+1), ... , A(s,k+8)]
```

is multiplied against a 9 × 16 weight tile:

```text
                    16 output channels
                ─────────────────────────►

K element 0      W00  W01  ...  W0,15
K element 1      W10  W11  ...  W1,15
   :
K element 8      W80  W81  ...  W8,15
```

to generate partial results for up to 16 output channels.

The same stationary weights can then be reused for subsequent
activation addresses.

Therefore, once a 9 × 16 weight tile has been loaded, activation
vectors are streamed from the Activation Buffer while the weights
remain inside the systolic array.

---

# 5. Tiling Dimensions

A matrix operation may exceed the physical dimensions of the
systolic array.

The complete computation is therefore tiled along two major
dimensions:

```text
K  → tiles of at most 9
OC → tiles of at most 16
```

The number of tiles is:

```text
K_tiles  = ceil(K / 9)
OC_tiles = ceil(OC / 16)
```

For example:

```text
K = 27
OC = 32
```

requires:

```text
K_tiles  = 3
OC_tiles = 2
```

for a total of:

```text
3 × 2 = 6
```

K/OC tile combinations.

---

# 6. OC-Dimension Tiling

If the number of output channels is greater than 16, the weight matrix
is divided into groups of at most 16 output channels.

For example:

```text
OC = 32

OC Tile 0 → channels  0 ~ 15
OC Tile 1 → channels 16 ~ 31
```

Each OC tile is mapped onto the 16 columns of the systolic array.

Conceptually:

```text
                Weight Matrix

          OC Tile 0       OC Tile 1
        ┌─────────────┬─────────────┐
        │   16 ch     │    16 ch    │
        │             │             │
        │             │             │
        └─────────────┴─────────────┘
```

The activation data associated with the same `K` region can be reused
when processing different OC tiles.

Only the weight tile and output destination change.

---

# 7. K-Dimension Tiling

When `K > 9`, the reduction dimension cannot be processed by the
physical array in a single execution.

The matrices are therefore divided as:

```text
A = [ A0 | A1 | A2 | ... ]

      K=9  K=9  K=9
```

and:

```text
        ┌ W0 ┐
        │ W1 │
W   =   │ W2 │
        │ .. │
        └────┘
```

The matrix multiplication becomes:

```text
C = A0W0 + A1W1 + A2W2 + ...
```

Each K tile therefore generates only a **partial sum** unless it is
the only K tile.

For example:

```text
K Tile 0

A0 × W0
   │
   ▼
PSUM0
```

followed by:

```text
K Tile 1

A1 × W1
   │
   ▼
new partial result
   +
PSUM0
   │
   ▼
PSUM1
```

and finally:

```text
Last K Tile

A_last × W_last
       +
previous PSUM
       │
       ▼
final output
```

Therefore, the Product Buffer must preserve the partial result between
K-tile executions.

---

# 8. First, Accumulate, and Last Tile

K-dimension tiling can be represented using three execution cases.

### First K Tile

The first tile initializes the output accumulation.

```text
PSUM = A0 × W0
```

No previous Product Buffer value is required.

### Intermediate K Tile

An intermediate tile reads the previous partial sum and accumulates the
new matrix multiplication result.

```text
PSUM_new = PSUM_old + Ai × Wi
```

### Last K Tile

The final K tile performs the final accumulation:

```text
OUTPUT = PSUM_old + A_last × W_last
```

After the final K tile, the output is complete and can proceed to the
required post-processing operation.

Conceptually, the controller therefore distinguishes:

```text
FIRST
ACCUMULATE
LAST
```

rather than treating every systolic-array execution as an independent
matrix multiplication.

---

# 9. Activation Buffer Capacity

The Activation Buffer depth is intentionally kept at:

```text
ACTIVATION_BUFFER_DEPTH = 1024
```

instead of increasing the depth to 3072 simply to hold an entire
32 × 32 RGB image simultaneously.

A 32 × 32 channel contains:

```text
32 × 32 = 1024 activations
```

Therefore, one complete image channel fits in the current Activation
Buffer.

For the first RGB input, the three channels can be processed
sequentially using the same general tiled-execution mechanism:

```text
R channel
    ↓
execute
    ↓
partial result

G channel
    ↓
execute + accumulate
    ↓
partial result

B channel
    ↓
execute + accumulate
    ↓
final result
```

This requires additional execution control compared with storing all
three channels in a 3072-depth buffer, but avoids increasing the
Activation Buffer solely for the first RGB layer.

---

# 10. Why the Activation Buffer Remains 1024 Deep

An alternative design would use:

```text
Activation Buffer Depth = 3072
```

allowing:

```text
[R: 1024][G: 1024][B: 1024]
```

to reside in the buffer simultaneously.

This simplifies the initial RGB input handling, but has several
disadvantages:

1. It increases on-chip memory consumption.
2. The additional capacity is primarily useful for the first RGB
   layer.
3. Later layers do not require a 3072-element spatial buffer per
   channel.
4. A tiling mechanism is required anyway for general matrix
   operations that exceed the physical accelerator dimensions.
5. The larger buffer therefore does not remove the need for general
   tiling logic.

For these reasons, the V2 architecture keeps the Activation Buffer
depth at 1024 and handles larger logical inputs through repeated tile
execution.

The same mechanism can therefore be reused for both:

```text
RGB channel decomposition
```

and more general:

```text
K-dimension tiling
```

instead of implementing a special large buffer specifically for the
first convolution layer.

---

# 11. Partial-Sum Feedback

K tiling requires the result generated by one execution to be reused
by the next execution.

The conceptual datapath is:

```text
                    ┌───────────────────┐
                    │                   │
                    │                   ▼
Activation ──► Systolic Array ──► Product Buffer
                    ▲                   │
                    │                   │
                    └──── PSUM feedback ┘
```

For the first K tile:

```text
feedback disabled
```

For subsequent K tiles:

```text
feedback enabled
```

and the previous Product Buffer value is accumulated with the newly
generated result.

The final result is therefore written only after all required K tiles
have contributed to the output.

---

# 12. Overall Tile Execution

At a high level, a matrix multiplication can be represented as:

```text
for each OC tile:

    for each K tile:

        load weight tile

        configure:
            first / accumulate / last

        for each required activation address:

            read 9 activation banks

            execute systolic array

            write or accumulate product
```

The exact controller scheduling may overlap loading and execution, but
the logical mapping remains:

```text
K tile
   │
   ├── Activation: 9 K-elements in parallel
   │
   └── Weight: 9 × 16 tile
                 │
                 ▼
          9 × 16 Systolic Array
                 │
                 ▼
             partial sum
                 │
          ┌──────┴──────┐
          │             │
      more K?          no
          │             │
          ▼             ▼
      feedback      final output
```

---

# 13. Handling Non-Multiple Dimensions

`K` and `OC` are not required to be exact multiples of 9 and 16.

For the final tile:

```text
valid_K  = min(9,  K  - K_base)
valid_OC = min(16, OC - OC_base)
```

Only valid matrix elements contribute to the computation.

Unused positions in the physical tile must either:

- be filled with zero, or
- be disabled through valid control,

so that they do not affect the final result.

This allows the same physical 9 × 16 array to support arbitrary matrix
dimensions.

---

# 14. Relationship to Convolution

The systolic array itself performs matrix multiplication and does not
need to directly understand convolution geometry.

For a convolution layer, the controller/input-loading logic transforms
the required convolution window into the `K` dimension expected by the
matrix multiplication engine.

Conceptually:

```text
Input Feature Map
       │
       │ window extraction / im2col
       ▼
Activation Matrix A[S × K]
       │
       │ tiled GEMM
       ▼
9 × 16 Systolic Array
       │
       ▼
Output Matrix C[S × OC]
       │
       │ reshape
       ▼
Output Feature Map
```

For a 3 × 3 convolution:

```text
K = Cin × 3 × 3
```

so increasing the number of input channels naturally increases the
number of K tiles.

The systolic array itself remains unchanged.

---

# 15. Design Rationale

The tiling architecture is designed around three principles.

### 1. Match the Physical Array

The buffer organization directly exposes:

```text
9 activation values
×
16 output-channel weights
```

to the 9 × 16 systolic array.

### 2. Reuse Data

Weight-stationary execution keeps the current weight tile inside the
array while multiple activation vectors are processed.

Activation data can also be reused across different OC tiles.

### 3. Keep On-Chip Storage Small

Instead of increasing buffer capacity for specific layers, larger
logical operations are decomposed into tiles.

This keeps the hardware architecture independent of a particular
layer size and allows the same execution mechanism to be reused across
the network.

---

# 16. Current V2 Configuration

| Parameter | Value |
|---|---:|
| Systolic Array | 9 × 16 |
| Processing Elements | 144 |
| Dataflow | Weight-stationary |
| K Tile Size | 9 |
| OC Tile Size | 16 |
| Activation Buffer Banks | 9 |
| Activation Buffer Depth | 1024 |
| Weight Buffer Banks | 16 |
| K-Tile Accumulation | Product Buffer feedback |
| Large-input handling | Tiled execution |

The main design goal is therefore not to make the on-chip buffers
large enough to contain every possible layer at once.

Instead, the accelerator provides a fixed 9 × 16 compute structure
and fixed-size local buffers, while the controller decomposes larger
operations into a sequence of reusable tile executions.
