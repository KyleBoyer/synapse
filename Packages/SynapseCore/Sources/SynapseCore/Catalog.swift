import Foundation
import Synchronization

public enum Catalog {
    private static func whisper(_ id: String, _ name: String, _ variant: String, _ mb: Int) -> ModelSpec {
        ModelSpec(id: id, engine: .whisper, displayName: name, variant: variant, approxMB: mb,
                  languages: nil, canTranslate: true, canDetectLanguage: true)
    }

    /// Qwen3.5 small models are natively multimodal: chat plus image input.
    private static func qwen(_ id: String, _ name: String, _ repo: String, _ mb: Int) -> ModelSpec {
        ModelSpec(id: id, engine: .mlx, displayName: name, variant: repo, approxMB: mb,
                  languages: nil, canTranslate: false, canDetectLanguage: false)
    }

    private static func image(_ id: String, _ name: String, _ engine: EngineKind, _ repo: String, _ mb: Int,
                              edit: Bool, ramGB: Int? = nil) -> ModelSpec {
        ModelSpec(id: id, engine: engine, displayName: name, variant: repo, approxMB: mb, languages: nil,
                  canTranslate: false, canDetectLanguage: false, canEditImages: edit, recommendedRAMGB: ramGB)
    }

    private static func hf(_ id: String, _ name: String, _ engine: EngineKind, _ repo: String, _ mb: Int,
                           ramGB: Int? = nil) -> ModelSpec {
        image(id, name, engine, repo, mb, edit: false, ramGB: ramGB)
    }

    private static func realtime(_ id: String, _ name: String, _ engine: EngineKind, _ variant: String, _ mb: Int,
                                 ramGB: Int?) -> ModelSpec {
        ModelSpec(id: id, engine: engine, displayName: name, variant: variant, approxMB: mb, languages: nil,
                  canTranslate: false, canDetectLanguage: false, recommendedRAMGB: ramGB)
    }

    /// Models added from Hugging Face (Settings.customModels), merged in by `setCustom`.
    private static let customStore = Mutex<[ModelSpec]>([])
    public static var custom: [ModelSpec] { customStore.withLock { $0 } }
    /// A repo id that is also a built-in id stays built-in.
    public static func setCustom(_ models: [CustomModel]) {
        let ids = Set(builtIn.map(\.id))
        customStore.withLock { $0 = models.map(\.spec).filter { !ids.contains($0.id) } }
    }
    public static var all: [ModelSpec] { builtIn + custom }

