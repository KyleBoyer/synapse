// swift-tools-version: 6.0
// Vendored from github.com/VincentGourbin/flux-2-swift-mlx @ 315c27e (MIT). See VENDORED.md.
import PackageDescription

let mlx: [Target.Dependency] = [
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "MLXNN", package: "mlx-swift"),
    .product(name: "MLXRandom", package: "mlx-swift"),
    .product(name: "MLXFast", package: "mlx-swift"),
]

let package = Package(
    name: "Flux2Swift",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FluxTextEncoders", targets: ["FluxTextEncoders"]),
        .library(name: "Flux2Core", targets: ["Flux2Core"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/VincentGourbin/swift-mlx-profiler", from: "1.4.0"),
    ],
    targets: [
        .target(name: "FluxTextEncoders", dependencies: mlx + [
            .product(name: "Transformers", package: "swift-transformers"),
            .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
        ]),
        .target(name: "Flux2Core", dependencies: ["FluxTextEncoders"] + mlx + [
            .product(name: "MLXOptimizers", package: "mlx-swift"),
            .product(name: "Transformers", package: "swift-transformers"),
            .product(name: "MLXProfiler", package: "swift-mlx-profiler"),
        ]),
    ]
)
