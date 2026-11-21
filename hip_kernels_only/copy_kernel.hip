// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void copy(double* a, double* b, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) a[i] = b[i];
}
