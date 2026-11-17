import Foundation
import Hummingbird

/// What Synapse knows about one downloaded model, read from its folder. Every model listing is built from this.
struct ModelFacts: Sendable {
    var id: String
    var spec: ModelSpec?
    var created = Date(timeIntervalSince1970: 0)
    var sizeBytes: Int64 = 0
    var architecture: String?
    var contextLength: Int?
    var quantization: String?
    var bits: Int?
    var vision = false
    var reasoning = false
    var tools = false
    var loaded = false
    var inputs: [String] = []
    var outputs: [String] = []

    var kind: String {
        guard let spec else { return "chat" }   // vOOM ids
        switch spec.engine {
        case .whisper, .parakeet: return "transcription"
        case .mlx, .mlxvlm, .gguf: return "chat"
        case .flux2, .zimage, .mflux: return "image"
        case .embedding: return "embedding"
        case .reranker: return "reranker"
        case .videogen: return "video"
        case .audiogen: return "sound"
        case .duplex: return "speech-to-speech"
        case .speech: return spec.isTTS ? "speech" : spec.id == "speaker-diarizer" ? "diarization" : "realtime"
        case .mlxspeech: return "speech"
        }
    }

    var endpoints: [String] {
        switch kind {
        case "chat": ["/v1/responses", "/v1/messages", "/v1/chat/completions", "/api/v1/chat"]
        case "transcription": ["/v1/audio/transcriptions", "/v1/audio/translations"]
        case "image": spec?.canEditImages == true ? ["/v1/images/generations", "/v1/images/edits"] : ["/v1/images/generations"]
        case "embedding": ["/v1/embeddings"]
        case "reranker": ["/v1/rerank"]
        case "video": ["/v1/videos"]
        case "sound": ["/v1/audio/generations"]
        case "speech": ["/v1/audio/speech", "/v1/realtime"]
        case "diarization": ["/v1/audio/transcriptions"]
        default: ["/v1/realtime"]
        }
    }

