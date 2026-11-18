#!/usr/bin/env bash
# Runs the unit tests (no models). SwiftPM can't compile MLX's Metal shaders, so the test bundle gets the
# metallib from an xcodebuild of the app or package. Usage: scripts/unit-tests.sh <path/to/mlx-swift_Cmlx.bundle>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMLX="$(cd "${1:?path to mlx-swift_Cmlx.bundle from an xcodebuild}" && pwd)"
cd "$ROOT/Packages/SynapseCore"
swift build --build-tests
BUNDLE="$(find "$(swift build --show-bin-path)" -maxdepth 1 -name '*Tests.xctest' -type d | head -1)"
[[ -n "$BUNDLE" ]] || { echo "test bundle not found" >&2; exit 1; }
cp "$CMLX/Contents/Resources/default.metallib" "$BUNDLE/Contents/MacOS/mlx.metallib"
codesign --force --deep -s - "$BUNDLE" >/dev/null
swift test --skip-build
