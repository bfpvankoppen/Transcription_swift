#!/bin/bash
# Download the Parakeet TDT 0.6B v3 INT8 model for sherpa-onnx
# Model: 25 European languages, ~640MB
#
# Output: Resources/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODEL_DIR="$PROJECT_DIR/Resources/models"
MODEL_NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"

echo "=== Downloading Parakeet TDT 0.6B v3 INT8 model ==="

mkdir -p "$MODEL_DIR"

if [ -d "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "Model already exists at $MODEL_DIR/$MODEL_NAME"
    exit 0
fi

echo "Downloading from $MODEL_URL..."
echo "(This is ~640MB, may take a few minutes)"

cd "$MODEL_DIR"
curl -L -o "${MODEL_NAME}.tar.bz2" "$MODEL_URL"

echo "Extracting..."
tar xjf "${MODEL_NAME}.tar.bz2"
rm "${MODEL_NAME}.tar.bz2"

echo ""
echo "=== Model files ==="
ls -la "$MODEL_DIR/$MODEL_NAME/"
echo ""
echo "Model ready at: $MODEL_DIR/$MODEL_NAME/"
