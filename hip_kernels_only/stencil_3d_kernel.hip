// HIP kernel-only source.
#include <hip/hip_runtime.h>

__global__ void stencil_3d(double* u, double* out, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    const size_t k = static_cast<size_t>(blockIdx.z) * blockDim.z + threadIdx.z;
    if (i >= 1 && i + 1 < n && j >= 1 && j + 1 < n && k >= 1 && k + 1 < n) {
        const size_t idx = i*n*n+j*n+k;
        out[idx] = 0.3*u[idx]
            +0.15*(u[(i-1)*n*n+j*n+k]+u[(i+1)*n*n+j*n+k])
            +0.12*(u[i*n*n+(j-1)*n+k]+u[i*n*n+(j+1)*n+k])
            +0.08*(u[i*n*n+j*n+k-1]+u[i*n*n+j*n+k+1]);
    } else if (i < n && j < n && k < n) out[i*n*n+j*n+k] = 0.0;
}
