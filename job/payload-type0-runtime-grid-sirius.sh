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

for required in \
    "$GENASPEN_SOURCE" \
    "$GENASPEN_SOURCE/.venv/lib" \
    "$UV_BIN" \
    "$PYTHON_DIST/bin/python3.13" \
    "$MEASURE_DRIVER"; do
    if [[ ! -e "$required" ]]; then
        echo "ERROR: PBSWRAP stage input is missing: $required" >&2
        exit 1
    fi
done

job_number="${PBS_JOBID%%.*}"
if [[ ! "$job_number" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid PBS_JOBID: $PBS_JOBID" >&2
    exit 1
fi

summary_dir="$PBSWRAP_WORK/summary"
experiment_root="$PBSWRAP_WORK/type0_runtime_grid_${job_number}"
genaspen_work="$PBSWRAP_WORK/genaspen_work"
measurement_log="$experiment_root/measurement/measurement.log"
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
        "$summary_dir/type0_runtime_grid_${job_number}.tar.gz" \
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
echo "run_log=$run_log"

git clone --depth 1 --branch main --single-branch "$REPO_URL" repo
repo_root="$PBSWRAP_WORK/repo"
repo_commit="$(git -C "$repo_root" rev-parse HEAD)"
echo "repo_commit=$repo_commit"
mkdir -p "$experiment_root/input_snapshot"
printf '%s\n' "$repo_commit" > "$experiment_root/input_snapshot/repo_commit.txt"
hipcc --version | tee "$experiment_root/input_snapshot/hipcc_version.txt"
uname -a > "$experiment_root/input_snapshot/uname.txt"

echo "=== Compile unchanged HIP measurement programs ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
ROCM_PATH="$(hipconfig --rocmpath)"
bin_dir="$PBSWRAP_WORK/bin"
mkdir -p "$bin_dir"
for kernel in axpy copy dot; do
    hipcc -std=c++17 -O3 -pthread -x hip \
        "$repo_root/hip_kernels/$kernel.hip" \
        -I"$ROCM_PATH/include" -L"$ROCM_PATH/lib" \
        -Wl,-rpath,"$ROCM_PATH/lib" -lamd_smi \
        -o "$bin_dir/$kernel"
done
record_stage "compile_three_hip_programs" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Measure 8 training and 7 held-out sizes per kernel ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
: > "$measurement_log"
for kernel in axpy copy dot; do
    echo "[MEASURE] $kernel" | tee -a "$measurement_log"
    case "$kernel" in
        axpy|dot)
            plan='train 16777216 10144
train 33554432 5382
train 67108864 2691
train 134217728 1378
train 268435456 689
train 536870912 346
train 1073741824 173
train 2147483648 87
target 23726566 7390
target 47453133 3805
target 94906266 1926
target 189812531 974
target 379625062 488
target 759250125 245
target 1518500250 123'
            ;;
        copy)
            plan='train 16777216 13541
train 33554432 7304
train 67108864 3652
train 134217728 1880
train 268435456 940
train 536870912 472
train 1073741824 236
train 2147483648 118
target 23726566 9945
target 47453133 5164
target 94906266 2620
target 189812531 1329
target 379625062 666
target 759250125 334
target 1518500250 167'
            ;;
    esac
    printf '%s\n' "$plan" | python3 -B -u "$MEASURE_DRIVER" \
        "$bin_dir/$kernel" "$experiment_root/measurement/power_data/$kernel" \
        | tee -a "$measurement_log"
done
record_stage "measure_45_runtime_power_points" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Create isolated GenASPEN prediction copy ==="
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
for kernel in axpy copy dot; do
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
record_stage "stage_cached_genaspen_models" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

echo "=== Fit one bandwidth, apply it, predict, and evaluate ==="
stage_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stage_started_seconds=$SECONDS
"$python_bin" "$repo_root/type0/run_type0_runtime_grid.py" \
    --genaspen-root "$genaspen_work" \
    --measurement-log "$measurement_log" \
    --base-machine \
        "$genaspen_work/aspen/models/machine/sockets/amd_mi300a.aspen" \
    --output-dir "$experiment_root" \
    --uv "$UV_BIN"
record_stage "fit_predict_evaluate" "$stage_started_at" \
    "$((SECONDS - stage_started_seconds))"

final_status="SUCCESS"
echo "TYPE0_RUNTIME_GRID_SUCCESS"
