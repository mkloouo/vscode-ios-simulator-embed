// =============================================================================
// ios-sim-helper — small macOS command-line tool for the VS Code extension
// =============================================================================
//
// Modes (first argument):
//   stream — picks a Simulator window by **bundle ID** (see findSimulatorWindow), captures
//            it with ScreenCaptureKit, writes JPEG frames to stdout (length-prefixed).
//            Sends one BOUNDS line on stderr for click mapping.
//   touch tap|down|up|move|longpress|swipe — Indigo HID (ratios 0…1 in device space; works when Simulator is obscured).
//   list   — prints every shareable on-screen window as **NDJSON** (debug: bundleId, title, …).
//
// The extension spawns this binary; it is not a .app bundle, so we must
// explicitly connect to the Window Server (see connectToWindowServer).
//
// Swift notes (if you are new to the language):
//   • `async` / `await` — asynchronous functions; `await` suspends until done.
//   • `throws` / `try` — functions that can fail with an Error; caller uses try.
//   • `guard` — early exit unless a condition holds (keeps “happy path” unindented).
//   • `?` after a type — optional (may be nil); `??` supplies a default if nil.
//   • `@MainActor` — run this code on the main UI thread (required for much of AppKit).
//   • `final class` — class that cannot be subclassed; NSObject is Apple’s Obj‑C base.
// =============================================================================

import AppKit
import CoreGraphics
import IndigoTouch
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Window Server bootstrap

/// Hooks this process into macOS’s graphics/window system (“Window Server”).
///
/// A normal .app does this automatically. A bare CLI executable does not—but
/// ScreenCaptureKit and many CoreGraphics calls still require it. If we skip this,
/// you can get `CGS_REQUIRE_INIT` assertions inside Apple’s frameworks.
///
/// `NSApplication.shared` creates the singleton app object; `.accessory` means we
/// behave like a background helper (no dock icon, no menu bar app requirement).
private func connectToWindowServer() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
}

// MARK: - Errors

/// Simple error type we can print or throw. `CustomStringConvertible` means it
/// stringifies for `"\(error)"` via the `description` property.
enum HelperError: Error, CustomStringConvertible {
  case usage
  case noSimulatorWindow(String)
  case streamFailed(String)

  var description: String {
    switch self {
    case .usage:
      return """
      Usage:
        ios-sim-helper stream                    # capture (stderr BOUNDS + optional MAP, stdout JPEG frames)
        ios-sim-helper touch tap <nx> <ny>
        ios-sim-helper touch down <nx> <ny> | up <nx> <ny> | move <nx> <ny>
        ios-sim-helper touch sess                 # stdin lines: d nx ny | m nx ny | u nx ny | q (one HID client)
        ios-sim-helper touch longpress <nx> <ny> [<holdMs>]   # default hold 600 ms
        ios-sim-helper touch swipe <x1> <y1> <x2> <y2> [<durationMs>]  # default 300 ms
        ios-sim-helper list                      # NDJSON: all windows (bundle IDs for stream)

      Coordinates nx, ny are [0,1] from top-left of the simulated display (after stream MAP letterbox in the extension).

      Optional environment:
        IOS_SIM_HELPER_BUNDLE_ID=<id>            # stream: filter windows by owning bundle id
        IOS_SIM_UDID=<uuid>                      # touch / MAP: booted device UDID (if multiple simulators booted)
      """
    case .noSimulatorWindow(let hint):
      return "No capture window found. \(hint)"
    case .streamFailed(let msg):
      return "Stream error: \(msg)"
    }
  }
}

// MARK: - Finding the Simulator window

/// Bundle IDs that usually own Simulator UI. **Do not** match on window title — titles like
/// “main” also appear on VS Code / Cursor (`main` branch), which led to capturing the wrong app.
private func isDefaultSimulatorBundle(_ bundleId: String) -> Bool {
  if bundleId == "com.apple.iphonesimulator" { return true }
  if bundleId.hasPrefix("com.apple.CoreSimulator.") { return true }
  return false
}

