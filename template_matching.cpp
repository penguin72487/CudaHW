#include <algorithm>
#include <chrono>
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
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std;

struct MatrixU8 {
    int rows = 0;
    int cols = 0;
    vector<uint8_t> data;
};

struct ArgConfig {
    string smallPath;
    string largePath;
    vector<int> threadConfigs;
    bool runThreadSweep = false;
    int threadSweepMax = 12;
    int sweepRepeats = 3;
    string threadSweepCsv;
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
        throw runtime_error("Cannot open file: " + path);
    }

    MatrixU8 matrix;
    string line;
    int expectedCols = -1;

    while (getline(in, line)) {
        line = trim(line);
        if (line.empty()) {
            continue;
        }

        stringstream ss(line);
        string token;
        vector<uint8_t> row;

        while (getline(ss, token, ',')) {
            token = trim(token);
            if (token.empty()) {
                throw runtime_error("Invalid empty value in file: " + path);
            }
            int v = stoi(token);
            if (v < 0 || v > 9) {
                throw runtime_error("Value out of [0,9] range in file: " + path);
            }
            row.push_back(static_cast<uint8_t>(v));
        }

        if (row.empty()) {
            continue;
        }
        if (expectedCols == -1) {
            expectedCols = static_cast<int>(row.size());
        } else if (expectedCols != static_cast<int>(row.size())) {
            throw runtime_error("Inconsistent column count in file: " + path);
        }

        matrix.data.insert(matrix.data.end(), row.begin(), row.end());
        matrix.rows += 1;
    }

    if (matrix.rows == 0 || expectedCols <= 0) {
        throw runtime_error("Empty matrix file: " + path);
    }

    matrix.cols = expectedCols;
    return matrix;
}

vector<int> defaultThreadConfigs() {
    unsigned hw = std::thread::hardware_concurrency();
    int maxHw = (hw == 0) ? 8 : static_cast<int>(hw);

    vector<int> cfg = {1, 2, 4, 8, maxHw};
    cfg.erase(remove_if(cfg.begin(), cfg.end(), [](int v) { return v <= 0; }), cfg.end());
    sort(cfg.begin(), cfg.end());
    cfg.erase(unique(cfg.begin(), cfg.end()), cfg.end());
    return cfg;
}

vector<int> parseThreadList(const string& raw) {
    vector<int> threads;
    stringstream ss(raw);
    string part;

    while (getline(ss, part, ';')) {
        part = trim(part);
        if (part.empty()) {
            continue;
        }

        int t = stoi(part);
        if (t <= 0 || t > 1024) {
            throw runtime_error("Invalid thread count: " + part);
        }
        threads.push_back(t);
    }

    if (threads.empty()) {
        throw runtime_error("No valid thread count found");
    }

    sort(threads.begin(), threads.end());
    threads.erase(unique(threads.begin(), threads.end()), threads.end());
    return threads;
}

ArgConfig parseArgs(int argc, char** argv) {
    ArgConfig cfg;
    cfg.threadConfigs = defaultThreadConfigs();

    for (int i = 1; i < argc; ++i) {
        string arg = argv[i];
        if (arg == "--small" && i + 1 < argc) {
            cfg.smallPath = argv[++i];
        } else if (arg == "--large" && i + 1 < argc) {
            cfg.largePath = argv[++i];
        } else if (arg == "--threads" && i + 1 < argc) {
            cfg.threadConfigs = parseThreadList(argv[++i]);
        } else if (arg == "--thread-sweep") {
            cfg.runThreadSweep = true;
        } else if (arg == "--thread-sweep-max" && i + 1 < argc) {
            cfg.runThreadSweep = true;
            cfg.threadSweepMax = stoi(argv[++i]);
        } else if (arg == "--sweep-repeats" && i + 1 < argc) {
            cfg.runThreadSweep = true;
            cfg.sweepRepeats = stoi(argv[++i]);
        } else if (arg == "--thread-sweep-csv" && i + 1 < argc) {
            cfg.runThreadSweep = true;
            cfg.threadSweepCsv = argv[++i];
        } else if (arg == "--help") {
            cout << "Usage:\n"
                 << "  template_matching --small <S_file> --large <T_file> [--threads 1;2;4;8]\n"
                 << "  template_matching --small <S_file> --large <T_file> --thread-sweep\n"
                 << "                   [--thread-sweep-max 12] [--sweep-repeats 3]\n"
                 << "                   [--thread-sweep-csv thread_sweep.csv]\n";
            std::exit(0);
        } else {
            throw runtime_error("Unknown/invalid argument: " + arg);
        }
    }

    if (cfg.smallPath.empty() || cfg.largePath.empty()) {
        throw runtime_error("Missing --small or --large argument");
    }
    if (cfg.threadSweepMax <= 0 || cfg.threadSweepMax > 1024) {
        throw runtime_error("--thread-sweep-max must be in [1, 1024]");
    }
    if (cfg.sweepRepeats <= 0) {
        throw runtime_error("--sweep-repeats must be > 0");
    }

    return cfg;
}

