#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Packages/SynapseCore/Tests/SynapseCoreTests/Fixtures"
FF="$ROOT/vendor/ffmpeg/bin/ffmpeg"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

say -o "$TMP/en.aiff" "The quick brown fox jumps over the lazy dog. Synapse makes subtitles."
afconvert -f m4af -d aac "$TMP/en.aiff" "$OUT/en.m4a"

FR=Thomas
say -v '?' | grep -q "^Thomas " || FR="$(say -v '?' | awk '/fr_FR/ {print $1; exit}')"
say -v "$FR" -o "$TMP/fr.aiff" "Bonjour, je m'appelle Synapse et je fais des sous-titres."
afconvert -f m4af -d aac "$TMP/fr.aiff" "$OUT/fr.m4a"

# The bundled ffmpeg has no matroska muxer, so the remux needs Homebrew's (dev-only).
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -i "$OUT/en.m4a" -c copy "$OUT/en.mkv"
"$FF" -hide_banner -loglevel error -y -i "$OUT/en.m4a" -f s16le -ac 1 -ar 16000 "$OUT/en.pcm"
ls -l "$OUT"
