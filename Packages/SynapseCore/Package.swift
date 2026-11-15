// swift-tools-version: 6.0
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
    ],
    targets: [
        .target(
            name: "SynapseCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
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
