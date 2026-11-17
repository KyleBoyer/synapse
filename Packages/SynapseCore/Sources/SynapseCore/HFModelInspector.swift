import Foundation
@preconcurrency import MLXEmbedders
@preconcurrency import MLXLLM
@preconcurrency import MLXVLM

/// A model the user added from Hugging Face. Its id is the repo id (`org/name`), which is also what API clients send.
public struct CustomModel: Codable, Sendable, Hashable, Identifiable {
    public var repo: String
    public var engine: EngineKind
    public var displayName: String
    public var approxMB: Int
    public var ramGB: Int?
    public var id: String { repo }

    public init(repo: String, engine: EngineKind, displayName: String, approxMB: Int, ramGB: Int?) {
        self.repo = repo; self.engine = engine; self.displayName = displayName; self.approxMB = approxMB; self.ramGB = ramGB
    }

    public var spec: ModelSpec {
        ModelSpec(id: repo, engine: engine, displayName: displayName, variant: repo, approxMB: approxMB,
                  languages: nil, canTranslate: false, canDetectLanguage: false, recommendedRAMGB: ramGB)
    }
}

/// Works out whether, and how, Synapse can run a Hugging Face repo: chat models run in-process when the Swift MLX
/// libraries know the architecture, otherwise through mlx-vlm (which knows far more); embedding models run in
/// the Embed engine. Formats Synapse has no runtime for (GGUF, diffusers pipelines) are refused with a reason.
public enum HFModelInspector {
    public struct Report: Sendable, Equatable {
        public var model: CustomModel
        /// Things worth knowing before downloading (runtime, precision, gating, memory).
        public var notes: [String]
    }

    public enum InspectError: Error, LocalizedError, Equatable {
        case badInput, notFound(String), unsupported(String), network(String)
        public var errorDescription: String? {
            switch self {
            case .badInput: "Enter a Hugging Face repo as org/name, or paste its huggingface.co link."
            case .notFound(let r): "No model named \(r) on Hugging Face (or it is private and your token cannot see it)."
            case .unsupported(let why): why
            case .network(let m): "Could not reach Hugging Face: \(m)"
            }
        }
    }

    /// `org/name` from `org/name`, `https://huggingface.co/org/name`, or any link inside the repo.
    public static func repoID(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        for host in ["huggingface.co/", "www.huggingface.co/", "hf.co/"] where s.hasPrefix(host) { s.removeFirst(host.count) }
        if s.hasPrefix("models/") { s.removeFirst("models/".count) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil }),
              !["datasets", "spaces"].contains(parts[0]) else { return nil }
        return parts.joined(separator: "/")
    }

    public static func inspect(_ input: String, token: String?, session: URLSession = .shared) async throws -> Report {
        guard let repo = repoID(from: input) else { throw InspectError.badInput }
        var infoURL = URL(string: "https://huggingface.co/api/models/\(repo)")!
        infoURL.append(queryItems: [URLQueryItem(name: "blobs", value: "true")])
        let info = try await fetchJSON(infoURL, token: token, session: session, repo: repo)
        // The info call carries config's model_type; the file itself also has the quantization block.
        let config = try? await fetchJSON(URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json")!,
                                          token: token, session: session, repo: repo)
        return try await classify(repo: repo, info: info, config: config ?? info["config"] as? [String: Any],
                                  chatInProcess: { t in
                                      if await VLMTypeRegistry.shared.contains(t) { return true }
                                      return await LLMTypeRegistry.shared.contains(t)
                                  },
                                  embedder: { t in await EmbedderTypeRegistry.shared.contains(t) })
    }

    private static func fetchJSON(_ url: URL, token: String?, session: URLSession, repo: String) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw InspectError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 401 { throw InspectError.notFound(repo) }
        guard (200..<300).contains(status), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InspectError.network("HTTP \(status)")
        }
        return o
    }

    /// The decision itself, separate from the network so it can be tested with recorded repo metadata.
    static func classify(repo: String, info: [String: Any], config: [String: Any]?,
                         chatInProcess: (String) async -> Bool, embedder: (String) async -> Bool) async throws -> Report {
        let files = (info["siblings"] as? [[String: Any]] ?? []).compactMap { f -> (String, Int64)? in
            guard let name = f["rfilename"] as? String else { return nil }
            return (name, (f["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let names = files.map(\.0)
        if names.contains("model_index.json") {
            throw InspectError.unsupported("\(repo) is a diffusers pipeline (image or video generation). Those come from the built-in catalog for now.")
        }
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            if names.contains(where: { $0.hasSuffix(".gguf") }) {
                throw InspectError.unsupported("\(repo) has only GGUF files, which Synapse does not run. Look for an MLX or safetensors version (mlx-community often has one).")
            }
            throw InspectError.unsupported("\(repo) has no safetensors weights.")
        }
        let pipeline = info["pipeline_tag"] as? String
        if let p = pipeline, ["automatic-speech-recognition", "text-to-speech", "text-to-audio", "text-to-image",
                              "text-to-video", "image-to-video", "image-to-image"].contains(p) {
            throw InspectError.unsupported("\(repo) is a \(p) model. Those come from the built-in catalog for now.")
        }
        guard let modelType = config?["model_type"] as? String else {
            throw InspectError.unsupported("\(repo) has no model_type in its config.json, so its architecture is unknown.")
        }

        var notes: [String] = []
        let engine: EngineKind
        if pipeline == "feature-extraction" || pipeline == "sentence-similarity" {
            guard await embedder(modelType) else {
                throw InspectError.unsupported("\(repo) is an embedding model with an architecture (\(modelType)) the Embed engine does not support.")
            }
            engine = .embedding
            notes.append("Embedding model: use it in Embed and at /v1/embeddings.")
        } else if await chatInProcess(modelType) {
            engine = .mlx
            notes.append("Runs in Synapse (MLX, \(modelType)).")
        } else {
            engine = .mlxvlm
            notes.append("Runs through mlx-vlm (\(modelType)); the first use installs its Python runtime.")
        }
        let bytes = files.filter { HFDownloader.wanted($0.0) }.reduce(Int64(0)) { $0 + $1.1 }
        let mb = Int((Double(bytes) / 1_000_000).rounded())
        let quantized = config?["quantization"] != nil || config?["quantization_config"] != nil
        if !quantized && mb > 4000 {
            notes.append("Not quantized: weights load at full precision. An MLX 4-bit version (often under mlx-community) needs about a quarter of the memory.")
        }
        let gated = (info["gated"] as? String) != nil || (info["gated"] as? Bool) == true
        if gated { notes.append("Gated: accept its license on huggingface.co first; Synapse uses your hf login or the token in Settings.") }
        let ram = max(1, Int((Double(mb) / 1000 * 1.25).rounded(.up)))
        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        return Report(model: CustomModel(repo: repo, engine: engine, displayName: name, approxMB: mb, ramGB: ram), notes: notes)
    }
}
