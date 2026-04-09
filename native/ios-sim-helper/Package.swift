// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ios-sim-helper",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "ios-sim-helper", targets: ["ios-sim-helper"])
  ],
  targets: [
    .target(
      name: "IndigoTouch",
      path: "Sources/IndigoTouch",
      sources: ["SimulatorIndigoTouch.m"],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("include"),
        .headerSearchPath("."),
      ]
    ),
    .executableTarget(
      name: "ios-sim-helper",
      dependencies: ["IndigoTouch"],
      linkerSettings: [
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("AppKit"),
        .linkedFramework("CoreImage"),
        .linkedFramework("ImageIO"),
        .linkedFramework("UniformTypeIdentifiers"),
      ]
    ),
  ]
)
