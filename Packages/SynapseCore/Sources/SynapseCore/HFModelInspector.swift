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
    /// GGUF: the chosen weights file(s) and any vision projector.
    public var files: [String]?
    public var id: String { repo }

    public init(repo: String, engine: EngineKind, displayName: String, approxMB: Int, ramGB: Int?, files: [String]? = nil) {
        self.repo = repo; self.engine = engine; self.displayName = displayName; self.approxMB = approxMB; self.ramGB = ramGB
        self.files = files
    }

    public var spec: ModelSpec {
        ModelSpec(id: repo, engine: engine, displayName: displayName, variant: repo, approxMB: approxMB,
                  languages: nil, canTranslate: false, canDetectLanguage: false, recommendedRAMGB: ramGB, files: files)
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
        /// GGUF repos: every quantization on offer; `model` uses `chosen`.
        public var ggufChoices: [GGUFChoice] = []
        public var projector: GGUFChoice?

        /// The same report with another quantization picked.
        public func choosing(_ c: GGUFChoice) -> Report {
            var r = self
            let mb = c.mb + (projector?.mb ?? 0)
            r.model.files = c.files + (projector?.files ?? [])
            r.model.approxMB = mb
            r.model.ramGB = HFModelInspector.ram(mb)
            return r
        }
    }

    /// One GGUF quantization: its label (Q4_K_M, ...), file(s) (split models have parts) and size.
    public struct GGUFChoice: Sendable, Equatable, Hashable, Identifiable {
        public var label: String
        public var files: [String]
        public var mb: Int
        public var id: String { files.first ?? label }
    }

    /// Preference when picking a default: good quality per byte first.
    static let quantOrder = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "IQ4_XS", "Q4_0", "Q5_K_S", "Q6_K", "Q8_0", "Q3_K_M", "Q3_K_L"]

    static func ram(_ mb: Int) -> Int { max(1, Int((Double(mb) / 1000 * 1.25).rounded(.up))) }

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
        let pipeline = info["pipeline_tag"] as? String
        if let p = pipeline, ["automatic-speech-recognition", "text-to-speech", "text-to-audio", "text-to-image",
                              "text-to-video", "image-to-video", "image-to-image"].contains(p) {
            throw InspectError.unsupported("\(repo) is a \(p) model. Those come from the built-in catalog for now.")
        }
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            if names.contains(where: { $0.lowercased().hasSuffix(".gguf") }) {
                return try gguf(repo: repo, files: files, gated: (info["gated"] as? String) != nil || (info["gated"] as? Bool) == true)
            }
            throw InspectError.unsupported("\(repo) has no safetensors or GGUF weights.")
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
        let ram = Self.ram(mb)
        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        return Report(model: CustomModel(repo: repo, engine: engine, displayName: name, approxMB: mb, ramGB: ram), notes: notes)
    }

    /// A GGUF-only repo: group the files into quantizations (split models have numbered parts), pick a default
    /// that fits this Mac, and add a vision projector (mmproj) when the repo has one.
    static func gguf(repo: String, files: [(String, Int64)], gated: Bool,
                     physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> Report {
        let all = files.filter { $0.0.lowercased().hasSuffix(".gguf") }
        let projectors = all.filter { $0.0.lowercased().contains("mmproj") }
        var groups: [String: (files: [String], bytes: Int64)] = [:]
        for (name, size) in all where !name.lowercased().contains("mmproj") {
            let key = name.replacing(/-\d{5}-of-\d{5}(?=\.gguf$)/, with: "")
            groups[key, default: ([], 0)].files.append(name)
            groups[key, default: ([], 0)].bytes += size
        }
        guard !groups.isEmpty else { throw InspectError.unsupported("\(repo) has only vision projector files, no model weights.") }
        let choices = groups.map { key, g in
            GGUFChoice(label: quantLabel(key), files: g.files.sorted(), mb: Int((Double(g.bytes) / 1_000_000).rounded()))
        }.sorted { $0.mb < $1.mb }
        let budgetMB = Int(Double(physicalMemory) * 0.75 / 1_000_000 / 1.25)
        let fits = choices.filter { $0.mb <= budgetMB }
        let preferred = quantOrder.lazy.compactMap { q in fits.first { $0.label.uppercased() == q } }.first
        let chosen = preferred ?? fits.last ?? choices[0]
        let projector = projectors.min { a, b in
            let fa = a.0.lowercased().contains("f16"), fb = b.0.lowercased().contains("f16")
            return fa != fb ? fa : a.1 < b.1
        }.map { GGUFChoice(label: "vision projector", files: [$0.0], mb: Int((Double($0.1) / 1_000_000).rounded())) }
        var notes = ["Runs through llama.cpp (GGUF). Pick another quantization below if you like."]
        if projector != nil { notes.append("Includes the vision projector, so it can read images.") }
        if gated { notes.append("Gated: accept its license on huggingface.co first; Synapse uses your hf login or the token in Settings.") }
        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        let base = Report(model: CustomModel(repo: repo, engine: .gguf, displayName: name, approxMB: 0, ramGB: nil),
                          notes: notes, ggufChoices: choices, projector: projector)
        return base.choosing(chosen)
    }

    /// "Llama-3.2-1B-Instruct-Q4_K_M.gguf" -> "Q4_K_M"; the file name when no quantization tag is found.
    static func quantLabel(_ file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        if let m = stem.firstMatch(of: /(?i)(UD-)?(IQ\d_[A-Z]+|Q\d_K_[SMLX]+|Q\d_K|Q\d_\d|BF16|F16|F32)$/) {
            return String(m.output.0).uppercased()
        }
        return (stem as NSString).lastPathComponent
    }
}
