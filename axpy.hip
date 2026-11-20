// HIP AXPY + 50 ms AMD SMI socket power and GPU temperature logger.
// Usage: ./axpy [N] [iterations]
// CSV: time_ms,power_W,gpu_temp_C
// Target: MI300A, ROCm 7.2.0

#include <hip/hip_runtime.h>
#include <amd_smi/amdsmi.h>

#include <atomic>
#include <chrono>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <string>
#include <thread>
#include <vector>

#define CHECK_HIP(call) do {                                                   \
    hipError_t err_ = (call);                                                 \
    if (err_ != hipSuccess) {                                                 \
        std::fprintf(stderr, "HIP error: %s: %s (%s:%d)\n", #call,            \
                     hipGetErrorString(err_), __FILE__, __LINE__);           \
        std::exit(EXIT_FAILURE);                                             \
    }                                                                         \
} while (0)

static void check_smi(amdsmi_status_t st, const char* expr) {
    if (st != AMDSMI_STATUS_SUCCESS) {
        const char* message = nullptr;
        amdsmi_status_code_to_string(st, &message);
        std::fprintf(stderr, "AMD SMI error: %s: %s (status=%d)\n", expr,
                     message ? message : "unknown", static_cast<int>(st));
        std::exit(EXIT_FAILURE);
    }
}
#define CHECK_SMI(call) check_smi((call), #call)

__global__ void axpy(const double* x, double* y, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) y[i] = 2.5 * x[i] + y[i];
}

using Clock = std::chrono::steady_clock;
constexpr auto kPollInterval = std::chrono::milliseconds(50);

struct Sample {
    double time_ms;
    double power_w;
    double temp_c;
};

// On MI300A, amdsmi_get_temp_metric(EDGE) can return NOT_SUPPORTED.
// Try the GPU metrics table first, then the direct temperature API.
enum class TempSource { METRICS_HOTSPOT, METRICS_EDGE,
                        SENSOR_HOTSPOT, SENSOR_EDGE, NONE };

static bool valid_temperature(double celsius) {
    return celsius > 0.0 && celsius < 150.0;
}

static double sensor_celsius(int64_t value) {
    // AMD SMI API versions can expose Celsius or milli-Celsius.
    double c = static_cast<double>(value);
    if (c > 1000.0) c /= 1000.0;
    return valid_temperature(c) ? c : std::numeric_limits<double>::quiet_NaN();
}

static TempSource find_temperature_source(amdsmi_processor_handle gpu) {
    amdsmi_gpu_metrics_t metrics{};
    if (amdsmi_get_gpu_metrics_info(gpu, &metrics) == AMDSMI_STATUS_SUCCESS) {
        if (valid_temperature(static_cast<double>(metrics.temperature_hotspot)))
            return TempSource::METRICS_HOTSPOT;
        if (valid_temperature(static_cast<double>(metrics.temperature_edge)))
            return TempSource::METRICS_EDGE;
    }
    int64_t raw = 0;
    if (amdsmi_get_temp_metric(gpu, AMDSMI_TEMPERATURE_TYPE_HOTSPOT,
                               AMDSMI_TEMP_CURRENT, &raw) == AMDSMI_STATUS_SUCCESS &&
        valid_temperature(sensor_celsius(raw)))
        return TempSource::SENSOR_HOTSPOT;
    if (amdsmi_get_temp_metric(gpu, AMDSMI_TEMPERATURE_TYPE_EDGE,
                               AMDSMI_TEMP_CURRENT, &raw) == AMDSMI_STATUS_SUCCESS &&
        valid_temperature(sensor_celsius(raw)))
        return TempSource::SENSOR_EDGE;
    return TempSource::NONE;
}

static const char* temperature_source_name(TempSource source) {
    switch (source) {
        case TempSource::METRICS_HOTSPOT: return "GPU metrics: hotspot";
        case TempSource::METRICS_EDGE: return "GPU metrics: edge";
        case TempSource::SENSOR_HOTSPOT: return "temperature API: hotspot";
        case TempSource::SENSOR_EDGE: return "temperature API: edge";
        default: return "unavailable (nan)";
    }
}

