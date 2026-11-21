#ifndef HIP_BENCHMARK_COMMON_HPP
#define HIP_BENCHMARK_COMMON_HPP

#include <hip/hip_runtime.h>
#include <amd_smi/amdsmi.h>

#include <atomic>
#include <chrono>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <limits>
#include <new>
#include <string>
#include <thread>
#include <vector>

#define CHECK_HIP(call) do {                                                   \
    hipError_t err_ = (call);                                                  \
    if (err_ != hipSuccess) {                                                  \
        std::fprintf(stderr, "HIP error: %s: %s (%s:%d)\n", #call,           \
                     hipGetErrorString(err_), __FILE__, __LINE__);             \
        std::exit(EXIT_FAILURE);                                               \
    }                                                                          \
} while (0)

static inline void check_smi(amdsmi_status_t st, const char* expr) {
    if (st != AMDSMI_STATUS_SUCCESS) {
        const char* message = nullptr;
        amdsmi_status_code_to_string(st, &message);
        std::fprintf(stderr, "AMD SMI error: %s: %s (status=%d)\n", expr,
                     message ? message : "unknown", static_cast<int>(st));
        std::exit(EXIT_FAILURE);
    }
}
#define CHECK_SMI(call) check_smi((call), #call)

using BenchmarkClock = std::chrono::steady_clock;
constexpr auto kPollInterval = std::chrono::milliseconds(50);

struct TelemetrySample {
    double time_ms;
    double power_w;
    double temp_c;
};

enum class TempSource {
    METRICS_HOTSPOT, METRICS_EDGE, SENSOR_HOTSPOT, SENSOR_EDGE, NONE
};

static inline bool valid_temperature(double celsius) {
    return celsius > 0.0 && celsius < 150.0;
}

static inline double sensor_celsius(int64_t value) {
    double c = static_cast<double>(value);
    if (c > 1000.0) c /= 1000.0;
    return valid_temperature(c) ? c : std::numeric_limits<double>::quiet_NaN();
}

