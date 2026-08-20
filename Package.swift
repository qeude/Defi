// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Defi",
  platforms: [
    .macOS(.v26)
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
    .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.4.5")
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
      dependencies: ["DefiModel", "DefiCore", "DefiConfig"]
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
      ]
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
      dependencies: ["DefiRuntime", "DefiConfig", "DefiModel"]
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
      dependencies: ["DefiMacOS", "DefiConfig", "DefiCore", "DefiModel"]
    ),
    .testTarget(
      name: "DefiDaemonTests",
      dependencies: ["DefiDaemon", "DefiModel"]
    ),
  ]
)
