// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void laplace(double* u, double* out, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    if (i >= 1 && i + 1 < n && j >= 1 && j + 1 < n) {
        const size_t idx = i*n+j;
        out[idx] = 0.3*u[idx]+0.2*u[(i-1)*n+j]+0.15*u[(i+1)*n+j]
            +0.2*u[i*n+j-1]+0.15*u[i*n+j+1];
    } else if (i < n && j < n) out[i*n+j] = 0.0;
}
