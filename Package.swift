// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "kv",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (scrubbing, grant signing) so it can be unit-tested without Keychain or AppKit.
        .target(name: "KVCore"),
        .executableTarget(name: "kv", dependencies: ["KVCore"]),
        .testTarget(name: "KVCoreTests", dependencies: ["KVCore"]),
    ],
    swiftLanguageModes: [.v5]
)
