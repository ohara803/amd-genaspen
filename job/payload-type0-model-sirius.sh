#!/bin/bash
set -euo pipefail

#PBSWRAP MODULE rocm/7.2.0

REPO_URL="https://github.com/ohara803/amd-genaspen.git"
STAGE_NAME="pbswrap_stage_type0_20261125"

cd "$PBSWRAP_WORK"
stage_root="$PBSWRAP_SRC/$STAGE_NAME"
GENASPEN_SOURCE="$stage_root/genaspen"
MEASUREMENT_SOURCE="$PBSWRAP_DATA"
OLLAMA_SOURCE="$stage_root/ollama-v0321"
OLLAMA_MODELS_SOURCE="$stage_root/ollama-models"
UV_BIN="$stage_root/bin/uv"
PYTHON_DIST="$stage_root/python"

for required in \
    "$GENASPEN_SOURCE" \
    "$GENASPEN_SOURCE/.venv/lib" \
    "$OLLAMA_SOURCE/bin/ollama" \
    "$OLLAMA_MODELS_SOURCE" \
    "$UV_BIN" \
    "$PYTHON_DIST/bin/python3.13"; do
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
experiment_root="$PBSWRAP_WORK/type0_axpy_copy_dot_${job_number}"
genaspen_work="$PBSWRAP_WORK/genaspen_work"
mkdir -p "$summary_dir" "$experiment_root/logs" "$experiment_root/input_snapshot"
run_log="$summary_dir/run_${job_number}.log"
exec > >(tee "$run_log") 2>&1

