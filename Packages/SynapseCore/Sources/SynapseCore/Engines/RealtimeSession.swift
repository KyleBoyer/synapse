import Foundation

/// Turn detection settings (OpenAI `audio.input.turn_detection`). nil on the session means manual commits.
public struct RealtimeTurnDetection: Sendable, Equatable {
    public var type = "server_vad"
    public var threshold: Double = 0.5
    public var prefixPaddingMs = 300
    public var silenceDurationMs = 500
    public var createResponse = true
    public var interruptResponse = true
    public init() {}
}

/// One OpenAI-Realtime-compatible session, independent of transport. Feed it client events as JSON (or the typed
/// helpers) and read server events from `events`. Cascade: VAD -> streaming ASR -> chat model -> streaming TTS.
public actor RealtimeSession {
    public nonisolated let events: AsyncStream<Data>
    private let out: AsyncStream<Data>.Continuation
    private let services: RealtimeServices

    // Session configuration.
    private var type: String
    private var model: String
    private var instructions = "You are a helpful voice assistant. Reply briefly and conversationally, in plain sentences without markdown."
    private var modalities = ["audio"]
    private var voice: String?
    private var speed = 1.0
    private var inputRate = 24000
    private var outputRate = 24000
    private var turn: RealtimeTurnDetection? = RealtimeTurnDetection()
    private var transcriptionModel = "parakeet-eou-120m"
    private var language: String?
    private var translationLanguage: String?
    private var tools: [Any] = []
    private let sessionID = "sess_" + UUID().uuidString.prefix(12).lowercased()

    // Components, created on first use.
    private var vad: (any RealtimeVAD)?
    private var asr: (any RealtimeASR)?
    private var tts: (any RealtimeTTS)?
    private var llm: (any RealtimeLLM)?
    private var omniVoice: (any RealtimeVoiceLLM)?
    /// The latest user utterance as WAV, kept only when the session's model hears and speaks itself.
    private var lastUtterance: (id: String, wav: URL)?
    private var speaks: Bool { Catalog.spec(model).map(OmniVoices.canSpeak) ?? false }
    private var special: RealtimeSpecialModel?
    private var inReady = false

    // Input state.
    private var up: StreamResampler?          // inputRate -> 16 kHz
    private var duplexUp: StreamResampler?
    private var duplexDown: StreamResampler?
    private var pending: [Float] = []         // 16 kHz samples not yet VAD-processed
    private var utt: [Float] = []             // current utterance (plus pre-roll while idle)
    private var clock = 0                     // 16 kHz samples consumed by the VAD
    private var speaking = false
    private var silenceSamples = 0
    private var itemID: String?
    private var emitted = ""                  // transcription deltas already sent
    private var speechStartMs = 0
    private var speechStoppedAt: Date?

    // Conversation and response state.
    private struct Item { var id: String; var role: String; var text: String; var images: [Data] = [] }
    /// Camera frames cost hundreds of prompt tokens each, so only the latest few stay in the conversation.
    static let maxImageItems = 2
    private var items: [Item] = []
    private var activeTask: Task<Void, Never>?
    private var active: Response?
    private var duplexResponse: Response?
    private var closed = false
    /// Seconds from speech_stopped to the first audio delta of the last response (for latency checks).
    public private(set) var lastFirstAudioLatency: Double?

    private final class Response: @unchecked Sendable {
        let id = "resp_" + UUID().uuidString.prefix(12).lowercased()
        let itemID = "item_" + UUID().uuidString.prefix(12).lowercased()
        let audio: Bool
        var text = ""
        var audioBytes = 0
        var gotAudio = false
        init(audio: Bool) { self.audio = audio }
    }

    public init(model: String? = nil, transcriptionOnly: Bool = false, services: RealtimeServices) {
        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        events = stream; out = cont; self.services = services
        type = transcriptionOnly ? "transcription" : "realtime"
        self.model = model ?? ""
        // Queued on the actor ahead of any client event.
        Task { await self.announce() }
    }

    private func announce() { emit("session.created", ["session": sessionJSON()]) }

    // MARK: Typed helpers

    public func appendAudio(pcm24k: [Int16]) async {
        await ingest(PCM.floats(fromInt16: pcm24k))
    }

    public func updateSession(instructions: String? = nil, voice: String? = nil, outputModalities: [String]? = nil,
                              translationLanguage: String? = nil, turnDetection: RealtimeTurnDetection?? = nil) {
        if let instructions { self.instructions = instructions }
        if let voice { self.voice = voice }
        if let outputModalities { modalities = outputModalities }
        if let translationLanguage { self.translationLanguage = translationLanguage }
        if let turnDetection { turn = turnDetection }
        emit("session.updated", ["session": sessionJSON()])
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        activeTask?.cancel()
        await activeTask?.value
        if duplexResponse != nil { await endResponse(duplexResponse!, status: "completed", reason: nil) }
        out.finish()
        vad = nil; asr = nil; tts = nil; llm = nil; special = nil; omniVoice = nil
        if let u = lastUtterance { try? FileManager.default.removeItem(at: u.wav); lastUtterance = nil }
    }

    // MARK: Client events

    public func handle(_ data: Data) async {
        guard !closed else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fail("invalid_request_error", "invalid_json", "Could not parse message as a JSON object.")
        }
        guard let t = obj["type"] as? String else {
            return fail("invalid_request_error", "missing_required_parameter", "Missing required parameter: 'type'.", param: "type")
        }
        switch t {
        case "session.update":
            guard let s = obj["session"] as? [String: Any] else {
                return fail("invalid_request_error", "missing_required_parameter", "Missing required parameter: 'session'.", param: "session")
            }
            if let err = applySession(s) { return fail("invalid_request_error", "invalid_value", err) }
            emit("session.updated", ["session": sessionJSON()])
        case "input_audio_buffer.append":
            guard let b64 = obj["audio"] as? String, let d = Data(base64Encoded: b64) else {
                return fail("invalid_request_error", "invalid_value", "'audio' must be base64-encoded PCM16.", param: "audio")
            }
            await ingest(PCM.floats(fromPCM16LE: d))
        case "input_audio_buffer.commit": await commit()
        case "input_audio_buffer.clear":
            pending = []; utt = []; speaking = false; silenceSamples = 0; emitted = ""; itemID = nil
            await asrReset()
            emit("input_audio_buffer.cleared", [:])
        case "conversation.item.create": createItem(obj["item"] as? [String: Any], previous: obj["previous_item_id"] as? String)
        case "conversation.item.delete":
            guard let id = obj["item_id"] as? String, let i = items.firstIndex(where: { $0.id == id }) else {
                return fail("invalid_request_error", "item_not_found", "The item with id '\(obj["item_id"] ?? "")' was not found.", param: "item_id")
            }
            items.remove(at: i)
            emit("conversation.item.deleted", ["item_id": id])
        case "conversation.item.truncate":
            guard let id = obj["item_id"] as? String, items.contains(where: { $0.id == id }) else {
                return fail("invalid_request_error", "item_not_found", "The item with id '\(obj["item_id"] ?? "")' was not found.", param: "item_id")
            }
            emit("conversation.item.truncated", ["item_id": id, "content_index": obj["content_index"] as? Int ?? 0,
                                                 "audio_end_ms": obj["audio_end_ms"] as? Int ?? 0])
        case "response.create":
            if active != nil {
                return fail("invalid_request_error", "conversation_already_has_active_response",
                            "Conversation already has an active response in progress.")
            }
            let r = obj["response"] as? [String: Any] ?? [:]
            startResponse(instructions: r["instructions"] as? String,
                          modalities: (r["output_modalities"] as? [String]) ?? (r["modalities"] as? [String]))
        case "response.cancel":
            if active == nil && duplexResponse == nil {
                return fail("invalid_request_error", "response_cancel_not_active", "Cancellation failed: no active response found.")
            }
            await cancelResponse(reason: "client_cancelled")
        default:
            fail("invalid_request_error", "unknown_event", "Unknown event type: '\(t)'.", param: "type")
        }
    }

    // MARK: Session configuration

    /// Returns an error message when a value is invalid.
    private func applySession(_ s: [String: Any]) -> String? {
        if let t = s["type"] as? String {
            guard t == "realtime" || t == "transcription" else { return "Invalid session type '\(t)'." }
            type = t
        }
        if let m = s["model"] as? String { model = m }
        if let i = s["instructions"] as? String { instructions = i }
        if let m = (s["output_modalities"] as? [String]) ?? (s["modalities"] as? [String]) {
            guard !m.isEmpty, m.allSatisfy({ $0 == "audio" || $0 == "text" }) else { return "output_modalities must be ['audio'] or ['text']." }
            modalities = m
        }
        if let l = s["translation_language"] as? String { translationLanguage = l.isEmpty ? nil : l }
        if let t = s["tools"] as? [Any] { tools = t }
        let audio = s["audio"] as? [String: Any] ?? [:]
        if let input = audio["input"] as? [String: Any] {
            if let f = input["format"] as? [String: Any] {
                guard (f["type"] as? String ?? "audio/pcm") == "audio/pcm" else { return "Only audio/pcm input is supported." }
                if let r = f["rate"] as? Int { inputRate = r; up = nil }
            }
            if let tr = input["transcription"] as? [String: Any] {
                if let m = tr["model"] as? String { transcriptionModel = m }
                language = tr["language"] as? String
            }
            if input.keys.contains("turn_detection") {
                if let td = input["turn_detection"] as? [String: Any] {
                    var d = turn ?? RealtimeTurnDetection()
                    if let v = td["type"] as? String {
                        guard v == "server_vad" || v == "semantic_vad" else { return "Invalid turn_detection type '\(v)'." }
                        d.type = v
                        if v == "semantic_vad" && td["silence_duration_ms"] == nil { d.silenceDurationMs = 800 }
                    }
                    if let v = (td["threshold"] as? NSNumber)?.doubleValue { d.threshold = v }
                    if let v = td["prefix_padding_ms"] as? Int { d.prefixPaddingMs = v }
                    if let v = td["silence_duration_ms"] as? Int { d.silenceDurationMs = v }
                    if let v = td["create_response"] as? Bool { d.createResponse = v }
                    if let v = td["interrupt_response"] as? Bool { d.interruptResponse = v }
                    turn = d
                } else { turn = nil }
            }
        }
        if let o = audio["output"] as? [String: Any] {
            if let v = o["voice"] as? String { voice = v }
            if let v = (o["speed"] as? NSNumber)?.doubleValue { speed = v }
            if let f = o["format"] as? [String: Any] {
                guard (f["type"] as? String ?? "audio/pcm") == "audio/pcm" else { return "Only audio/pcm output is supported." }
                if let r = f["rate"] as? Int { outputRate = r }
            }
        }
        return nil
    }

    private func sessionJSON() -> [String: Any] {
        var input: [String: Any] = ["format": ["type": "audio/pcm", "rate": inputRate],
                                    "transcription": ["model": transcriptionModel, "language": language as Any]]
        if let t = turn {
            input["turn_detection"] = ["type": t.type, "threshold": t.threshold, "prefix_padding_ms": t.prefixPaddingMs,
                                       "silence_duration_ms": t.silenceDurationMs, "create_response": t.createResponse,
                                       "interrupt_response": t.interruptResponse]
        } else { input["turn_detection"] = NSNull() }
        var s: [String: Any] = ["type": type, "id": sessionID, "object": "realtime.session", "model": model]
        if type == "transcription" {
            s["audio"] = ["input": input]
        } else {
            s["instructions"] = instructions
            s["output_modalities"] = modalities
            s["tools"] = tools
            s["tool_choice"] = "auto"
            s["audio"] = ["input": input, "output": ["format": ["type": "audio/pcm", "rate": outputRate],
                                                      "voice": voice ?? "alloy", "speed": speed]]
        }
        if let l = translationLanguage { s["translation_language"] = l }
        return s
    }

    // MARK: Events out

    private func emit(_ type: String, _ fields: [String: Any]) {
        var o = fields
        o["type"] = type
        o["event_id"] = "event_" + UUID().uuidString.prefix(12).lowercased()
        if let d = try? JSONSerialization.data(withJSONObject: o) { out.yield(d) }
    }

    private func fail(_ kind: String, _ code: String, _ message: String, param: String? = nil) {
        var e: [String: Any] = ["type": kind, "code": code, "message": message]
        e["param"] = param ?? NSNull()
        emit("error", ["error": e])
    }

    // MARK: Input pipeline

    private var special_duplex: (any DuplexSpeechEngine)? { special?.duplex }

    private func isDuplexModel() -> Bool { Catalog.spec(model)?.engine == .duplex }

    private func ingest(_ samples: [Float]) async {
        guard !closed, !samples.isEmpty else { return }
        if isDuplexModel(), type == "realtime", !(Catalog.spec(model)?.id.hasPrefix("hibiki") ?? false) {
            return await pumpDuplex(samples)
        }
        do { try await ensureInput() } catch { return fail("server_error", "model_unavailable", error.localizedDescription) }
        if up == nil { up = StreamResampler(from: Double(inputRate), to: 16000) }
        let x = up!.convert(samples)
        guard turn != nil else {
            if itemID == nil { itemID = newItemID() }
            utt += x
            await asrFeed(x)
            return
        }
        pending += x
        while pending.count >= RealtimeVADChunk, !closed {
            let chunk = Array(pending.prefix(RealtimeVADChunk))
            pending.removeFirst(RealtimeVADChunk)
            await vadChunk(chunk)
        }
    }

    private func ensureInput() async throws {
        guard !inReady else { return }
        if turn != nil { vad = try await services.vad() }
        if let spec = Catalog.spec(model), spec.id.hasPrefix("hibiki") {
            special = try await services.special(spec)
        } else {
            asr = try await services.asr()
        }
        inReady = true
    }

    private func newItemID() -> String { "item_" + UUID().uuidString.prefix(12).lowercased() }

    private func vadChunk(_ chunk: [Float]) async {
        guard let t = turn, let vad else { return }
        let p: Float
        do { p = try await vad.speechProbability(chunk) } catch { return fail("server_error", "vad_failed", error.localizedDescription) }
        let startMs = clock * 1000 / 16000
        clock += chunk.count
        let endMs = clock * 1000 / 16000
        utt += chunk
        let thr = Float(t.threshold)
        if !speaking {
            let keep = t.prefixPaddingMs * 16 + RealtimeVADChunk
            if utt.count > keep + RealtimeVADChunk { utt.removeFirst(utt.count - keep) }
            guard p >= thr else { return }
            speaking = true; silenceSamples = 0; emitted = ""
            let id = newItemID(); itemID = id
            speechStartMs = max(0, startMs - t.prefixPaddingMs)
            emit("input_audio_buffer.speech_started", ["item_id": id, "audio_start_ms": speechStartMs])
            if t.interruptResponse, active != nil || duplexResponse != nil { await cancelResponse(reason: "turn_detected") }
            await asrFeed(utt)
        } else {
            await asrFeed(chunk)
            if p >= thr - 0.15 { silenceSamples = 0 } else { silenceSamples += chunk.count }
            if silenceSamples * 1000 / 16000 >= t.silenceDurationMs || utt.count > 16000 * 120 {
                speaking = false
                emit("input_audio_buffer.speech_stopped", ["item_id": itemID ?? "", "audio_end_ms": endMs])
                speechStoppedAt = Date()
                await finalizeUtterance(respond: t.createResponse)
            }
        }
    }

    private func asrFeed(_ x: [Float]) async {
        guard let asr, !x.isEmpty, let id = itemID else { return }
        do {
            let partial = try await asr.feed(x)
            if partial.count > emitted.count, partial.hasPrefix(emitted) {
                let d = String(partial.dropFirst(emitted.count))
                emitted = partial
                emit("conversation.item.input_audio_transcription.delta", ["item_id": id, "content_index": 0, "delta": d])
            }
        } catch { fail("server_error", "transcription_failed", error.localizedDescription) }
    }

    private func asrReset() async { _ = try? await asr?.finish() }

    private func commit() async {
        guard turn == nil || !speaking else {
            return fail("invalid_request_error", "input_audio_buffer_commit_empty", "Cannot commit while speech is in progress.")
        }
        guard !utt.isEmpty || itemID != nil else {
            return fail("invalid_request_error", "input_audio_buffer_commit_empty",
                        "Error committing input audio buffer: buffer too small. Expected at least 100ms of audio, but buffer only has 0.00ms of audio.")
        }
        if let d = duplexResponse { await endResponse(d, status: "completed", reason: nil); duplexResponse = nil; return }
        if itemID == nil { itemID = newItemID() }
        await finalizeUtterance(respond: false)
    }

    /// Commits the buffered utterance, transcribes (or translates) it and optionally answers.
    private func finalizeUtterance(respond: Bool) async {
        let id = itemID ?? newItemID()
        let audio = utt
        itemID = nil; utt = []; silenceSamples = 0
        var prev = items.last?.id.isEmpty == false ? items.last?.id : nil
        if prev == nil { prev = nil }
        emit("input_audio_buffer.committed", ["item_id": id, "previous_item_id": prev as Any])
        emit("conversation.item.added", ["item": ["id": id, "object": "realtime.item", "type": "message", "role": "user", "status": "completed",
                                                  "content": [["type": "input_audio", "transcript": NSNull()]]]])
        if let tr = special?.translator {
            do {
                let r = try await tr.translate(audio, sampleRate: 16000, sourceLanguage: language)
                complete(id, "")
                items.append(Item(id: id, role: "user", text: ""))
                await respondWithAudio(r.audio, rate: r.sampleRate, text: r.text)
            } catch { fail("server_error", "translation_failed", error.localizedDescription) }
            return
        }
        var text = ""
        do { text = try await asr?.finish() ?? "" } catch { fail("server_error", "transcription_failed", error.localizedDescription) }
        if text.count > emitted.count, text.hasPrefix(emitted) {
            emit("conversation.item.input_audio_transcription.delta", ["item_id": id, "content_index": 0, "delta": String(text.dropFirst(emitted.count))])
        }
        emitted = ""
        complete(id, text)
        guard !text.isEmpty else { return }
        if type == "realtime", speaks { keepUtterance(id, audio) }
        if type == "realtime" {
            items.append(Item(id: id, role: "user", text: text))
            if respond { startResponse(instructions: nil, modalities: nil) }
        }
    }

    private func complete(_ id: String, _ text: String) {
        emit("conversation.item.input_audio_transcription.completed",
             ["item_id": id, "content_index": 0, "transcript": text,
              "usage": ["type": "tokens", "input_tokens": 0, "output_tokens": 0, "total_tokens": 0]])
        emit("conversation.item.done", ["item": ["id": id, "object": "realtime.item", "type": "message", "role": "user", "status": "completed",
                                                 "content": [["type": "input_audio", "transcript": text]]]])
    }

    private func createItem(_ item: [String: Any]?, previous: String?) {
        guard let item, (item["type"] as? String ?? "message") == "message", let role = item["role"] as? String,
              ["user", "assistant", "system"].contains(role) else {
            return fail("invalid_request_error", "invalid_value", "Unsupported item; expected a message with role user, assistant or system.", param: "item")
        }
        let parts = item["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { ($0["text"] as? String) ?? ($0["transcript"] as? String) }.joined(separator: "\n")
        var images: [Data] = []
        for p in parts where p["type"] as? String == "input_image" {
            let url = (p["image_url"] as? String) ?? ((p["image_url"] as? [String: Any])?["url"] as? String) ?? ""
            // Only inline frames: a session must not fetch URLs mid-conversation.
            guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  data.count <= 20 * 1024 * 1024 else {
                return fail("invalid_request_error", "invalid_value", "input_image must be a base64 data:image/... URL up to 20 MB.", param: "item.content")
            }
            images.append(data)
        }
        let id = (item["id"] as? String) ?? newItemID()
        items.append(Item(id: id, role: role, text: text, images: images))
        let withImages = items.indices.filter { !items[$0].images.isEmpty }
        for i in withImages.dropLast(Self.maxImageItems) { items[i].images = [] }
        var echoed = item
        echoed["id"] = id; echoed["object"] = "realtime.item"; echoed["status"] = "completed"
        emit("conversation.item.added", ["item": echoed])
        emit("conversation.item.done", ["item": echoed])
    }

    // MARK: Responses

    private func startResponse(instructions override: String?, modalities override2: [String]?) {
        guard type == "realtime" else { return fail("invalid_request_error", "invalid_value", "Responses are not available in transcription sessions.") }
        let audio = (override2 ?? modalities).contains("audio")
        let r = Response(audio: audio)
        active = r
        let spec = Catalog.spec(model)
        let prompt = override ?? instructions
        if audio, let spec, OmniVoices.canSpeak(spec) {
            activeTask = Task { [weak self] in await self?.runVoice(r, instructions: prompt, spec: spec) }
            return
        }
        activeTask = Task { [weak self] in
            await self?.runCascade(r, instructions: prompt, spec: spec)
        }
    }

    /// Writes the utterance (16 kHz) for the omni model to hear; only the latest is kept.
    private func keepUtterance(_ id: String, _ audio: [Float]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Synapse-voice-turns", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appending(path: "\(UUID().uuidString).wav")
        guard (try? PCM.wav16(audio, rate: 16000).write(to: wav)) != nil else { return }
        if let old = lastUtterance { try? FileManager.default.removeItem(at: old.wav) }
        lastUtterance = (id, wav)
    }

    /// An omni model hears the latest turn (and any camera frame) and answers in its own voice: no separate ASR
    /// text in, no TTS out. Earlier turns go in as their transcripts.
    private func runVoice(_ r: Response, instructions: String, spec: ModelSpec) async {
        beginResponse(r)
        do {
            if omniVoice == nil { omniVoice = try await services.voice(spec) }
            var messages = messagesForResponse(instructions: instructions)
            if let u = lastUtterance, items.last(where: { $0.role == "user" && !$0.text.isEmpty })?.id == u.id,
               let i = messages.lastIndex(where: { $0.role == .user }) {
                messages[i].audios = [u.wav]
                messages[i].text = ""
            }
            var down: StreamResampler?
            for try await e in omniVoice!.respond(messages, options: ChatOptions(maxTokens: 512)) {
                try Task.checkCancellation()
                switch e {
                case .text(let t): respText(r, t)
                case .audio(let a, let rate):
                    if down == nil { down = StreamResampler(from: Double(rate), to: Double(outputRate)) }
                    respAudio(r, down!.convert(a))
                case .done: break
                }
            }
            await finishCascade(r, failure: nil)
        } catch is CancellationError {
            await finishCascade(r, failure: nil)
        } catch {
            if Task.isCancelled { await finishCascade(r, failure: nil) } else {
                fail("server_error", "response_failed", error.localizedDescription)
                await finishCascade(r, failure: "response_failed")
            }
        }
    }

    private func beginResponse(_ r: Response) {
        emit("response.created", ["response": responseJSON(r, status: "in_progress", details: nil)])
        let item = itemJSON(r, status: "in_progress")
        emit("response.output_item.added", ["response_id": r.id, "output_index": 0, "item": item])
        emit("conversation.item.added", ["item": item])
        emit("response.content_part.added", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0,
                                             "part": r.audio ? ["type": "audio", "transcript": ""] : ["type": "text", "text": ""]])
    }

    private func itemJSON(_ r: Response, status: String) -> [String: Any] {
        ["id": r.itemID, "object": "realtime.item", "type": "message", "role": "assistant", "status": status,
         "content": [r.audio ? ["type": "output_audio", "transcript": r.text] : ["type": "output_text", "text": r.text]]]
    }

    private func responseJSON(_ r: Response, status: String, details: [String: Any]?) -> [String: Any] {
        var j: [String: Any] = ["id": r.id, "object": "realtime.response", "status": status,
                                "output": status == "in_progress" ? [] : [itemJSON(r, status: status == "completed" ? "completed" : "incomplete")],
                                "output_modalities": r.audio ? ["audio"] : ["text"]]
        j["status_details"] = details ?? NSNull()
        if status != "in_progress" {
            j["usage"] = ["total_tokens": 0, "input_tokens": 0, "output_tokens": 0]
        }
        return j
    }

    private func respText(_ r: Response, _ delta: String) {
        guard !Task.isCancelled || r === duplexResponse, !delta.isEmpty else { return }
        r.text += delta
        emit(r.audio ? "response.output_audio_transcript.delta" : "response.output_text.delta",
             ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0, "delta": delta])
    }

    private func respAudio(_ r: Response, _ samples: [Float]) {
        guard !Task.isCancelled || r === duplexResponse, !samples.isEmpty else { return }
        if !r.gotAudio {
            r.gotAudio = true
            if let t = speechStoppedAt { lastFirstAudioLatency = Date().timeIntervalSince(t) }
        }
        let d = PCM.pcm16LE(from: samples)
        r.audioBytes += d.count
        emit("response.output_audio.delta", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0,
                                             "delta": d.base64EncodedString()])
    }

    private func endResponse(_ r: Response, status: String, reason: String?) async {
        if r.audio {
            emit("response.output_audio.done", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0])
            emit("response.output_audio_transcript.done", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0,
                                                           "transcript": r.text])
        } else {
            emit("response.output_text.done", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0, "text": r.text])
        }
        emit("response.content_part.done", ["response_id": r.id, "item_id": r.itemID, "output_index": 0, "content_index": 0,
                                            "part": r.audio ? ["type": "audio", "transcript": r.text] : ["type": "text", "text": r.text]])
        let item = itemJSON(r, status: status == "completed" ? "completed" : "incomplete")
        emit("response.output_item.done", ["response_id": r.id, "output_index": 0, "item": item])
        emit("conversation.item.done", ["item": item])
        if !r.text.isEmpty { items.append(Item(id: r.itemID, role: "assistant", text: r.text)) }
        var details: [String: Any]? = nil
        switch status {
        case "cancelled": details = ["type": "cancelled", "reason": reason ?? "client_cancelled"]
        case "failed": details = ["type": "failed", "error": ["type": "server_error", "code": reason ?? "error"]]
        default: details = ["type": "completed"]
        }
        emit("response.done", ["response": responseJSON(r, status: status, details: details)])
    }

    /// Cancels the active response (Qwen generation and TTS stop; response.done carries status "cancelled").
    private func cancelResponse(reason: String) async {
        if let t = activeTask {
            cancelReason = reason
            t.cancel()
            await t.value
        } else if let d = duplexResponse {
            duplexResponse = nil
            await endResponse(d, status: "cancelled", reason: reason)
            await special?.duplex?.reset()
        }
    }
    private var cancelReason = "client_cancelled"

    private func finishCascade(_ r: Response, failure: String?) async {
        let cancelled = Task.isCancelled
        await endResponse(r, status: failure != nil ? "failed" : cancelled ? "cancelled" : "completed",
                          reason: failure ?? (cancelled ? cancelReason : nil))
        active = nil; activeTask = nil
    }

    private func respondWithAudio(_ audio: [Float], rate: Int, text: String) async {
        let r = Response(audio: true)
        beginResponse(r)
        respText(r, text)
        let x = StreamResampler(from: Double(rate), to: Double(outputRate)).convert(audio)
        var i = 0
        while i < x.count { respAudio(r, Array(x[i..<min(i + 4800, x.count)])); i += 4800 }
        await endResponse(r, status: "completed", reason: nil)
    }

    private func messagesForResponse(instructions: String) -> [ChatMessage] {
        let translating = translationLanguage != nil || instructions.lowercased().contains("translat")
        if translating {
            let sys = translationLanguage.map {
                "You are a live interpreter. Translate everything the user says into \($0). Output only the translation, with no commentary."
            } ?? instructions
            let last = items.last { $0.role == "user" }
            return [ChatMessage(role: .system, text: sys), ChatMessage(role: .user, text: last?.text ?? "")]
        }
        var m = [ChatMessage(role: .system, text: instructions)]
        // A camera frame arrives as its own image-only item just before the user's words; it joins that next turn.
        var carried: [Data] = []
        for i in items.suffix(40) {
            let role = ChatMessage.Role(rawValue: i.role) ?? .user
            if role == .user, i.text.isEmpty, !i.images.isEmpty { carried += i.images; continue }
            if role == .user {
                m.append(ChatMessage(role: .user, text: i.text, images: carried + i.images)); carried = []
            } else {
                m.append(ChatMessage(role: role, text: i.text))
            }
        }
        if !carried.isEmpty { m.append(ChatMessage(role: .user, text: "(camera frame)", images: carried)) }
        return m
    }

    private func runCascade(_ r: Response, instructions: String, spec: ModelSpec?) async {
        beginResponse(r)
        do {
            if llm == nil { llm = try await services.llm(spec?.isChat == true ? spec?.id : nil) }
            if r.audio, tts == nil { tts = try await services.tts() }
            let llm = self.llm!
            let tts = self.tts
            let messages = messagesForResponse(instructions: instructions)
            let (sentences, sentenceIn) = AsyncStream<String>.makeStream()
            let voice = ttsVoice(), speed = self.speed
            let down = tts.map { StreamResampler(from: Double($0.sampleRate), to: Double(outputRate)) }
            try await withThrowingTaskGroup(of: Void.self) { g in
                g.addTask { [self] in
                    var splitter = SentenceSplitter()
                    defer { sentenceIn.finish() }
                    for try await ev in try await llm.stream(messages, options: ChatOptions(maxTokens: 600)) {
                        try Task.checkCancellation()
                        if case .delta(let d) = ev {
                            await respText(r, d)
                            splitter.feed(d).forEach { sentenceIn.yield($0) }
                        }
                    }
                    if let rest = splitter.flush() { sentenceIn.yield(rest) }
                }
                if r.audio, let tts, let down {
                    g.addTask { [self] in
                        for await s in sentences {
                            for try await frame in tts.synthesize(s, voice: voice, speed: speed) {
                                try Task.checkCancellation()
                                await respAudio(r, down.convert(frame))
                            }
                        }
                    }
                }
                try await g.waitForAll()
            }
            await finishCascade(r, failure: nil)
        } catch is CancellationError {
            await finishCascade(r, failure: nil)
        } catch {
            if Task.isCancelled { await finishCascade(r, failure: nil) } else {
                fail("server_error", "response_failed", error.localizedDescription)
                await finishCascade(r, failure: "response_failed")
            }
        }
    }

    private func ttsVoice() -> String? { SpeechService.voice(voice) }

    // MARK: Duplex

    private func pumpDuplex(_ samples: [Float]) async {
        do {
            if special == nil, let spec = Catalog.spec(model) { special = try await services.special(spec) }
            guard let engine = special?.duplex else { return fail("server_error", "model_unavailable", "Model is not a duplex model.") }
            if duplexUp == nil {
                duplexUp = StreamResampler(from: Double(inputRate), to: Double(await engine.inputSampleRate))
                duplexDown = StreamResampler(from: Double(await engine.outputSampleRate), to: Double(outputRate))
            }
            for ev in try await engine.push(duplexUp!.convert(samples)) {
                switch ev {
                case .audio(let a): respAudio(duplexResponseOpen(), duplexDown!.convert(a))
                case .assistantText(let t): respText(duplexResponseOpen(), t)
                case .userText(let t):
                    let id = newItemID()
                    items.append(Item(id: id, role: "user", text: t))
                    complete(id, t)
                }
            }
        } catch { fail("server_error", "duplex_failed", error.localizedDescription) }
    }

    private func duplexResponseOpen() -> Response {
        if let d = duplexResponse { return d }
        let r = Response(audio: true)
        duplexResponse = r
        beginResponse(r)
        return r
    }
}

/// Splits streamed text into speakable sentences; flushes early at a comma once a clause is long enough
/// so the first audio starts sooner.
struct SentenceSplitter {
    private var buf = ""

    mutating func feed(_ s: String) -> [String] {
        buf += s.filter { !"*_#`".contains($0) }
        var out: [String] = []
        var i = buf.startIndex
        while i < buf.endIndex {
            let c = buf[i]
            let next = buf.index(after: i)
            // "." only ends a sentence once whitespace follows ("3.5" stays whole); the rest end at once.
            let ends = c == "." ? (next < buf.endIndex && buf[next].isWhitespace)
                : ".!?\n;:".contains(c) || (c == "," && buf.distance(from: buf.startIndex, to: i) >= 40)
            if ends {
                out.append(clean(String(buf[..<next])))
                buf = String(buf[next...]); i = buf.startIndex
            } else { i = next }
        }
        return out.filter { !$0.isEmpty }
    }

    mutating func flush() -> String? {
        defer { buf = "" }
        let c = clean(buf)
        return c.isEmpty ? nil : c
    }

    private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