static double read_temperature(amdsmi_processor_handle gpu, TempSource source) {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    if (source == TempSource::METRICS_HOTSPOT || source == TempSource::METRICS_EDGE) {
        amdsmi_gpu_metrics_t metrics{};
        if (amdsmi_get_gpu_metrics_info(gpu, &metrics) != AMDSMI_STATUS_SUCCESS)
            return nan;
        const double c = static_cast<double>(
            source == TempSource::METRICS_HOTSPOT
                ? metrics.temperature_hotspot : metrics.temperature_edge);
        return valid_temperature(c) ? c : nan;
    }
    if (source == TempSource::SENSOR_HOTSPOT || source == TempSource::SENSOR_EDGE) {
        int64_t raw = 0;
        auto kind = source == TempSource::SENSOR_HOTSPOT
            ? AMDSMI_TEMPERATURE_TYPE_HOTSPOT : AMDSMI_TEMPERATURE_TYPE_EDGE;
        if (amdsmi_get_temp_metric(gpu, kind, AMDSMI_TEMP_CURRENT, &raw)
            != AMDSMI_STATUS_SUCCESS) return nan;
        return sensor_celsius(raw);
    }
    return nan;
}

static unsigned long long parse_positive_ull(const char* text, const char* name) {
    if (!text || !*text || text[0] == '-') {
        std::fprintf(stderr, "Invalid %s: %s\n", name, text ? text : "(null)");
        std::exit(EXIT_FAILURE);
    }
    errno = 0;
    char* end = nullptr;
    unsigned long long value = std::strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0) {
        std::fprintf(stderr, "Invalid %s: %s\n", name, text);
        std::exit(EXIT_FAILURE);
    }
    return value;
}

// Do not assume that HIP GPU 0 == AMD SMI GPU 0; match by PCI BDF.
static amdsmi_processor_handle find_smi_gpu(int hip_gpu) {
    char pci[64] = {};
    CHECK_HIP(hipDeviceGetPCIBusId(pci, sizeof(pci), hip_gpu));

    unsigned long long domain = 0;
    unsigned bus = 0, device = 0, function = 0;
    if (std::sscanf(pci, "%llx:%x:%x.%x", &domain, &bus, &device, &function) != 4) {
        std::fprintf(stderr, "Cannot parse HIP PCI BDF: %s\n", pci);
        std::exit(EXIT_FAILURE);
    }

    amdsmi_bdf_t bdf{};
    bdf.bdf.domain_number = domain;
    bdf.bdf.bus_number = bus;
    bdf.bdf.device_number = device;
    bdf.bdf.function_number = function;

    amdsmi_processor_handle handle = nullptr;
    CHECK_SMI(amdsmi_get_processor_handle_from_bdf(bdf, &handle));
    std::fprintf(stderr, "Measurement target: HIP GPU %d / PCI %s\n", hip_gpu, pci);
    return handle;
}

