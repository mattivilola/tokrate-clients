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
        .target(name: "TokrateCore"),
        .executableTarget(name: "tokrate", dependencies: ["TokrateCore"]),
        .executableTarget(name: "TokrateApp", dependencies: ["TokrateCore"]),
        .testTarget(name: "TokrateCoreTests", dependencies: ["TokrateCore"])
    ]
)
