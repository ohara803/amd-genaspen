// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void trmm(double* a, double* b, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    if (i < n && j < n) {
        double sum = 0.0;
        for (size_t l = 0; l < n; ++l) sum += a[i * n + l] * b[l * n + j];
        b[i * n + j] = sum;
    }
}
