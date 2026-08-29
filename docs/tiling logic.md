# Matrix Tiling and Memory Layout Example

This document explains how matrix tiling, buffer mapping, tiled matrix multiplication, and partial-product accumulation are performed for a **9 × 16 systolic array**.

The following matrix multiplication is used as an example:

<img width="2570" height="888" alt="image" src="https://github.com/user-attachments/assets/5be0319a-7b9c-488b-8f06-7371cd2a9e60" />

```
A : 40 × 20
W : 20 × 37
P : 40 × 37
```

where:

- `A` is the activation matrix.
- `W` is the weight matrix.
- `P` is the final product matrix.
- The systolic array contains **9 rows × 16 columns**.

---

## 1. Activation Matrix

The original activation matrix has size:

\[
A \in \mathbb{Z}^{40 \times 20}
\]

![Original activation matrix](./images/activation_matrix_original.png)

The systolic array can process **9 values along the K dimension at once**. Therefore, the 20 activation columns are divided into groups of 9.

The activation matrix is divided into:

- Tile `1`: `40 × 9`
- Tile `2`: `40 × 9`
- Tile `3`: `40 × 2`

Since the third tile contains only two valid columns, the remaining seven columns are zero-padded. Therefore, the tiled activation matrix has an effective size of:

\[
40 \times 27
\]

![Tiled activation matrix](./images/activation_matrix_tiled.png)

The three activation tiles correspond to:

```text
Tile 1 : original columns  0 ~  8
Tile 2 : original columns  9 ~ 17
Tile 3 : original columns 18 ~ 19 + 7 zero-padded columns
```

The zero-padding allows every activation tile to have a fixed width of 9, matching the number of rows in the systolic array.

---

## 2. Activation Buffer Mapping

The Activation Buffer is organized into **9 banks**, corresponding to the 9 rows of the systolic array.

![Activation buffer mapping](./images/activation_buffer_mapping.png)

Each activation tile contains 40 rows. Therefore, each tile occupies 40 addresses across the 9 banks.

The address mapping is:

```text
Address   0 ~  39 : Activation Tile 1
Address  40 ~  79 : Activation Tile 2
Address  80 ~ 119 : Activation Tile 3
```

At a given address, all 9 banks are read in parallel.

```text
AB[address]

Bank 0 : A[s][k+0]
Bank 1 : A[s][k+1]
Bank 2 : A[s][k+2]
...
Bank 8 : A[s][k+8]
```

Thus, one Activation Buffer read provides one complete 9-element activation vector to the systolic array. For Activation Tile 3, the banks corresponding to the padded K positions contain zero.

---

## 3. Weight Matrix

The original weight matrix has size:

\[
W \in \mathbb{Z}^{20 \times 37}
\]

![Original weight matrix](./images/weight_matrix_original.png)

The systolic array processes 9 values along the K dimension and 16 output columns at once. Therefore, the weight matrix is divided into **9 × 16 tiles**.

![Tiled weight matrix](./images/weight_matrix_tiled.png)

The resulting weight tiles are:

| Tile | Valid K rows | Valid output columns | Valid size |
|---|---:|---:|---:|
| `W11` | 9 | 16 | `9 × 16` |
| `W12` | 9 | 16 | `9 × 16` |
| `W13` | 9 | 5 | `9 × 5` |
| `W21` | 9 | 16 | `9 × 16` |
| `W22` | 9 | 16 | `9 × 16` |
| `W23` | 9 | 5 | `9 × 5` |
| `W31` | 2 | 16 | `2 × 16` |
| `W32` | 2 | 16 | `2 × 16` |
| `W33` | 2 | 5 | `2 × 5` |

### 3.1 Partial output-column tile

Tiles `W13`, `W23`, and `W33` contain only five valid output columns.

The physical systolic array still contains 16 columns, but only the valid columns are enabled. For example, for a tile with five valid columns:

```text
Valid_P = 0000_0000_0001_1111
```

Only systolic-array columns `[4:0]` are treated as valid. The remaining columns are ignored.

### 3.2 Partial K tile

Tiles `W31`, `W32`, and `W33` contain only two valid K rows.

