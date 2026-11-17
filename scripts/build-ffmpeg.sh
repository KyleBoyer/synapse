#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=8.0
SHA256=b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e
LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
PREFIX="$ROOT/vendor/ffmpeg"
MARKER="$VERSION-audioenc1"
SRC="$ROOT/vendor/src"
TARBALL="$SRC/ffmpeg-$VERSION.tar.xz"

if [[ -x "$PREFIX/bin/ffmpeg" && "$(cat "$PREFIX/.version" 2>/dev/null)" == "$MARKER" ]]; then
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

# LAME (LGPL) is built static so the bundled ffmpeg stays free of third-party dylibs.
LAME_TARBALL="$SRC/lame-$LAME_VERSION.tar.gz"
[[ -f "$LAME_TARBALL" ]] || curl -fsSL -o "$LAME_TARBALL" "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
echo "$LAME_SHA256  $LAME_TARBALL" | shasum -a 256 -c -
# libtool and ffmpeg's configure both break on a space in the path, so LAME builds and installs under a temp dir.
LAME_WORK="$(mktemp -d)"; trap 'rm -rf "$LAME_WORK"' EXIT
LAME_PREFIX="$LAME_WORK/prefix"
tar -xf "$LAME_TARBALL" -C "$LAME_WORK"
(cd "$LAME_WORK/lame-$LAME_VERSION" && ./configure --prefix="$LAME_PREFIX" --disable-shared --enable-static --disable-frontend --disable-debug \
  CFLAGS="-mmacosx-version-min=15.0" && make -j"$(sysctl -n hw.ncpu)" && make install)

rm -rf "$SRC/ffmpeg-$VERSION"
tar -xf "$TARBALL" -C "$SRC"
cd "$SRC/ffmpeg-$VERSION"

./configure --prefix="$PREFIX" --arch=arm64 --cc=clang \
  --extra-cflags="-mmacosx-version-min=15.0 -I$LAME_PREFIX/include" --extra-ldflags="-mmacosx-version-min=15.0 -L$LAME_PREFIX/lib" \
  --disable-everything --disable-gpl --disable-nonfree --disable-network --disable-doc \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg --disable-shared --enable-static \
  --disable-autodetect --enable-zlib --enable-libmp3lame \
  --enable-protocol=file,pipe \
  --enable-demuxer=matroska,mov,avi,mpegts,mpegps,flv,asf,ogg,wav,aiff,mp3,aac,flac,ac3,eac3,dts,truehd,pcm_s16le,w64,caf \
  --enable-decoder=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,mp3float,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw \
  --enable-parser=aac,aac_latm,ac3,dca,mlp,mpegaudio,opus,vorbis,flac \
  --enable-encoder=pcm_s16le,aac,flac,libmp3lame,opus --enable-muxer=wav,pcm_s16le,mp3,adts,flac,ogg \
  --enable-filter=aresample,aformat,anull,atrim,asetpts,adelay \
  --enable-swresample

make -j"$(sysctl -n hw.ncpu)"
make install
echo "$MARKER" > "$PREFIX/.version"
otool -L "$PREFIX/bin/ffmpeg"
