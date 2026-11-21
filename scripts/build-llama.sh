#!/usr/bin/env bash
# Builds llama.cpp (MIT)'s llama-server (GGUF models) and llama-quantize (ModelPrep) for Synapse: static, Metal,
# shaders embedded, no curl. Output: vendor/llama.cpp/bin/. Re-running is a no-op when the pinned version is already built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A master commit, not a release tag: Inkling 2 Mini's looped layers need ggml-org/llama.cpp#32704 (merged 2026-11-21),
# which no b-tag held yet. Move back to a tag once one includes it.
VERSION=690b87d88151dbd775bb6eff5581663688785928
BUILD_NUMBER=12609
SHA256=3da0702f6760faac5476f546f2b2556ec48b4efe55e46ab995a20563b1acb31c
PREFIX="$ROOT/vendor/llama.cpp"
MARKER="$VERSION-server3"
SRC="$ROOT/vendor/src"
TARBALL="$SRC/llama.cpp-$VERSION.tar.gz"

if [[ -x "$PREFIX/bin/llama-server" && "$(cat "$PREFIX/.version" 2>/dev/null)" == "$MARKER" ]]; then
  echo "llama-server $VERSION already built"; exit 0
fi
mkdir -p "$SRC" "$PREFIX/bin"
if [[ ! -f "$TARBALL" ]]; then
  curl -fL --retry 3 -o "$TARBALL.part" "https://github.com/ggml-org/llama.cpp/archive/$VERSION.tar.gz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -
rm -rf "$SRC/llama.cpp-$VERSION"
tar -xzf "$TARBALL" -C "$SRC"
cd "$SRC/llama.cpp-$VERSION"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_NUMBER="$BUILD_NUMBER" -DLLAMA_BUILD_COMMIT="${VERSION:0:7}" \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON
cmake --build build --config Release --target llama-server llama-quantize -j "$(sysctl -n hw.ncpu)"
cp build/bin/llama-server build/bin/llama-quantize "$PREFIX/bin/"
echo "$MARKER" > "$PREFIX/.version"
# Only system libraries: Synapse talks to it over plain HTTP on 127.0.0.1, so no OpenSSL.
for tool in llama-server llama-quantize; do
  if otool -L "$PREFIX/bin/$tool" | tail -n +2 | grep -vqE "^\s+(/System/|/usr/lib/)"; then
    otool -L "$PREFIX/bin/$tool"; echo "error: $tool links a non-system library"; exit 1
  fi
done
"$PREFIX/bin/llama-server" --version 2>&1 | tail -2
