# Template Matching (全 C++ 版本)

這個專案目前可直接用純 C++ 執行 Template Matching：

- SSD (Sum of Squared Differences)
- PCC (Pearson Correlation Coefficient)

輸出內容包含：

- 最佳匹配座標 `(row,col)`，若有多個同分會全部列出
- 不同 thread 數量下的執行時間
- 各方法最佳 thread 數量
- 可選的 thread sweep CSV（用於作圖）

## 主要檔案

- `template_matching.cpp`：純 C++ 主程式（`std::thread` 平行）
- `code_runner.sh`：Linux/macOS 一鍵編譯執行
- `code_runner.ps1`：Windows PowerShell 一鍵編譯執行
- `plot_thread_sweep.py`：將 thread sweep CSV 繪成圖
- `template_matching.cu`：原 CUDA 版本（保留）

## 編譯（純 C++）

Linux/macOS：

```bash
g++ -O3 -std=c++17 -pthread template_matching.cpp -o template_matching
```

Windows（MinGW-w64 / MSYS2）：

```powershell
g++.exe -O3 -std=c++17 -pthread template_matching.cpp -o template_matching.exe
```

## 單組執行

Linux/macOS：

```bash
./template_matching --small data/4/S4_5_5.txt --large data/4/T4_50_50.txt
```

Windows：

```powershell
.\template_matching.exe --small data/4/S4_5_5.txt --large data/4/T4_50_50.txt
```

可自訂 thread 清單：

```bash
./template_matching --small data/4/S4_5_5.txt --large data/4/T4_50_50.txt --threads "1;2;4;8;12"
```

## 一鍵跑全部測資

Linux/macOS：

```bash
bash code_runner.sh
```

Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\code_runner.ps1
```

只編譯不執行：

```bash
bash code_runner.sh --build-only
```

```powershell
powershell -ExecutionPolicy Bypass -File .\code_runner.ps1 -BuildOnly
```

## Thread Sweep（1~12）

```bash
./template_matching --small data/4/S4_5_5.txt --large data/4/T4_50_50.txt \
  --thread-sweep --thread-sweep-max 12 --sweep-repeats 5 \
  --thread-sweep-csv thread_sweep_case4.csv
```

繪圖：

```bash
python3 plot_thread_sweep.py --input thread_sweep_case4.csv --output thread_sweep_case4.png
```

## 參數說明

- `--small <path>`：小矩陣 S（template）
- `--large <path>`：大矩陣 T（search image）
- `--threads "1;2;4;..."`：要測試的 thread 數量清單（分號分隔）
- `--thread-sweep`：啟用 thread sweep
- `--thread-sweep-max <N>`：thread sweep 最大 thread
- `--sweep-repeats <N>`：每個點重複次數（取平均）
- `--thread-sweep-csv <path>`：CSV 輸出路徑
