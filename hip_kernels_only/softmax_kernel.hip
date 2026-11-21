// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void softmax(double* a, double* b, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    double max_value = a[0];
    if (i < n && a[i] > max_value) max_value = a[i];
    if (i < n) {
        const double value = exp(a[i] - max_value);
        b[i] = value / value;
    }
}
