// swift-tools-version:5.9
import PackageDescription

// Vendor/libssh.xcframework is built locally by Vendor/build-libssh.sh (see
// docs/research/ssh-c-library-packaging.md) — `swift build` fails until it exists.
let package = Package(
    name: "joey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "joey-spike", targets: ["joey-spike"])
    ],
    targets: [
        .binaryTarget(name: "CLibssh", path: "Vendor/libssh.xcframework"),
        .executableTarget(
            name: "joey-spike",
            dependencies: ["CLibssh"],
            path: "Sources/JoeySpike"
        ),
    ]
)
