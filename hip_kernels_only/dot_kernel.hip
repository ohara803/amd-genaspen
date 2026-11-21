// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void dot(double* a, double* b, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) b[i] = a[i] * b[i];
}