    public static let builtIn: [ModelSpec] = [
        whisper("whisper-tiny", "Whisper Tiny", "tiny", 75),
        whisper("whisper-base", "Whisper Base", "base", 145),
        whisper("whisper-small", "Whisper Small", "small", 480),
        whisper("whisper-medium", "Whisper Medium", "medium", 1500),
        whisper("whisper-large-v3", "Whisper Large v3", "large-v3", 3000),
        whisper("whisper-large-v3-turbo", "Whisper Large v3 Turbo", "large-v3-v20240930_turbo", 1600),
        whisper("whisper-large-v3-turbo-q", "Whisper Large v3 Turbo (Quantized)", "large-v3-v20240930_turbo_632MB", 632),
        ModelSpec(id: "distil-large-v3", engine: .whisper, displayName: "Distil Large v3 (English)", variant: "distil-large-v3",
                  approxMB: 1500, languages: ["en"], canTranslate: false, canDetectLanguage: false),
        ModelSpec(id: "parakeet-v3", engine: .parakeet, displayName: "Parakeet v3", variant: "v3", approxMB: 600,
                  languages: Set("bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk".split(separator: " ").map(String.init)),
                  canTranslate: false, canDetectLanguage: false),
        qwen("qwen3.5-0.8b", "Qwen3.5 0.8B", "mlx-community/Qwen3.5-0.8B-4bit", 652),
        qwen("qwen3.5-2b", "Qwen3.5 2B", "mlx-community/Qwen3.5-2B-4bit", 1749),
        qwen("qwen3.5-4b", "Qwen3.5 4B", "mlx-community/Qwen3.5-4B-MLX-4bit", 3061),
        qwen("qwen3.5-9b", "Qwen3.5 9B", "mlx-community/Qwen3.5-9B-MLX-4bit", 5977),
        image("flux2-klein-4b", "FLUX.2 klein 4B", .flux2, "black-forest-labs/FLUX.2-klein-4B", 16000, edit: true, ramGB: 24),
        // Under 48 GB it runs with a 4-bit encoder and transformer (Flux2ImageEngine); verified on a 16 GB M4.
        image("flux2-klein-9b", "FLUX.2 klein 9B (gated, non-commercial)", .flux2, "black-forest-labs/FLUX.2-klein-9B", 34600, edit: true, ramGB: 16),
        image("z-image-turbo", "Z-Image Turbo", .zimage, "mlx-community/Z-Image-Turbo-bf16", 20540, edit: false, ramGB: 32),
        image("z-image", "Z-Image", .zimage, "mlx-community/Z-Image-bf16", 20540, edit: false, ramGB: 32),
        image("qwen-image-2.1-q4", "Qwen-Image 2.1 (4-bit, research license)", .mflux, "mlx-community/Qwen-Image-2.1-mflux-q4", 9600, edit: false, ramGB: 16),
        image("qwen-image-2512-4bit", "Qwen-Image 2512 (4-bit)", .mflux, "mlx-community/Qwen-Image-2512-4bit", 25900, edit: false, ramGB: 32),
        image("qwen-image-edit-2511-8bit", "Qwen-Image Edit 2511 (8-bit)", .mflux, "mlx-community/qwen-image-edit-2511-8bit", 37500, edit: true, ramGB: 48),
        // Realtime. shortcut: variants/sizes are provisional until each engine's downloader lands.
        realtime("parakeet-eou-120m", "Parakeet EOU 120M (streaming, English)", .speech, "parakeet-eou-160ms", 220, ramGB: nil),
        realtime("silero-vad", "Silero VAD", .speech, "silero-vad", 2, ramGB: nil),
        realtime("pocket-tts", "PocketTTS (streaming voice)", .speech, "pocket-tts", 523, ramGB: nil),
        // About 47 GB of LTX-2.3 plus 49 GB for the Gemma 3 12B text encoder borrowed from LTX-2 (see VideoEngines.download).
        // Under 64 GB it runs in low-memory mode instead (8 GB 4-bit Gemma, transformer quantized while loading; ~55 GB
        // download); verified on a 16 GB M4. LTX-2 Community License. The name stays short so the toolbar's menu fits.
        hf("ltx-2.3-distilled", "LTX-2.3 Distilled", .videogen, "prince-canuma/LTX-2.3-distilled", 96000, ramGB: 16),
        // Text or a start image to video at 24 fps (Apache-2.0); 8-bit transformer, bf16 UMT5 text encoder (freed before
        // denoising). On a 16 GB M4 an 832x480, 2 s clip takes about 36 s per step, 40 steps.
        hf("wan2.2-ti2v-5b", "Wan 2.2 TI2V 5B", .videogen, "Anes1032/Wan2.2-TI2V-5B-mlx-q8", 19600, ramGB: 16),
        // Video with stereo sound through stable-diffusion.cpp (MiniMax H3 Community License). The files depend on the Mac
        // (MiniMaxH3.files): under 64 GB a pruned 2-bit transformer and the 4B text encoder (14.4 GB, pages on 16 GB:
        // a 1.6 s 480x288 clip took 13 min with the Turbo LoRA), otherwise 4-bit with the 32B encoder (43 GB).
        hf("minimax-h3", "MiniMax H3", .videogen, "MiniMaxAI/MiniMax-H3", 14400, ramGB: 24),
        // LoRA add-on: H3 in 4 steps instead of 20. Applied per clip from the Video pane's LoRA menu.
        ModelSpec(id: "minimax-h3-turbo", engine: .videogen, displayName: "MiniMax H3 Turbo (4-step LoRA)",
                  variant: "Comfy-Org/MiniMax-H3", approxMB: 1960, languages: nil, canTranslate: false, canDetectLanguage: false,
                  files: ["loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors"], baseModel: "minimax-h3"),
        // Stability AI Community License (free under $1M annual revenue). The cards show a license prompt but the
        // repos are not gated, so no token is needed. Names stay short so the toolbar's model menu fits.
        hf("stable-audio-3-small-sfx", "Stable Audio 3 SFX", .audiogen, "mlx-community/stable-audio-3-small-sfx", 3490, ramGB: 8),
        hf("stable-audio-3-small-music", "Stable Audio 3 Music", .audiogen, "mlx-community/stable-audio-3-small-music", 3490, ramGB: 8),
        // General sound and music in one larger model (Stability AI Community License).
        hf("stable-audio-3-medium", "Stable Audio 3 Medium", .audiogen, "mlx-community/stable-audio-3-medium", 5833, ramGB: 12),
        // Full songs from a style caption, with sung vocals when lyrics are given (MiniMax Music 3 Community License).
        hf("minimax-music3-4bit", "MiniMax Music 3 (songs, vocals)", .audiogen, "mlx-community/MiniMax-Music3-4bit", 9211, ramGB: 16),
        // Instrumental music from a style caption, 48 kHz stereo (MIT). A 20 s clip takes ~10 s on a 16 GB M4.
        hf("ace-step-1.5-4bit", "ACE-Step 1.5 (instrumental)", .audiogen, "mlx-community/ACE-Step1.5-MLX-4bit", 5300, ramGB: 12),
        ModelSpec(id: "depth-anything-v2-small", engine: .imagetool, displayName: "Depth Anything V2 small (depth maps)",
                  variant: "apple/coreml-depth-anything-v2-small", approxMB: 50, languages: nil, canTranslate: false,
                  canDetectLanguage: false, files: ["DepthAnythingV2SmallF16.mlpackage/"]),
        hf("real-esrgan-x4plus", "Real-ESRGAN x4plus (upscaling)", .imagetool, "mlx-community/Real-ESRGAN-x4plus", 33),
        hf("real-esrgan-general-x4v3", "Real-ESRGAN general x4v3 (fast upscaling, for video)", .imagetool, "mlx-community/Real-ESRGAN-general-x4v3", 5),
        // Audio to audio through mlx-audio's speech-to-speech models.
        hf("deepfilternet-3", "DeepFilterNet 3 (noise removal)", .audioedit, "mlx-community/DeepFilterNet-mlx", 30),
        hf("nemotron-reuse", "NemotronLabs RE-USE (noise removal)", .audioedit, "nvidia/NVIDIA-NemotronLabs-RE-USE", 40),
        hf("dialoguesidon", "DialogueSidon (splits two speakers, non-commercial)", .audioedit, "mlx-community/DialogueSidon-bf16", 889, ramGB: 4),
        hf("sam-audio-small", "SAM-Audio small (separates a described sound, SAM license)", .audioedit, "mlx-community/sam-audio-small", 2410, ramGB: 8),
        // Omni models through a managed mlx-vlm server (audio, image and video in; Gemma 3n has no video).
        hf("gemma-3n-e2b", "Gemma 3n E2B (omni, Gemma terms)", .mlxvlm, "mlx-community/gemma-3n-E2B-it-4bit", 4295, ramGB: 8),
        // Gemma 4 hears through mlx-vlm, which has its audio tower; mlx-swift-lm loads it without one (see P5).
        hf("gemma-4-e2b", "Gemma 4 E2B (omni, Gemma terms)", .mlxvlm, "mlx-community/gemma-4-e2b-it-4bit", 3583, ramGB: 8),
        // Hears, sees and speaks: mlx-vlm's generate_audio gives it a voice (Live, Voice call). LFM Open License v1.0.
        hf("lfm3-omni-2b", "LFM3 Omni 2B (speaks)", .mlxvlm, "LiquidAI/LFM3-Omni-2B", 4500, ramGB: 8),
        hf("minicpm-o-4.5", "MiniCPM-o 4.5 (omni)", .mlxvlm, "openbmb/MiniCPM-o-4_5", 20000, ramGB: 32),
        // bf16, prepared after download (ModelPrep): the published 4/5/8-bit MLX copies were quantized by mlx-vlm 0.3.10
        // and give empty answers to audio; quantizing the bf16 with the current mlx-vlm hears correctly.
        hf("qwen3-omni-30b", "Qwen3-Omni 30B-A3B (omni)", .mlxvlm, "mlx-community/Qwen3-Omni-30B-A3B-Instruct-bf16", 70530, ramGB: 16),
        realtime("speaker-diarizer", "Speaker diarization (who spoke when)", .speech, "speaker-diarizer", 21, ramGB: nil),
        realtime("kokoro-82m", "Kokoro 82M (voices)", .speech, "kokoro", 350, ramGB: nil),
        // Voice cloning through mlx-audio, ranked by speaker similarity to the reference in VoiceCloneE2ETests' setup:
        // Qwen3-TTS 0.83, VoxCPM2 0.76, Chatterbox Turbo 0.65 (PocketTTS 0.59).
        hf("qwen3-tts-1.7b", "Qwen3-TTS 1.7B (clones voices)", .mlxspeech, "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", 2968, ramGB: 8),
        hf("voxcpm2", "VoxCPM2 (clones voices)", .mlxspeech, "mlx-community/VoxCPM2-8bit", 3078, ramGB: 8),
        hf("chatterbox-turbo", "Chatterbox Turbo (clones voices, English)", .mlxspeech, "mlx-community/chatterbox-turbo-4bit", 398, ramGB: 2),
        realtime("voicechat-11b", "Nemotron VoiceChat 11B (full duplex)", .duplex, "voicechat-int8", 12127, ramGB: 20),
        realtime("voicechat-11b-int5", "Nemotron VoiceChat 11B int5 (full duplex, smaller)", .duplex, "voicechat-int5", 8581, ramGB: 14),
        realtime("personaplex-7b", "PersonaPlex 7B (full duplex, non-commercial)", .duplex, "personaplex-4bit", 5821, ramGB: 12),
        realtime("hibiki-zero-3b", "Hibiki Zero 3B (speech translation to English, non-commercial)", .duplex, "hibiki-zero-8bit", 4130, ramGB: 10),
        hf("qwen3-embedding-0.6b", "Qwen3 Embedding 0.6B", .embedding, "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", 335),
        hf("embeddinggemma-300m", "EmbeddingGemma 300M (Gemma terms)", .embedding, "mlx-community/embeddinggemma-300m-4bit", 200),
        hf("qwen3-reranker-0.6b", "Qwen3 Reranker 0.6B", .reranker, "mlx-community/Qwen3-Reranker-0.6B-4bit", 335),
        // Text and images in one vector space, through mlx-embeddings.
        hf("qwen3-vl-embedding-2b", "Qwen3-VL Embedding 2B (text and images)", .embedding, "mlx-community/Qwen3-VL-Embedding-2B-8bit", 2534, ramGB: 4),
        hf("siglip2-so400m", "SigLIP2 so400m (text and images)", .embedding, "mlx-community/siglip2-so400m-patch16-384", 2200, ramGB: 4),
        ModelSpec(id: "parakeet-v2", engine: .parakeet, displayName: "Parakeet v2 (English)", variant: "v2", approxMB: 600,
                  languages: ["en"], canTranslate: false, canDetectLanguage: false),
    ]

