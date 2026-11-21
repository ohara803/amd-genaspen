// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void axpy(double* x, double* y, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) y[i] = 2.5 * x[i] + y[i];
}
