#!/bin/bash
set -euo pipefail

#PBSWRAP MODULE rocm/7.2.0

REPO_URL="https://github.com/ohara803/amd-genaspen.git"
STAGE_NAME="pbswrap_stage_type0_20261125"

cd "$PBSWRAP_WORK"
stage_root="$PBSWRAP_SRC/$STAGE_NAME"
GENASPEN_SOURCE="$stage_root/genaspen"
MEASUREMENT_SOURCE="$PBSWRAP_DATA"
UV_BIN="$stage_root/bin/uv"
PYTHON_DIST="$stage_root/python"
MEASURE_DRIVER="$MEASUREMENT_SOURCE/measurement/mi300a_measure.py"
PRIOR_ARCHIVE="$MEASUREMENT_SOURCE/runs/51389.pbs/summary/type0_six_kernel_grid_51389.tar.gz"

for required in \
    "$GENASPEN_SOURCE" \
    "$GENASPEN_SOURCE/.venv/lib" \
    "$UV_BIN" \
    "$PYTHON_DIST/bin/python3.13" \
    "$MEASURE_DRIVER" \
    "$PRIOR_ARCHIVE"; do
    if [[ ! -e "$required" ]]; then
        echo "ERROR: PBSWRAP input is missing: $required" >&2
        exit 1
    fi
done

