# Changelog

All notable changes to WindowRecorder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-07-15

### Added
- AI-generated app icon (AppIcon.icns) with all macOS sizes (16x16–512x512@2x)
- App icon integrated into app bundle Resources and Info.plist

### Fixed
- Release workflow now auto-tags on VERSION changes pushed to main

## [1.0.0] - 2026-07-14

### Added
- macOS window recording via ScreenCaptureKit + AVFoundation
- CLI tool (`wr`) with commands: launch, list, start, stop, status, kill
- Unix domain socket protocol for daemon communication
- E2E test runner with Chrome DevTools Protocol integration
- JSON-based test spec format with actions: navigate, click, type, assert, screenshot, wait, scroll, select, press, evaluate
- `wr e2e` subcommand for orchestrated E2E test runs with recording
- GitHub Actions CI for automated builds and releases
- Version-controlled packaging with downloadable artifacts
