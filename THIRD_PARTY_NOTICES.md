# Third-party notices

Synapse bundles or depends on the following software and models.

## Swift packages

- **WhisperKit** (argmax-oss-swift), MIT License. https://github.com/argmaxinc/argmax-oss-swift
- **FluidAudio**, Apache License 2.0. https://github.com/FluidInference/FluidAudio
- **Hummingbird**, Apache License 2.0. https://github.com/hummingbird-project/hummingbird
- **MultipartKit**, MIT License. https://github.com/vapor/multipart-kit

The multipart request decoder and `File` part type in `Server/Context.swift` are adapted from the hummingbird-examples `multipart-form` sample (Apache License 2.0). https://github.com/hummingbird-project/hummingbird-examples

## FFmpeg

Synapse bundles an unmodified `ffmpeg` command-line binary, FFmpeg 8.0, licensed under the GNU Lesser General Public License, version 2.1 or later (LGPL-2.1-or-later). https://ffmpeg.org

- It is built without GPL or nonfree components (`--disable-gpl --disable-nonfree`), as a static binary with no external libraries other than zlib, LAME (statically linked, see below) and macOS system libraries.
- Source: https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
- Build recipe: `scripts/build-ffmpeg.sh` in this repository. It downloads the tarball above, verifies its SHA-256, and runs `./configure` with these flags:

```
--prefix=<vendor/ffmpeg> --arch=arm64 --cc=clang
--extra-cflags="-mmacosx-version-min=15.0 -I<lame>/include" --extra-ldflags="-mmacosx-version-min=15.0 -L<lame>/lib"
--disable-everything --disable-gpl --disable-nonfree --disable-network --disable-doc
--disable-ffplay --disable-ffprobe --enable-ffmpeg --disable-shared --enable-static
--disable-autodetect --enable-zlib --enable-libmp3lame
--enable-protocol=file,pipe
--enable-demuxer=matroska,mov,avi,mpegts,mpegps,flv,asf,ogg,wav,aiff,mp3,aac,flac,ac3,eac3,dts,truehd,pcm_s16le,w64,caf
--enable-decoder=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,mp3float,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw
--enable-parser=aac,aac_latm,ac3,dca,mlp,mpegaudio,opus,vorbis,flac
--enable-encoder=pcm_s16le,aac,flac,libmp3lame,opus --enable-muxer=wav,pcm_s16le,mp3,adts,flac,ogg
--enable-filter=aresample,aformat,anull,atrim,asetpts,adelay
--enable-swresample
```

The corresponding source is available at the URL above. Because ffmpeg is a separate executable inside the app bundle (`Contents/MacOS/ffmpeg`), you can replace it with your own build of the same program.

## LAME

The bundled `ffmpeg` statically links LAME 3.100 (MP3 encoder), licensed under the GNU Lesser General Public License, version 2 or later (LGPL-2.0-or-later). https://lame.sourceforge.io

- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- Build recipe: `scripts/build-ffmpeg.sh` in this repository. It verifies the tarball's SHA-256 and builds LAME with `--disable-shared --enable-static --disable-frontend` before building ffmpeg.

## Model weights

Models are downloaded by the user at runtime and are not part of the app bundle.

- **OpenAI Whisper** model weights (as converted to Core ML by Argmax), MIT License. https://github.com/openai/whisper
- **NVIDIA Parakeet TDT** model weights (v2 and v3, as converted to Core ML by FluidInference), Creative Commons Attribution 4.0 International (CC-BY-4.0). Attribution: NVIDIA, Parakeet TDT. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and https://creativecommons.org/licenses/by/4.0/
