#!/usr/bin/env bash
set -euo pipefail

# 控制編譯/執行行為的旗標。
BUILD_ONLY=0
SKIP_BUILD=0
BLOCKS=""

usage() {
  echo "Usage: $0 [--build-only] [--skip-build] [--blocks \"16x16;32x8\"]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --blocks)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] --blocks requires a value." >&2
        usage
        exit 2
      fi
      BLOCKS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

build_cuda_project() {
  # 編譯 .cu 檔案需要 nvcc。
  if ! command -v nvcc >/dev/null 2>&1; then
    echo "[ERROR] nvcc not found in PATH. Please install CUDA Toolkit." >&2
    return 1
  fi

  local build_cmd=(nvcc -O3 -std=c++17 template_matching.cu -o template_matching)
  echo "[INFO] Building: ${build_cmd[*]}"
  "${build_cmd[@]}"
}

invoke_case() {
  local id="$1"
  local small="$2"
  local large="$3"

  echo
  echo "==============================="
  echo "Case ${id}"
  echo "==============================="

  local cmd=(./template_matching --small "$small" --large "$large")
  # 只有使用者提供 --blocks 時才附加自訂 block 清單。
  if [[ -n "$BLOCKS" ]]; then
    cmd+=(--blocks "$BLOCKS")
  fi

  "${cmd[@]}"
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_cuda_project
fi

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "[DONE] Build only completed."
  exit 0
fi

cases=(
  # id | 小矩陣路徑 | 大矩陣路徑
  "1|data/1/S1_3_3.txt|data/1/T1_3750_4320.txt"
  "2|data/2/S2_5_5.txt|data/2/T2_7750_1320.txt"
  "3|data/3/S3_3_3.txt|data/3/T3_8140_9925.txt"
  "4|data/4/S4_5_5.txt|data/4/T4_50_50.txt"
  "5|data/5/S5_5_5.txt|data/5/T5_5000_5000.txt"
)

for c in "${cases[@]}"; do
  IFS='|' read -r id small large <<< "$c"
  invoke_case "$id" "$small" "$large"
done

echo
echo "[DONE] All cases finished."
