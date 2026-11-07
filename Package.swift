// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "kv",
    // The request panel uses Liquid Glass on macOS 26+ and falls back to system materials on 15.
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic (scrubbing, grant signing) so it can be unit-tested without Keychain or AppKit.
        .target(name: "KVCore"),
        .executableTarget(name: "kv", dependencies: ["KVCore"]),
        .testTarget(name: "KVCoreTests", dependencies: ["KVCore"]),
    ],
    swiftLanguageModes: [.v5]
)
