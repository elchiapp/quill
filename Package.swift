// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "dropsift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .executable(name: "dropsift", targets: ["dropsift"]),
        .library(name: "DropsiftShared", targets: ["DropsiftShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            .upToNextMajor(from: "3.31.3")
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            .upToNextMinor(from: "0.31.4")
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DropsiftShared",
            path: "Shared/DropsiftShared"
        ),
        .executableTarget(
            name: "dropsift",
            dependencies: [
                "DropsiftShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to Dropsift itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/dropsift/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "dropsiftTests",
            dependencies: ["dropsift"]
        ),
        .testTarget(
            name: "DropsiftSharedTests",
            dependencies: ["DropsiftShared"],
            path: "Shared/DropsiftSharedTests"
        ),
    ]
)
