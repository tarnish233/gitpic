// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitPic",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable lives here: no AppKit windows, no UI.
        .target(name: "GitPicCore"),

        // Thin UI shell. An executable target cannot be imported by tests,
        // so it holds only wiring.
        .executableTarget(name: "GitPicApp", dependencies: ["GitPicCore"]),

        .testTarget(name: "GitPicCoreTests", dependencies: ["GitPicCore"]),
    ]
)
