# iOS Simulator (streamed panel)

VS Code / Cursor extension for **macOS** that streams the iOS Simulator window into a webview via **ScreenCaptureKit** and sends **taps** with **SimulatorKit Indigo HID** (private SPI), so touches reach the booted simulator even when its window is **behind other apps**.

This is not true window embedding; it is a live JPEG stream plus host-side HID injection.

## Setup

1. **Xcode** (not only CLT): the helper links **CoreSimulator** and **SimulatorKit** from your active developer dir (`xcode-select -p`).
2. From the repo root:

   ```bash
   npm install
   npm run compile
   npm run build:native
   ```

   `build:native` runs [`native/ios-sim-helper/build.sh`](native/ios-sim-helper/build.sh), which adds framework search paths and **rpath** so the binary finds those frameworks at runtime.

3. Open this folder in VS Code or Cursor, run **Run Extension** (F5).

4. Command Palette: **iOS Simulator: Open streamed panel**.

## Choosing the right window (stream) and device (touch)

**Stream** — windows are filtered by **owning bundle ID** (not title):

1. **iOS Simulator: List capture windows (debug)** → Output **“iOS Simulator Embed”** (NDJSON, largest first).
2. Set **Target Bundle Id** (`ios-simulator-embed.targetBundleId`) or env `IOS_SIM_HELPER_BUNDLE_ID`.

**Touch** — targets the **booted** simulator via CoreSimulator:

- If only one simulator is booted, nothing else is required.
- If several are booted, set **Simulator Udid** (`ios-simulator-embed.simulatorUdid`) or env `IOS_SIM_UDID` (`xcrun simctl list devices | grep Booted`).

**Coordinates** — webview clicks are turned into **normalized (0–1, top-left)** positions over the streamed image. That matches Indigo’s ratio space for the **device surface** only approximately when the JPEG includes window chrome; adjust or crop later if needed.

## macOS permissions

- **Screen Recording**: allow the app that hosts the Extension Host (Cursor / VS Code) for capture.
- **Accessibility** is **not** required for Indigo taps (unlike older `CGEvent` injection).

## Private API / stability

Touch uses **undocumented** Apple frameworks and wire formats; Xcode/Simulator updates can break this. See [`native/ios-sim-helper/THIRD_PARTY.md`](native/ios-sim-helper/THIRD_PARTY.md).

## Limits

- **Performance**: ~12 FPS capture + coalesced webview updates; still CPU-heavy.
- **Packaging**: `.vscodeignore` excludes `native/**/.build`; ship a prebuilt `ios-sim-helper` per arch with the same rpath or an installer that sets `DYLD_FRAMEWORK_PATH` (discouraged for Gatekeeper).

## Native helper CLI

`native/ios-sim-helper/.build/release/ios-sim-helper`:

- `stream` — stderr `BOUNDS:…`, stdout length-prefixed JPEG. Env `IOS_SIM_HELPER_BUNDLE_ID` optional.
- `touch tap <nx> <ny>` — Indigo tap; `nx`,`ny` in `[0,1]` from top-left of the simulated display. Env `IOS_SIM_UDID` optional.
- `list` — NDJSON of shareable macOS windows (debug bundle IDs for streaming).
