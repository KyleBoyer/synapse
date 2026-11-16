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
# Ask SwiftPM where test bundles go (the layout differs between build systems), then put MLX's library next
# to the test binary and re-sign the bundle, which the copy invalidates.
BIN="$(swift build --show-bin-path)"
BUNDLE="$(find "$BIN" -maxdepth 1 -name '*Tests.xctest' -type d | head -1)"
[[ -n "$BUNDLE" ]] || { echo "test bundle not found in $BIN" >&2; exit 1; }
cp "$ROOT/build/pkg/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
   "$BUNDLE/Contents/MacOS/mlx.metallib"
codesign --force --deep -s - "$BUNDLE" >/dev/null
SYNAPSE_E2E=1 swift test --skip-build --filter "${1:-ChatE2ETests}"