job_number="${PBS_JOBID%%.*}"
if [[ ! "$job_number" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid PBS_JOBID: $PBS_JOBID" >&2
    exit 1
fi

summary_dir="$PBSWRAP_WORK/summary"
experiment_root="$PBSWRAP_WORK/type0_softmax_corrected_${job_number}"
genaspen_work="$PBSWRAP_WORK/genaspen_work"
new_log="$experiment_root/measurement/corrected_softmax.log"
combined_log="$experiment_root/measurement/six_kernel_measurement.log"
preserved_log="$experiment_root/measurement/prior_without_softmax.log"
mkdir -p "$summary_dir" "$experiment_root/logs" \
    "$experiment_root/measurement/power_data" "$experiment_root/timings"
run_log="$summary_dir/run_${job_number}.log"
exec > >(tee "$run_log") 2>&1

record_stage() {
    local stage="$1"
    local started_at="$2"
    local elapsed="$3"
    printf '{"stage":"%s","started_at_utc":"%s","ended_at_utc":"%s","elapsed_seconds":%s,"status":"complete","prompt_tokens":0,"completion_tokens":0}\n' \
        "$stage" "$started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" \
        >> "$experiment_root/timings/job_stages.jsonl"
}

final_status="FAILED"
cleanup() {
    set +e
    cp "$run_log" "$experiment_root/logs/job_${job_number}.log" 2>/dev/null
    printf '%s\n' "$final_status" > "$experiment_root/JOB_STATUS.txt"
    tar -C "$PBSWRAP_WORK" -czf \
        "$summary_dir/type0_softmax_corrected_${job_number}.tar.gz" \
        "$(basename "$experiment_root")"
    cp "$experiment_root/JOB_STATUS.txt" "$summary_dir/"
    if [[ -f "$experiment_root/evaluation/mape_summary.csv" ]]; then
        cp "$experiment_root/evaluation/mape_summary.csv" "$summary_dir/"
    fi
    if [[ -f "$experiment_root/EXECUTION_LOG.md" ]]; then
        cp "$experiment_root/EXECUTION_LOG.md" "$summary_dir/"
    fi
}
trap cleanup EXIT

echo "=== PBS job ==="
echo "PBS_JOBID=$PBS_JOBID"
echo "PBSWRAP_WORK=$PBSWRAP_WORK"

git clone --depth 1 --branch main --single-branch "$REPO_URL" repo
repo_root="$PBSWRAP_WORK/repo"
repo_commit="$(git -C "$repo_root" rev-parse HEAD)"
echo "repo_commit=$repo_commit"
mkdir -p "$experiment_root/input_snapshot"
printf '%s\n' "$repo_commit" > "$experiment_root/input_snapshot/repo_commit.txt"
hipcc --version | tee "$experiment_root/input_snapshot/hipcc_version.txt"
uname -a > "$experiment_root/input_snapshot/uname.txt"
cp "$repo_root/hip_kernels/softmax.hip" \
    "$experiment_root/input_snapshot/softmax.corrected.hip"
cp "$repo_root/hip_kernels_only/softmax_kernel.hip" \
    "$experiment_root/input_snapshot/softmax_kernel.corrected.hip"

echo "=== Extract prior six-kernel data and remove old softmax blocks ==="
mkdir -p "$PBSWRAP_WORK/prior"
tar -xzf "$PRIOR_ARCHIVE" -C "$PBSWRAP_WORK/prior"
prior_log="$PBSWRAP_WORK/prior/type0_six_kernel_grid_51389/measurement/six_kernel_measurement.log"
test -s "$prior_log"
awk '
    /^\[RUN\] softmax / {drop=1}
    /^\[RUN\] gelu / {drop=0}
    !drop {print}
' "$prior_log" > "$preserved_log"
if grep -q '^\[RUN\] softmax ' "$preserved_log"; then
    echo "ERROR: old softmax rows remain after filtering" >&2
    exit 1
fi
test "$(grep -c '^\[RUN\] ' "$preserved_log")" -eq 75

echo "=== Compile corrected softmax HIP program ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
ROCM_PATH="$(hipconfig --rocmpath)"
bin_dir="$PBSWRAP_WORK/bin"
mkdir -p "$bin_dir"
hipcc -std=c++17 -O3 -pthread -x hip \
    "$repo_root/hip_kernels/softmax.hip" \
    -I"$ROCM_PATH/include" -L"$ROCM_PATH/lib" \
    -Wl,-rpath,"$ROCM_PATH/lib" -lamd_smi \
    -o "$bin_dir/softmax"
record_stage "compile_corrected_softmax" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Measure 15 corrected softmax points ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
plan='train 16777216 13135
train 33554432 7092
train 67108864 3546
train 134217728 1826
train 268435456 913
train 536870912 460
train 1073741824 230
train 2147483648 111
target 23726566 9651
target 47453133 5015
target 94906266 2545
target 189812531 1291
target 379625062 648
target 759250125 325
target 1518500250 160'
printf '%s\n' "$plan" | python3 -B -u "$MEASURE_DRIVER" \
    "$bin_dir/softmax" "$experiment_root/measurement/power_data/softmax" \
    | tee "$new_log"
record_stage "measure_15_corrected_softmax_points" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

cp "$preserved_log" "$combined_log"
printf '\n' >> "$combined_log"
cat "$new_log" >> "$combined_log"
test "$(grep -c '^\[RUN\] ' "$combined_log")" -eq 90

echo "=== Create isolated six-kernel GenASPEN copy ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
mkdir -p "$genaspen_work/kernels"
cp -a "$GENASPEN_SOURCE/aspen" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/src" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/llm_assistants" "$genaspen_work/"
cp "$GENASPEN_SOURCE/config.py" "$genaspen_work/"
cp "$GENASPEN_SOURCE/pyproject.toml" "$genaspen_work/"
cp "$GENASPEN_SOURCE/uv.lock" "$genaspen_work/"
cp "$GENASPEN_SOURCE/kernels/kernel_pairs.yaml" "$genaspen_work/kernels/"
cp "$GENASPEN_SOURCE/kernels/run_kernel_size_energy.py" "$genaspen_work/kernels/"
for kernel in axpy copy dot softmax gelu relu; do
    mkdir -p "$genaspen_work/kernels/$kernel"
    cp "$repo_root/type0/cached_apps/$kernel.aspen" \
        "$genaspen_work/kernels/$kernel/app.aspen"
done

mkdir -p "$genaspen_work/.venv/bin"
ln -s "$PYTHON_DIST/bin/python3.13" "$genaspen_work/.venv/bin/python"
ln -s python "$genaspen_work/.venv/bin/python3"
ln -s python "$genaspen_work/.venv/bin/python3.13"
ln -s "$GENASPEN_SOURCE/.venv/lib" "$genaspen_work/.venv/lib"
cp "$GENASPEN_SOURCE/.venv/pyvenv.cfg" "$genaspen_work/.venv/pyvenv.cfg"
sed -i "s#^home =.*#home = $PYTHON_DIST/bin#" \
    "$genaspen_work/.venv/pyvenv.cfg"
python_bin="$genaspen_work/.venv/bin/python"

export PATH="$stage_root/bin:$PATH"
export PYTHONPATH="$genaspen_work:$genaspen_work/src"
export PYTHONDONTWRITEBYTECODE=1
export UV_PYTHON_DOWNLOADS=never
record_stage "stage_six_cached_genaspen_models" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Refit six-kernel coefficients and evaluate 42 points ==="
"$python_bin" "$repo_root/type0/run_type0_six_kernel_grid.py" \
    --genaspen-root "$genaspen_work" \
    --measurement-log "$combined_log" \
    --base-machine \
        "$genaspen_work/aspen/models/machine/sockets/amd_mi300a.aspen" \
    --output-dir "$experiment_root" \
    --wavefront-size 64 \
    --uv "$UV_BIN" \
    --measurement-note \
        "axpy/copy/dot reuse 51388.pbs; gelu/relu reuse 51389.pbs; corrected softmax newly measured by this job."

final_status="SUCCESS"
echo "TYPE0_CORRECTED_SOFTMAX_SUCCESS"