template <typename Fn>
void parallelFor(size_t count, int threads, Fn&& fn) {
    if (count == 0) {
        return;
    }
    int workerCount = std::max(1, std::min(threads, static_cast<int>(count)));

    vector<thread> workers;
    workers.reserve(static_cast<size_t>(workerCount));

    size_t chunk = (count + static_cast<size_t>(workerCount) - 1) / static_cast<size_t>(workerCount);
    for (int t = 0; t < workerCount; ++t) {
        size_t begin = static_cast<size_t>(t) * chunk;
        size_t end = std::min(count, begin + chunk);
        if (begin >= end) {
            break;
        }

        workers.emplace_back([=, &fn] {
            for (size_t i = begin; i < end; ++i) {
                fn(i);
            }
        });
    }

    for (auto& w : workers) {
        w.join();
    }
}

double benchmarkSsd(const MatrixU8& small, const MatrixU8& large, int threads, vector<int>& out) {
    const int outRows = large.rows - small.rows + 1;
    const int outCols = large.cols - small.cols + 1;
    const size_t outCount = static_cast<size_t>(outRows) * static_cast<size_t>(outCols);

    auto start = chrono::steady_clock::now();
    parallelFor(outCount, threads, [&](size_t idx) {
        int row = static_cast<int>(idx / static_cast<size_t>(outCols));
        int col = static_cast<int>(idx % static_cast<size_t>(outCols));

        int sum = 0;
        for (int r = 0; r < small.rows; ++r) {
            const int largeRowBase = (row + r) * large.cols + col;
            const int smallRowBase = r * small.cols;
            for (int c = 0; c < small.cols; ++c) {
                int diff = static_cast<int>(small.data[smallRowBase + c]) -
                           static_cast<int>(large.data[largeRowBase + c]);
                sum += diff * diff;
            }
        }
        out[idx] = sum;
    });
    auto stop = chrono::steady_clock::now();

    return chrono::duration<double, std::milli>(stop - start).count();
}

