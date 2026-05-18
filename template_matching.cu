#include <cuda_runtime.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace std;

struct MatrixU8 {
    int rows = 0;
    int cols = 0;
    std::vector<uint8_t> data;
};

struct BlockSize {
    int x;
    int y;
};

struct ArgConfig {
    string smallPath;
    string largePath;
    vector<BlockSize> blocks;
};

inline void cudaCheck(cudaError_t err, const char* file, int line) {
    if (err != cudaSuccess) {
        ostringstream oss;
        oss << "CUDA error at " << file << ":" << line << " -> " << cudaGetErrorString(err);
        throw runtime_error(oss.str());
    }
}

#define CUDA_CHECK(call) cudaCheck((call), __FILE__, __LINE__)

template <typename T>
class DeviceBuffer {
  public:
    DeviceBuffer() = default;

    explicit DeviceBuffer(size_t count) : count_(count) {
        CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&ptr_), count_ * sizeof(T)));
    }

    ~DeviceBuffer() {
        if (ptr_) {
            cudaFree(ptr_);
        }
    }

    DeviceBuffer(const DeviceBuffer&) = delete;
    DeviceBuffer& operator=(const DeviceBuffer&) = delete;

    DeviceBuffer(DeviceBuffer&& other) noexcept
        : ptr_(exchange(other.ptr_, nullptr)), count_(exchange(other.count_, 0)) {}

    DeviceBuffer& operator=(DeviceBuffer&& other) noexcept {
        if (this != &other) {
            if (ptr_) {
                cudaFree(ptr_);
            }
            ptr_ = exchange(other.ptr_, nullptr);
            count_ = exchange(other.count_, 0);
        }
        return *this;
    }

    T* get() const { return ptr_; }

    void copyFromHost(const vector<T>& host) const {
        if (host.size() != count_) {
            throw runtime_error("Host/device size mismatch in copyFromHost");
        }
        CUDA_CHECK(cudaMemcpy(ptr_, host.data(), count_ * sizeof(T), cudaMemcpyHostToDevice));
    }

    void copyToHost(vector<T>& host) const {
        host.resize(count_);
        CUDA_CHECK(cudaMemcpy(host.data(), ptr_, count_ * sizeof(T), cudaMemcpyDeviceToHost));
    }

  private:
    T* ptr_ = nullptr;
    size_t count_ = 0;
};

class EventTimer {
  public:
    EventTimer() {
        CUDA_CHECK(cudaEventCreate(&start_));
        CUDA_CHECK(cudaEventCreate(&stop_));
    }

    ~EventTimer() {
        cudaEventDestroy(start_);
        cudaEventDestroy(stop_);
    }

    float measure(const function<void()>& fn) {
        CUDA_CHECK(cudaEventRecord(start_));
        fn();
        CUDA_CHECK(cudaEventRecord(stop_));
        CUDA_CHECK(cudaEventSynchronize(stop_));
        CUDA_CHECK(cudaGetLastError());

        float ms = 0.0f;
        CUDA_CHECK(cudaEventElapsedTime(&ms, start_, stop_));
        return ms;
    }

  private:
    cudaEvent_t start_{};
    cudaEvent_t stop_{};
};

string trim(const string& s) {
    size_t left = 0;
    while (left < s.size() && std::isspace(static_cast<unsigned char>(s[left]))) {
        ++left;
    }
    size_t right = s.size();
    while (right > left && std::isspace(static_cast<unsigned char>(s[right - 1]))) {
        --right;
    }
    return s.substr(left, right - left);
}

