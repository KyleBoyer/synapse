#!/usr/bin/env bash
# Runs a command while holding a machine-wide lock so real-model runs never overlap (16 GB machines swap
# badly with two models resident). Usage: scripts/with-gpu-lock.sh <command> [args...]
set -euo pipefail
LOCK="${SYNAPSE_GPU_LOCK:-/tmp/synapse-gpu.lock}"
until mkdir "$LOCK" 2>/dev/null; do
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  sleep 5
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
"$@"
