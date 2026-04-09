// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ios-sim-helper",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ios-sim-helper", targets: ["ios-sim-helper"])
  ],
  targets: [
    .executableTarget(
      name: "ios-sim-helper",
      linkerSettings: [
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
        .linkedFramework("CoreImage"),
        .linkedFramework("ImageIO"),
        .linkedFramework("UniformTypeIdentifiers"),
      ]
    )
  ]
)