int main(int argc, char** argv) {
    if (argc > 3) {
        std::fprintf(stderr, "Usage: %s [N] [iterations]\n", argv[0]);
        return EXIT_FAILURE;
    }
    const unsigned long long n_arg = (argc >= 2)
        ? parse_positive_ull(argv[1], "N") : 1000000000ULL;
    const unsigned long long it_arg = (argc >= 3)
        ? parse_positive_ull(argv[2], "iterations") : 1000ULL;
    if (n_arg > std::numeric_limits<size_t>::max() / sizeof(double) ||
        it_arg > INT_MAX) {
        std::fprintf(stderr, "N or iterations exceeds supported range\n");
        return EXIT_FAILURE;
    }
    const size_t N = static_cast<size_t>(n_arg);
    const int iterations = static_cast<int>(it_arg);
    const size_t bytes = N * sizeof(double);

    constexpr unsigned int threads_per_block = 256;
    const size_t blocks = N / threads_per_block + (N % threads_per_block != 0);
    if (blocks > std::numeric_limits<unsigned int>::max()) {
        std::fprintf(stderr, "Grid size exceeds limit\n");
        return EXIT_FAILURE;
    }

    CHECK_HIP(hipSetDevice(0));
    size_t free_bytes = 0, total_bytes = 0;
    CHECK_HIP(hipMemGetInfo(&free_bytes, &total_bytes));
    // Both arrays must fit; compare this way to avoid overflow from 2 * bytes.
    if (bytes > free_bytes / 2) {
        std::fprintf(stderr, "Not enough free GPU memory for two arrays: need %.2f GiB\n",
                     2.0 * static_cast<double>(bytes) / (1024.0 * 1024.0 * 1024.0));
        return EXIT_FAILURE;
    }

    CHECK_SMI(amdsmi_init(AMDSMI_INIT_AMD_GPUS));
    const amdsmi_processor_handle gpu = find_smi_gpu(0);

    amdsmi_power_info_t initial_power{};
    CHECK_SMI(amdsmi_get_power_info(gpu, &initial_power));
    if (initial_power.current_socket_power == UINT32_MAX) {
        std::fprintf(stderr, "current_socket_power not supported\n");
        return EXIT_FAILURE;
    }
    const TempSource temp_source = find_temperature_source(gpu);
    std::fprintf(stderr, "Temperature source: %s\n",
                 temperature_source_name(temp_source));
    if (temp_source == TempSource::NONE) {
        std::fprintf(stderr, "Warning: GPU temperature unavailable; CSV will contain nan but socket power measurement will continue.\n");
    }

    // Host-side initialization and copies are outside the measurement interval.
    std::vector<double> h_a(N), h_b(N, 0.5);
    for (size_t i = 0; i < N; ++i) h_a[i] = static_cast<double>(i);

    double* d_a = nullptr;
    double* d_b = nullptr;
    CHECK_HIP(hipMalloc(&d_a, bytes));
    CHECK_HIP(hipMalloc(&d_b, bytes));
    CHECK_HIP(hipMemcpy(d_a, h_a.data(), bytes, hipMemcpyHostToDevice));
    CHECK_HIP(hipMemcpy(d_b, h_b.data(), bytes, hipMemcpyHostToDevice));

    const dim3 grid(static_cast<unsigned int>(blocks));
    const dim3 block(threads_per_block);

    // One warmup run, excluded from timing and telemetry (same as CUDA).
    hipLaunchKernelGGL(axpy, grid, block, 0, 0, d_a, d_b, N);
    CHECK_HIP(hipGetLastError());
    CHECK_HIP(hipDeviceSynchronize());

    hipEvent_t start{}, stop{};
    CHECK_HIP(hipEventCreate(&start));
    CHECK_HIP(hipEventCreate(&stop));

    std::vector<Sample> samples;
    samples.reserve(4096);
    std::atomic<bool> ready{false};
    std::atomic<bool> sampling{false};
    std::atomic<bool> stop_sampling{false};
    Clock::time_point measure_begin{};

    std::thread sampler([&]() {
        ready.store(true, std::memory_order_release);
        while (!sampling.load(std::memory_order_acquire)) std::this_thread::yield();
        // The release/acquire handshake makes measure_begin visible here.
        auto next = measure_begin;

        while (!stop_sampling.load(std::memory_order_acquire)) {
            const auto t0 = Clock::now();
            amdsmi_power_info_t p{};
            const auto ps = amdsmi_get_power_info(gpu, &p);
            const double temp_c = read_temperature(gpu, temp_source);
            const auto t1 = Clock::now();
            const auto timestamp = t0 + (t1 - t0) / 2;

            const double nan = std::numeric_limits<double>::quiet_NaN();
            const double power_w = (ps == AMDSMI_STATUS_SUCCESS &&
                                    p.current_socket_power != UINT32_MAX)
                ? static_cast<double>(p.current_socket_power) : nan;
            samples.push_back({
                std::chrono::duration<double, std::milli>(timestamp - measure_begin).count(),
                power_w, temp_c
            });

            next += kPollInterval;
            const auto now = Clock::now();
            while (next <= now) next += kPollInterval; // Skip missed slots.
            std::this_thread::sleep_until(next);
        }
    });

    while (!ready.load(std::memory_order_acquire)) std::this_thread::yield();
    float total_ms = 0.0f;
    measure_begin = Clock::now();
    sampling.store(true, std::memory_order_release);

    // Same per-iteration event/synchronize pattern as the CUDA version.
    // All iterations count because the warmup is already excluded.
    for (int i = 0; i < iterations; ++i) {
        CHECK_HIP(hipEventRecord(start));
        hipLaunchKernelGGL(axpy, grid, block, 0, 0, d_a, d_b, N);
        CHECK_HIP(hipGetLastError());
        CHECK_HIP(hipDeviceSynchronize());
        CHECK_HIP(hipEventRecord(stop));
        CHECK_HIP(hipEventSynchronize(stop));
        float ms = 0.0f;
        CHECK_HIP(hipEventElapsedTime(&ms, start, stop));
        total_ms += ms;
    }
    const auto measure_end = Clock::now();
    stop_sampling.store(true, std::memory_order_release);
    sampler.join();

    // Write CSV after measurement to keep disk I/O outside the timing interval.
    std::ofstream out("power.csv");
    if (!out) {
        std::fprintf(stderr, "Cannot open power.csv for writing\n");
        return EXIT_FAILURE;
    }
    out << "time_ms,power_W,gpu_temp_C\n";
    out << std::fixed << std::setprecision(3);
    size_t sample_count = 0;
    const double end_ms =
        std::chrono::duration<double, std::milli>(measure_end - measure_begin).count();
    for (const Sample& s : samples) {
        if (s.time_ms < 0 || s.time_ms > end_ms) continue;
        out << s.time_ms << ',' << s.power_w << ',' << s.temp_c << '\n';
        ++sample_count;
    }
    out.close();
    if (!out) {
        std::fprintf(stderr, "Failed to write power.csv\n");
        return EXIT_FAILURE;
    }

    // Match CUDA: copy both arrays back, outside the measurement interval.
    CHECK_HIP(hipMemcpy(h_a.data(), d_a, bytes, hipMemcpyDeviceToHost));
    CHECK_HIP(hipMemcpy(h_b.data(), d_b, bytes, hipMemcpyDeviceToHost));

    // AXPY: one multiply + one add per element = 2 FLOPs.
    const double elapsed_sec = total_ms / 1000.0;
    const double avg_ms = total_ms / static_cast<double>(iterations);
    const double gflops = elapsed_sec > 0
        ? 2.0 * static_cast<double>(N) * iterations / elapsed_sec / 1.0e9 : 0.0;
    std::printf("problem size,iterations,total kernel time [s],avg kernel time [ms],GFLOP/s,TFLOP/s\n");
    std::printf("%zu,%d,%.6f,%.6f,%.6f,%.6f\n",
                N, iterations, elapsed_sec, avg_ms, gflops, gflops / 1000.0);
    std::fprintf(stderr, "Saved %zu power/temperature samples to power.csv\n", sample_count);
    if (sample_count < 2) {
        std::fprintf(stderr, "Warning: measurement too short for reliable 50 ms polling; increase iterations.\n");
    }

    CHECK_HIP(hipEventDestroy(start));
    CHECK_HIP(hipEventDestroy(stop));
    CHECK_HIP(hipFree(d_a));
    CHECK_HIP(hipFree(d_b));
    CHECK_SMI(amdsmi_shut_down());
    return EXIT_SUCCESS;
}