/// Asks ScreenCaptureKit for on-screen windows, filters by **bundle ID only**, then picks the largest.
///
/// Set `IOS_SIM_HELPER_BUNDLE_ID` to an exact id from `ios-sim-helper list` if the default list misses your setup.
@MainActor
private func findSimulatorWindow() async throws -> SCWindow {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  let envBid =
    ProcessInfo.processInfo.environment["IOS_SIM_HELPER_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    ?? ""

  let candidates = content.windows.filter { window in
    let bid = window.owningApplication?.bundleIdentifier ?? ""
    if envBid.isEmpty {
      return isDefaultSimulatorBundle(bid)
    }
    return bid == envBid
  }

  let sized = candidates.filter { $0.frame.width >= 120 && $0.frame.height >= 120 }
  func area(_ w: SCWindow) -> CGFloat { w.frame.width * w.frame.height }
  guard let best = sized.max(by: { area($0) < area($1) })
  else {
    let hint: String
    if envBid.isEmpty {
      hint =
        "Open Simulator with a booted device, or run `ios-sim-helper list` and set IOS_SIM_HELPER_BUNDLE_ID to the Simulator row’s bundleId."
    } else {
      hint =
        "No on-screen window with bundle id \"\(envBid)\". Run `ios-sim-helper list` and copy the exact bundleId for the Simulator window."
    }
    throw HelperError.noSimulatorWindow(hint)
  }
  return best
}

// MARK: - Debug: list windows

/// One line per window, NDJSON. Use to discover `bundleId` / `windowID` without guessing from titles.
@MainActor
private func listCaptureCandidates() async throws {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

  struct Row: Encodable {
    let bundleId: String
    let appName: String
    let title: String
    let windowID: UInt64
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let area: Double
  }

  var rows: [Row] = []
  for w in content.windows {
    let bid = w.owningApplication?.bundleIdentifier ?? ""
    let name = w.owningApplication?.applicationName ?? ""
    let title = w.title ?? ""
    let f = w.frame
    let wid = UInt64(w.windowID)
    rows.append(
      Row(
        bundleId: bid,
        appName: name,
        title: title,
        windowID: wid,
        x: Double(f.origin.x),
        y: Double(f.origin.y),
        width: Double(f.width),
        height: Double(f.height),
        area: Double(f.width * f.height)))
  }
  rows.sort { $0.area > $1.area }

  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  for r in rows {
    let data = try enc.encode(r)
    if let line = String(data: data, encoding: .utf8) {
      print(line)
    }
  }
}

// MARK: - Frame encoding (video sample → JPEG bytes)

/// Converts one video frame (`CMSampleBuffer`) from the capture pipeline into JPEG `Data`.
///
/// Pipeline: pixel buffer → Core Image → `CGImage` → ImageIO JPEG encoder.
/// We compress a bit to keep bandwidth reasonable for the extension/webview.
/// Reusing one `CIContext` avoids creating a new Metal/GL context every frame (big CPU/GPU win).
private let sharedJPEGContext = CIContext(options: [.useSoftwareRenderer: false])

private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
  guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
  let ciImage = CIImage(cvPixelBuffer: buffer)
  guard let cgImage = sharedJPEGContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
  let data = NSMutableData()
  guard
    let dest = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
  else { return nil }
  let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.55]
  CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return data as Data
}

// MARK: - Indigo HID touch (private SimulatorKit SPI)

/// `phase`: 1 = down, 2 = up, 0 = move (mapped to NSEvent left-mouse-dragged in native code).
private func hidSendPhase(normX: Double, normY: Double, phase: Int32) -> String? {
  var err = [CChar](repeating: 0, count: 512)
  guard IOSEmbedLoadSimulatorFrameworks() else {
    return "Failed to load CoreSimulator / SimulatorKit (is Xcode installed?)"
  }
  let udid: String? = ProcessInfo.processInfo.environment["IOS_SIM_UDID"]
  guard IOSEmbedHIDSendTouch(udid, normX, normY, Int32(phase), &err, err.count) else {
    return String(cString: err)
  }
  return nil
}

/// Short down–up for a tap (single process; useful for scripts).
private func runTouchTap(normX: Double, normY: Double) -> String? {
  if let e = hidSendPhase(normX: normX, normY: normY, phase: 1) { return e }
  usleep(25_000)
  return hidSendPhase(normX: normX, normY: normY, phase: 2)
}

private func runTouchLongPress(normX: Double, normY: Double, holdMs: Int) -> String? {
  if let e = hidSendPhase(normX: normX, normY: normY, phase: 1) { return e }
  usleep(useconds_t(max(1, holdMs)) * 1000)
  return hidSendPhase(normX: normX, normY: normY, phase: 2)
}

