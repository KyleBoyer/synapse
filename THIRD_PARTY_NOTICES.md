# Third-party notices

Synapse bundles or depends on the following software and models.

## Swift packages

- **WhisperKit** (argmax-oss-swift), MIT License. https://github.com/argmaxinc/argmax-oss-swift
- **FluidAudio**, Apache License 2.0. https://github.com/FluidInference/FluidAudio
- **Hummingbird**, Apache License 2.0. https://github.com/hummingbird-project/hummingbird
- **MultipartKit**, MIT License. https://github.com/vapor/multipart-kit
- **MLX Swift** and **MLX Swift LM** (MLXLLM, MLXVLM, MLXEmbedders, MLXRerankers), MIT License. https://github.com/ml-explore/mlx-swift and https://github.com/ml-explore/mlx-swift-lm

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

## llama.cpp

- **llama.cpp** (`llama-server`, release b12477), MIT License. https://github.com/ggml-org/llama.cpp
- Bundled as a static binary built by `scripts/build-llama.sh` in this repository: the release tarball (SHA-256 verified), Metal with embedded shaders, no OpenSSL or curl. It runs GGUF models added from Hugging Face.

## Python tools installed on first use

Synapse does not ship these. It installs them with uv into `<models folder>/runtimes/` the first time a model needs them.

- **mlx-video** (pinned to commit 87db56a5), MIT License. https://github.com/Blaizzy/mlx-video
- **mlx-audio** 0.6.6, MIT License. https://github.com/Blaizzy/mlx-audio
- **mlx-vlm** 0.8.0, MIT License. https://github.com/Blaizzy/mlx-vlm

## Model weights

Models are downloaded by the user at runtime and are not part of the app bundle.

- **OpenAI Whisper** model weights (as converted to Core ML by Argmax), MIT License. https://github.com/openai/whisper
- **NVIDIA Parakeet TDT** model weights (v2 and v3, as converted to Core ML by FluidInference), Creative Commons Attribution 4.0 International (CC-BY-4.0). Attribution: NVIDIA, Parakeet TDT. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and https://creativecommons.org/licenses/by/4.0/
- **Qwen3 Embedding 0.6B** and **Qwen3 Reranker 0.6B** (MLX conversions by mlx-community), Apache License 2.0. https://huggingface.co/Qwen
- **EmbeddingGemma 300M**, **Gemma 3n E2B** and **Gemma 4 E2B** (MLX conversions by mlx-community), Gemma Terms of Use. https://ai.google.dev/gemma/terms
- **Speaker diarization** models (Core ML conversions by FluidInference), scoped CC-BY-4.0; see the repository's NOTICE. https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md
- **LTX-2.3** and the LTX-2 Gemma text encoder (MLX conversions by prince-canuma), LTX-2 Community License Agreement. https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2
- **Stable Audio 3 Small** (SFX and Music, MLX conversions by mlx-community), Stability AI Community License; the bundled T5Gemma encoder is under the Gemma Terms of Use. https://huggingface.co/stabilityai
- **LFM3 Omni 2B** (Liquid AI), LFM Open License v1.0. https://huggingface.co/LiquidAI/LFM3-Omni-2B
- **MiniCPM-o 4.5**, Apache License 2.0. https://huggingface.co/openbmb/MiniCPM-o-4_5
- **Qwen3-Omni 30B-A3B** (MLX conversion by mlx-community), Apache License 2.0. https://huggingface.co/Qwen