MatrixU8 loadCsvMatrix(const string& path) {
    ifstream in(path);
    if (!in.is_open()) {
        throw std::runtime_error("Cannot open file: " + path);
    }

    MatrixU8 matrix;
    string line;
    int expectedCols = -1;

    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty()) {
            continue;
        }

        stringstream ss(line);
        string token;
        vector<uint8_t> row;

        while (std::getline(ss, token, ',')) {
            token = trim(token);
            if (token.empty()) {
                throw std::runtime_error("Invalid empty value in file: " + path);
            }
            int v = std::stoi(token);
            if (v < 0 || v > 9) {
                throw std::runtime_error("Value out of [0,9] range in file: " + path);
            }
            row.push_back(static_cast<uint8_t>(v));
        }

        if (row.empty()) {
            continue;
        }
        if (expectedCols == -1) {
            expectedCols = static_cast<int>(row.size());
        } else if (expectedCols != static_cast<int>(row.size())) {
            throw std::runtime_error("Inconsistent column count in file: " + path);
        }

        matrix.data.insert(matrix.data.end(), row.begin(), row.end());
        matrix.rows += 1;
    }

    if (matrix.rows == 0 || expectedCols <= 0) {
        throw std::runtime_error("Empty matrix file: " + path);
    }

    matrix.cols = expectedCols;
    return matrix;
}

vector<BlockSize> defaultBlocks() {
    return {
        {8, 8}, {16, 8}, {8, 16}, {16, 16}, {32, 8}, {8, 32}, {32, 16}, {16, 32}, {32, 32},
    };
}

vector<BlockSize> parseBlockList(const string& raw) {
    vector<BlockSize> blocks;
    stringstream ss(raw);
    string part;

    while (std::getline(ss, part, ';')) {
        part = trim(part);
        if (part.empty()) {
            continue;
        }

        size_t xPos = part.find('x');
        if (xPos == string::npos) {
            xPos = part.find('X');
        }
        if (xPos == string::npos) {
            throw runtime_error("Invalid block format, use e.g. 16x16;32x8");
        }

        int bx = std::stoi(trim(part.substr(0, xPos)));
        int by = std::stoi(trim(part.substr(xPos + 1)));
        if (bx <= 0 || by <= 0 || bx > 1024 || by > 1024 || bx * by > 1024) {
            throw runtime_error("Invalid CUDA block size: " + part);
        }

        blocks.push_back({bx, by});
    }

    if (blocks.empty()) {
        throw runtime_error("No valid block size found");
    }
    return blocks;
}

ArgConfig parseArgs(int argc, char** argv) {
    ArgConfig cfg;
    cfg.blocks = defaultBlocks();

    for (int i = 1; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--small" && i + 1 < argc) {
            cfg.smallPath = argv[++i];
        } else if (arg == "--large" && i + 1 < argc) {
            cfg.largePath = argv[++i];
        } else if (arg == "--blocks" && i + 1 < argc) {
            cfg.blocks = parseBlockList(argv[++i]);
        } else if (arg == "--help") {
            cout << "Usage:\n"
                      << "  template_matching.exe --small <S_file> --large <T_file> [--blocks 8x8;16x16;32x8]\n";
            std::exit(0);
        } else {
            throw runtime_error("Unknown/invalid argument: " + arg);
        }
    }

    if (cfg.smallPath.empty() || cfg.largePath.empty()) {
        throw runtime_error("Missing --small or --large argument");
    }

    return cfg;
}

__global__ void ssdKernel(const uint8_t* small, int sRows, int sCols, const uint8_t* large, int lCols,
                          int outRows, int outCols, int* out) {
    const int col = blockIdx.x * blockDim.x + threadIdx.x;
    const int row = blockIdx.y * blockDim.y + threadIdx.y;

    if (row >= outRows || col >= outCols) {
        return;
    }

    int sum = 0;
    for (int r = 0; r < sRows; ++r) {
        const int largeRowBase = (row + r) * lCols + col;
        const int smallRowBase = r * sCols;
        for (int c = 0; c < sCols; ++c) {
            int diff = static_cast<int>(small[smallRowBase + c]) - static_cast<int>(large[largeRowBase + c]);
            sum += diff * diff;
        }
    }

    out[row * outCols + col] = sum;
}