    static func read(_ id: String, folder: URL?, chat: ChatService, residents: Set<String>) async -> ModelFacts {
        var f = ModelFacts(id: id, spec: Catalog.spec(id))
        f.loaded = residents.contains(id) || residents.contains { $0.hasSuffix(":" + id) }
        guard let spec = f.spec, let folder else { return f }
        let fm = FileManager.default
        f.created = (try? fm.attributesOfItem(atPath: folder.path)[.creationDate] as? Date) ?? f.created
        f.sizeBytes = folderBytes(folder)
        let config = (try? Data(contentsOf: folder.appending(path: "config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let text = config?["text_config"] as? [String: Any]
        f.architecture = config?["model_type"] as? String
        f.contextLength = (config?["max_position_embeddings"] ?? text?["max_position_embeddings"]) as? Int
        let q = (config?["quantization"] ?? config?["quantization_config"]) as? [String: Any]
        f.bits = q?["bits"] as? Int
        f.quantization = f.bits.map { "\($0)bit" }
        if spec.engine == .gguf, let weights = spec.files?.first(where: { !$0.lowercased().contains("mmproj") }) {
            f.quantization = HFModelInspector.quantLabel(weights)
            f.bits = f.quantization.flatMap { $0.firstMatch(of: /\d+/) }.flatMap { Int($0.output) }
        }

        switch f.kind {
        case "chat":
            // The chat template says whether the model thinks and calls tools.
            let template = ["chat_template.jinja", "chat_template.json", "tokenizer_config.json"]
                .compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }.joined()
            f.reasoning = template.contains("<think>") || template.contains("enable_thinking")
            f.tools = template.contains("tools")
            f.vision = switch spec.engine {
            case .gguf: spec.files?.contains { $0.lowercased().contains("mmproj") } == true
            case .mlxvlm: true
            default: fm.fileExists(atPath: folder.appending(path: "preprocessor_config.json").path)
            }
            f.inputs = ["text"] + (f.vision ? ["image"] : []) + (await chat.supportsVideo(spec) ? ["video"] : [])
                + (await chat.supportsAudio(spec) ? ["audio"] : [])
            f.outputs = ["text"] + (OmniVoices.canSpeak(spec) ? ["audio"] : [])
        case "transcription", "diarization": (f.inputs, f.outputs) = (["audio"], ["text"])
        case "image": (f.inputs, f.outputs) = (spec.canEditImages ? ["text", "image"] : ["text"], ["image"])
        case "embedding", "reranker": (f.inputs, f.outputs) = (["text"], ["embedding"])
        case "video": (f.inputs, f.outputs) = (["text", "image"], ["video"])
        case "sound": (f.inputs, f.outputs) = (["text"], ["audio"])
        case "speech": (f.inputs, f.outputs) = (["text"], ["audio"])
        default: (f.inputs, f.outputs) = (["audio"], ["audio", "text"])
        }
        return f
    }

    private static func folderBytes(_ folder: URL) -> Int64 {
        let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.allObjects as? [URL] ?? []
        return urls.reduce(0) { sum, u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return sum + (v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : 0)
        }
    }

    /// One object that reads as an OpenAI model (`object`, `created`, `owned_by`) and an Anthropic ModelInfo (`type`,
    /// `display_name`, `created_at`, `capabilities`, token limits), plus Synapse's own facts under `synapse`.
    var wire: AnyEncodableDict {
        let iso = ISO8601DateFormatter().string(from: created)
        return AnyEncodableDict([
            "id": id, "object": "model", "created": Int(created.timeIntervalSince1970), "owned_by": "synapse",
            "type": "model", "display_name": spec?.displayName ?? id, "created_at": iso, "lifecycle": "active",
            "deprecated_at": String?.none, "retires_at": String?.none, "line": String?.none,
            "max_input_tokens": kind == "chat" ? contextLength : nil, "max_tokens": kind == "chat" ? contextLength : nil,
            "capabilities": kind == "chat" ? anthropicCapabilities : nil,
            "synapse": AnyEncodableDict([
                "kind": kind, "engine": spec?.engine.rawValue ?? "voom", "size_bytes": sizeBytes, "loaded": loaded,
                "architecture": architecture, "context_length": contextLength, "quantization": quantization,
                "input_modalities": inputs, "output_modalities": outputs, "endpoints": endpoints,
            ]),
        ])
    }

    /// Anthropic's capability tree: what Synapse's Messages route does for this model. Hosted-only features are false.
    private var anthropicCapabilities: AnyEncodableDict {
        func s(_ b: Bool) -> AnyEncodableDict { AnyEncodableDict(["supported": b]) }
        return AnyEncodableDict([
            "batch": s(false), "citations": s(false), "code_execution": s(false), "pdf_input": s(false),
            "structured_outputs": s(false), "image_input": s(vision),
            "context_management": AnyEncodableDict(["supported": false, "clear_thinking_20251015": AnyEncodableDict?.none,
                                                    "clear_tool_uses_20250919": AnyEncodableDict?.none, "compact_20260112": AnyEncodableDict?.none]),
            "effort": AnyEncodableDict(["supported": false, "low": s(false), "medium": s(false), "high": s(false), "max": s(false),
                                        "xhigh": AnyEncodableDict?.none]),
            "server_tools": AnyEncodableDict(["supported": false, "code_execution": s(false), "web_search": s(false)]),
            "thinking": AnyEncodableDict(["supported": reasoning, "types": AnyEncodableDict([
                "adaptive": s(false), "between_tools": s(false), "disabled": s(true), "enabled": s(reasoning)])]),
        ])
    }

    /// LM Studio's `GET /api/v1/models` entry (chat and embedding models only, as LM Studio lists).
    var lmStudio: AnyEncodableDict {
        let publisher = spec.map { String($0.variant.split(separator: "/").first ?? "synapse") } ?? "synapse"
        var caps: [String: any Encodable & Sendable] = ["vision": vision, "trained_for_tool_use": tools]
        if reasoning { caps["reasoning"] = AnyEncodableDict(["allowed_options": ["off", "on"], "default": "off"]) }
        return AnyEncodableDict([
            "type": kind == "chat" ? "llm" : "embedding", "publisher": publisher, "key": id,
            "display_name": spec?.displayName ?? id, "architecture": architecture,
            "quantization": quantization.map { AnyEncodableDict(["name": $0, "bits_per_weight": bits]) },
            "size_bytes": sizeBytes, "params_string": String?.none,
            "loaded_instances": loaded ? [AnyEncodableDict(["id": id, "config": AnyEncodableDict(["context_length": contextLength ?? 0])])] : [],
            "max_context_length": contextLength, "format": spec?.engine == .gguf ? "gguf" : "mlx",
            "capabilities": AnyEncodableDict(caps), "description": String?.none,
        ])
    }
}

func addModelRoutes(to g: RouterGroup<SynapseContext>, store: ModelStore, chat: ChatService, settings: SettingsBox) {
    @Sendable func ids() async -> [String] {
        var ids = await store.downloaded.filter { Catalog.spec($0) != nil }.sorted()
        if let checkout = settings.current.voomCheckout, !checkout.isEmpty { ids += VOOMRuntime.modelIDs(checkout: checkout, modelsRoot: store.root) }
        return ids
    }
    @Sendable func facts(_ ids: [String]) async -> [ModelFacts] {
        let residents = Set(await chat.models.residents().map(\.id))
        var out: [ModelFacts] = []
        for id in ids { out.append(await ModelFacts.read(id, folder: await store.folder(for: id), chat: chat, residents: residents)) }
        return out
    }

    // OpenAI and Anthropic share this path; Anthropic's cursor paging (limit, after_id, before_id) applies when sent.
    g.get("models") { req, _ in
        var page = await ids()
        if let after = req.uri.queryParameters.get("after_id"), let i = page.firstIndex(of: after) { page = Array(page[(i + 1)...]) }
        if let before = req.uri.queryParameters.get("before_id"), let i = page.firstIndex(of: before) { page = Array(page[..<i]) }
        var hasMore = false
        if let limit = req.uri.queryParameters.get("limit").flatMap(Int.init) {
            guard (1...1000).contains(limit) else { throw HTTPError(.badRequest, message: "limit must be between 1 and 1000.") }
            hasMore = page.count > limit
            page = Array(page.prefix(limit))
        }
        return json(AnyEncodableDict(["object": "list", "data": await facts(page).map(\.wire), "has_more": hasMore,
                                      "first_id": page.first, "last_id": page.last]))
    }

    // Ids of models added from Hugging Face contain a slash (org/name), so the rest of the path is the id.
    g.get("models/**") { _, ctx in
        // SDKs may send the slash percent-encoded (org%2Fname).
        let joined = ctx.parameters.getCatchAll().joined(separator: "/")
        let id = joined.removingPercentEncoding ?? joined
        guard await ids().contains(id) else {
            return apiError(.notFound, "Model '\(id)' is not downloaded" + (Catalog.spec(id) == nil ? " or not in the catalog." : "; download it in Models."))
        }
        return json(await facts([id])[0].wire)
    }

    g.get("api/v1/models") { _, _ in
        let models = await facts(await ids()).filter { $0.kind == "chat" || $0.kind == "embedding" }
        return json(AnyEncodableDict(["models": models.map(\.lmStudio)]))
    }
}