static inline TempSource find_temperature_source(amdsmi_processor_handle gpu) {
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

static inline const char* temperature_source_name(TempSource source) {
    switch (source) {
        case TempSource::METRICS_HOTSPOT: return "GPU metrics: hotspot";
        case TempSource::METRICS_EDGE: return "GPU metrics: edge";
        case TempSource::SENSOR_HOTSPOT: return "temperature API: hotspot";
        case TempSource::SENSOR_EDGE: return "temperature API: edge";
        default: return "unavailable (nan)";
    }
}

static inline double read_temperature(amdsmi_processor_handle gpu,
                                      TempSource source) {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    if (source == TempSource::METRICS_HOTSPOT ||
        source == TempSource::METRICS_EDGE) {
        amdsmi_gpu_metrics_t metrics{};
        if (amdsmi_get_gpu_metrics_info(gpu, &metrics) != AMDSMI_STATUS_SUCCESS)
            return nan;
        const double c = static_cast<double>(
            source == TempSource::METRICS_HOTSPOT
                ? metrics.temperature_hotspot : metrics.temperature_edge);
        return valid_temperature(c) ? c : nan;
    }
    if (source == TempSource::SENSOR_HOTSPOT ||
        source == TempSource::SENSOR_EDGE) {
        int64_t raw = 0;
        const auto kind = source == TempSource::SENSOR_HOTSPOT
            ? AMDSMI_TEMPERATURE_TYPE_HOTSPOT
            : AMDSMI_TEMPERATURE_TYPE_EDGE;
        if (amdsmi_get_temp_metric(gpu, kind, AMDSMI_TEMP_CURRENT, &raw)
            != AMDSMI_STATUS_SUCCESS) return nan;
        return sensor_celsius(raw);
    }
    return nan;
}

static inline amdsmi_processor_handle find_smi_gpu(int hip_gpu) {
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

static inline unsigned long long parse_positive_ull(const char* text,
                                                    const char* name) {
    if (!text || !*text || text[0] == '-') {
        std::fprintf(stderr, "Invalid %s: %s\n", name, text ? text : "(null)");
        std::exit(EXIT_FAILURE);
    }
    errno = 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0) {
        std::fprintf(stderr, "Invalid %s: %s\n", name, text);
        std::exit(EXIT_FAILURE);
    }
    return value;
}

static inline size_t checked_mul(size_t a, size_t b, const char* label) {
    if (a != 0 && b > std::numeric_limits<size_t>::max() / a) {
        std::fprintf(stderr, "%s size overflows size_t\n", label);
        std::exit(EXIT_FAILURE);
    }
    return a * b;
}

static inline size_t square_elements(size_t n) {
    return checked_mul(n, n, "N*N");
}

static inline size_t cube_elements(size_t n) {
    return checked_mul(square_elements(n), n, "N*N*N");
}

static inline dim3 make_grid_1d(size_t n, unsigned int threads = 256) {
    const size_t blocks = n / threads + (n % threads != 0);
    if (blocks > std::numeric_limits<unsigned int>::max()) {
        std::fprintf(stderr, "1D grid size exceeds HIP limit\n");
        std::exit(EXIT_FAILURE);
    }
    return dim3(static_cast<unsigned int>(blocks));
}

struct BenchmarkBuffers {
    std::vector<std::vector<double>> host;
    std::vector<double*> device;

    void allocate(const std::vector<size_t>& counts) {
        host.resize(counts.size());
        device.assign(counts.size(), nullptr);
        try {
            for (size_t a = 0; a < counts.size(); ++a) {
                host[a].resize(counts[a]);
                const double fill = a == 0 ? 0.0 : 0.5;
                for (size_t i = 0; i < counts[a]; ++i)
                    host[a][i] = a == 0 ? static_cast<double>(i) : fill;
                CHECK_HIP(hipMalloc(&device[a], checked_mul(counts[a], sizeof(double), "array")));
                CHECK_HIP(hipMemcpy(device[a], host[a].data(),
                                    checked_mul(counts[a], sizeof(double), "array"),
                                    hipMemcpyHostToDevice));
            }
        } catch (const std::bad_alloc&) {
            std::fprintf(stderr, "Host allocation failed\n");
            std::exit(EXIT_FAILURE);
        }
    }

    void copy_back() {
        for (size_t a = 0; a < host.size(); ++a)
            CHECK_HIP(hipMemcpy(host[a].data(), device[a],
                                host[a].size() * sizeof(double),
                                hipMemcpyDeviceToHost));
    }

    void release() {
        for (double* p : device) if (p) CHECK_HIP(hipFree(p));
        device.clear();
        host.clear();
    }
};

static inline size_t total_device_bytes(const std::vector<size_t>& counts) {
    size_t total = 0;
    for (size_t count : counts) {
        const size_t bytes = checked_mul(count, sizeof(double), "device allocation");
        if (bytes > std::numeric_limits<size_t>::max() - total) {
            std::fprintf(stderr, "Total device allocation overflows size_t\n");
            std::exit(EXIT_FAILURE);
        }
        total += bytes;
    }
    return total;
}

static inline std::string make_power_filename(const char* kernel_name,
                                              size_t n, int iterations) {
    const std::time_t now = std::chrono::system_clock::to_time_t(
        std::chrono::system_clock::now());
    std::tm local_time{};
    if (localtime_r(&now, &local_time) == nullptr) {
        std::fprintf(stderr, "Cannot convert execution time\n");
        std::exit(EXIT_FAILURE);
    }
    char timestamp[32] = {};
    if (std::strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S",
                      &local_time) == 0) {
        std::fprintf(stderr, "Cannot format execution time\n");
        std::exit(EXIT_FAILURE);
    }
    return std::string("power_") + kernel_name + "_" + timestamp +
           "_N" + std::to_string(n) + "_iter" +
           std::to_string(iterations) + ".csv";
}

