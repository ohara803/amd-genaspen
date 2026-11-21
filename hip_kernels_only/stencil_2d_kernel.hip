// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void stencil_2d(double* u, double* out, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    if (i >= 1 && i + 1 < n && j >= 1 && j + 1 < n)
        out[i*n+j] = 0.25*(u[(i-1)*n+j]+u[(i+1)*n+j])
            +0.25*(u[(i-1)*n+j-1]+u[(i-1)*n+j+1])
            +0.25*(u[(i+1)*n+j-1]+u[(i+1)*n+j+1])
            +0.25*(u[i*n+j-1]+u[i*n+j+1])-u[i*n+j];
}
