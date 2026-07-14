# WindowRecorder

A macOS window recording tool built with Swift, ScreenCaptureKit, and AVFoundation.

Records specific windows by name and outputs `.mov` files. Controlled via a Unix domain socket CLI (`wr`). Includes Chrome DevTools Protocol integration for browser automation and an MCP server for AI agents.

[![Release](https://github.com/karthiknish/window-recorder-cli/actions/workflows/auto-tag.yml/badge.svg)](https://github.com/karthiknish/window-recorder-cli/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Components

- **WindowRecorderApp.swift** — Swift app with ScreenCaptureKit + AVFoundation + Unix socket server + menu bar UI
- **wr.swift** — CLI tool that sends JSON commands to the app via Unix domain socket
- **chrome.swift** — Chrome DevTools Protocol integration (native Swift WebSocket, no Node.js needed)
- **mcp.swift** — MCP server (JSON-RPC over stdio) exposing Chrome recording tools to AI agents
- **build.sh** — Builds both binaries, installs to `/Applications/WindowRecorder.app` and `~/.local/bin/wr`
- **e2e/** — E2E test runner with Chrome DevTools Protocol + WindowRecorder integration

## Download & Install

### From GitHub Releases

1. Go to [Releases](https://github.com/karthiknish/window-recorder-cli/releases)
2. Download the latest release artifacts
3. Run the install script: `bash install.sh`

Or install manually:

```bash
# Download and install
unzip WindowRecorder-v*.app.zip -d /tmp/
cp -R /tmp/WindowRecorder.app /Applications/
cp wr-v* ~/.local/bin/wr
chmod +x ~/.local/bin/wr
```

### Build from Source

```bash
git clone https://github.com/karthiknish/window-recorder-cli.git
cd window-recorder-cli
./build.sh
```

## CLI Commands

```bash
wr launch                          # Launch the recorder app
wr list                            # List available windows
wr start --app "Google Chrome" --out /path/to/output.mov --duration 60
wr start --window <id> --out /path/to/output.mov  # Record specific window by ID
wr stop                            # Stop current recording
wr status                          # Check recording status (window, elapsed, frames, file size)
wr kill                            # Kill the recorder app
```

## Chrome DevTools Protocol

```bash
wr chrome launch [--url <url>]       # Launch Chrome with remote debugging
wr chrome tabs                       # List open Chrome tabs
wr chrome navigate <url>             # Navigate current tab to URL
wr chrome screenshot [--out <path>]  # Take a screenshot
wr chrome click <selector>           # Click an element (trusted CDP pointer events)
  --container <selector>             # Scope click within a container
  --text "label"                     # Click element by text label (fuzzy match)
wr chrome type <selector> <text>     # Type text (React-compatible, char-by-char)
wr chrome press <key>                # Press a key (Enter, Tab, Escape, Space)
wr chrome scroll <selector>          # Scroll to an element
wr chrome evaluate <expr>            # Evaluate JavaScript expression
wr chrome assert <sel> <text>        # Assert element contains text
wr chrome wait <ms>                  # Wait for N milliseconds
wr chrome wait-for-text <sel> <text> [timeout_ms]  # Wait until element contains text
wr chrome snapshot                   # Get page accessibility tree
wr chrome console [--errors]         # Get console messages
wr chrome network                    # List network requests
wr chrome record <url> <dur>         # Record Chrome while navigating (non-blocking)
```

## MCP Server

Run `wr mcp` to start an MCP server (JSON-RPC over stdio) that exposes Chrome recording tools to AI agents.

### MCP Tools

| Tool | Description |
|------|-------------|
| `record_chrome` | Record Chrome window (duration, out) |
| `record_chrome_navigate` | Navigate + record (url, duration, out) |
| `stop_recording` | Stop current recording |
| `recording_status` | Check recording state |
| `chrome_screenshot` | Take screenshot (out) |
| `chrome_navigate` | Navigate to URL (url) |
| `chrome_click` | Click element (selector, container, text) |
| `chrome_type` | Type text (selector, text) |
| `chrome_evaluate` | Evaluate JS (expression) |
| `chrome_press` | Press key (key) |
| `chrome_scroll` | Scroll to element (selector) |
| `chrome_assert` | Assert text content (selector, expected) |
| `chrome_wait` | Wait milliseconds (ms) |
| `chrome_wait_for_text` | Wait until element contains text (selector, text, timeoutMs) |
| `chrome_snapshot` | Get accessibility tree |
| `chrome_tabs` | List Chrome tabs |
| `chrome_network` | List network requests |

## Requirements

- macOS 14+ (ScreenCaptureKit)
- Google Chrome (for CDP integration)
- Screen Recording permission in System Settings > Privacy & Security

## E2E Testing with Recording

The project includes an E2E test runner that integrates Chrome DevTools Protocol (CDP) with WindowRecorder to record test executions.

### Setup

1. Build the project: `./build.sh`
2. Install e2e dependencies: `cd e2e && npm install`

### Running E2E Tests

```bash
# Run a test spec with recording
wr e2e e2e/specs/example.json

# Run without recording
wr e2e e2e/specs/example.json --no-record
```

### Test Spec Format

Create JSON spec files in `e2e/specs/`:

```json
{
  "name": "My Test",
  "url": "http://localhost:3000",
  "app": "Google Chrome",
  "steps": [
    { "action": "navigate", "url": "http://localhost:3000" },
    { "action": "click", "selector": "#login-btn" },
    { "action": "type", "selector": "#email", "text": "user@example.com" },
    { "action": "assert", "selector": "h1", "expected": "Dashboard" },
    { "action": "wait", "ms": 2000 },
    { "action": "screenshot", "path": "screenshots/step1.png" }
  ]
}
```

## CI/CD

### Auto Tag & Release

Every push to `main` that changes the `VERSION` file triggers the [Auto Tag & Release workflow](.github/workflows/auto-tag.yml):
- Creates a git tag `v<version>`
- Builds WindowRecorder.app + `wr` CLI on macOS 14
- Packages artifacts (app zip, CLI binary, e2e tools, install script)
- Creates a GitHub Release with download links and changelog
- Guards against incomplete releases (rebuilds if tag exists but release is missing)

```bash
# Bump version
echo "1.4.0" > VERSION

# Update CHANGELOG.md with new section
# Then commit and push:
git add VERSION CHANGELOG.md
git commit -m "chore: bump to v1.4.0"
git push
```

### Versioning

Version is tracked in [VERSION](VERSION) using [Semantic Versioning](https://semver.org/). Release notes are maintained in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
