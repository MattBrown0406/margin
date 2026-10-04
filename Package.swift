// swift-tools-version:5.9
// Builds Margin's pure money logic (ios/Margin/Logic) on its own so it can be unit-tested with
// `swift test` without Xcode. The app and widget compile the same files directly.
import PackageDescription

let package = Package(
    name: "MarginLogic",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(name: "MarginLogic", path: "ios/Margin/Logic"),
        .testTarget(name: "MarginLogicTests", dependencies: ["MarginLogic"]),
    ]
)