private func runTouchSwipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMs: Int) -> String? {
  let udid: String? = ProcessInfo.processInfo.environment["IOS_SIM_UDID"]
  var openErr = [CChar](repeating: 0, count: 512)
  guard let session = IOSEmbedHIDSessionOpen(udid, &openErr, openErr.count) else {
    return String(cString: openErr)
  }
  defer { IOSEmbedHIDSessionClose(session) }

  let dur = max(16, durationMs)
  let steps = max(8, dur / 16)
  let stepDelayUs = useconds_t(max(1000, (dur * 1000) / steps))

  func send(_ phase: Int32, _ nx: Double, _ ny: Double) -> String? {
    var err = [CChar](repeating: 0, count: 512)
    guard IOSEmbedHIDSessionSend(session, nx, ny, phase, &err, err.count) else {
      return String(cString: err)
    }
    return nil
  }

  if let e = send(1, x1, y1) { return e }
  if steps <= 1 {
    usleep(stepDelayUs)
    return send(2, x2, y2)
  }
  for i in 1..<steps {
    let t = Double(i) / Double(steps - 1)
    let nx = x1 + (x2 - x1) * t
    let ny = y1 + (y2 - y1) * t
    if let e = send(0, nx, ny) { return e }
    usleep(stepDelayUs)
  }
  return send(2, x2, y2)
}

/// One persistent HID client; reads stdin until EOF or `q`. Lines: `d nx ny`, `m nx ny`, `u nx ny`, `q`.
private func runTouchSession() async {
  await MainActor.run {
    connectToWindowServer()
  }
  let udid: String? = ProcessInfo.processInfo.environment["IOS_SIM_UDID"]
  let opened: (Int, [CChar]) = await MainActor.run {
    var e = [CChar](repeating: 0, count: 512)
    guard let p = IOSEmbedHIDSessionOpen(udid, &e, e.count) else {
      return (0, e)
    }
    return (Int(bitPattern: p), e)
  }
  guard opened.0 != 0 else {
    fputs(String(cString: opened.1), stderr)
    exit(1)
  }
  let sessionBits = opened.0
  defer {
    if let s = UnsafeMutableRawPointer(bitPattern: sessionBits) {
      IOSEmbedHIDSessionClose(s)
    }
  }

  while true {
    let line: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
      DispatchQueue.global(qos: .utility).async {
        cont.resume(returning: readLine())
      }
    }
    guard let raw = line else { break }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      continue
    }
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let cmd = parts.first else { continue }
    if cmd == "q" || cmd == "quit" {
      break
    }

    let errMsg: String? = await MainActor.run { () -> String? in
      guard let session = UnsafeMutableRawPointer(bitPattern: sessionBits) else {
        return "session lost"
      }
      var err = [CChar](repeating: 0, count: 512)
      let phase: Int32
      switch cmd {
      case "d", "down":
        phase = 1
      case "u", "up":
        phase = 2
      case "m", "move":
        phase = 0
      default:
        return "unknown command (use d|m|u|q)"
      }
      guard parts.count == 3, let nx = Double(parts[1]), let ny = Double(parts[2]) else {
        return "expected: d|m|u <nx> <ny>"
      }
      guard IOSEmbedHIDSessionSend(session, nx, ny, phase, &err, err.count) else {
        return String(cString: err)
      }
      return nil
    }
    if let errMsg {
      FileHandle.standardError.write(Data("ERR:\(errMsg)\n".utf8))
      fflush(stderr)
    }
  }
}

/// Backing scale of the `NSScreen` that contains the center of `windowFrame` (points, Cocoa global).
private func backingScale(for windowFrame: CGRect) -> CGFloat {
  let mid = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
  for screen in NSScreen.screens {
    if screen.frame.contains(mid) {
      return screen.backingScaleFactor
    }
  }
  return NSScreen.main?.backingScaleFactor ?? 2.0
}

