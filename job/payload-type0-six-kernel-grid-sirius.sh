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
PRIOR_ARCHIVE="$MEASUREMENT_SOURCE/runs/51388.pbs/summary/type0_runtime_grid_51388.tar.gz"

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
experiment_root="$PBSWRAP_WORK/type0_six_kernel_grid_${job_number}"
genaspen_work="$PBSWRAP_WORK/genaspen_work"
new_log="$experiment_root/measurement/new_three_kernels.log"
combined_log="$experiment_root/measurement/six_kernel_measurement.log"
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
        "$summary_dir/type0_six_kernel_grid_${job_number}.tar.gz" \
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

echo "=== Extract prior axpy/copy/dot measurements ==="
mkdir -p "$PBSWRAP_WORK/prior"
tar -xzf "$PRIOR_ARCHIVE" -C "$PBSWRAP_WORK/prior"
prior_log="$PBSWRAP_WORK/prior/type0_runtime_grid_51388/measurement/measurement.log"
test -s "$prior_log"

echo "=== Compile softmax/gelu/relu HIP programs ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
ROCM_PATH="$(hipconfig --rocmpath)"
bin_dir="$PBSWRAP_WORK/bin"
mkdir -p "$bin_dir"
for kernel in softmax gelu relu; do
    hipcc -std=c++17 -O3 -pthread -x hip \
        "$repo_root/hip_kernels/$kernel.hip" \
        -I"$ROCM_PATH/include" -L"$ROCM_PATH/lib" \
        -Wl,-rpath,"$ROCM_PATH/lib" -lamd_smi \
        -o "$bin_dir/$kernel"
done
record_stage "compile_three_new_hip_programs" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Measure 45 new softmax/gelu/relu points ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
: > "$new_log"
for kernel in softmax gelu relu; do
    echo "[MEASURE] $kernel" | tee -a "$new_log"
    case "$kernel" in
        softmax)
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
            ;;
        gelu)
            plan='train 16777216 12738
train 33554432 6826
train 67108864 3413
train 134217728 1760
train 268435456 880
train 536870912 444
train 1073741824 222
train 2147483648 107
target 23726566 9324
target 47453133 4826
target 94906266 2451
target 189812531 1244
target 379625062 625
target 759250125 314
target 1518500250 154'
            ;;
        relu)
            plan='train 16777216 13373
train 33554432 7260
train 67108864 3630
train 134217728 1874
train 268435456 937
train 536870912 472
train 1073741824 236
train 2147483648 114
target 23726566 9853
target 47453133 5133
target 94906266 2608
target 189812531 1325
target 379625062 665
target 759250125 334
target 1518500250 164'
            ;;
    esac
    printf '%s\n' "$plan" | python3 -B -u "$MEASURE_DRIVER" \
        "$bin_dir/$kernel" "$experiment_root/measurement/power_data/$kernel" \
        | tee -a "$new_log"
done
record_stage "measure_45_new_runtime_power_points" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

cp "$prior_log" "$combined_log"
printf '\n' >> "$combined_log"
cat "$new_log" >> "$combined_log"

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

echo "=== Fit six-kernel coefficients and evaluate 42 held-out points ==="
"$python_bin" "$repo_root/type0/run_type0_six_kernel_grid.py" \
    --genaspen-root "$genaspen_work" \
    --measurement-log "$combined_log" \
    --base-machine \
        "$genaspen_work/aspen/models/machine/sockets/amd_mi300a.aspen" \
    --output-dir "$experiment_root" \
    --wavefront-size 64 \
    --uv "$UV_BIN"

final_status="SUCCESS"
echo "TYPE0_SIX_KERNEL_GRID_SUCCESS"
