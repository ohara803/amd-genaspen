// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void gemm(double* a, double* b, double* c, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    if (i < n && j < n) {
        double sum = 0.0;
        for (size_t k = 0; k < n; ++k) sum += a[i * n + k] * b[k * n + j];
        c[i * n + j] = sum;
    }
}
