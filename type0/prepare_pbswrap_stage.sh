#!/bin/bash
set -euo pipefail

# Run on the Sirius login node.  This creates new directory entries only;
# large immutable inputs are hard-linked instead of physically duplicated.
BASE=/work/CSPP/ohara_803
PROJECT="$BASE/20261120_amd_genaspen"
SOURCE="$BASE/genaspen"
STAGE="$PROJECT/pbswrap_stage_type0_20261125"
PYTHON_LINK=/home/CSPP/ohara_803/.local/share/uv/python/cpython-3.13-linux-x86_64-gnu
PYTHON_SOURCE="$(readlink -f "$PYTHON_LINK")"
UV_SOURCE=/home/CSPP/ohara_803/.local/bin/uv

if [[ -e "$STAGE" ]]; then
    echo "ERROR: stage already exists: $STAGE" >&2
    exit 1
fi

mkdir -p "$STAGE/genaspen/kernels" "$STAGE/bin"

for directory in aspen src llm_assistants examples cache paper .venv; do
    cp -al "$SOURCE/$directory" "$STAGE/genaspen/"
done
for file in config.py pyproject.toml uv.lock; do
    cp -al "$SOURCE/$file" "$STAGE/genaspen/"
done
cp -al "$SOURCE/kernels/kernel_pairs.yaml" "$STAGE/genaspen/kernels/"
cp -al "$SOURCE/kernels/run_kernel_size_energy.py" \
    "$STAGE/genaspen/kernels/"
for kernel in axpy copy dot; do
    cp -al "$SOURCE/kernels/$kernel" "$STAGE/genaspen/kernels/"
done

cp -al "$BASE/ollama-v0321" "$STAGE/"
cp -al "$BASE/ollama/models" "$STAGE/ollama-models"
# /home and /work are separate mounts on Sirius even when stat(2) reports the
# same device number.  These two small inputs must therefore be real copies.
cp -a "$PYTHON_SOURCE" "$STAGE/python"
cp -a "$UV_SOURCE" "$STAGE/bin/uv"

for required in \
    "$STAGE/genaspen/aspen/tools/prediction/gpu_runtime_prediction" \
    "$STAGE/genaspen/.venv/lib" \
    "$STAGE/ollama-v0321/bin/ollama" \
    "$STAGE/ollama-models" \
    "$STAGE/python/bin/python3.13" \
    "$STAGE/bin/uv"; do
    test -e "$required"
done

echo "stage=$STAGE"
echo "stage_files=$(find "$STAGE" -xdev -type f | wc -l)"
echo "hardlink_check=$(stat -c %h "$STAGE/ollama-v0321/bin/ollama")"
sha256sum \
    "$STAGE/genaspen/src/agenticGenASPEN/agenticGenASPEN_cot.py" \
    "$STAGE/genaspen/aspen/models/machine/sockets/amd_mi300a.aspen" \
    "$STAGE/ollama-v0321/bin/ollama" \
    "$STAGE/bin/uv"
