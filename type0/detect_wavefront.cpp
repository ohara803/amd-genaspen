#include <hip/hip_runtime.h>

#include <cstdlib>
#include <iostream>

int main() {
    int device = 0;
    if (hipGetDevice(&device) != hipSuccess) {
        return EXIT_FAILURE;
    }
    hipDeviceProp_t properties{};
    if (hipGetDeviceProperties(&properties, device) != hipSuccess) {
        return EXIT_FAILURE;
    }
    std::cout << "gpu_name=" << properties.name << '\n';
    std::cout << "gcn_arch_name=" << properties.gcnArchName << '\n';
    std::cout << "wavefront_size=" << properties.warpSize << '\n';
    return EXIT_SUCCESS;
}
