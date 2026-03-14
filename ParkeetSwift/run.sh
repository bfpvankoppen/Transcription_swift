#!/bin/bash
# Build Praten with SPM and create a runnable .app bundle.
# Usage: bash run.sh [--release] [--dmg]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="debug"
MAKE_DMG=false
SWIFT_FLAGS=""
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release"; SWIFT_FLAGS="-c release" ;;
        --dmg) MAKE_DMG=true ;;
    esac
done

BUILD_APP="$SCRIPT_DIR/.build/Praten.app"
CONTENTS="$BUILD_APP/Contents"
MACOS="$CONTENTS/MacOS"

# Install location — ~/Applications/ so macOS recognizes it in permission dialogs
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/Praten.app"

echo "=== Building Praten ($CONFIG) ==="
swift build $SWIFT_FLAGS

echo "=== Creating .app bundle ==="
rm -rf "$BUILD_APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"

# Copy executable (statically linked — no Frameworks/ needed)
cp ".build/$CONFIG/Praten" "$MACOS/Praten"

# Copy model into bundle so the app doesn't depend on the dev source path
MODEL_SRC="$SCRIPT_DIR/Resources/models"
if [ -d "$MODEL_SRC" ]; then
    echo "=== Bundling model ==="
    cp -R "$MODEL_SRC" "$CONTENTS/Resources/models"
fi

# Copy Info.plist
cp "$SCRIPT_DIR/Support/Info.plist" "$CONTENTS/Info.plist"

# Copy app icon
ICON_SRC="$SCRIPT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$CONTENTS/Resources/AppIcon.icns"
fi

# Copy entitlements (used during signing)
ENTITLEMENTS="$SCRIPT_DIR/Support/Praten.entitlements"

# ---------- Code Signing ----------
# Use a stable self-signed certificate so macOS preserves permissions across rebuilds.
# The certificate lives in a dedicated keychain with an empty password so codesign
# never prompts for a password. This is the standard CI/CD approach.
CERT_NAME="Praten Dev"
KEYCHAIN="praten-dev.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN"

# Create the dedicated keychain and certificate if they don't exist yet
if ! security find-identity -v -p codesigning -s "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "=== Setting up code signing certificate ==="

    # Use system LibreSSL — Homebrew OpenSSL 3.x creates incompatible PKCS12 files
    SYSSL=/usr/bin/openssl

    # Generate a self-signed code signing certificate (valid 10 years)
    cat > /tmp/praten-cert.conf <<CERTEOF
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
    $SYSSL req -x509 -newkey rsa:2048 -keyout /tmp/praten-key.pem \
        -out /tmp/praten-cert.pem -days 3650 -nodes \
        -config /tmp/praten-cert.conf 2>/dev/null

    # Create a dedicated keychain with empty password (no prompts ever)
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "" "$KEYCHAIN"

    # Add it to the search list (keep login keychain too)
    EXISTING=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
    security list-keychains -d user -s $EXISTING "$KEYCHAIN_PATH"

    # Import key and certificate into the dedicated keychain
    security import /tmp/praten-key.pem -k "$KEYCHAIN_PATH" -T /usr/bin/codesign
    security import /tmp/praten-cert.pem -k "$KEYCHAIN_PATH" -T /usr/bin/codesign

    # Allow codesign to access the key without prompting
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN_PATH" >/dev/null 2>&1

    # Trust the certificate for code signing
    security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" /tmp/praten-cert.pem

    rm -f /tmp/praten-cert.conf /tmp/praten-key.pem /tmp/praten-cert.pem
    echo "Certificate '$CERT_NAME' ready (no password prompts)."
fi

# Unlock the dedicated keychain (it has an empty password)
security unlock-keychain -p "" "$KEYCHAIN_PATH" 2>/dev/null || true

# Strip resource forks that break code signing
xattr -cr "$BUILD_APP"

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
echo "=== Praten.app ready ==="
echo "Location: $INSTALL_APP"

# ---------- DMG Creation ----------
if $MAKE_DMG; then
    DMG_PATH="$SCRIPT_DIR/.build/Praten.dmg"
    DMG_STAGING="$SCRIPT_DIR/.build/dmg-staging"

    echo ""
    echo "=== Creating DMG ==="
    rm -rf "$DMG_STAGING" "$DMG_PATH"
    mkdir -p "$DMG_STAGING"

    # Copy signed app into staging
    cp -R "$INSTALL_APP" "$DMG_STAGING/Praten.app"

    # Add Applications symlink for drag-to-install
    ln -s /Applications "$DMG_STAGING/Applications"

    # Create compressed DMG
    hdiutil create \
        -volname "Praten" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"

    rm -rf "$DMG_STAGING"

    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo ""
    echo "=== DMG ready ==="
    echo "Location: $DMG_PATH ($DMG_SIZE)"
    echo "Share this file — the recipient drags Praten.app to Applications."
else
    echo ""
    echo "Launching..."
    open "$INSTALL_APP"
fi
