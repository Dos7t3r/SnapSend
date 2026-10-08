// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapSend",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SnapSend", targets: ["SnapSend"])],
    targets: [
        .target(name: "SnapSendCore"),
        .executableTarget(name: "SnapSend", dependencies: ["SnapSendCore"]),
        .executableTarget(name: "SnapSendNativeHost"),
        .testTarget(name: "SnapSendCoreTests", dependencies: ["SnapSendCore"])
    ]
)