    public static func spec(_ id: String) -> ModelSpec? { all.first { $0.id == id } }

    public static let whisperFallbackOrder: [String] = [
        "whisper-large-v3-turbo", "whisper-large-v3-turbo-q", "whisper-large-v3", "whisper-medium", "whisper-small", "whisper-base", "whisper-tiny",
    ]
}

public enum ResolveError: Error, Equatable, LocalizedError {
    case unknownModel(String), notDownloaded(String), noCapableModel, wrongKind(String), noChatModel

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model '\(id)'."
        case .notDownloaded(let id): return "Model '\(id)' is not downloaded."
        case .noCapableModel: return "No downloaded Whisper model can handle this request."
        case .noChatModel: return "No chat model is downloaded. Download one (e.g. qwen3.5-0.8b) in Models."
        case .wrongKind(let id): return "Model '\(id)' cannot be used for this endpoint."
        }
    }
}

public enum ModelResolver {
    public static func resolve(requested: String?, task: TaskKind, language: String?, defaultID: String,
                               downloaded: Set<String>) throws -> ModelSpec {
        // OpenAI clients hard-code their own transcription model names; they mean "the default local model".
        let aliases: Set<String> = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe-diarize"]
        let id = (requested == nil || aliases.contains(requested!)) ? defaultID : requested!
        guard var spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
        guard !spec.isChat, !spec.isEmbedding, !spec.isReranker, spec.engine != .videogen, !spec.isAudioGen, !spec.isAudioEdit, spec.engine != .imagetool else { throw ResolveError.wrongKind(id) }
        if (task == .translate && !spec.canTranslate) || !spec.supports(language: language) {
            guard let fb = whisperFallbackOrder.compactMap(Catalog.spec).first(where: {
                downloaded.contains($0.id) && ($0.canTranslate || task != .translate) && $0.supports(language: language)
            }) else { throw ResolveError.noCapableModel }
            spec = fb
        }
        guard downloaded.contains(spec.id) else { throw ResolveError.notDownloaded(spec.id) }
        return spec
    }

    /// Chat requests: nil picks the smallest downloaded chat model.
    public static func resolveChat(requested: String?, downloaded: Set<String>) throws -> ModelSpec {
        if let id = requested, !id.isEmpty {
            guard let spec = Catalog.spec(id) else { throw ResolveError.unknownModel(id) }
            guard spec.isChat else { throw ResolveError.wrongKind(id) }
            guard downloaded.contains(id) else { throw ResolveError.notDownloaded(id) }
            return spec
        }
        guard let spec = Catalog.all.filter({ $0.isChat && downloaded.contains($0.id) })
            .min(by: { $0.approxMB < $1.approxMB }) else { throw ResolveError.noChatModel }
        return spec
    }

    private static var whisperFallbackOrder: [String] { Catalog.whisperFallbackOrder }

    public static func smallestDetector(downloaded: Set<String>) -> ModelSpec? {
        ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large-v3-turbo-q", "whisper-large-v3-turbo", "whisper-large-v3"]
            .compactMap(Catalog.spec).first { downloaded.contains($0.id) && $0.canDetectLanguage }
    }
}
