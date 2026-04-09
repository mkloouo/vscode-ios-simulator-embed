// =============================================================================
// ios-sim-helper — small macOS command-line tool for the VS Code extension
// =============================================================================
//
// Modes (first argument):
//   stream — picks a Simulator window by **bundle ID** (see findSimulatorWindow), captures
//            it with ScreenCaptureKit, writes JPEG frames to stdout (length-prefixed).
//            Sends one BOUNDS line on stderr for click mapping.
//   click  — synthesizes a left click at Quartz global (x, y).
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
import ApplicationServices
import CoreGraphics
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
        ios-sim-helper stream              # capture (stderr BOUNDS, stdout JPEG frames)
        ios-sim-helper click <x> <y>       # Quartz global point click
        ios-sim-helper list                # NDJSON lines: all windows (use to read bundle IDs)

      Optional environment:
        IOS_SIM_HELPER_BUNDLE_ID=<id>      # exact owning bundle; only those windows are candidates for stream
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
  enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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

// MARK: - Synthetic click

/// Posts a left click at `quartzGlobal` using the same coordinate space as `CGEvent` / `NSEvent.mouseLocation`
/// (global **points**, origin at the **bottom-left** of the primary display, Y increases upward).
///
/// Why move the cursor first? Many AppKit apps (including Simulator) resolve clicks using the **hardware
/// cursor position** as well as the event location. Posting only down/up without moving the cursor often
/// misses the intended view and makes the pointer appear to “fight” the webview under your hand.
///
/// We save `NSEvent.mouseLocation`, `mouseMoved` to the target, click, then `mouseMoved` back so your
/// cursor returns where you were in the editor.
private func postClick(quartzGlobal: CGPoint) {
  let before = NSEvent.mouseLocation

  func moveMouse(to p: CGPoint) {
    guard
      let e = CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
    else { return }
    e.post(tap: .cghidEventTap)
  }

  moveMouse(to: quartzGlobal)
  usleep(4_000)

  guard
    let down = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartzGlobal,
      mouseButton: .left),
    let up = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: quartzGlobal,
      mouseButton: .left)
  else { return }

  down.post(tap: .cghidEventTap)
  usleep(10_000)
  up.post(tap: .cghidEventTap)

  usleep(3_000)
  moveMouse(to: CGPoint(x: before.x, y: before.y))
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

/// Configures and runs capture until stdin closes (parent process kill/dispose).
///
/// Protocol for the Node extension:
///   1. One line on stderr: `BOUNDS:{...json...}\n` with window frame (for click mapping).
///   2. Repeated on stdout: 4-byte big-endian length + JPEG bytes (no delimiters otherwise).
@MainActor
private func runStream() async throws {
  let window = try await findSimulatorWindow()
  let frame = window.frame
  let scale = backingScale(for: frame)
  // `SCWindow.frame` is in **points** (Cocoa global); same space as `NSEvent.mouseLocation` / `CGEvent`.
  let boundsPayload: [String: Double] = [
    "x": Double(frame.origin.x),
    "y": Double(frame.origin.y),
    "width": Double(frame.width),
    "height": Double(frame.height),
  ]
  let json = try JSONSerialization.data(withJSONObject: boundsPayload, options: [])
  guard let line = String(data: json, encoding: .utf8) else { throw HelperError.streamFailed("bounds encode") }
  FileHandle.standardError.write(Data("BOUNDS:\(line)\n".utf8))

  // Capture only this window (not the whole display).
  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  // 1× logical size + moderate FPS keeps GPU/CPU down; still readable in the webview.
  let capW = min(frame.width * scale, 2560)
  let capH = min(frame.height * scale, 2560)
  config.width = max(1, Int(capW))
  config.height = max(1, Int(capH))
  config.minimumFrameInterval = CMTime(value: 1, timescale: 12)  // ~12 fps
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

  // Block until stdin is closed (extension disposes the child or closes the pipe).
  // `withCheckedContinuation` bridges callback-style async APIs into Swift `async`.
  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    DispatchQueue.global(qos: .utility).async {
      _ = FileHandle.standardInput.readDataToEndOfFile()
      cont.resume()
    }
  }

  try await stream.stopCapture()
}

// MARK: - Entry point

/// `@main` tells Swift this is the program entry. `async` lets us use `await` here.
///
/// Flow: initialize Window Server on the main thread → parse argv → either one-shot
/// `click` or long-running `stream`.
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

    if first == "click" {
      guard args.count == 3,
        let x = Double(args[args.index(args.startIndex, offsetBy: 1)]),
        let y = Double(args[args.index(args.startIndex, offsetBy: 2)])
      else {
        fputs("\(HelperError.usage)\n", stderr)
        exit(2)
      }
      await MainActor.run {
        postClick(quartzGlobal: CGPoint(x: x, y: y))
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
