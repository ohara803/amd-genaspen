// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void softmax(double* a, double* b, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    double max_val = a[0];
    if (i < n) {
        double ai = a[i];
        if (ai > max_val) {
            max_val = ai;
        }
        double sum = expf(ai - max_val);
        sum /= sum;
        b[i] = sum;
    }
}
