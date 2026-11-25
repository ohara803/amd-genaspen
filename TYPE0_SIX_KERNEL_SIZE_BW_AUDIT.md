# MI300A Type0 six-kernel size/bandwidth audit

## Runtime calibration

Job `51389.pbs` fitted one Type0 runtime coefficient using the model

```text
runtime_ms = (loads_bytes + stores_bytes) / bw_B_per_s * 1000
```

The fit used weighted least squares through the origin with
`sample_weight = 1 / runtime_ms^2`.  Only the 48 training rows
(six kernels times eight sizes) were used.  The 42 target rows were held out
until final evaluation.  The fitted value was:

```text
bw = 4028.8748926229428 GB/s
runtime train MAPE = 17.69695194293325%
runtime target MAPE = 17.194398019223684%
```

The calibration procedure was applied correctly, but the single-bandwidth
model is not adequate for all six kernels.  In particular, the cached softmax
traffic model counts a common `a[0]` load for every element, while gelu includes
transcendental compute that is not represented by `bytes / bw`.

## Measured problem sizes

Training sizes:

```text
16,777,216
33,554,432
67,108,864
134,217,728
268,435,456
536,870,912
1,073,741,824
2,147,483,648
```

Held-out target sizes:

```text
23,726,566
47,453,133
94,906,266
189,812,531
379,625,062
759,250,125
1,518,500,250
```

## Logical effective bandwidth

The following values are `(ASPEN logical load bytes + store bytes) / measured
runtime`.  They are model-equivalent effective bandwidths, not direct HBM
counter measurements.

| phase | n | softmax GB/s | gelu GB/s | relu GB/s |
|---|---:|---:|---:|---:|
| train | 16,777,216 | 5058.076 | 2075.409 | 3540.244 |
| train | 33,554,432 | 5133.820 | 2076.011 | 3757.495 |
| train | 67,108,864 | 5334.338 | 2088.192 | 3937.981 |
| train | 134,217,728 | 5404.967 | 2113.380 | 4028.785 |
| train | 268,435,456 | 5441.425 | 2117.786 | 4083.721 |
| train | 536,870,912 | 5444.197 | 2117.517 | 4097.823 |
| train | 1,073,741,824 | 5464.305 | 2119.333 | 4119.163 |
| train | 2,147,483,648 | 5464.483 | 2121.989 | 4117.874 |
| target | 23,726,566 | 5085.944 | 2068.001 | 3671.458 |
| target | 47,453,133 | 5248.974 | 2090.855 | 3846.681 |
| target | 94,906,266 | 5375.184 | 2110.183 | 3984.111 |
| target | 189,812,531 | 5424.539 | 2119.082 | 4059.157 |
| target | 379,625,062 | 5445.142 | 2117.764 | 4086.444 |
| target | 759,250,125 | 5454.790 | 2117.238 | 4112.496 |
| target | 1,518,500,250 | 5449.090 | 2121.679 | 4114.524 |

Stability summary over all 15 measured sizes:

| kernel | min GB/s | max GB/s | CV | max/min span | interpretation |
|---|---:|---:|---:|---:|---|
| softmax | 5058.076 | 5464.483 | 2.620% | 8.035% | small-size ramp; stable from 67M (CV 0.717%) |
| gelu | 2068.001 | 2121.989 | 0.890% | 2.611% | stable across the full range |
| relu | 3540.244 | 4119.163 | 4.482% | 16.353% | not stable at small sizes; stable from 134M (CV 0.707%) |

Softmax values above the physical HBM range reflect logical traffic
over-counting of the common `a[0]` load; they must not be interpreted as
measured HBM bandwidth.

## Softmax source alignment

The softmax source measured by `51389.pbs` did not exactly match the requested
reference kernel.  After the job, both sources were aligned to the same HIP
kernel:

- `hip_kernels/softmax.hip` (complete measurement program)
- `hip_kernels_only/softmax_kernel.hip` (kernel-only source)

The aligned kernel now uses `max_val`, loads `a[i]` once into `ai`, performs the
conditional maximum update, calls `expf`, divides `sum` by itself, and stores
the result.  Consequently, the `51389.pbs` softmax measurements describe the
pre-correction kernel and must not be presented as measurements of the aligned
source.  A new GPU measurement is required before recalibrating with the
corrected softmax implementation.
