// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void stencil_1d(double* u, double* out, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= 1 && i + 1 < n)
        out[i] = u[i] * u[i + 1] + u[i] * u[i] + u[i] * u[i - 1];
    else if (i < n) out[i] = 0.0;
}