__global__ void pccKernel(const uint8_t* small, int sRows, int sCols, const uint8_t* large, int lCols,
                          int outRows, int outCols, float* out) {
    const int col = blockIdx.x * blockDim.x + threadIdx.x;
    const int row = blockIdx.y * blockDim.y + threadIdx.y;

    if (row >= outRows || col >= outCols) {
        return;
    }

    const int n = sRows * sCols;
    double sumX = 0.0;
    double sumY = 0.0;

    for (int r = 0; r < sRows; ++r) {
        const int largeRowBase = (row + r) * lCols + col;
        const int smallRowBase = r * sCols;
        for (int c = 0; c < sCols; ++c) {
            sumX += static_cast<double>(small[smallRowBase + c]);
            sumY += static_cast<double>(large[largeRowBase + c]);
        }
    }

    const double meanX = sumX / static_cast<double>(n);
    const double meanY = sumY / static_cast<double>(n);

    double num = 0.0;
    double denX = 0.0;
    double denY = 0.0;

    for (int r = 0; r < sRows; ++r) {
        const int largeRowBase = (row + r) * lCols + col;
        const int smallRowBase = r * sCols;
        for (int c = 0; c < sCols; ++c) {
            const double x = static_cast<double>(small[smallRowBase + c]) - meanX;
            const double y = static_cast<double>(large[largeRowBase + c]) - meanY;
            num += x * y;
            denX += x * x;
            denY += y * y;
        }
    }

    const double den = std::sqrt(denX * denY);
    out[row * outCols + col] = static_cast<float>((den <= 1e-12) ? 0.0 : (num / den));
}

float benchmarkSsd(const uint8_t* dSmall, int sRows, int sCols, const uint8_t* dLarge, int lRows, int lCols,
                   int* dOut, BlockSize block) {
    const int outRows = lRows - sRows + 1;
    const int outCols = lCols - sCols + 1;
    dim3 blockDim(block.x, block.y);
    dim3 gridDim((outCols + blockDim.x - 1) / blockDim.x, (outRows + blockDim.y - 1) / blockDim.y);

    EventTimer timer;
    return timer.measure([&] {
        ssdKernel<<<gridDim, blockDim>>>(dSmall, sRows, sCols, dLarge, lCols, outRows, outCols, dOut);
    });
}

float benchmarkPcc(const uint8_t* dSmall, int sRows, int sCols, const uint8_t* dLarge, int lRows, int lCols,
                   float* dOut, BlockSize block) {
    const int outRows = lRows - sRows + 1;
    const int outCols = lCols - sCols + 1;
    dim3 blockDim(block.x, block.y);
    dim3 gridDim((outCols + blockDim.x - 1) / blockDim.x, (outRows + blockDim.y - 1) / blockDim.y);

    EventTimer timer;
    return timer.measure([&] {
        pccKernel<<<gridDim, blockDim>>>(dSmall, sRows, sCols, dLarge, lCols, outRows, outCols, dOut);
    });
}

vector<pair<int, int>> collectBestSsdPositions(const vector<int>& scores, int outRows, int outCols, int& bestVal) {
    bestVal = numeric_limits<int>::max();
    for (int v : scores) {
        bestVal = std::min(bestVal, v);
    }

    vector<pair<int, int>> pos;
    pos.reserve(8);
    for (int r = 0; r < outRows; ++r) {
        const int base = r * outCols;
        for (int c = 0; c < outCols; ++c) {
            if (scores[base + c] == bestVal) {
                pos.push_back({r, c});
            }
        }
    }
    return pos;
}

vector<pair<int, int>> collectBestPccPositions(const vector<float>& scores, int outRows, int outCols,
                                               float& bestVal) {
    bestVal = -numeric_limits<float>::infinity();
    for (float v : scores) {
        bestVal = std::max(bestVal, v);
    }

    const float eps = 1e-6f;
    vector<pair<int, int>> pos;
    pos.reserve(8);
    for (int r = 0; r < outRows; ++r) {
        const int base = r * outCols;
        for (int c = 0; c < outCols; ++c) {
            if (std::fabs(scores[base + c] - bestVal) <= eps) {
                pos.push_back({r, c});
            }
        }
    }
    return pos;
}

void printPositions(const vector<pair<int, int>>& pos) {
    for (size_t i = 0; i < pos.size(); ++i) {
        cout << "(" << pos[i].first << "," << pos[i].second << ")";
        if (i + 1 < pos.size()) {
            cout << ", ";
        }
    }
    cout << "\n";
}