ollama_pid=""
final_status="FAILED"
cleanup() {
    set +e
    if [[ -n "$ollama_pid" ]]; then
        kill "$ollama_pid" 2>/dev/null
        wait "$ollama_pid" 2>/dev/null
    fi
    if [[ -d "$genaspen_work/result_agentic_workflow/generation_debug" ]]; then
        mkdir -p "$experiment_root/generation"
        cp -a "$genaspen_work/result_agentic_workflow/generation_debug" \
            "$experiment_root/generation/"
    fi
    if [[ -d "$genaspen_work/kernels" ]]; then
        mkdir -p "$experiment_root/generated_models"
        for kernel in axpy copy dot; do
            if [[ -d "$genaspen_work/kernels/$kernel" ]]; then
                cp -a "$genaspen_work/kernels/$kernel" \
                    "$experiment_root/generated_models/"
            fi
        done
    fi
    cp "$run_log" "$experiment_root/logs/job_${job_number}.log" 2>/dev/null
    printf '%s\n' "$final_status" > "$experiment_root/JOB_STATUS.txt"
    tar -C "$PBSWRAP_WORK" -czf \
        "$summary_dir/type0_axpy_copy_dot_${job_number}.tar.gz" \
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
printf '%s\n' "$repo_commit" > "$experiment_root/input_snapshot/repo_commit.txt"

echo "=== System inventory and wavefront detection ==="
hipcc --version | tee "$experiment_root/input_snapshot/hipcc_version.txt"
rocminfo > "$experiment_root/input_snapshot/rocminfo.txt" 2>&1 || true
uname -a > "$experiment_root/input_snapshot/uname.txt"
hipcc -O2 "$repo_root/type0/detect_wavefront.cpp" \
    -o "$PBSWRAP_WORK/detect_wavefront"
wavefront_output="$($PBSWRAP_WORK/detect_wavefront)"
printf '%s\n' "$wavefront_output" | tee \
    "$experiment_root/input_snapshot/wavefront.txt"
wavefront_size="$(printf '%s\n' "$wavefront_output" | \
    awk -F= '$1 == "wavefront_size" {print $2}')"
if [[ "$wavefront_size" != "32" && "$wavefront_size" != "64" ]]; then
    echo "ERROR: unexpected or missing wavefront size: $wavefront_size" >&2
    exit 1
fi

echo "=== Snapshot source inputs ==="
cp "$MEASUREMENT_SOURCE/measurement/run_all.sh.o50858" \
    "$experiment_root/input_snapshot/"
cp "$GENASPEN_SOURCE/aspen/models/machine/sockets/amd_mi300a.aspen" \
    "$experiment_root/input_snapshot/amd_mi300a.before.aspen"
cp "$GENASPEN_SOURCE/src/agenticGenASPEN/agenticGenASPEN_cot.py" \
    "$experiment_root/input_snapshot/agenticGenASPEN_cot.before.py"
mkdir -p "$experiment_root/input_snapshot/hip_kernels"
for kernel in axpy copy dot; do
    cp "$MEASUREMENT_SOURCE/hip_kernels_only/${kernel}_kernel.hip" \
        "$experiment_root/input_snapshot/hip_kernels/"
done
find "$experiment_root/input_snapshot" -type f -exec sha256sum {} + \
    > "$experiment_root/input_snapshot/SHA256SUMS"

echo "=== Create isolated GenASPEN working copy ==="
mkdir -p "$genaspen_work/kernels"
cp -a "$GENASPEN_SOURCE/aspen" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/src" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/llm_assistants" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/examples" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/cache" "$genaspen_work/"
cp -a "$GENASPEN_SOURCE/paper" "$genaspen_work/"
cp "$GENASPEN_SOURCE/config.py" "$genaspen_work/"
cp "$GENASPEN_SOURCE/pyproject.toml" "$genaspen_work/"
cp "$GENASPEN_SOURCE/uv.lock" "$genaspen_work/"
cp "$GENASPEN_SOURCE/kernels/kernel_pairs.yaml" "$genaspen_work/kernels/"
cp "$GENASPEN_SOURCE/kernels/run_kernel_size_energy.py" \
    "$genaspen_work/kernels/"
for kernel in axpy copy dot; do
    cp -a "$GENASPEN_SOURCE/kernels/$kernel" "$genaspen_work/kernels/"
done

# Recreate only the writable venv shell.  Its large site-packages directory is
# exposed read-only through PBSWRAP and is never copied or modified.
mkdir -p "$genaspen_work/.venv/bin"
ln -s "$PYTHON_DIST/bin/python3.13" "$genaspen_work/.venv/bin/python"
ln -s python "$genaspen_work/.venv/bin/python3"
ln -s python "$genaspen_work/.venv/bin/python3.13"
ln -s "$GENASPEN_SOURCE/.venv/lib" "$genaspen_work/.venv/lib"
cp "$GENASPEN_SOURCE/.venv/pyvenv.cfg" "$genaspen_work/.venv/pyvenv.cfg"
sed -i "s#^home =.*#home = $PYTHON_DIST/bin#" \
    "$genaspen_work/.venv/pyvenv.cfg"
python_bin="$genaspen_work/.venv/bin/python"

mkdir -p "$genaspen_work/result_agentic_workflow/generation_debug"
cp "$repo_root/type0/inputs.sirius.json" \
    "$genaspen_work/examples/type0_inputs.json"
sed -i \
    "s#/work/CSPP/ohara_803/20261120_amd_genaspen#$MEASUREMENT_SOURCE#g" \
    "$genaspen_work/examples/type0_inputs.json"

"$python_bin" \
    "$repo_root/type0/instrument_genaspen.py" \
    "$genaspen_work/src/agenticGenASPEN/agenticGenASPEN_cot.py"
cp "$genaspen_work/src/agenticGenASPEN/agenticGenASPEN_cot.py" \
    "$experiment_root/input_snapshot/agenticGenASPEN_cot.instrumented.py"

export PATH="$stage_root/bin:$OLLAMA_SOURCE/bin:$PATH"
export PYTHONPATH="$genaspen_work:$genaspen_work/src"
export PYTHONDONTWRITEBYTECODE=1
export UV_PYTHON_DOWNLOADS=never
export OLLAMA_MODELS="$OLLAMA_MODELS_SOURCE"
export OLLAMA_HOST=127.0.0.1:11435
export OLLAMA_IGPU_ENABLE=1
export OLLAMA_CONTEXT_LENGTH=4096
export OLLAMA_KEEP_ALIVE=-1
export NO_PROXY=localhost,127.0.0.1,::1
export no_proxy="$NO_PROXY"
unset LLAMA_ARG_LOAD_MODE || true

echo "=== Start Ollama ==="
ollama serve > "$experiment_root/logs/ollama.log" 2>&1 &
ollama_pid=$!
ready=0
for _ in $(seq 1 60); do
    if curl --noproxy '*' -fsS http://127.0.0.1:11435/api/version \
        > "$experiment_root/input_snapshot/ollama_version.json" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$ollama_pid" 2>/dev/null; then
        echo "ERROR: Ollama exited during startup" >&2
        exit 1
    fi
    sleep 2
done
if [[ "$ready" -ne 1 ]]; then
    echo "ERROR: Ollama startup timeout" >&2
    exit 1
fi

echo "=== Generate axpy/copy/dot application models ==="
generation_timing="$experiment_root/timings/generation_commands.jsonl"
mkdir -p "$experiment_root/logs/generation" "$experiment_root/timings"
for kernel in axpy copy dot; do
    "$python_bin" \
        "$repo_root/type0/run_logged_command.py" \
        --stage "genaspen_${kernel}" \
        --timing-jsonl "$generation_timing" \
        --stdout "$experiment_root/logs/generation/${kernel}.stdout.txt" \
        --stderr "$experiment_root/logs/generation/${kernel}.stderr.txt" \
        --cwd "$genaspen_work" -- \
        "$UV_BIN" run --no-sync \
        src/agenticGenASPEN/agenticGenASPEN_cot.py \
        --ollama --kernel "$kernel" --config examples/type0_inputs.json
done

kill "$ollama_pid" 2>/dev/null || true
wait "$ollama_pid" 2>/dev/null || true
ollama_pid=""

echo "=== Fit coefficients, run official predictions, and evaluate ==="
"$python_bin" \
    "$repo_root/type0/run_type0_analysis.py" \
    --genaspen-root "$genaspen_work" \
    --measurement-log "$MEASUREMENT_SOURCE/measurement/run_all.sh.o50858" \
    --base-machine \
        "$genaspen_work/aspen/models/machine/sockets/amd_mi300a.aspen" \
    --wavefront-size "$wavefront_size" \
    --output-dir "$experiment_root" \
    --uv "$UV_BIN"

final_status="SUCCESS"
echo "TYPE0_JOB_SUCCESS"