/// Letterbox of the booted device’s LCD inside the Simulator window (fractions of window width/height).
private func mapInsetsForDeviceInWindow(
  windowWidth: Double,
  windowHeight: Double,
  deviceWidth: Double,
  deviceHeight: Double
) -> (padLeft: Double, padRight: Double, padTop: Double, padBottom: Double) {
  guard windowWidth > 0, windowHeight > 0, deviceWidth > 0, deviceHeight > 0 else {
    return (0, 0, 0, 0)
  }
  let w = windowWidth
  let h = windowHeight
  let scale = min(w / deviceWidth, h / deviceHeight)
  let fittedW = deviceWidth * scale
  let fittedH = deviceHeight * scale
  let ox = (w - fittedW) / 2
  let oy = (h - fittedH) / 2
  // Clamp to [0,1): float noise can yield tiny negative L/R when the fit is symmetric.
  func clampPad(_ v: Double) -> Double { min(max(v, 0), 0.999999) }
  let padLeft = clampPad(ox / w)
  let padRight = clampPad((w - ox - fittedW) / w)
  let padTop = clampPad(oy / h)
  let padBottom = clampPad((h - oy - fittedH) / h)
  return (padLeft, padRight, padTop, padBottom)
}

private func framesDiffer(_ a: CGRect, _ b: CGRect, epsilon: CGFloat = 0.5) -> Bool {
  abs(a.origin.x - b.origin.x) > epsilon || abs(a.origin.y - b.origin.y) > epsilon
    || abs(a.width - b.width) > epsilon || abs(a.height - b.height) > epsilon
}

/// Same `SCWindow` as when streaming started (by `windowID`), if still present.
@MainActor
private func scWindowById(_ windowID: CGWindowID) async throws -> SCWindow? {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  return content.windows.first { UInt32($0.windowID) == windowID }
}

// MARK: - ScreenCaptureKit delegate

/// Receives `CMSampleBuffer` frames from `SCStream` (ScreenCaptureKit’s capture object).
///
/// `NSObject` + `SCStreamOutput` is the Objective‑C “delegate/protocol” pattern Swift inherits.
/// Apple calls `stream(_:didOutputSampleBuffer:of:)` on the queue we pass when adding this output.
final class StreamOutput: NSObject, SCStreamOutput {
  let onFrame: (Data) -> Void
  /// Serial queue so we don’t encode JPEG or touch stdout from multiple threads at once.
  private let queue = DispatchQueue(label: "ios-sim-helper.frames", qos: .userInitiated)

  init(onFrame: @escaping (Data) -> Void) {
    self.onFrame = onFrame
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    guard let data = jpegData(from: sampleBuffer) else { return }
    queue.async { self.onFrame(data) }
  }
}

// MARK: - Stream mode (wire protocol: stderr BOUNDS, stdout length + JPEG)

