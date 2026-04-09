# iOS Simulator (streamed panel)

VS Code / Cursor extension for **macOS** that streams the iOS Simulator window into a webview via **ScreenCaptureKit** and forwards **left-clicks** with **CGEvent**.

This is not true window embedding; it is a live JPEG stream plus synthetic pointer events.

## Setup

1. **Xcode Command Line Tools** (or Xcode) so `swift` is available.
2. From the repo root:

   ```bash
   npm install
   npm run compile
   npm run build:native
   ```

3. Open this folder in VS Code or Cursor, run **Run Extension** (F5).

4. Command Palette: **iOS Simulator: Open streamed panel**.

## Choosing the right window (bundle ID)

Capture targets are chosen by **owning app bundle ID**, not window title (titles like `main` also appear on VS Code/Cursor).

1. Command Palette: **iOS Simulator: List capture windows (debug)** — opens the **“iOS Simulator Embed”** output with one **NDJSON** line per window (`bundleId`, `appName`, `title`, `windowID`, frame, `area`). Lines are sorted by area (largest first).
2. Copy the Simulator row’s `bundleId` into Settings → **iOS Simulator Embed: Target Bundle Id** (`ios-simulator-embed.targetBundleId`), or set env **`IOS_SIM_HELPER_BUNDLE_ID`** when launching the editor (same value the helper reads).

CLI: `native/ios-sim-helper/.build/release/ios-sim-helper list`

## macOS permissions

- **Screen Recording**: allow **Cursor** or **Visual Studio Code** (whichever hosts the Extension Host) when macOS prompts. Without this, capture can fail or show black frames.
- **Accessibility**: synthetic clicks often require Accessibility permission for the same app. Enable it under **System Settings → Privacy & Security → Accessibility** if taps do nothing.

## Limits

- **Coordinate mapping** assumes `SCWindow.frame` matches Quartz space used by `CGEvent`; multi-display or unusual scaling may need tweaks.
- **Performance**: stream is throttled (~12 FPS capture + coalesced webview updates); still CPU-heavy.
- **Packaging**: `.vscodeignore` excludes `native/**/.build`; for a `.vsix` you would ship a prebuilt `ios-sim-helper` binary (per architecture) under a path your extension resolves.

## Native helper CLI

Built at `native/ios-sim-helper/.build/release/ios-sim-helper`:

- `ios-sim-helper stream` — writes `BOUNDS:{json}\n` to stderr, then length-prefixed JPEG frames to stdout. Optional env `IOS_SIM_HELPER_BUNDLE_ID` restricts candidates to that bundle.
- `ios-sim-helper click <x> <y>` — left click at Quartz global coordinates.
- `ios-sim-helper list` — prints all shareable windows as NDJSON (debug).
