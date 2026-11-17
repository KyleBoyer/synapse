#!/usr/bin/env bash
# Builds llama.cpp (MIT)'s llama-server (GGUF models) for Synapse: static, Metal, shaders embedded, no curl.
# Output: vendor/llama.cpp/bin/llama-server. Re-running is a no-op when the pinned version is already built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=b12477
SHA256=fbe1256588fd66db2bd65714515cf2cf278a5e92464362872a78f63c9a39cd56
PREFIX="$ROOT/vendor/llama.cpp"
MARKER="$VERSION-server2"
SRC="$ROOT/vendor/src"
TARBALL="$SRC/llama.cpp-$VERSION.tar.gz"

if [[ -x "$PREFIX/bin/llama-server" && "$(cat "$PREFIX/.version" 2>/dev/null)" == "$MARKER" ]]; then
  echo "llama-server $VERSION already built"; exit 0
fi
mkdir -p "$SRC" "$PREFIX/bin"
if [[ ! -f "$TARBALL" ]]; then
  curl -fL --retry 3 -o "$TARBALL.part" "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$VERSION.tar.gz"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -
rm -rf "$SRC/llama.cpp-$VERSION"
tar -xzf "$TARBALL" -C "$SRC"
cd "$SRC/llama.cpp-$VERSION"
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_NUMBER="${VERSION#b}" -DLLAMA_BUILD_COMMIT="$VERSION" \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON
cmake --build build --config Release --target llama-server -j "$(sysctl -n hw.ncpu)"
cp build/bin/llama-server "$PREFIX/bin/llama-server"
echo "$MARKER" > "$PREFIX/.version"
# Only system libraries: Synapse talks to it over plain HTTP on 127.0.0.1, so no OpenSSL.
if otool -L "$PREFIX/bin/llama-server" | tail -n +2 | grep -vqE "^\s+(/System/|/usr/lib/)"; then
  otool -L "$PREFIX/bin/llama-server"; echo "error: llama-server links a non-system library"; exit 1
fi
"$PREFIX/bin/llama-server" --version 2>&1 | tail -2
