// swift-tools-version:5.9
// Tools version 5.9 means the target builds in Swift 5 language mode.
import PackageDescription

let package = Package(
    name: "Leaf",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Leaf",
            path: "Sources/Leaf"
        )
    ]
)
