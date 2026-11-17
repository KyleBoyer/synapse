#!/usr/bin/env bash
# Starts the real API stack (APIServerTool) on localhost:19000 in the background for SDK scripts and prints its PID.
# Extra environment (SYNAPSE_FAKE_IMAGES, SYNAPSE_API_TEST_KEY, SYNAPSE_API_TEST_PORT, ...) passes through.
# Stop it with: kill <pid>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${SYNAPSE_API_TEST_PORT:-19000}"
SCRATCH="/Volumes/Workspace NVME/SynapseScratch/sdk-server"
MODELS="${SYNAPSE_MODELS_DIR:-/Volumes/Workspace NVME/SynapseModels}"

# Building the bundle is the point; the filter matches nothing, so swift test's own exit status is ignored.
"$ROOT/scripts/test-chat-e2e.sh" NoSuchTestJustBuild >/dev/null 2>&1 || true
BIN="$(cd "$ROOT/Packages/SynapseCore" && swift build --show-bin-path)"
BUNDLE="$(find "$BIN" -maxdepth 1 -name '*Tests.xctest' -type d | head -1)"
[[ -n "$BUNDLE" ]] || { echo "test bundle not found in $BIN" >&2; exit 1; }

rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
cp -R "$BUNDLE" "$SCRATCH/"
LOG="$SCRATCH/server.log"
SYNAPSE_API_TEST_SERVER=1 SYNAPSE_MODELS_DIR="$MODELS" nohup xcrun xctest \
  -XCTest SynapseCoreTests.APIServerTool/testServe "$SCRATCH/$(basename "$BUNDLE")" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 120); do
  curl -sf "localhost:$PORT/health" >/dev/null && { echo "serving on localhost:$PORT, pid $PID (log: $LOG)"; exit 0; }
  kill -0 "$PID" 2>/dev/null || { echo "server exited; see $LOG" >&2; exit 1; }
  sleep 1
done
echo "server did not answer /health in 120s; see $LOG" >&2; exit 1
