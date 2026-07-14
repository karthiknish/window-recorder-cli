# WindowRecorder

A macOS window recording tool built with Swift, ScreenCaptureKit, and AVFoundation.

Records specific windows by name and outputs `.mov` files. Controlled via a Unix domain socket CLI (`wr`).

## Components

- **WindowRecorderApp.swift** — Swift app with ScreenCaptureKit + AVFoundation + Unix socket server
- **wr.swift** — CLI tool that sends JSON commands to the app via Unix domain socket
- **build.sh** — Builds both binaries, installs to `/Applications/WindowRecorder.app` and `~/.local/bin/wr`

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
