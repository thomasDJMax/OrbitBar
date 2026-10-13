// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OrbitBar", targets: ["OrbitBar"])],
    targets: [
        .target(name: "OrbitBarCore"),
        .executableTarget(name: "OrbitBar", dependencies: ["OrbitBarCore"]),
        .testTarget(name: "OrbitBarCoreTests", dependencies: ["OrbitBarCore"])
    ]
)
