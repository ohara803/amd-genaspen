#!/bin/bash
set -euo pipefail

#PBSWRAP MODULE rocm/7.2.0

REPO_URL="https://github.com/ohara803/amd-genaspen.git"

# pbswrap が提供する書き込み可能な作業領域
cd "$PBSWRAP_WORK"

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
    axpy.hip.cpp \
    -I"$ROCM_PATH/include" \
    -L"$ROCM_PATH/lib" \
    -Wl,-rpath,"$ROCM_PATH/lib" \
    -lamd_smi \
    -o axpy

echo "=== Running AXPY ==="

# 約 1 GiB のデバイスメモリを使い、電力サンプルを十分に取得する
./axpy 67108864 1000

echo "=== Completed ==="

# ジョブ終了後に回収する成果物
mkdir -p "$PBSWRAP_WORK/summary"
cp power.csv "$PBSWRAP_WORK/summary/"
git rev-parse HEAD > "$PBSWRAP_WORK/summary/commit.txt"

echo "AGENT_TEST_SUCCESS"
