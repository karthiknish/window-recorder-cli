#!/bin/bash
# Build WindowRecorder.app + wr CLI tool
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/tmp/WindowRecorder.app"
BIN_DIR="${HOME}/.local/bin"

echo "Building WindowRecorder.app..."

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$BIN_DIR"

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

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
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
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "App built: $APP_DIR"

# Build the CLI tool
echo "Building wr CLI..."
swiftc \
  -framework Foundation \
  -O \
  "$SCRIPT_DIR/wr.swift" \
  -o "$BIN_DIR/wr" 2>&1 | grep -v warning || true

chmod +x "$BIN_DIR/wr"

echo "CLI installed: $BIN_DIR/wr"
echo ""
echo "Usage:"
echo "  wr launch                          Start the recorder daemon"
echo "  wr list                            List available windows"
echo "  wr start --app 'Google Chrome' --out rec.mov --duration 30"
echo "  wr stop                            Stop recording"
echo "  wr status                          Check status"
echo "  wr kill                            Kill the daemon"