/// Writes `BOUNDS:` and `MAP:` / `MAP_SKIP` / `MAP_DEBUG` for the current Simulator window frame (points).
/// Called at stream start and periodically when the window is resized so the extension can refresh insets.
@MainActor
private func emitBoundsAndMap(for frame: CGRect) throws {
  let boundsPayload: [String: Double] = [
    "x": Double(frame.origin.x),
    "y": Double(frame.origin.y),
    "width": Double(frame.width),
    "height": Double(frame.height),
  ]
  let json = try JSONSerialization.data(withJSONObject: boundsPayload, options: [])
  guard let line = String(data: json, encoding: .utf8) else {
    throw HelperError.streamFailed("bounds encode")
  }
  FileHandle.standardError.write(Data("BOUNDS:\(line)\n".utf8))

  var errMap = [CChar](repeating: 0, count: 512)
  let envUdid =
    ProcessInfo.processInfo.environment["IOS_SIM_UDID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let udidForMap: String? = envUdid.isEmpty ? nil : envUdid
  let udidLabel = udidForMap ?? "(nil → first booted device)"
  let mapDebugEnv =
    ProcessInfo.processInfo.environment["IOS_SIM_HELPER_MAP_DEBUG"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    ?? ""
  let mapDebug = mapDebugEnv == "1" || mapDebugEnv.lowercased() == "true" || mapDebugEnv.lowercased() == "yes"

  func writeMapDiagLine(_ tag: String, _ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }
    FileHandle.standardError.write(Data("\(tag):\(json)\n".utf8))
  }

  var dW: Double = 0
  var dH: Double = 0
  if !IOSEmbedBootedMainScreenLogicalSize(udidForMap, &dW, &dH, &errMap, errMap.count) {
    let detail = String(cString: errMap).trimmingCharacters(in: .whitespacesAndNewlines)
    writeMapDiagLine(
      "MAP_SKIP",
      [
        "reason": "booted_main_screen_logical_size_failed",
        "detail": String(detail.prefix(500)),
        "iosSimUdidFilter": udidLabel,
        "windowSizePt": ["w": Double(frame.width), "h": Double(frame.height)],
        "hint":
          "Boot a simulator; if several are booted set IOS_SIM_UDID (extension: simulatorUdid) to match the streamed device.",
      ])
  } else if dW <= 0 || dH <= 0 {
    writeMapDiagLine(
      "MAP_SKIP",
      [
        "reason": "invalid_main_screen_dimensions",
        "mainScreenLogical": ["w": dW, "h": dH],
        "iosSimUdidFilter": udidLabel,
        "windowSizePt": ["w": Double(frame.width), "h": Double(frame.height)],
      ])
  } else {
    let ins = mapInsetsForDeviceInWindow(
      windowWidth: Double(frame.width),
      windowHeight: Double(frame.height),
      deviceWidth: dW,
      deviceHeight: dH
    )
    let mapPayload: [String: Double] = [
      "padLeft": ins.padLeft,
      "padRight": ins.padRight,
      "padTop": ins.padTop,
      "padBottom": ins.padBottom,
    ]
    if let mj = try? JSONSerialization.data(withJSONObject: mapPayload),
      let mline = String(data: mj, encoding: .utf8)
    {
      FileHandle.standardError.write(Data("MAP:\(mline)\n".utf8))
      if mapDebug {
        writeMapDiagLine(
          "MAP_DEBUG",
          [
            "phase": "map_emitted",
            "windowSizePt": ["w": Double(frame.width), "h": Double(frame.height)],
            "mainScreenLogical": ["w": dW, "h": dH],
            "pads": mapPayload,
            "iosSimUdidFilter": udidLabel,
            "note":
              "Pads are fractions of the captured window; extension remaps pointer (x/w,y/h) through this inner rect before Indigo.",
          ])
      }
    } else {
      writeMapDiagLine(
        "MAP_SKIP",
        [
          "reason": "map_json_encode_failed",
          "iosSimUdidFilter": udidLabel,
          "mainScreenLogical": ["w": dW, "h": dH],
        ])
    }
  }
}

/// Configures and runs capture until stdin closes (parent process kill/dispose).
///
/// Protocol for the Node extension:
///   1. One line on stderr: `BOUNDS:{...}\n` with window frame in Cocoa global coordinates (points).
///   2. Optional: `MAP:{"padLeft","padRight","padTop","padBottom"}\n` — letterbox of the device LCD inside
///      the captured window (fractions of window width/height). The webview maps clicks through this inset
///      before sending normalized Indigo coordinates.
///   3. Repeated on stdout: 4-byte big-endian length + JPEG bytes (no delimiters otherwise).
///
///   While streaming, the helper polls the same `windowID` every 500ms and may emit additional
///   `BOUNDS:` / `MAP:` lines when the Simulator window frame changes (resize / move). The extension
///   should apply the latest MAP. Video dimensions are fixed at capture start until the stream restarts.
@MainActor
private func runStream() async throws {
  let window = try await findSimulatorWindow()
  let captureWindowID = window.windowID
  let frame = window.frame
  let scale = backingScale(for: frame)
  try emitBoundsAndMap(for: frame)

  // Capture only this window (not the whole display).
  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  // 1× logical size + moderate FPS keeps GPU/CPU down; still readable in the webview.
  let capW = min(frame.width * scale, 2560)
  let capH = min(frame.height * scale, 2560)
  config.width = max(1, Int(capW))
  config.height = max(1, Int(capH))
  config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // up to ~60 fps
  config.pixelFormat = kCVPixelFormatType_32BGRA as OSType
  config.showsCursor = false
  config.capturesAudio = false

  // Encode + write on a background queue; lock stdout so frame writes don’t interleave.
  let stdoutLock = NSLock()
  let output = StreamOutput { data in
    var len = UInt32(data.count).bigEndian
    let header = Data(bytes: &len, count: 4)
    stdoutLock.lock()
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(data)
    stdoutLock.unlock()
  }

  let stream = SCStream(filter: filter, configuration: config, delegate: nil)
  try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
  try await stream.startCapture()

  var lastPolledFrame = frame
  let mapPoll = Task { @MainActor in
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard let w = try? await scWindowById(captureWindowID) else { continue }
      let f = w.frame
      if framesDiffer(f, lastPolledFrame) {
        lastPolledFrame = f
        try? emitBoundsAndMap(for: f)
      }
    }
  }

  // Block until stdin is closed (extension disposes the child or closes the pipe).
  // `withCheckedContinuation` bridges callback-style async APIs into Swift `async`.
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    DispatchQueue.global(qos: .utility).async {
      _ = FileHandle.standardInput.readDataToEndOfFile()
      cont.resume()
    }
  }

  mapPoll.cancel()
  try await stream.stopCapture()
}

