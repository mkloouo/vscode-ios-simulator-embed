// =============================================================================
// ios-sim-helper — small macOS command-line tool for the VS Code extension
// =============================================================================
//
// Two modes (chosen by the first argument):
//   stream — finds the Simulator window, captures it with ScreenCaptureKit, and
//            writes JPEG frames to stdout (length-prefixed). Sends one BOUNDS
//            line on stderr so the extension can map clicks to screen coords.
//   click  — synthesizes a left click at Quartz global (x, y).
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
  case noSimulatorWindow
  case streamFailed(String)

  var description: String {
    switch self {
    case .usage:
      return "Usage:\n  ios-sim-helper stream\n  ios-sim-helper click <x> <y>  (Quartz global coordinates)"
    case .noSimulatorWindow:
      return "No iOS Simulator window found. Open Simulator and a booted device first."
    case .streamFailed(let msg):
      return "Stream error: \(msg)"
    }
  }
}

// MARK: - Finding the Simulator window

/// Asks ScreenCaptureKit for every on-screen window, then picks the Simulator.
///
/// `@MainActor` forces this to run on the main thread. Apple’s capture APIs expect
/// UI-thread affinity in practice; the VS Code–spawned CLI would otherwise skip
/// normal app startup, so we pair this with `connectToWindowServer()`.
///
/// `async throws` means: may suspend (await) and may fail (`throw`); callers use
/// `try await`.
@MainActor
private func findSimulatorWindow() async throws -> SCWindow {
  // Snapshot of shareable content: windows, displays, apps (async system call).
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

  // Heuristic filters: bundle IDs Apple uses for Simulator, plus title patterns
  // (e.g. “main — iOS …” when the device name is “main”).
  let candidates = content.windows.filter { window in
    let bid = window.owningApplication?.bundleIdentifier ?? ""
    if bid == "com.apple.iphonesimulator" { return true }
    if bid.contains("CoreSimulator") { return true }
    if bid.contains("Simulator") { return true }
    let title = window.title ?? ""
    // Comma between conditions = logical AND. The `||` group matches common title shapes.
    if title.contains("iOS"), title.contains("—") || title.contains("-") || title.contains("main") { return true }
    return false
  }

  // Ignore tiny helper windows (icons, chrome); keep anything reasonably large.
  let sized = candidates.filter { $0.frame.width >= 120 && $0.frame.height >= 120 }
  func area(_ w: SCWindow) -> CGFloat { w.frame.width * w.frame.height }
  guard let best = sized.max(by: { area($0) < area($1) })
  else {
    throw HelperError.noSimulatorWindow
  }
  return best
}

// MARK: - Frame encoding (video sample → JPEG bytes)

/// Converts one video frame (`CMSampleBuffer`) from the capture pipeline into JPEG `Data`.
///
/// Pipeline: pixel buffer → Core Image → `CGImage` → ImageIO JPEG encoder.
/// We compress a bit (0.72) to keep bandwidth reasonable for the extension/webview.
private func jpegData(from sampleBuffer: CMSampleBuffer) -> Data? {
  guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
  let ciImage = CIImage(cvPixelBuffer: buffer)
  let context = CIContext(options: [.useSoftwareRenderer: false])
  guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
  let data = NSMutableData()
  guard
    let dest = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
  else { return nil }
  let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.72]
  CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return data as Data
}

// MARK: - Synthetic click

/// Posts a left mouse down + up at the given point in **Quartz global coordinates**
/// (origin bottom-left of the combined desktop space, as used by `CGEvent`).
///
/// The TypeScript side maps from webview/image coordinates into this space using
/// the BOUNDS line emitted on stderr.
private func postClick(quartzGlobal: CGPoint) {
  let down = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartzGlobal,
    mouseButton: .left)
  let up = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: quartzGlobal,
    mouseButton: .left)
  down?.post(tap: .cghidEventTap)
  usleep(8_000)  // tiny gap so the OS sees distinct down/up
  up?.post(tap: .cghidEventTap)
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
  let boundsPayload: [String: CGFloat] = [
    "x": frame.origin.x,
    "y": frame.origin.y,
    "width": frame.width,
    "height": frame.height,
  ]
  let json = try JSONSerialization.data(withJSONObject: boundsPayload, options: [])
  guard let line = String(data: json, encoding: .utf8) else { throw HelperError.streamFailed("bounds encode") }
  FileHandle.standardError.write(Data("BOUNDS:\(line)\n".utf8))

  // Capture only this window (not the whole display).
  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  // ~2x size for Retina-ish sharpness; cap dimensions for safety.
  config.width = Int(min(frame.width * 2, 4096))
  config.height = Int(min(frame.height * 2, 4096))
  config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // ~30 fps
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

    fputs("\(HelperError.usage)\n", stderr)
    exit(2)
  }
}
