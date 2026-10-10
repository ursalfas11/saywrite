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
        // llama.cpp as a prebuilt XCFramework (MIT), pinned by release tag and checksum. The b-tags are
        // nightly prereleases: bump deliberately, and re-run the eval (Tests/Eval) when you do.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11534/llama-b11534-xcframework.zip",
            checksum: "401818cb413a1e2fe61120c12cd343cfbf3912ea4f0d10ec60b2351d82ee6b16"
        ),
        .target(
            name: "SaywriteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The built-in model engine. Kept out of SaywriteCore so the core, its tests and the
        // rules-only eval do not depend on the binary framework.
        .target(
            name: "SaywriteLlama",
            dependencies: ["SaywriteCore", "llama"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Saywrite",
            dependencies: [
                "SaywriteCore",
                "SaywriteLlama",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // llama.framework is embedded in the app bundle (make app); dyld finds it there.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "SaywriteEval",
            dependencies: ["SaywriteCore", "SaywriteLlama"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Next to the executable in .build/<config>/, where SwiftPM puts the framework.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .testTarget(
            name: "SaywriteCoreTests",
            dependencies: ["SaywriteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
