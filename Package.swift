// swift-tools-version: 5.10
import PackageDescription

// Vendor/libssh.xcframework is built locally by Vendor/build-libssh.sh (see
// docs/research/ssh-c-library-packaging.md) — `swift build` fails until it exists.
let package = Package(
    name: "joey",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "joey", targets: ["Joey"]),
        .executable(name: "joey-spike", targets: ["joey-spike"]),
    ],
    dependencies: [
        .package(path: "../leafiy-ui")
    ],
    targets: [
        .binaryTarget(name: "CLibssh", path: "Vendor/libssh.xcframework"),
        .executableTarget(
            name: "Joey",
            dependencies: [
                "CLibssh",
                .product(name: "LeafiyUI", package: "leafiy-ui"),
                .product(name: "LeafiyUICore", package: "leafiy-ui"),
            ],
            path: "Sources/Joey",
            resources: [.process("Resources")]
        ),
        // Ticket-03 engine spike CLI; kept until the spike is verified on hardware.
        .executableTarget(
            name: "joey-spike",
            dependencies: ["CLibssh"],
            path: "Sources/JoeySpike"
        ),
        .testTarget(
            name: "JoeyTests",
            dependencies: [
                "Joey",
                .product(name: "LeafiyUI", package: "leafiy-ui"),
            ]
        ),
    ]
)
