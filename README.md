# WindowRecorder

A macOS window recording tool built with Swift, ScreenCaptureKit, and AVFoundation.

Records specific windows by name and outputs `.mov` files. Controlled via a Unix domain socket CLI (`wr`). Includes E2E test runner with Chrome DevTools Protocol integration for recorded browser testing.

[![CI](https://github.com/karthiknish/window-recorder-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/karthiknish/window-recorder-cli/actions/workflows/ci.yml)
[![Release](https://github.com/karthiknish/window-recorder-cli/actions/workflows/release.yml/badge.svg)](https://github.com/karthiknish/window-recorder-cli/releases)

## Components

- **WindowRecorderApp.swift** — Swift app with ScreenCaptureKit + AVFoundation + Unix socket server
- **wr.swift** — CLI tool that sends JSON commands to the app via Unix domain socket
- **build.sh** — Builds both binaries, installs to `/Applications/WindowRecorder.app` and `~/.local/bin/wr`
- **e2e/** — E2E test runner with Chrome DevTools Protocol + WindowRecorder integration
- **.github/workflows/** — CI (build/test) and Release (package/publish) workflows

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
wr start --app "AppName" --out /path/to/output.mov --duration 60
wr stop                            # Stop current recording
wr status                          # Check recording status
wr kill                            # Kill the recorder app
```

## Requirements

- macOS 14+ (ScreenCaptureKit)
- Screen Recording permission in System Settings > Privacy & Security

## Build

```bash
./build.sh
```

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

# Run directly via the shell script
./e2e/e2e-record.sh e2e/specs/example.json

# Run directly via Node.js
cd e2e && node runner.js --spec specs/example.json --record
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

### Available Actions

| Action      | Fields                              | Description                     |
|-------------|-------------------------------------|---------------------------------|
| `navigate`  | `url`                               | Navigate to a URL               |
| `click`     | `selector`                          | Click an element                |
| `type`      | `selector`, `text`                  | Type text into an input         |
| `select`    | `selector`, `value`                 | Select an option                |
| `press`     | `key`                               | Press a key (Enter, Tab, etc.)  |
| `scroll`    | `selector`                          | Scroll to an element            |
| `assert`    | `selector`, `expected`              | Assert element text contains    |
| `wait`      | `ms`                                | Wait for N milliseconds         |
| `screenshot`| `path` (optional)                   | Take a screenshot               |
| `evaluate`  | `expression`, `expected` (optional) | Evaluate JS and optionally assert |

### How It Works

1. **Chrome** is launched with `--remote-debugging-port=9222`
2. **WindowRecorder** is launched and starts recording the Chrome window
3. **Node.js runner** connects to Chrome via CDP WebSocket and executes test steps
4. **Recording stops** after tests complete, producing a `.mov` file
5. **Results** are written to `e2e/results.json` with pass/fail per step

### Using with Chrome MCP

The Chrome DevTools MCP tools can be used alongside the E2E runner for interactive testing:

1. Use Chrome MCP tools (`chrome-devtools_navigate_page`, `chrome-devtools_click`, etc.) to interact with the page
2. Use `wr start` / `wr stop` to control recording around specific interactions
3. Use the E2E runner for automated, repeatable test scenarios

### Recordings

Recordings are saved to `recordings/` with the test name and timestamp. Screenshots are saved to `e2e/screenshots/`.

## CI/CD

### Continuous Integration

Every push to `main` and every PR triggers [CI](.github/workflows/ci.yml):
- Builds WindowRecorder.app + `wr` CLI on macOS 14
- Verifies CLI and E2E runner
- Uploads build artifacts (retained 30 days)

### Releases

Push a tag `v*` to trigger the [Release workflow](.github/workflows/release.yml):
- Builds and packages all artifacts
- Creates a GitHub Release with download links and install instructions
- Extracts release notes from [CHANGELOG.md](CHANGELOG.md)

```bash
# Bump version
echo "1.1.0" > VERSION

# Update CHANGELOG.md with new section
# Then commit and tag:
git add VERSION CHANGELOG.md
git commit -m "release: v1.1.0"
git tag v1.1.0
git push origin main --tags
```

### Versioning

Version is tracked in [VERSION](VERSION) using [Semantic Versioning](https://semver.org/). Release notes are maintained in [CHANGELOG.md](CHANGELOG.md).