void run(const ArgConfig& cfg) {
    const MatrixU8 small = loadCsvMatrix(cfg.smallPath);
    const MatrixU8 large = loadCsvMatrix(cfg.largePath);

    if (small.rows > large.rows || small.cols > large.cols) {
        throw runtime_error("Small matrix must fit inside large matrix");
    }

    const int outRows = large.rows - small.rows + 1;
    const int outCols = large.cols - small.cols + 1;
    const size_t outCount = static_cast<size_t>(outRows) * static_cast<size_t>(outCols);

    cout << "Small(S): " << small.rows << "x" << small.cols << "\n";
    cout << "Large(T): " << large.rows << "x" << large.cols << "\n";
    cout << "Output map: " << outRows << "x" << outCols << "\n";

    DeviceBuffer<uint8_t> dSmall(small.data.size());
    DeviceBuffer<uint8_t> dLarge(large.data.size());
    DeviceBuffer<int> dSsdOut(outCount);
    DeviceBuffer<float> dPccOut(outCount);

    dSmall.copyFromHost(small.data);
    dLarge.copyFromHost(large.data);

    vector<pair<BlockSize, float>> ssdTimes;
    vector<pair<BlockSize, float>> pccTimes;
    ssdTimes.reserve(cfg.blocks.size());
    pccTimes.reserve(cfg.blocks.size());

    for (const auto& b : cfg.blocks) {
        float tSsd = benchmarkSsd(dSmall.get(), small.rows, small.cols, dLarge.get(), large.rows, large.cols,
                                  dSsdOut.get(), b);
        float tPcc = benchmarkPcc(dSmall.get(), small.rows, small.cols, dLarge.get(), large.rows, large.cols,
                                  dPccOut.get(), b);
        ssdTimes.push_back({b, tSsd});
        pccTimes.push_back({b, tPcc});
    }

    auto bestSsdIt = std::min_element(ssdTimes.begin(), ssdTimes.end(),
                                      [](const auto& a, const auto& b) { return a.second < b.second; });
    auto bestPccIt = std::min_element(pccTimes.begin(), pccTimes.end(),
                                      [](const auto& a, const auto& b) { return a.second < b.second; });

    // Re-run with best block size before copying results.
    benchmarkSsd(dSmall.get(), small.rows, small.cols, dLarge.get(), large.rows, large.cols, dSsdOut.get(),
                 bestSsdIt->first);
    benchmarkPcc(dSmall.get(), small.rows, small.cols, dLarge.get(), large.rows, large.cols, dPccOut.get(),
                 bestPccIt->first);

    vector<int> hSsd;
    vector<float> hPcc;

    dSsdOut.copyToHost(hSsd);
    dPccOut.copyToHost(hPcc);

    int bestSsdValue = 0;
    float bestPccValue = 0.0f;
    const auto ssdPos = collectBestSsdPositions(hSsd, outRows, outCols, bestSsdValue);
    const auto pccPos = collectBestPccPositions(hPcc, outRows, outCols, bestPccValue);

    cout << "\n=== SSD Result ===\n";
    cout << "Best value: " << bestSsdValue << "\n";
    cout << "Positions: ";
    printPositions(ssdPos);
    cout << "Timing (ms) by block size:\n";
    for (const auto& [b, t] : ssdTimes) {
        cout << "  " << b.x << "x" << b.y << " -> " << fixed << setprecision(3) << t << " ms\n";
    }
    cout << "Best block: " << bestSsdIt->first.x << "x" << bestSsdIt->first.y << "\n";

    cout << "\n=== PCC Result ===\n";
    cout << "Best value: " << fixed << setprecision(6) << bestPccValue << "\n";
    cout << "Positions: ";
    printPositions(pccPos);
    cout << "Timing (ms) by block size:\n";
    for (const auto& [b, t] : pccTimes) {
        cout << "  " << b.x << "x" << b.y << " -> " << fixed << setprecision(3) << t << " ms\n";
    }
    cout << "Best block: " << bestPccIt->first.x << "x" << bestPccIt->first.y << "\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        ArgConfig cfg = parseArgs(argc, argv);
        run(cfg);
        return 0;
    } catch (const exception& ex) {
        cerr << "Error: " << ex.what() << "\n";
        return 1;
    }
}
