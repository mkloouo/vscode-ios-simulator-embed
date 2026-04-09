# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.2] - 2026-04-09

### Fixed

- **Modifier chords** (e.g. **⌃⌥Z** or **⌃⌘Z**): webview forwards when **`event.code`** is a known physical key (`KeyA`–`KeyZ`, digits, space, specials), not only when `event.key.length === 1` — fixes empty / control / multi-character `key` values from macOS.
- HID **modifier key-up order** matched **key-down order** incorrectly (using `unshift`), so multi-modifier shortcuts could fail; now press **⌘ → Ctrl → Alt → Shift** and release the **exact reverse** (fixes **⌃⌘** combinations like ⌃⌘Z).

### Notes

- If a chord never reaches the simulator, check **Keyboard Shortcuts** for a host binding on the same keys (documented in README).

## [1.3.1] - 2026-04-09

### Changed

- **Keyboard UX** — Removed the separate ⌨ control. Typing arms on the **first pointer down on the stream image** and turns off when the webview **loses focus**, the document is **hidden**, or the panel tab becomes **inactive** (`onDidChangeViewState`). Pending character buffer is discarded on deactivate (no partial word sent after you click away).

## [1.3.0] - 2026-04-09

### Changed

- **⌨ Keyboard strip** no longer uses AppleScript / Accessibility. Keys are mapped to **USB HID usage** values and sent with **`IndigoHIDMessageForKeyboardArbitrary`** on the **same `touch sess` session** as pointer events (`kp` / `kd` / `ku` stdin lines). Behaves like touches: works when Simulator is not frontmost and tracks **Spaces** like stream/touch.

### Added

- `IOSEmbedHIDSessionSendKeyboard` in the native helper; `touch sess` accepts `kd`, `ku`, `kp` with decimal or `0x` hex usages.
- `src/hidKeyboard.ts` — `ev.code` and ASCII batch mapping for common keys and modifiers.

## [1.2.0] - 2026-04-09

### Added

- **Keyboard strip (⌨)** on the streamed panel: click to focus, then type — keys are forwarded to the booted simulator using **AppleScript** / **System Events** (activate Simulator, keystroke, restore the previous front app). Printable text is batched briefly to reduce round-trips. Arrows, Tab, Return, Escape, delete, Home/End, page keys, F1–F12, and modifier+key chords are supported where the webview delivers the events.
- Setting **`forwardSimulatorKeys`** (default on) hides the strip when disabled.

### Notes

- Host shortcuts may still consume some key chords before the webview sees them. Hardware keyboard layout must match what you expect in the simulator.

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
