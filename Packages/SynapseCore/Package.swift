// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SynapseCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SynapseCore", targets: ["SynapseCore"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.7.1"),
        // FoundationModels bridge needs the macOS 27 SDK; we don't use it.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SynapseCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "SynapseCoreTests",
            dependencies: [
                "SynapseCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
