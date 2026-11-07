// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "kv",
    // macOS 26 for Liquid Glass in the request panel.
    platforms: [.macOS(.v26)],
    targets: [
        // Pure logic (scrubbing, grant signing) so it can be unit-tested without Keychain or AppKit.
        .target(name: "KVCore"),
        .executableTarget(name: "kv", dependencies: ["KVCore"]),
        .testTarget(name: "KVCoreTests", dependencies: ["KVCore"]),
    ],
    swiftLanguageModes: [.v5]
)
