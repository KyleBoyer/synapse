#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=8.0
SHA256=b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e
PREFIX="$ROOT/vendor/ffmpeg"
SRC="$ROOT/vendor/src"
TARBALL="$SRC/ffmpeg-$VERSION.tar.xz"

if [[ -x "$PREFIX/bin/ffmpeg" && "$(cat "$PREFIX/.version" 2>/dev/null)" == "$VERSION" ]]; then
  echo "ffmpeg $VERSION already built"
  exit 0
fi

# Some machines have a CLT SDK newer than Xcode's linker; fall back to Xcode's SDK if a trivial link fails.
if ! echo 'int main(void){return 0;}' | clang -x c - -o /dev/null 2>/dev/null; then
  export SDKROOT="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
fi

mkdir -p "$SRC"
[[ -f "$TARBALL" ]] || curl -fsSL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$SRC/ffmpeg-$VERSION"
tar -xf "$TARBALL" -C "$SRC"
cd "$SRC/ffmpeg-$VERSION"

./configure --prefix="$PREFIX" --arch=arm64 --cc=clang \
  --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" \
  --disable-everything --disable-gpl --disable-nonfree --disable-network --disable-doc \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg --disable-shared --enable-static \
  --disable-autodetect --enable-zlib \
  --enable-protocol=file,pipe \
  --enable-demuxer=matroska,mov,avi,mpegts,mpegps,flv,asf,ogg,wav,aiff,mp3,aac,flac,ac3,eac3,dts,truehd,pcm_s16le,w64,caf \
  --enable-decoder=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,mp3float,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw \
  --enable-parser=aac,aac_latm,ac3,dca,mlp,mpegaudio,opus,vorbis,flac \
  --enable-encoder=pcm_s16le --enable-muxer=wav,pcm_s16le \
  --enable-filter=aresample,aformat,anull,atrim,asetpts,adelay \
  --enable-swresample

make -j"$(sysctl -n hw.ncpu)"
make install
echo "$VERSION" > "$PREFIX/.version"
otool -L "$PREFIX/bin/ffmpeg"
