// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void trmv(double* a, double* x, double* y, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        double sum = 0.0;
        for (size_t j = i; j < n; ++j) sum += a[i * n + j] * x[j];
        y[i] = sum;
    }
}
