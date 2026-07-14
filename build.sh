#!/bin/bash
# Build WindowRecorder.app + wr CLI tool
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/Applications/WindowRecorder.app"
BIN_DIR="${HOME}/.local/bin"
HASH_FILE="${HOME}/.local/share/window-recorder/.source_hash"

# Read version from VERSION file
VERSION_FILE="$SCRIPT_DIR/VERSION"
if [ -f "$VERSION_FILE" ]; then
  VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  VERSION="0.0.0-dev"
fi

echo "Building WindowRecorder.app v${VERSION}..."

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$BIN_DIR"
mkdir -p "$(dirname "$HASH_FILE")"

# Ensure stable code signing for TCC persistence
# A self-signed code-signing certificate is created once and reused across
# builds so macOS TCC recognises the same identity (no repeated permission prompts).
CERT_NAME="WindowRecorder Dev"
SIGN_IDENTITY="-"
NEEDS_REBUILD=true
CURRENT_HASH=$(cat "$SCRIPT_DIR/WindowRecorderApp.swift" "$SCRIPT_DIR/wr.swift" "$SCRIPT_DIR/chrome.swift" "$SCRIPT_DIR/mcp.swift" "$SCRIPT_DIR/VERSION" 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$CURRENT_HASH" ]; then
  if codesign --verify --verbose=1 "$APP_DIR" 2>/dev/null; then
    NEEDS_REBUILD=false
  fi
fi

ensure_signing_cert() {
  if security find-identity -p codesigning -v 2>/dev/null | grep -q "$CERT_NAME"; then
    return 0
  fi

  echo "Creating self-signed code-signing certificate '$CERT_NAME' (one-time setup)..."

  TMP_DIR=$(mktemp -d)
  local KEY="$TMP_DIR/wr_key.pem"
  local CSR="$TMP_DIR/wr_csr.pem"
  local CERT="$TMP_DIR/wr_cert.pem"
  local P12="$TMP_DIR/wr_dev.p12"
  local CONF="$TMP_DIR/wr_openssl.cnf"

  cat > "$CONF" << CNF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = $CERT_NAME
[v3_ext]
extendedKeyUsage = codeSigning
basicConstraints = critical,CA:FALSE
keyUsage = digitalSignature
CNF

  openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
    -days 3650 -nodes -config "$CONF" -extensions v3_ext 2>/dev/null

  openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -out "$P12" \
    -passout pass:wrtemp 2>/dev/null

  security import "$P12" -P wrtemp -T /usr/bin/codesign 2>/dev/null

  security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$CERT" 2>/dev/null

  rm -rf "$TMP_DIR"

  if security find-identity -p codesigning -v 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate created and trusted for code signing."
    return 0
  fi
  return 1
}

if [ -n "$CI" ] || ! ensure_signing_cert; then
  SIGN_IDENTITY="-"
  echo "Using ad-hoc signing."
fi

if [ "$NEEDS_REBUILD" = true ]; then
  echo "Source changed or first build, compiling and signing..."

  # Build the app binary
  swiftc \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework AppKit \
    -framework Foundation \
    -O \
    "$SCRIPT_DIR/WindowRecorderApp.swift" \
    -o "$APP_DIR/Contents/MacOS/WindowRecorder" 2>&1 | grep -v warning || true

  chmod +x "$APP_DIR/Contents/MacOS/WindowRecorder"

  # Write Info.plist BEFORE signing
  cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WindowRecorder</string>
    <key>CFBundleIdentifier</key>
    <string>com.falnor.window-recorder</string>
    <key>CFBundleName</key>
    <string>WindowRecorder</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

  # Copy app icon if available
  if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  fi

  # Sign with stable identity (or ad-hoc fallback)
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Warning: No stable signing cert. Using ad-hoc signing (TCC may reset on rebuild)."
  else
    echo "Signing with '$SIGN_IDENTITY'..."
  fi
  codesign --force --sign "$SIGN_IDENTITY" --identifier "com.falnor.window-recorder" "$APP_DIR" 2>&1 || true

  echo "$CURRENT_HASH" > "$HASH_FILE"
else
  echo "No source changes detected, skipping rebuild (TCC permissions preserved)."
fi

echo "App built: $APP_DIR (v${VERSION})"

# Build the CLI tool
echo "Building wr CLI..."
swiftc \
  -framework Foundation \
  -O \
  "$SCRIPT_DIR/wr.swift" \
  "$SCRIPT_DIR/chrome.swift" \
  "$SCRIPT_DIR/mcp.swift" \
  -o "$BIN_DIR/wr" 2>&1 | grep -v warning || true

chmod +x "$BIN_DIR/wr"

echo "CLI installed: $BIN_DIR/wr (v${VERSION})"
echo ""
echo "Usage:"
echo "  wr launch                          Start the recorder daemon"
echo "  wr list                            List available windows"
echo "  wr start --app 'Google Chrome' --out rec.mov --duration 30"
echo "  wr stop                            Stop recording"
echo "  wr status                          Check status"
echo "  wr kill                            Kill the daemon"
echo "  wr e2e e2e/specs/example.json      Run E2E test with recording"
