# Changelog

All notable changes to WindowRecorder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.5] - 2026-07-15

### Fixed
- TCC permission no longer resets on rebuild — self-signed code-signing certificate
  with `codeSigning` extended key usage is created once and reused
- CI build failure from Swift concurrency — all NSAlert calls dispatched to main thread
- Version comparison in update checker now properly handles semver

## [1.0.4] - 2026-07-15

### Fixed
- Repetitive TCC permission prompts on rebuild — build.sh now skips recompilation
  and re-signing when source files haven't changed (SHA-256 hash check)
- Info.plist now written before code signing (was invalidating the signature)
- Removed use of revoked Apple Development certificate that caused malware warning

## [1.0.3] - 2026-07-15

### Added
- Menu bar UI with live status indicator (green=ready, red=recording)
- "Check for Updates" menu item that queries GitHub releases API
- "List Windows" menu item with alert dialog
- "Stop Recording" menu item
- "About" dialog showing version and app icon
- Version display read from Info.plist

## [1.0.2] - 2026-07-15

### Fixed
- Merged release workflow into auto-tag to fix GitHub Actions tag trigger limitation

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
