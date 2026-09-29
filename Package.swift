// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Saywrite",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Saywrite", targets: ["Saywrite"]),
        .library(name: "SaywriteCore", targets: ["SaywriteCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .target(
            name: "SaywriteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Saywrite",
            dependencies: [
                "SaywriteCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SaywriteEval",
            dependencies: ["SaywriteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SaywriteCoreTests",
            dependencies: ["SaywriteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
