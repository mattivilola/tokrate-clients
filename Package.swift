// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokrateClients",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokrateCore", targets: ["TokrateCore"]),
        .executable(name: "tokrate", targets: ["tokrate"]),
        .executable(name: "TokrateApp", targets: ["TokrateApp"])
    ],
    targets: [
        .target(name: "TokrateCore", path: "shared/Sources/TokrateCore"),
        .executableTarget(name: "tokrate", dependencies: ["TokrateCore"], path: "shared/Sources/tokrate"),
        .executableTarget(name: "TokrateApp", dependencies: ["TokrateCore"], path: "macos/Sources/TokrateApp"),
        .testTarget(name: "TokrateCoreTests", dependencies: ["TokrateCore"], path: "shared/Tests/TokrateCoreTests"),
        .testTarget(name: "TokrateAppTests", dependencies: ["TokrateApp", "TokrateCore"], path: "macos/Tests/TokrateAppTests")
    ]
)
