#!/bin/bash
set -euo pipefail

#PBSWRAP MODULE rocm/7.2.0

REPO_URL="https://github.com/ohara803/amd-genaspen.git"

# pbswrap が提供する書き込み可能な作業領域
cd "$PBSWRAP_WORK"
mkdir -p "$PBSWRAP_WORK/summary"
exec > >(tee "$PBSWRAP_WORK/000-run.log") 2>&1

# GitHub から最新コードを取得
git clone --depth 1 --branch main --single-branch "$REPO_URL" repo
cd repo

echo "=== Git commit ==="
git rev-parse HEAD

echo "=== HIP compiler ==="
hipcc --version

# HIP + AMD SMI のコンパイル
export ROCM_PATH="$(hipconfig --rocmpath)"

hipcc -std=c++17 -O3 -pthread -x hip \
    axpy.hip \
    -I"$ROCM_PATH/include" \
    -L"$ROCM_PATH/lib" \
    -Wl,-rpath,"$ROCM_PATH/lib" \
    -lamd_smi \
    -o axpy

echo "=== Running AXPY ==="

# 約 1 GiB のデバイスメモリを使い、電力サンプルを十分に取得する
./axpy 67108864 1000

sample_count="$(awk 'END { print NR - 1 }' power.csv)"
if [[ "$sample_count" -lt 1 ]]; then
    echo "ERROR: power.csv contains no samples" >&2
    exit 1
fi
awk -F, '
    NR > 1 && $2 != "nan" { sum += $2; count++ }
    END {
        if (count == 0) exit 1
        printf "power_samples=%d average_power_W=%.3f\n", count, sum / count
    }
' power.csv

echo "=== Completed ==="

# ジョブ終了後に回収する成果物
cp power.csv "$PBSWRAP_WORK/summary/"
git rev-parse HEAD > "$PBSWRAP_WORK/summary/commit.txt"

echo "AGENT_TEST_SUCCESS"
