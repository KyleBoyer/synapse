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

# Two voices taking alternating turns, for diarization tests. A single turn each is too little evidence for the
# diarizer's default clustering; four alternating turns is what a real conversation gives it.
say -v Samantha -o "$TMP/t1.aiff" "Hello, how are you today? It is lovely weather for a walk in the park."
say -v Daniel -o "$TMP/t2.aiff" "I am fine, thank you very much. I was hoping we could go to the river instead."
say -v Samantha -o "$TMP/t3.aiff" "The river sounds wonderful. Should we bring something to eat on the way?"
say -v Daniel -o "$TMP/t4.aiff" "Yes, let us pack sandwiches and some fruit, and leave in about ten minutes."
/opt/homebrew/bin/ffmpeg -loglevel error -y -i "$TMP/t1.aiff" -i "$TMP/t2.aiff" -i "$TMP/t3.aiff" -i "$TMP/t4.aiff" \
  -filter_complex "[0:a]aresample=22050[a];[1:a]aresample=22050[b];[2:a]aresample=22050[c];[3:a]aresample=22050[d];[a][b][c][d]concat=n=4:v=0:a=1" "$TMP/two.aiff"
afconvert -f m4af -d aac "$TMP/two.aiff" "$OUT/two-speakers.m4a"
ls -l "$OUT"
