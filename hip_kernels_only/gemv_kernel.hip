// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void gemv(double* a, double* b, double* c, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        double sum = 0.0;
        for (size_t j = 0; j < n; ++j) sum += a[i * n + j] * b[j];
        c[i] = sum;
    }
}
