// swift-tools-version: 5.10
import PackageDescription

// Vendored subset of soniqo/speech-swift (see VENDORED.md).
let package = Package(
    name: "Qwen3Speech",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "PersonaPlex", targets: ["PersonaPlex"]),
        .library(name: "HibikiTranslate", targets: ["HibikiTranslate"]),
        .library(name: "VoiceChat", targets: ["VoiceChat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .target(name: "AudioCommon", dependencies: [.product(name: "Hub", package: "swift-transformers")]),
        .target(
            name: "MLXCommon",
            dependencies: [
                "AudioCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "PersonaPlex",
            dependencies: [
                "AudioCommon", "MLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "HibikiTranslate",
            dependencies: [
                "AudioCommon", "MLXCommon", "PersonaPlex",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "VoiceChat",
            dependencies: [
                "AudioCommon", "MLXCommon",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            resources: [.process("Resources")]
        ),
    ]
)