No special arithmetic handling is required because the corresponding activation tile has already been zero-padded from width 2 to width 9. For the padded K positions:

\[
A_{\text{padding}} = 0
\]

and therefore:

\[
A_{\text{padding}} \times W = 0
\]

regardless of the undefined or unused weight values in those rows.

Thus, the same 9-row systolic-array datapath can process the final K tile without modifying the MAC structure.

---

## 4. Weight Buffer Mapping

The Weight Buffer is organized into **16 banks**, corresponding to the 16 columns of the systolic array.

![Weight buffer mapping](./images/weight_buffer_mapping.png)

A full `9 × 16` weight tile occupies:

```text
9 addresses × 16 banks
```

The tiles are mapped in the following order:

```text
W11
W21
W31

W12
W22
W32

W13
W23
W33
```

This matches the mapping shown in the Weight Buffer figure.

For the final output-column group (`W13`, `W23`, `W33`), only the first five banks contain valid output-column weights.

For the final K group (`W31`, `W32`, `W33`), only the first two K rows are valid. The remaining K positions are harmless because the corresponding activation values are zero.

---

## 5. Tiled Matrix Multiplication Order

The full matrix multiplication is decomposed into nine tiled matrix multiplications.

The execution order is:

```text
#1 : Activation Tile 1 × W11
#2 : Activation Tile 1 × W12
#3 : Activation Tile 1 × W13

#4 : Activation Tile 2 × W21
#5 : Activation Tile 2 × W22
#6 : Activation Tile 2 × W23

#7 : Activation Tile 3 × W31
#8 : Activation Tile 3 × W32
#9 : Activation Tile 3 × W33
```

### Steps #1 ~ #3