template <class Workload>
int run_hip_benchmark(int argc, char** argv) {
    if (argc > 3) {
        std::fprintf(stderr, "Usage: %s [N] [iterations]\n", argv[0]);
        return EXIT_FAILURE;
    }
    const unsigned long long n_arg = argc >= 2
        ? parse_positive_ull(argv[1], "N") : Workload::default_n;
    const unsigned long long it_arg = argc >= 3
        ? parse_positive_ull(argv[2], "iterations") : 1000ULL;
    if (n_arg > std::numeric_limits<size_t>::max() || it_arg > INT_MAX) {
        std::fprintf(stderr, "N or iterations exceeds supported range\n");
        return EXIT_FAILURE;
    }
    const size_t n = static_cast<size_t>(n_arg);
    const int iterations = static_cast<int>(it_arg);
    const std::vector<size_t> counts = Workload::array_counts(n);
    const size_t required = total_device_bytes(counts);

    CHECK_HIP(hipSetDevice(0));
    size_t free_bytes = 0, total_bytes = 0;
    CHECK_HIP(hipMemGetInfo(&free_bytes, &total_bytes));
    if (required > free_bytes) {
        std::fprintf(stderr, "Not enough free GPU memory: need %.2f GiB, have %.2f GiB\n",
                     static_cast<double>(required) / (1ULL << 30),
                     static_cast<double>(free_bytes) / (1ULL << 30));
        return EXIT_FAILURE;
    }

    CHECK_SMI(amdsmi_init(AMDSMI_INIT_AMD_GPUS));
    const amdsmi_processor_handle gpu = find_smi_gpu(0);
    amdsmi_power_info_t initial_power{};
    CHECK_SMI(amdsmi_get_power_info(gpu, &initial_power));
    if (initial_power.current_socket_power == UINT32_MAX) {
        std::fprintf(stderr, "current_socket_power not supported\n");
        CHECK_SMI(amdsmi_shut_down());
        return EXIT_FAILURE;
    }
    const TempSource temp_source = find_temperature_source(gpu);
    std::fprintf(stderr, "Temperature source: %s\n",
                 temperature_source_name(temp_source));

    Workload workload;
    workload.buffers.allocate(counts);
    workload.configure(n);
    workload.launch(n);
    CHECK_HIP(hipGetLastError());
    CHECK_HIP(hipDeviceSynchronize());

    hipEvent_t start{}, stop{};
    CHECK_HIP(hipEventCreate(&start));
    CHECK_HIP(hipEventCreate(&stop));

    std::vector<TelemetrySample> samples;
    samples.reserve(4096);
    std::atomic<bool> ready{false}, sampling{false}, stop_sampling{false};
    BenchmarkClock::time_point measure_begin{};
    std::thread sampler([&]() {
        ready.store(true, std::memory_order_release);
        while (!sampling.load(std::memory_order_acquire)) std::this_thread::yield();
        auto next = measure_begin;
        while (!stop_sampling.load(std::memory_order_acquire)) {
            const auto t0 = BenchmarkClock::now();
            amdsmi_power_info_t p{};
            const auto ps = amdsmi_get_power_info(gpu, &p);
            const double temp_c = read_temperature(gpu, temp_source);
            const auto t1 = BenchmarkClock::now();
            const auto timestamp = t0 + (t1 - t0) / 2;
            const double nan = std::numeric_limits<double>::quiet_NaN();
            const double power_w = ps == AMDSMI_STATUS_SUCCESS &&
                                   p.current_socket_power != UINT32_MAX
                ? static_cast<double>(p.current_socket_power) : nan;
            samples.push_back({
                std::chrono::duration<double, std::milli>(timestamp - measure_begin).count(),
                power_w, temp_c
            });
            next += kPollInterval;
            const auto now = BenchmarkClock::now();
            while (next <= now) next += kPollInterval;
            std::this_thread::sleep_until(next);
        }
    });

    while (!ready.load(std::memory_order_acquire)) std::this_thread::yield();
    float total_ms = 0.0f;
    measure_begin = BenchmarkClock::now();
    sampling.store(true, std::memory_order_release);
    for (int i = 0; i < iterations; ++i) {
        CHECK_HIP(hipEventRecord(start));
        workload.launch(n);
        CHECK_HIP(hipGetLastError());
        CHECK_HIP(hipDeviceSynchronize());
        CHECK_HIP(hipEventRecord(stop));
        CHECK_HIP(hipEventSynchronize(stop));
        float ms = 0.0f;
        CHECK_HIP(hipEventElapsedTime(&ms, start, stop));
        total_ms += ms;
    }
    const auto measure_end = BenchmarkClock::now();
    stop_sampling.store(true, std::memory_order_release);
    sampler.join();

    const std::string power_csv = make_power_filename(
        Workload::name, n, iterations);
    std::ofstream out(power_csv);
    if (!out) {
        std::fprintf(stderr, "Cannot open %s for writing\n", power_csv.c_str());
        return EXIT_FAILURE;
    }
    out << "time_ms,power_W,gpu_temp_C\n" << std::fixed << std::setprecision(3);
    const double end_ms = std::chrono::duration<double, std::milli>(
        measure_end - measure_begin).count();
    size_t sample_count = 0;
    for (const auto& s : samples) {
        if (s.time_ms < 0.0 || s.time_ms > end_ms) continue;
        out << s.time_ms << ',' << s.power_w << ',' << s.temp_c << '\n';
        ++sample_count;
    }
    out.close();
    if (!out) {
        std::fprintf(stderr, "Failed to write %s\n", power_csv.c_str());
        return EXIT_FAILURE;
    }

    workload.buffers.copy_back();
    const double elapsed_sec = total_ms / 1000.0;
    const double avg_ms = total_ms / static_cast<double>(iterations);
    const double total_flops = workload.flops_per_iteration(n) * iterations;
    const double gflops = elapsed_sec > 0.0
        ? total_flops / elapsed_sec / 1.0e9 : 0.0;
    std::printf("kernel,problem size,iterations,total kernel time [s],avg kernel time [ms],GFLOP/s,TFLOP/s\n");
    std::printf("%s,%zu,%d,%.6f,%.6f,%.6f,%.6f\n", Workload::name, n,
                iterations, elapsed_sec, avg_ms, gflops, gflops / 1000.0);
    std::fprintf(stderr, "Saved %zu power/temperature samples to %s\n",
                 sample_count, power_csv.c_str());
    if (sample_count < 2)
        std::fprintf(stderr, "Warning: measurement too short for reliable 50 ms polling; increase iterations.\n");

    CHECK_HIP(hipEventDestroy(start));
    CHECK_HIP(hipEventDestroy(stop));
    workload.buffers.release();
    CHECK_SMI(amdsmi_shut_down());
    return EXIT_SUCCESS;
}

#endif


__global__ void symm(const double* a, const double* b, double* c, size_t n) {
    const size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t j = static_cast<size_t>(blockIdx.y) * blockDim.y + threadIdx.y;
    if (i < n && j < n) {
        double sum = 0.0;
        for (size_t l = 0; l <= j; ++l) sum += a[i * n + l] * b[l * n + j];
        c[i * n + j] = sum * c[i * n + j];
    }
}

struct SymmWorkload {
    static constexpr const char* name = "symm";
    static constexpr unsigned long long default_n = 4096ULL;
    BenchmarkBuffers buffers; dim3 grid, block{16, 16};
    static std::vector<size_t> array_counts(size_t n) { const size_t s = square_elements(n); return {s, s, s}; }
    void configure(size_t n) { grid = dim3((n + 15) / 16, (n + 15) / 16); }
    void launch(size_t n) { hipLaunchKernelGGL(symm, grid, block, 0, 0, buffers.device[0], buffers.device[1], buffers.device[2], n); }
    double flops_per_iteration(size_t n) const { const double d = n; return 1.5 * d * d * d; }
};

int main(int argc, char** argv) { return run_hip_benchmark<SymmWorkload>(argc, argv); }
