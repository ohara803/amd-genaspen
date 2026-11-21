// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void gelu(double* a, double* b, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        const double x = a[i];
        const double arg = 0.7978845608 * (x + 0.044715 * x * x * x);
        b[i] = 0.5 * x * (1.0 + tanh(arg));
    }
}
