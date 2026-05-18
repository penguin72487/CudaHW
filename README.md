# CUDA Template Matching (PCC + SSD)

這個專案使用 CUDA + C++ 完成作業要求的 Template Matching：

- SSD (Sum of Squared Differences)
- PCC (Pearson Correlation Coefficient)

程式會輸出：

- 最佳匹配座標 `(row,col)`，若有多個同分會全部列出
- 不同 block size 下的執行時間
- 各方法最佳 block size

## 檔案

- `template_matching.cu`：主程式
- `run_all.bat`：依序執行作業 4 組資料

## 編譯

請先確認 `nvcc` 可用（CUDA Toolkit 已安裝）。

```bat
nvcc -O3 -std=c++17 template_matching.cu -o template_matching.exe
```

## 單組執行

```bat
template_matching.exe --small data\1\S1_3_3.txt --large data\1\T1_3750_4320.txt
```

可自訂 block size：

```bat
template_matching.exe --small data\1\S1_3_3.txt --large data\1\T1_3750_4320.txt --blocks "8x8;16x16;32x8;32x16"
```

## 四組資料一次跑完

```bat
run_all.bat
```

或直接用 PowerShell code runner：

```powershell
powershell -ExecutionPolicy Bypass -File .\code_runner.ps1
```

只編譯不執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\code_runner.ps1 -BuildOnly
```

自訂 blocks 跑全部：

```powershell
powershell -ExecutionPolicy Bypass -File .\code_runner.ps1 -Blocks "8x8;16x16;32x8"
```

## VS Code Code Runner 外掛

已在工作區設定 `.cu` 副檔名對應到 `code_runner.ps1`。

使用方式：

1. 在 VS Code 開啟 [template_matching.cu](template_matching.cu)
2. 按 `Ctrl+Alt+N`（Code Runner 預設快捷鍵）
3. 會自動執行 `code_runner.ps1`，進行編譯並跑 4 組測資

## 參數說明

- `--small <path>`：小矩陣 S（template/kernel）
- `--large <path>`：大矩陣 T（search image）
- `--blocks "8x8;16x16;..."`：要測試的 block size 清單，分號分隔
