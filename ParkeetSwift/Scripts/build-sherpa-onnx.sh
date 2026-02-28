#!/bin/bash
# Build sherpa-onnx for macOS (universal binary: arm64 + x86_64)
# Run this once before building Parkeet in Xcode.
#
# Prerequisites: cmake, git
# Output: ../sherpa-onnx/build-swift-macos/install/{lib,include}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$PROJECT_DIR")/sherpa-onnx"

echo "=== Building sherpa-onnx for macOS ==="

# Clone if not present
if [ ! -d "$REPO_DIR" ]; then
    echo "Cloning sherpa-onnx..."
    git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx.git "$REPO_DIR"
else
    echo "sherpa-onnx already cloned at $REPO_DIR"
fi

cd "$REPO_DIR"

# Build for macOS
if [ ! -d "build-swift-macos/install" ]; then
    echo "Building sherpa-onnx (this may take a few minutes)..."
    mkdir -p build-swift-macos
    cd build-swift-macos
    cmake \
        -DCMAKE_INSTALL_PREFIX=./install \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DSHERPA_ONNX_ENABLE_BINARY=OFF \
        -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
        -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
        -DSHERPA_ONNX_ENABLE_C_API=ON \
        ..
    cmake --build . --config Release --target install -- -j$(sysctl -n hw.ncpu)
    echo "Build complete: $REPO_DIR/build-swift-macos/install/"
else
    echo "sherpa-onnx already built at $REPO_DIR/build-swift-macos/install/"
fi

echo ""
echo "=== Library files ==="
ls -la "$REPO_DIR/build-swift-macos/install/lib/"
echo ""
echo "=== Next steps ==="
echo "1. Open ParkeetSwift in Xcode (xcodegen generate && open Parkeet.xcodeproj)"
echo "2. The project is already configured to find libraries at:"
echo "   $REPO_DIR/build-swift-macos/install/lib/"
echo "3. Download the Parakeet model: bash Scripts/download-model.sh"
