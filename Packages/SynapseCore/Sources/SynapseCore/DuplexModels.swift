import Foundation

/// Downloads and locates full-duplex and speech-translation weights (speech-swift models).
/// Files land in `<root>/duplex/<variant>` via HFDownloader; speech-swift is then pointed at that folder.
enum DuplexModels {
    /// Catalog variant -> Hugging Face repo (aufklarer's MLX conversions that speech-swift loads).
    static let repos: [String: String] = [
        "voicechat-int8": "aufklarer/VoiceChat-11B-Perception-MLX-int8",   // encoder/ llm/ tts/ (12.1 GB)
        "voicechat-int5": "aufklarer/VoiceChat-11B-Perception-MLX-int5",   // same layout, 5-bit with 8-bit heads (8.6 GB)
        "personaplex-4bit": "aufklarer/PersonaPlex-7B-MLX-4bit",           // 4 safetensors + voices/ + SPM (5.8 GB)
        "hibiki-zero-8bit": "aufklarer/Hibiki-Zero-3B-MLX-8bit",           // 4 safetensors + SPM + config (4.1 GB)
    ]

    static func folder(_ spec: ModelSpec, root: URL) -> URL {
        root.appending(path: "duplex/\(spec.variant)", directoryHint: .isDirectory)
    }

    static func download(_ spec: ModelSpec, root: URL, token: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let repo = repos[spec.variant] else { throw EngineError.unsupported("\(spec.displayName): unknown variant \(spec.variant)") }
        return try await HFDownloader.download(repo: repo, to: folder(spec, root: root), token: token, progress: progress)
    }
}
