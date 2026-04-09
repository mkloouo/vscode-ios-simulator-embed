import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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

private func findSimulatorWindow() async throws -> SCWindow {
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  let candidates = content.windows.filter { window in
    let bid = window.owningApplication?.bundleIdentifier ?? ""
    if bid == "com.apple.iphonesimulator" { return true }
    if bid.contains("CoreSimulator") { return true }
    if bid.contains("Simulator") { return true }
    let title = window.title ?? ""
    if title.contains("iOS"), title.contains("—") || title.contains("-") { return true }
    return false
  }
  let sized = candidates.filter { $0.frame.width >= 120 && $0.frame.height >= 120 }
  func area(_ w: SCWindow) -> CGFloat { w.frame.width * w.frame.height }
  guard let best = sized.max(by: { area($0) < area($1) })
  else {
    throw HelperError.noSimulatorWindow
  }
  return best
}

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

private func postClick(quartzGlobal: CGPoint) {
  let down = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: quartzGlobal,
    mouseButton: .left)
  let up = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: quartzGlobal,
    mouseButton: .left)
  down?.post(tap: .cghidEventTap)
  usleep(8_000)
  up?.post(tap: .cghidEventTap)
}

final class StreamOutput: NSObject, SCStreamOutput {
  let onFrame: (Data) -> Void
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

  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  config.width = Int(min(frame.width * 2, 4096))
  config.height = Int(min(frame.height * 2, 4096))
  config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
  config.pixelFormat = kCVPixelFormatType_32BGRA as OSType
  config.showsCursor = false
  config.capturesAudio = false

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

  await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    DispatchQueue.global(qos: .utility).async {
      _ = FileHandle.standardInput.readDataToEndOfFile()
      cont.resume()
    }
  }

  try await stream.stopCapture()
}

@main
enum Entry {
  static func main() async {
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
      postClick(quartzGlobal: CGPoint(x: x, y: y))
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
