#!/bin/bash
# Build Parkeet with SPM and create a runnable .app bundle.
# Usage: bash run.sh [--release]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    SWIFT_FLAGS="-c release"
else
    SWIFT_FLAGS=""
fi

SHERPA_LIB="$SCRIPT_DIR/../sherpa-onnx/build-swift-macos/install/lib"
BUILD_APP="$SCRIPT_DIR/.build/Parkeet.app"
CONTENTS="$BUILD_APP/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"

# Install location — ~/Applications/ so macOS recognizes it in permission dialogs
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/Parkeet.app"

echo "=== Building Parkeet ($CONFIG) ==="
swift build $SWIFT_FLAGS

echo "=== Creating .app bundle ==="
rm -rf "$BUILD_APP"
mkdir -p "$MACOS" "$FRAMEWORKS" "$CONTENTS/Resources"

# Copy executable
cp ".build/$CONFIG/Parkeet" "$MACOS/Parkeet"

# Copy dylibs into Frameworks (preserve versioned names + symlinks)
cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/"
cp "$SHERPA_LIB/libonnxruntime.1.23.2.dylib" "$FRAMEWORKS/"
ln -sf libonnxruntime.1.23.2.dylib "$FRAMEWORKS/libonnxruntime.dylib"

# Fix dylib rpaths so the executable finds them in Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Parkeet" 2>/dev/null || true

# Copy Info.plist
cp "$SCRIPT_DIR/Support/Info.plist" "$CONTENTS/Info.plist"

# Copy entitlements (used during signing)
ENTITLEMENTS="$SCRIPT_DIR/Support/Parkeet.entitlements"

# ---------- Code Signing ----------
# Use a stable self-signed certificate so macOS preserves permissions across rebuilds.
# The certificate lives in a dedicated keychain with an empty password so codesign
# never prompts for a password. This is the standard CI/CD approach.
CERT_NAME="Parkeet Dev"
KEYCHAIN="parkeet-dev.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN"

# Create the dedicated keychain and certificate if they don't exist yet
if ! security find-identity -v -p codesigning -s "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "=== Setting up code signing certificate ==="

    # Use system LibreSSL — Homebrew OpenSSL 3.x creates incompatible PKCS12 files
    SYSSL=/usr/bin/openssl

    # Generate a self-signed code signing certificate (valid 10 years)
    cat > /tmp/parkeet-cert.conf <<CERTEOF
[ req ]
default_bits       = 2048
distinguished_name = req_dn
x509_extensions    = codesign_ext
prompt             = no

[ req_dn ]
CN = $CERT_NAME

[ codesign_ext ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
CERTEOF
    $SYSSL req -x509 -newkey rsa:2048 -keyout /tmp/parkeet-key.pem \
        -out /tmp/parkeet-cert.pem -days 3650 -nodes \
        -config /tmp/parkeet-cert.conf 2>/dev/null

    # Create a dedicated keychain with empty password (no prompts ever)
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "" "$KEYCHAIN"

    # Add it to the search list (keep login keychain too)
    EXISTING=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
    security list-keychains -d user -s $EXISTING "$KEYCHAIN_PATH"

    # Import key and certificate into the dedicated keychain
    security import /tmp/parkeet-key.pem -k "$KEYCHAIN_PATH" -T /usr/bin/codesign
    security import /tmp/parkeet-cert.pem -k "$KEYCHAIN_PATH" -T /usr/bin/codesign

    # Allow codesign to access the key without prompting
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN_PATH" >/dev/null 2>&1

    # Trust the certificate for code signing
    security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" /tmp/parkeet-cert.pem

    rm -f /tmp/parkeet-cert.conf /tmp/parkeet-key.pem /tmp/parkeet-cert.pem
    echo "Certificate '$CERT_NAME' ready (no password prompts)."
fi

# Unlock the dedicated keychain (it has an empty password)
security unlock-keychain -p "" "$KEYCHAIN_PATH" 2>/dev/null || true

echo "=== Signing ==="
codesign --force --deep --sign "$CERT_NAME" \
    --keychain "$KEYCHAIN_PATH" \
    --entitlements "$ENTITLEMENTS" "$BUILD_APP"

# Install to ~/Applications/ so macOS finds it in permission dialogs
echo "=== Installing to ~/Applications/ ==="
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP"
cp -R "$BUILD_APP" "$INSTALL_APP"

# Register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP"

echo ""
echo "=== Parkeet.app ready ==="
echo "Location: $INSTALL_APP"
echo ""
echo "Launching..."
open "$INSTALL_APP"
