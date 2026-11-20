#include <amd_smi/amdsmi.h>
#include <hip/hip_runtime.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#define HIP_CHECK(call)                                                        \
    do {                                                                       \
        const hipError_t error = (call);                                       \
        if (error != hipSuccess) {                                             \
            std::cerr << "HIP error at " << __FILE__ << ':' << __LINE__       \
                      << ": " << hipGetErrorString(error) << '\n';             \
            std::exit(EXIT_FAILURE);                                           \
        }                                                                      \
    } while (false)

__global__ void initialize_vectors(double* x, double* y, std::size_t n) {
    const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        x[i] = 1.0;
        y[i] = 2.0;
    }
}

__global__ void axpy(const double* x, double* y, std::size_t n, double alpha) {
    const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        y[i] = alpha * x[i] + y[i];
    }
}

class AmdSmiSession {
  public:
    AmdSmiSession() {
        const amdsmi_status_t status = amdsmi_init(AMDSMI_INIT_AMD_GPUS);
        if (status != AMDSMI_STATUS_SUCCESS) {
            throw std::runtime_error("amdsmi_init failed with status " +
                                     std::to_string(status));
        }
        initialized_ = true;
    }

    ~AmdSmiSession() {
        if (initialized_) {
            amdsmi_shut_down();
        }
    }

    AmdSmiSession(const AmdSmiSession&) = delete;
    AmdSmiSession& operator=(const AmdSmiSession&) = delete;

  private:
    bool initialized_ = false;
};

amdsmi_processor_handle find_power_device() {
    uint32_t socket_count = 0;
    if (amdsmi_get_socket_handles(&socket_count, nullptr) !=
            AMDSMI_STATUS_SUCCESS ||
        socket_count == 0) {
        throw std::runtime_error("AMD SMI found no GPU sockets");
    }

    std::vector<amdsmi_socket_handle> sockets(socket_count);
    if (amdsmi_get_socket_handles(&socket_count, sockets.data()) !=
        AMDSMI_STATUS_SUCCESS) {
        throw std::runtime_error("amdsmi_get_socket_handles failed");
    }

    for (const auto socket : sockets) {
        uint32_t processor_count = 0;
        if (amdsmi_get_processor_handles(socket, &processor_count, nullptr) !=
                AMDSMI_STATUS_SUCCESS ||
            processor_count == 0) {
            continue;
        }

        std::vector<amdsmi_processor_handle> processors(processor_count);
        if (amdsmi_get_processor_handles(socket, &processor_count,
                                         processors.data()) !=
            AMDSMI_STATUS_SUCCESS) {
            continue;
        }

        for (const auto processor : processors) {
            amdsmi_power_info_t info{};
            if (amdsmi_get_power_info(processor, &info) ==
                AMDSMI_STATUS_SUCCESS) {
                return processor;
            }
        }
    }

    throw std::runtime_error("no AMD SMI device exposes power telemetry");
}

double read_power_w(amdsmi_processor_handle processor) {
    amdsmi_power_info_t info{};
    const amdsmi_status_t status = amdsmi_get_power_info(processor, &info);
    if (status != AMDSMI_STATUS_SUCCESS) {
        throw std::runtime_error("amdsmi_get_power_info failed with status " +
                                 std::to_string(status));
    }

    if (info.current_socket_power != std::numeric_limits<uint32_t>::max()) {
        return static_cast<double>(info.current_socket_power);
    }
    if (info.socket_power != std::numeric_limits<uint64_t>::max() &&
        info.socket_power != std::numeric_limits<uint32_t>::max()) {
        return static_cast<double>(info.socket_power);
    }
    throw std::runtime_error("AMD SMI returned no supported power metric");
}

long long parse_positive(const char* text, const char* name) {
    char* end = nullptr;
    const long long value = std::strtoll(text, &end, 10);
    if (end == text || *end != '\0' || value <= 0) {
        throw std::invalid_argument(std::string(name) + " must be positive");
    }
    return value;
}

