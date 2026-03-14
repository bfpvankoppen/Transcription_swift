#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/../Resources/models"

ONNX_URL="https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model_qint8_arm64.onnx"
VOCAB_URL="https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/vocab.txt"

ONNX_FILE="$MODEL_DIR/all-MiniLM-L6-v2-int8.onnx"
VOCAB_FILE="$MODEL_DIR/vocab.txt"

mkdir -p "$MODEL_DIR"

if [ -f "$ONNX_FILE" ]; then
    echo "Embedding model already downloaded: $ONNX_FILE"
else
    echo "Downloading all-MiniLM-L6-v2 INT8 ONNX model (~6MB)..."
    curl -L -o "$ONNX_FILE" "$ONNX_URL"
    echo "Downloaded: $ONNX_FILE"
fi

if [ -f "$VOCAB_FILE" ]; then
    echo "Vocab already downloaded: $VOCAB_FILE"
else
    echo "Downloading vocab.txt (~230KB)..."
    curl -L -o "$VOCAB_FILE" "$VOCAB_URL"
    echo "Downloaded: $VOCAB_FILE"
fi

echo ""
echo "Embedding model ready:"
ls -lh "$ONNX_FILE" "$VOCAB_FILE"
