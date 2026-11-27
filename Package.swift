// swift-tools-version: 6.2

import Foundation
import PackageDescription

let macOSDeploymentTarget = "15.4"

/// SwiftPM records the deployment target as the SDK version in
/// `LC_BUILD_VERSION`, and macOS picks window chrome from that SDK version: the
/// daemon otherwise keeps the pre-Tahoe titlebar, with its smaller traffic
/// lights and centered title. SwiftPM has no typed setting for the real SDK, so
/// pass it to the linker directly. SwiftPM caches this with the manifest: after an
/// SDK update, `swift package purge-cache` refreshes the recorded version.
func linkerSDKVersionFlags() -> [String] {
  let xcrun = Process()
  xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  xcrun.arguments = ["--sdk", "macosx", "--show-sdk-version"]
  let output = Pipe()
  xcrun.standardOutput = output
  xcrun.standardError = FileHandle.nullDevice
  do {
    try xcrun.run()
  } catch {
    return []
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  xcrun.waitUntilExit()
  let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  guard xcrun.terminationStatus == 0, !version.isEmpty else { return [] }
  return [
    "-Xlinker", "-platform_version",
    "-Xlinker", "macos",
    "-Xlinker", macOSDeploymentTarget,
    "-Xlinker", version,
  ]
}

let sdkLinkerFlags = linkerSDKVersionFlags()

let package = Package(
  name: "Defi",
  platforms: [
    .macOS(macOSDeploymentTarget)
  ],
  products: [
    .library(name: "DefiModel", targets: ["DefiModel"]),
    .library(name: "DefiCore", targets: ["DefiCore"]),
    .library(name: "DefiConfig", targets: ["DefiConfig"]),
    .library(name: "DefiRuntime", targets: ["DefiRuntime"]),
    .library(name: "DefiIPC", targets: ["DefiIPC"]),
    .library(name: "DefiMacOS", targets: ["DefiMacOS"]),
    .executable(name: "defi-daemon", targets: ["DefiDaemon"]),
    .executable(name: "defi", targets: ["DefiCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.5"),
  ],
  targets: [
    .target(name: "DefiModel"),
    .target(
      name: "DefiCore",
      dependencies: ["DefiModel"]
    ),
    .target(
      name: "DefiConfig",
      dependencies: [
        "DefiModel",
        .product(name: "TOMLDecoder", package: "TOMLDecoder"),
      ]
    ),
    .target(
      name: "DefiRuntime",
      dependencies: ["DefiModel", "DefiCore", "DefiConfig"]
    ),
    .target(
      name: "DefiIPC",
      dependencies: ["DefiModel"]
    ),
    .target(
      name: "DefiMacOS",
      dependencies: [
        "DefiModel", "DefiCore", "DefiConfig", "DefiRuntime",
      ]
    ),
    .executableTarget(
      name: "DefiDaemon",
      dependencies: [
        "DefiModel",
        "DefiCore",
        "DefiConfig",
        "DefiRuntime",
        "DefiIPC",
        "DefiMacOS",
      ],
      linkerSettings: sdkLinkerFlags.isEmpty ? [] : [.unsafeFlags(sdkLinkerFlags)]
    ),
    .executableTarget(
      name: "DefiCLI",
      dependencies: ["DefiModel", "DefiIPC"]
    ),
    .testTarget(
      name: "DefiModelTests",
      dependencies: ["DefiModel"]
    ),
    .testTarget(
      name: "DefiCoreTests",
      dependencies: ["DefiCore", "DefiModel"]
    ),
    .testTarget(
      name: "DefiConfigTests",
      dependencies: ["DefiConfig", "DefiModel"]
    ),
    .testTarget(
      name: "DefiRuntimeTests",
      dependencies: [
        "DefiRuntime",
        "DefiConfig",
        "DefiModel",
      ]
    ),
    .testTarget(
      name: "DefiIPCTests",
      dependencies: ["DefiIPC", "DefiModel"]
    ),
    .testTarget(
      name: "DefiCLITests",
      dependencies: ["DefiCLI"]
    ),
    .testTarget(
      name: "DefiMacOSTests",
      dependencies: [
        "DefiMacOS",
        "DefiConfig",
        "DefiCore",
        "DefiIPC",
        "DefiModel",
      ]
    ),
    .testTarget(
      name: "DefiDaemonTests",
      dependencies: ["DefiDaemon", "DefiModel"]
    ),
  ]
)

for target in package.targets {
  target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