// MARK: - Entry point

/// `@main` tells Swift this is the program entry. `async` lets us use `await` here.
///
/// Flow: initialize Window Server on the main thread → parse argv → `touch`, `stream`, or `list`.
@main
enum Entry {
  static func main() async {
    // Must run on main: touching NSApplication from a background thread is unsafe.
    await MainActor.run {
      connectToWindowServer()
    }

    let args = CommandLine.arguments.dropFirst()
    guard let first = args.first else {
      fputs("\(HelperError.usage)\n", stderr)
      exit(2)
    }

    if first == "touch" {
      let r = Array(args.dropFirst())
      guard let sub = r.first else {
        fputs("\(HelperError.usage)\n", stderr)
        exit(2)
      }
      let tail = Array(r.dropFirst())

      if sub == "sess" {
        if !tail.isEmpty {
          fputs("\(HelperError.usage)\n", stderr)
          exit(2)
        }
        await runTouchSession()
        exit(0)
      }

      enum TouchOp {
        case tap(Double, Double)
        case down(Double, Double)
        case up(Double, Double)
        case move(Double, Double)
        case longpress(Double, Double, Int)
        case swipe(Double, Double, Double, Double, Int)
      }

      let op: TouchOp?
      switch sub {
      case "tap":
        if tail.count == 2, let nx = Double(tail[0]), let ny = Double(tail[1]) {
          op = .tap(nx, ny)
        } else {
          op = nil
        }
      case "down":
        if tail.count == 2, let nx = Double(tail[0]), let ny = Double(tail[1]) {
          op = .down(nx, ny)
        } else {
          op = nil
        }
      case "up":
        if tail.count == 2, let nx = Double(tail[0]), let ny = Double(tail[1]) {
          op = .up(nx, ny)
        } else {
          op = nil
        }
      case "move":
        if tail.count == 2, let nx = Double(tail[0]), let ny = Double(tail[1]) {
          op = .move(nx, ny)
        } else {
          op = nil
        }
      case "longpress":
        if tail.count >= 2, let nx = Double(tail[0]), let ny = Double(tail[1]) {
          let ms = tail.count >= 3 ? max(1, Int(tail[2]) ?? 600) : 600
          op = .longpress(nx, ny, ms)
        } else {
          op = nil
        }
      case "swipe":
        if tail.count >= 4,
          let x1 = Double(tail[0]), let y1 = Double(tail[1]),
          let x2 = Double(tail[2]), let y2 = Double(tail[3])
        {
          let dur = max(16, tail.count >= 5 ? Int(tail[4]) ?? 300 : 300)
          op = .swipe(x1, y1, x2, y2, dur)
        } else {
          op = nil
        }
      default:
        op = nil
      }

      guard let parsed = op else {
        fputs("\(HelperError.usage)\n", stderr)
        exit(2)
      }

      let fail: String? = await MainActor.run {
        switch parsed {
        case .tap(let nx, let ny):
          return runTouchTap(normX: nx, normY: ny)
        case .down(let nx, let ny):
          return hidSendPhase(normX: nx, normY: ny, phase: 1)
        case .up(let nx, let ny):
          return hidSendPhase(normX: nx, normY: ny, phase: 2)
        case .move(let nx, let ny):
          return hidSendPhase(normX: nx, normY: ny, phase: 0)
        case .longpress(let nx, let ny, let ms):
          return runTouchLongPress(normX: nx, normY: ny, holdMs: ms)
        case .swipe(let x1, let y1, let x2, let y2, let dur):
          return runTouchSwipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: dur)
        }
      }

      if let fail {
        fputs("\(fail)\n", stderr)
        exit(1)
      }
      exit(0)
    }

    if first == "stream" {
      do {
        try await runStream()
        exit(0)
      } catch {
        fputs("\(error)\n", stderr)
        exit(1)
      }
    }

    if first == "list" {
      do {
        try await listCaptureCandidates()
        exit(0)
      } catch {
        fputs("\(error)\n", stderr)
        exit(1)
      }
    }

    fputs("\(HelperError.usage)\n", stderr)
    exit(2)
  }
}