int main(int argc, char** argv) {
    try {
        if (argc > 3) {
            std::cerr << "Usage: " << argv[0] << " [N] [iterations]\n";
            return EXIT_FAILURE;
        }

        const long long n_input = argc >= 2 ? parse_positive(argv[1], "N")
                                             : 67'108'864;
        const long long iterations_input =
            argc >= 3 ? parse_positive(argv[2], "iterations") : 1000;
        const std::size_t n = static_cast<std::size_t>(n_input);
        const int iterations = static_cast<int>(iterations_input);
        if (iterations_input > std::numeric_limits<int>::max() ||
            n > std::numeric_limits<std::size_t>::max() / sizeof(double)) {
            throw std::invalid_argument("input is too large");
        }

        int device = 0;
        HIP_CHECK(hipGetDevice(&device));
        hipDeviceProp_t properties{};
        HIP_CHECK(hipGetDeviceProperties(&properties, device));
        std::cout << "GPU: " << properties.name << '\n';

        double* x = nullptr;
        double* y = nullptr;
        const std::size_t bytes = n * sizeof(double);
        HIP_CHECK(hipMalloc(&x, bytes));
        HIP_CHECK(hipMalloc(&y, bytes));

        constexpr unsigned int threads = 256;
        const unsigned int blocks =
            static_cast<unsigned int>((n + threads - 1) / threads);
        hipLaunchKernelGGL(initialize_vectors, dim3(blocks), dim3(threads), 0,
                           0, x, y, n);
        HIP_CHECK(hipGetLastError());
        hipLaunchKernelGGL(axpy, dim3(blocks), dim3(threads), 0, 0, x, y, n,
                           2.5);
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipDeviceSynchronize());

        AmdSmiSession smi;
        const amdsmi_processor_handle power_device = find_power_device();
        std::ofstream power_csv("power.csv");
        if (!power_csv) {
            throw std::runtime_error("cannot create power.csv");
        }
        power_csv << "elapsed_ms,power_w\n";

        hipEvent_t start{};
        hipEvent_t stop{};
        HIP_CHECK(hipEventCreate(&start));
        HIP_CHECK(hipEventCreate(&stop));
        HIP_CHECK(hipEventRecord(start));
        const auto wall_start = std::chrono::steady_clock::now();

        for (int i = 0; i < iterations; ++i) {
            hipLaunchKernelGGL(axpy, dim3(blocks), dim3(threads), 0, 0, x, y,
                               n, 2.5);
        }
        HIP_CHECK(hipGetLastError());
        HIP_CHECK(hipEventRecord(stop));

        std::size_t power_samples = 0;
        double power_sum_w = 0.0;
        while (true) {
            const hipError_t query = hipEventQuery(stop);
            if (query == hipSuccess) {
                break;
            }
            if (query != hipErrorNotReady) {
                HIP_CHECK(query);
            }

            const double power_w = read_power_w(power_device);
            const auto now = std::chrono::steady_clock::now();
            const double elapsed_ms =
                std::chrono::duration<double, std::milli>(now - wall_start)
                    .count();
            power_csv << elapsed_ms << ',' << power_w << '\n';
            power_sum_w += power_w;
            ++power_samples;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        HIP_CHECK(hipEventSynchronize(stop));
        power_csv.flush();
        if (power_samples == 0 || !power_csv) {
            throw std::runtime_error("no power samples were recorded");
        }

        float kernel_ms = 0.0F;
        HIP_CHECK(hipEventElapsedTime(&kernel_ms, start, stop));

        double first = 0.0;
        double last = 0.0;
        HIP_CHECK(hipMemcpy(&first, y, sizeof(double), hipMemcpyDeviceToHost));
        HIP_CHECK(hipMemcpy(&last, y + n - 1, sizeof(double),
                            hipMemcpyDeviceToHost));
        const double expected = 2.0 + 2.5 * (iterations + 1);
        if (std::abs(first - expected) > 1e-9 ||
            std::abs(last - expected) > 1e-9) {
            throw std::runtime_error("AXPY result validation failed");
        }

        const double seconds = kernel_ms / 1000.0;
        const double bytes_moved =
            static_cast<double>(n) * 3.0 * sizeof(double) * iterations;
        const double flops = static_cast<double>(n) * 2.0 * iterations;
        std::cout << "N=" << n << " iterations=" << iterations << '\n'
                  << "kernel_time_s=" << seconds << '\n'
                  << "average_kernel_ms=" << kernel_ms / iterations << '\n'
                  << "bandwidth_GB_s=" << bytes_moved / seconds / 1.0e9
                  << '\n'
                  << "performance_GFLOP_s=" << flops / seconds / 1.0e9
                  << '\n'
                  << "power_samples=" << power_samples << '\n'
                  << "average_power_W=" << power_sum_w / power_samples << '\n'
                  << "validation=PASS\n";

        HIP_CHECK(hipEventDestroy(start));
        HIP_CHECK(hipEventDestroy(stop));
        HIP_CHECK(hipFree(x));
        HIP_CHECK(hipFree(y));
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
