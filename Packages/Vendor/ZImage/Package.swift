// swift-tools-version: 6.2
// Vendored core target of github.com/xocialize/z-image-swift @ f7c22ed (MIT). See VENDORED.md.
import PackageDescription

let package = Package(
    name: "ZImage",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ZImage", targets: ["ZImage"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        .package(url: "https://github.com/xocialize/mlx-profiling.git", from: "0.1.0"),
        .package(url: "https://github.com/xocialize/mlx-exact-conv-swift", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ZImage",
            dependencies: [
                .product(name: "MLXExactConv", package: "mlx-exact-conv-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MLXProfiling", package: "mlx-profiling"),
            ],
            path: "Sources/ZImage"
        ),
    ]
)