![Tiled matrix multiplication #1 to #3](./images/matmul_steps_1_3.png)

Activation Tile 1 is reused while the weight tile moves across the three output-column groups:

```text
#1 : A1 × W11
#2 : A1 × W12
#3 : A1 × W13
```

For `#3`, only five systolic-array columns are valid. The bold blue outline in the figure represents the full physical size of the systolic array.

### Steps #4 ~ #6

![Tiled matrix multiplication #4 to #6](./images/matmul_steps_4_6.png)

Activation Tile 2 is then processed:

```text
#4 : A2 × W21
#5 : A2 × W22
#6 : A2 × W23
```

These products contribute to the same final output-column groups as `#1`, `#2`, and `#3`, respectively.

### Steps #7 ~ #9

![Tiled matrix multiplication #7 to #9](./images/matmul_steps_7_9.png)

Finally, the zero-padded Activation Tile 3 is processed:

```text
#7 : A3 × W31
#8 : A3 × W32
#9 : A3 × W33
```

The valid region of the weight tile can now be smaller in both dimensions. For example, `W31` has only 2 valid K rows, while `W33` has only 2 valid K rows and 5 valid output columns.

The bold blue rectangle still represents the full physical `9 × 16` systolic array.

The two boundary mechanisms guarantee correct operation:

1. invalid K positions contribute zero because the activation values are zero-padded;
2. invalid output columns are disabled by the valid mask.

---

## 6. Partial Product Accumulation

Each output-column tile is produced by accumulating the partial products generated by the three K tiles.

### 6.1 Product Tile 1

The first output tile is obtained from:

\[
P_1 = \#1 + \#4 + \#7
\]

![Product Tile 1 accumulation](./images/product_tile_1_accumulation.png)

Therefore:

\[
P_1 = A_1W_{11} + A_2W_{21} + A_3W_{31}
\]

and:

\[
P_1 \in \mathbb{Z}^{40 \times 16}
\]

### 6.2 Product Tile 2

The second output tile is obtained from:

\[
P_2 = \#2 + \#5 + \#8
\]

![Product Tile 2 accumulation](./images/product_tile_2_accumulation.png)

Therefore:

\[
P_2 = A_1W_{12} + A_2W_{22} + A_3W_{32}
\]

and:

\[
P_2 \in \mathbb{Z}^{40 \times 16}
\]

### 6.3 Product Tile 3

The final output tile is obtained from:

\[
P_3 = \#3 + \#6 + \#9
\]

![Product Tile 3 accumulation](./images/product_tile_3_accumulation.png)

Only five output columns are valid in this tile.

Therefore:

\[
P_3 = A_1W_{13} + A_2W_{23} + A_3W_{33}
\]

and:

\[
P_3 \in \mathbb{Z}^{40 \times 5}
\]

---

## 7. Final Product Matrix

The three accumulated product tiles are concatenated along the output-column dimension:

\[
P = [P_1 \; P_2 \; P_3]
\]

![Final product matrix construction](./images/product_matrix_final.png)

The three product tiles have widths:

```text
P1 : 16 columns
P2 : 16 columns
P3 :  5 columns
```

Therefore:

\[
16 + 16 + 5 = 37
\]

and the final product matrix has the expected shape:

\[
P \in \mathbb{Z}^{40 \times 37}
\]

which matches:

\[
A_{40 \times 20} W_{20 \times 37} = P_{40 \times 37}
\]

---

## 8. Product Buffer Mapping

The Product Buffer is organized into **16 banks**, matching the number of systolic-array output columns.

![Product Buffer mapping](./images/product_buffer_mapping.png)

Each final product tile contains 40 rows, so each tile occupies 40 addresses.

The address mapping is:

```text
Address   0 ~  39 : Product Tile 1
Address  40 ~  79 : Product Tile 2
Address  80 ~ 119 : Product Tile 3
```

At a given address:

- Product Tile 1 uses all 16 banks.
- Product Tile 2 uses all 16 banks.
- Product Tile 3 uses only the first 5 banks.

Thus, the Product Buffer layout directly matches the tiled output-column structure of the systolic array.

---

## 9. Complete Example

For:

\[
A_{40 \times 20} \times W_{20 \times 37}
\]

the tiling parameters are:

```text
Systolic-array rows    = 9
Systolic-array columns = 16

K tiles  = ceil(20 / 9)  = 3
OC tiles = ceil(37 / 16) = 3

Total tiled multiplications = 3 × 3 = 9
```

The activation tiles are:

```text
A1 : 40 × 9
A2 : 40 × 9
A3 : 40 × 2 -> zero-padded to 40 × 9
```

The weight tiles are:

```text
W11 : 9 × 16
W12 : 9 × 16
W13 : 9 × 5

W21 : 9 × 16
W22 : 9 × 16
W23 : 9 × 5

W31 : 2 × 16
W32 : 2 × 16
W33 : 2 × 5
```

The multiplication sequence is:

```text
#1  A1 × W11
#2  A1 × W12
#3  A1 × W13

#4  A2 × W21
#5  A2 × W22
#6  A2 × W23

#7  A3 × W31
#8  A3 × W32
#9  A3 × W33
```

The final product tiles are:

```text
P1 = #1 + #4 + #7
P2 = #2 + #5 + #8
P3 = #3 + #6 + #9
```

and:

```text
P = [P1 P2 P3]
```

resulting in:

\[
P \in \mathbb{Z}^{40 \times 37}
\]

---

## 10. Key Design Principles

The tiling scheme is based on four principles.

### 1. Fixed K width

The activation matrix is padded along the K dimension so that every activation tile has width 9. This allows every tile to use all 9 systolic-array rows without adding a special datapath for the final K tile.

### 2. Valid-mask handling for output columns

The final output-column tile does not need to be padded to 16 valid outputs. Instead, invalid systolic-array columns are disabled using the valid signal.

### 3. Partial-sum accumulation across K tiles

Multiple K tiles contribute to the same final output tile. For example:

\[
P_1 = \#1 + \#4 + \#7
\]

The Product Buffer therefore stores partial sums and provides them again when processing the next K tile.

### 4. Fixed physical systolic-array structure

Even when a logical tile is smaller than `9 × 16`, the physical systolic array remains unchanged.

Boundary conditions are handled through:

- activation zero-padding for the K dimension;
- valid masking for the output-column dimension.

Therefore, arbitrary matrix dimensions can be processed using the same fixed **9 × 16 systolic-array datapath**.
