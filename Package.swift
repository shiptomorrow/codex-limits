// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexLimits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexLimits", targets: ["CodexLimits"])
    ],
    dependencies: [
        // Claude's desktop app caches API responses zstd-compressed.
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")
    ],
    targets: [
        .executableTarget(
            name: "CodexLimits",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .testTarget(name: "CodexLimitsTests", dependencies: ["CodexLimits"])
    ]
)
