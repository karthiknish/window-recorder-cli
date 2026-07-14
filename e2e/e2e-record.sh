#!/bin/bash
# e2e-record.sh — Orchestrate E2E test with WindowRecorder recording
# 
# Usage:
#   ./e2e/e2e-record.sh [spec-file] [--no-record]
#
# This script:
#   1. Launches Chrome with remote debugging enabled
#   2. Launches the WindowRecorder daemon
#   3. Starts recording the Chrome window
#   4. Runs the E2E test spec via the Node.js runner
#   5. Stops recording and cleans up

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC_FILE=""
RECORD=true
CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CDP_PORT=9222

for arg in "$@"; do
  case "$arg" in
    --no-record) RECORD=false ;;
    --help|-h)
      echo "Usage: $0 [spec-file] [--no-record]"
      echo "  spec-file  Path to JSON test spec (default: e2e/specs/example.json)"
      echo "  --no-record  Run tests without recording"
      exit 0
      ;;
    *) SPEC_FILE="$arg" ;;
  esac
done

if [ -z "$SPEC_FILE" ]; then
  SPEC_FILE="$SCRIPT_DIR/specs/example.json"
fi

if [ ! -f "$SPEC_FILE" ]; then
  echo "Error: Spec file not found: $SPEC_FILE"
  exit 1
fi

echo "=========================================="
echo "  E2E Test Runner with Recording"
echo "  Spec:   $SPEC_FILE"
echo "  Record: $RECORD"
echo "=========================================="

# ─── 1. Launch Chrome with remote debugging ────────────────────────────
echo "[setup] Launching Chrome with remote debugging on port $CDP_PORT..."

# Check if Chrome is already running with debugging port
if curl -s "http://localhost:$CDP_PORT/json/version" > /dev/null 2>&1; then
  echo "[setup] Chrome already running with remote debugging"
else
  "$CHROME_PATH" --remote-debugging-port=$CDP_PORT --user-data-dir=/tmp/chrome-e2e-profile &
  CHROME_PID=$!
  echo "[setup] Chrome launched (PID: $CHROME_PID)"
  
  # Wait for CDP to be ready
  for i in $(seq 1 15); do
    if curl -s "http://localhost:$CDP_PORT/json/version" > /dev/null 2>&1; then
      echo "[setup] Chrome DevTools ready"
      break
    fi
    sleep 1
  done
fi

# ─── 2. Launch WindowRecorder if recording ─────────────────────────────
if [ "$RECORD" = true ]; then
  echo "[setup] Launching WindowRecorder..."
  wr launch 2>/dev/null || true
  sleep 1
fi

# ─── 3. Run E2E tests ──────────────────────────────────────────────────
echo "[run] Starting E2E test runner..."
cd "$SCRIPT_DIR"

if [ "$RECORD" = true ]; then
  node runner.js --spec "$SPEC_FILE" --record
else
  node runner.js --spec "$SPEC_FILE"
fi

EXIT_CODE=$?

# ─── 4. Cleanup ────────────────────────────────────────────────────────
echo "[cleanup] Done. Exit code: $EXIT_CODE"

exit $EXIT_CODE
