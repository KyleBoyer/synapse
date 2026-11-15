#!/usr/bin/env bash
# Runs the real-model Qwen tests under `swift test`. SwiftPM can't compile MLX's Metal shaders, so build
# them once with xcodebuild and place the library where MLX looks first (next to the test binary).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/Packages/SynapseCore"
cd "$PKG"
xcodebuild build -scheme SynapseCore -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/build/pkg" \
  -skipPackagePluginValidation -skipMacroValidation -quiet
swift build --build-tests
cp "$ROOT/build/pkg/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
   "$PKG/.build/debug/SynapseCorePackageTests.xctest/Contents/MacOS/mlx.metallib"
SYNAPSE_E2E=1 swift test --skip-build --filter "${1:-ChatE2ETests}"
