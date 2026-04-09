# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-04-09

### Added

- **Select booted simulator (UDID)** — Command Palette command runs `xcrun simctl list devices booted -j`, lets you pick a booted device, and writes **User** setting `ios-simulator-embed.simulatorUdid` (or clear it). Same UDID flows to stream MAP / Indigo touch (`IOS_SIM_UDID`) and toolbar screenshot (`simctl io`).

### Changed

- **`simulatorUdid` description** — Documents the command and that an empty value defers to default booted-device behavior.
- **Command titles** — **Start streamed panel** / **Stop streamed panel** (paired wording; command IDs unchanged).

### Notes

- **Spaces (Mission Control)** — Documented in README and stream panel hints: Simulator must share the editor’s desktop to **start** capture; after that, moving Simulator can leave stream/touch working while toolbar shortcuts may target the wrong Space.

## [1.0.0] - 2026-04-09

First stable release for macOS.

### Added

- **Streamed panel** — Open the iOS Simulator inside VS Code via ScreenCaptureKit (`ios-sim-helper stream`), length-prefixed JPEG frames to the webview.
- **Touch injection** — Persistent Indigo HID session (`touch sess`) so tap, drag, and long-press work with correct move/up pairing; coordinates mapped using **MAP** letterbox insets from the booted device’s logical screen vs the captured window.
- **MAP options** — `mapStackVerticalLetterboxOnTop` (LCD bottom-aligned vs centered vertical fit); extension validates MAP lines; optional `debugMap` / `MAP_DEBUG` / `MAP_SKIP` diagnostics.
- **Toolbar** — Home (debounced single vs double for app switcher), Screenshot (`simctl` via temp file), Rotate (⌘→); timing configurable under `homeToolbar*` / `homeAfter*` / `homeBetween*` / `homeBefore*` settings.
- **Stream UI** — `streamMaxWidthPx` / `streamMaxHeightPx`, optional `streamShowUsageHint`, toolbar width aligned with the stream column; `streamJpegQuality` → native encoder.
- **Debug** — `debugTouches`, `debugTouchPipeline` (OK/ERR lines, gesture summary), command **Touch / MAP debug checklist**; **List capture windows** (NDJSON).
- **Packaging** — `vscode:prepublish` stages `ios-sim-helper` into `native/ios-sim-helper/dist/` for the VSIX; dev uses `.build/release` when present.
- **Platform** — `extensionKind: ui`, macOS guards on stream/list commands; Apache-2.0 license; marketplace `icon`.

### Notes

- Requires **Xcode** (not only CLT), **Screen Recording** for the host app, and **Accessibility** for toolbar shortcuts that drive Simulator via AppleScript.
- Native helper includes portions derived from Meta [idb](https://github.com/facebook/idb) (MIT); see `native/ios-sim-helper/THIRD_PARTY.md`.
- Touch path relies on private Apple APIs; Xcode/Simulator updates may require fixes.