double benchmarkPcc(const MatrixU8& small, const MatrixU8& large, int threads, vector<float>& out) {
    const int outRows = large.rows - small.rows + 1;
    const int outCols = large.cols - small.cols + 1;
    const size_t outCount = static_cast<size_t>(outRows) * static_cast<size_t>(outCols);
    const int n = small.rows * small.cols;

    auto start = chrono::steady_clock::now();
    parallelFor(outCount, threads, [&](size_t idx) {
        int row = static_cast<int>(idx / static_cast<size_t>(outCols));
        int col = static_cast<int>(idx % static_cast<size_t>(outCols));

        double sumX = 0.0;
        double sumY = 0.0;

        for (int r = 0; r < small.rows; ++r) {
            const int largeRowBase = (row + r) * large.cols + col;
            const int smallRowBase = r * small.cols;
            for (int c = 0; c < small.cols; ++c) {
                sumX += static_cast<double>(small.data[smallRowBase + c]);
                sumY += static_cast<double>(large.data[largeRowBase + c]);
            }
        }

        const double meanX = sumX / static_cast<double>(n);
        const double meanY = sumY / static_cast<double>(n);

        double num = 0.0;
        double denX = 0.0;
        double denY = 0.0;

        for (int r = 0; r < small.rows; ++r) {
            const int largeRowBase = (row + r) * large.cols + col;
            const int smallRowBase = r * small.cols;
            for (int c = 0; c < small.cols; ++c) {
                const double x = static_cast<double>(small.data[smallRowBase + c]) - meanX;
                const double y = static_cast<double>(large.data[largeRowBase + c]) - meanY;
                num += x * y;
                denX += x * x;
                denY += y * y;
            }
        }

        const double den = std::sqrt(denX * denY);
        out[idx] = static_cast<float>((den <= 1e-12) ? 0.0 : (num / den));
    });
    auto stop = chrono::steady_clock::now();

    return chrono::duration<double, std::milli>(stop - start).count();
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

    vector<int> ssdOut(outCount);
    vector<float> pccOut(outCount);

    vector<pair<int, double>> ssdTimes;
    vector<pair<int, double>> pccTimes;
    ssdTimes.reserve(cfg.threadConfigs.size());
    pccTimes.reserve(cfg.threadConfigs.size());

    for (int threads : cfg.threadConfigs) {
        double tSsd = benchmarkSsd(small, large, threads, ssdOut);
        double tPcc = benchmarkPcc(small, large, threads, pccOut);
        ssdTimes.push_back({threads, tSsd});
        pccTimes.push_back({threads, tPcc});
    }

    auto bestSsdIt = std::min_element(ssdTimes.begin(), ssdTimes.end(),
                                      [](const auto& a, const auto& b) { return a.second < b.second; });
    auto bestPccIt = std::min_element(pccTimes.begin(), pccTimes.end(),
                                      [](const auto& a, const auto& b) { return a.second < b.second; });

    benchmarkSsd(small, large, bestSsdIt->first, ssdOut);
    benchmarkPcc(small, large, bestPccIt->first, pccOut);

    int bestSsdValue = 0;
    float bestPccValue = 0.0f;
    const auto ssdPos = collectBestSsdPositions(ssdOut, outRows, outCols, bestSsdValue);
    const auto pccPos = collectBestPccPositions(pccOut, outRows, outCols, bestPccValue);

    cout << "\n=== SSD Result ===\n";
    cout << "Best value: " << bestSsdValue << "\n";
    cout << "Positions: ";
    printPositions(ssdPos);
    cout << "Timing (ms) by thread count:\n";
    for (const auto& [t, ms] : ssdTimes) {
        cout << "  " << t << " -> " << fixed << setprecision(3) << ms << " ms\n";
    }
    cout << "Best threads: " << bestSsdIt->first << "\n";

    cout << "\n=== PCC Result ===\n";
    cout << "Best value: " << fixed << setprecision(6) << bestPccValue << "\n";
    cout << "Positions: ";
    printPositions(pccPos);
    cout << "Timing (ms) by thread count:\n";
    for (const auto& [t, ms] : pccTimes) {
        cout << "  " << t << " -> " << fixed << setprecision(3) << ms << " ms\n";
    }
    cout << "Best threads: " << bestPccIt->first << "\n";

    if (cfg.runThreadSweep) {
        struct ThreadSweepRow {
            int threads;
            double ssdMs;
            double pccMs;
        };

        vector<ThreadSweepRow> rows;
        rows.reserve(static_cast<size_t>(cfg.threadSweepMax));

        for (int threads = 1; threads <= cfg.threadSweepMax; ++threads) {
            double ssdSum = 0.0;
            double pccSum = 0.0;
            for (int rep = 0; rep < cfg.sweepRepeats; ++rep) {
                ssdSum += benchmarkSsd(small, large, threads, ssdOut);
                pccSum += benchmarkPcc(small, large, threads, pccOut);
            }

            rows.push_back({threads, ssdSum / static_cast<double>(cfg.sweepRepeats),
                            pccSum / static_cast<double>(cfg.sweepRepeats)});
        }

        const string csvPath = cfg.threadSweepCsv.empty() ? "thread_sweep.csv" : cfg.threadSweepCsv;
        ofstream csv(csvPath);
        if (!csv.is_open()) {
            throw runtime_error("Cannot open CSV output file: " + csvPath);
        }
        csv << "threads,ssd_ms,pcc_ms\n";
        for (const auto& row : rows) {
            csv << row.threads << "," << fixed << setprecision(6) << row.ssdMs << "," << row.pccMs << "\n";
        }

        cout << "\n=== Thread Sweep ===\n";
        cout << "Repeat per point: " << cfg.sweepRepeats << "\n";
        cout << left << setw(10) << "Threads" << setw(14) << "SSD(ms)" << setw(14) << "PCC(ms)" << "\n";
        for (const auto& row : rows) {
            cout << left << setw(10) << row.threads << setw(14) << fixed << setprecision(6) << row.ssdMs
                 << setw(14) << row.pccMs << "\n";
        }
        cout << "CSV saved to: " << csvPath << "\n";
    }
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
