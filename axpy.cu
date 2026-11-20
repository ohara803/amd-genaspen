#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <math.h>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#ifdef LIKWID_NVMON
  #include <likwid-marker.h>
#else
  #define NVMON_MARKER_INIT
  #define NVMON_MARKER_REGISTER(tag)
  #define NVMON_MARKER_THREADINIT
  #define NVMON_MARKER_START(tag)
  #define NVMON_MARKER_STOP(tag)
  #define NVMON_MARKER_CLOSE
#endif


#define CHECK_CUDA_ERROR(val) check((val), #val, __FILE__, __LINE__)
template <typename T>
void check(T err, const char* const func, const char* const file, const int line) {
    if (err != cudaSuccess) {
        fprintf(stderr, "CUDA Runtime Error at: %s:%d\\n", file, line);
        fprintf(stderr, "%s %s\\n", cudaGetErrorString(err), func);
        exit(EXIT_FAILURE);
    }
}

#define CHECK_NULL(ptr, name) \\
    if ((ptr) == NULL) { \\
        fprintf(stderr, "Memory allocation failed for %s\\n", name); \\
        exit(EXIT_FAILURE); \\
    }

__global__ void axpy(double* x, double* y, size_t n) {
  size_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) {
    y[i] = 2.5 * x[i] + y[i];
  }
}


// int main(){
//     long long N = 1073741824;
//     int num_arrays = 2;
//     int iterations = 10;

int main(int argc, char** argv){
    long long N = 1000000000;  // default
    int iterations = 1000;     // default

    if (argc >= 2) {
        N = atoll(argv[1]);
    }

    if (argc >= 3) {
        iterations = atoi(argv[2]);
    }

    if (argc > 3) {
        fprintf(stderr, "Usage: %s [N] [iterations]\n", argv[0]);
        return EXIT_FAILURE;
    }
    
    if (N <= 0) {
        fprintf(stderr, "Error: Invalid array size N = %lld\\n", N);
        return EXIT_FAILURE;
    }
    
    size_t free_mem, total_mem;
    CHECK_CUDA_ERROR(cudaMemGetInfo(&free_mem, &total_mem));

    NVMON_MARKER_INIT;
    NVMON_MARKER_REGISTER("AXPY");
    
    size_t size = N * sizeof(double);
    
    cudaEvent_t start, stop;
    CHECK_CUDA_ERROR(cudaEventCreate(&start));
    CHECK_CUDA_ERROR(cudaEventCreate(&stop));
    
    // Host memory
    double *h_a = (double *)malloc(size);
double *h_b = (double *)malloc(size);

    
    for(long long i = 0; i < N; i++){
  h_a[i] = (double)i;
  h_b[i] = 0.5;
}

    
    // Device memory
    double *d_a, *d_b;
cudaMalloc(&d_a, size);
cudaMalloc(&d_b, size);

    
    // Copy to device
    cudaMemcpy(d_a, h_a, size, cudaMemcpyHostToDevice);
cudaMemcpy(d_b, h_b, size, cudaMemcpyHostToDevice);

    
    // Grid calculation
    long long threadsPerBlock = 256;
long long blocksPerGrid = (N + threadsPerBlock - 1) / threadsPerBlock;

int blocksPerGrid_int = (int)blocksPerGrid;
int threadsPerBlock_int = (int)threadsPerBlock;

    
    float total_ms = 0.0;

    /* warmup */
    axpy<<<blocksPerGrid_int, threadsPerBlock_int>>>(d_a, d_b, N);
    CHECK_CUDA_ERROR(cudaGetLastError());
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    NVMON_MARKER_THREADINIT;
    NVMON_MARKER_START("AXPY");
    
    for(int iter = 0; iter < iterations; iter++){
    
    // Execute kernel
    CHECK_CUDA_ERROR(cudaEventRecord(start));
    axpy<<<blocksPerGrid_int, threadsPerBlock_int>>>(d_a, d_b, N);
    CHECK_CUDA_ERROR(cudaGetLastError());
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    CHECK_CUDA_ERROR(cudaEventRecord(stop));
    CHECK_CUDA_ERROR(cudaEventSynchronize(stop));
    
    float milliseconds = 0.0;
    CHECK_CUDA_ERROR(cudaEventElapsedTime(&milliseconds, start, stop));

    if(iter > 0){
        total_ms += milliseconds;
    }
    
    }

    NVMON_MARKER_STOP("AXPY");
    NVMON_MARKER_CLOSE;
    
    // Copy back (commented out for performance measurement)
    cudaMemcpy(h_a, d_a, size, cudaMemcpyDeviceToHost);
cudaMemcpy(h_b, d_b, size, cudaMemcpyDeviceToHost);

    
    // printf("%f\\n", total_ms / iterations);
    printf("problem size, # of iterations, kernel time\n");
    printf("%lld,%d,%f\n", N, iterations, total_ms / 1000);

    double total_flops = (double)N * iterations;
    double elapsed_sec = total_ms / 1000.0;
    double avg_ms = total_ms / iterations;

    double gflops = total_flops / elapsed_sec / 1e9;
    double tflops = total_flops / elapsed_sec / 1e12;

    printf("problem size, iterations, total time [s], avg kernel time [ms], GFLOP/s, TFLOP/s\n");
    printf("%lld,%d,%f,%f,%f,%f\n",
        N, iterations, elapsed_sec, avg_ms, gflops, tflops);
    
    // Cleanup
    CHECK_CUDA_ERROR(cudaEventDestroy(start));
    CHECK_CUDA_ERROR(cudaEventDestroy(stop));
    
    cudaFree(d_a); cudaFree(d_b);
free(h_a); free(h_b); 

    return 0;
}