#!/usr/bin/env bash
# Starts the opt-in API test server (HTTP + /v1/realtime) on real models and runs the official-SDK check.
# Needs: SynapseModels with qwen3.5-0.8b, silero-vad, parakeet-eou-120m, pocket-tts; MLX metallib built once
# via scripts/test-chat-e2e.sh (xcodebuild). Usage: scripts/verify-realtime.sh <python-with-openai[realtime]>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${SYNAPSE_PKG:-$ROOT/Packages/SynapseCore}"
PY="${1:?path to python with openai and websockets}"
export SYNAPSE_MODELS_DIR="${SYNAPSE_MODELS_DIR:-/Volumes/Workspace NVME/SynapseModels}"
export SYNAPSE_FFMPEG="${SYNAPSE_FFMPEG:-$ROOT/vendor/ffmpeg/bin/ffmpeg}"
export SYNAPSE_API_TEST_SERVER=1 SYNAPSE_FAKE_IMAGES=1 SYNAPSE_API_TEST_PORT="${PORT:-19000}"
cd "$PKG"
swift build --build-tests
BUNDLE="$(find "$(swift build --show-bin-path)" -maxdepth 1 -name '*Tests.xctest' -type d | head -1)"
cp "$ROOT/build/pkg/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$BUNDLE/Contents/MacOS/mlx.metallib"
codesign --force --deep -s - "$BUNDLE" >/dev/null
"$ROOT/scripts/with-gpu-lock.sh" bash -c '
  swift test --skip-build --filter APIServerTool > "${TMPDIR:-/tmp}/synapse-realtime-server.log" 2>&1 &
  SERVER=$!
  trap "kill $SERVER 2>/dev/null; pkill -f SynapseCorePackageTests 2>/dev/null || true" EXIT
  for i in $(seq 1 120); do curl -fs "http://127.0.0.1:$SYNAPSE_API_TEST_PORT/health" >/dev/null && break; sleep 1; done
  "'"$PY"'" "'"$ROOT"'/scripts/verify-openai-realtime.py" --base-url "http://127.0.0.1:$SYNAPSE_API_TEST_PORT/v1"
'
