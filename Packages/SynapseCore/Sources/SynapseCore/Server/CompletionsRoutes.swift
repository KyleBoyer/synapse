import Foundation
import Hummingbird

/// Legacy OpenAI Completions (`POST /v1/completions`): a raw prompt continued as text, no chat template.
struct CompletionRequest: Decodable {
    var model: String?
    var prompt: JSONValue
    var max_tokens: Int?
    var temperature: Float?
    var top_p: Float?
    var stream: Bool?
    var stream_options: JSONValue?
    var stop: JSONValue?
    var echo: Bool?
    var n: Int?
    var suffix: String?
}

struct CompletionWire: Encodable {
    struct Choice: Encodable {
        var text: String
        var index = 0
        var logprobs: String? = nil
        var finish_reason: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encode(index, forKey: .index)
            try c.encodeNil(forKey: .logprobs)
            try c.encode(finish_reason, forKey: .finish_reason)
        }
        enum CodingKeys: String, CodingKey { case text, index, logprobs, finish_reason }
    }
    var id: String
    var object = "text_completion"
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: ChatUsageWire?
}

/// `stop` is a string or an array of strings in both Completions and Chat Completions.
func stopSequences(_ v: JSONValue?) -> [String] {
    if let s = v?.string { return [s] }
    return v?.array?.compactMap(\.string) ?? []
}

/// Cuts a generation at the earliest stop sequence (which is not emitted). A cut run reports finish "stop".
func applyStops(_ events: AsyncThrowingStream<ChatEvent, Error>, _ stops: [String]) -> AsyncThrowingStream<ChatEvent, Error> {
    guard stops.contains(where: { !$0.isEmpty }) else { return events }
    return AsyncThrowingStream { c in
        let task = Task {
            var scanner = StopScanner(stops)
            var chunks = 0
            do {
                for try await e in events {
                    switch e {
                    case .delta(let s):
                        chunks += 1
                        let (out, hit) = scanner.feed(s)
                        if !out.isEmpty { c.yield(.delta(out)) }
                        if hit != nil {
                            // shortcut: generation is cancelled before MLX reports usage, so completion tokens count chunks and prompt tokens are 0.
                            c.yield(.done(finishReason: "stop", usage: ChatUsage(promptTokens: 0, completionTokens: chunks)))
                            c.finish()
                            return
                        }
                    case .done(let f, let u):
                        let tail = scanner.finish()
                        if !tail.isEmpty { c.yield(.delta(tail)) }
                        c.yield(.done(finishReason: f, usage: u))
                    case .toolCall:
                        c.yield(e)
                    }
                }
                c.finish()
            } catch { c.finish(throwing: error) }
        }
        c.onTermination = { _ in task.cancel() }
    }
}

func addCompletionsRoutes(to g: RouterGroup<SynapseContext>, chat: ChatService) {
    g.post("completions") { req, ctx in
        let body = try decodeJSON(CompletionRequest.self, try await rawBody(req, ctx))
        let prompts = body.prompt.string.map { [$0] } ?? body.prompt.array?.compactMap(\.string) ?? []
        guard prompts.count == 1, let prompt = prompts.first, !prompt.isEmpty else {
            throw HTTPError(.badRequest, message: "prompt must be one non-empty string (token arrays and batches are not supported).")
        }
        guard (body.n ?? 1) == 1 else { throw HTTPError(.badRequest, message: "n > 1 is not supported.") }
        guard body.suffix == nil else { throw HTTPError(.badRequest, message: "suffix (insertion) is not supported.") }
        let spec = try await resolveChat(chat, body.model)
        // OpenAI's default is 16 tokens, which silently truncates most answers; clients that care send max_tokens.
        let options = ChatOptions(maxTokens: body.max_tokens ?? 256, temperature: body.temperature, topP: body.top_p)
        let id = "cmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)
        let events = applyStops(try await chat.streamText(model: spec, prompt: prompt, options: options), stopSequences(body.stop))
        let echo = body.echo == true ? prompt : ""

        guard body.stream == true else {
            var text = echo, finish = "stop"
            var usage = ChatUsage(promptTokens: 0, completionTokens: 0)
            for try await e in events {
                switch e {
                case .delta(let s): text += s
                case .done(let f, let u): finish = f; usage = u
                case .toolCall: break
                }
            }
            return json(CompletionWire(id: id, created: created, model: spec.id,
                                       choices: [.init(text: text, finish_reason: finish)], usage: ChatUsageWire(usage)))
        }

        let includeUsage = body.stream_options?["include_usage"]?.bool == true
        return sse { write in
            func chunk(_ text: String, finish: String? = nil) -> CompletionWire {
                CompletionWire(id: id, created: created, model: spec.id, choices: [.init(text: text, finish_reason: finish)])
            }
            if !echo.isEmpty { try await write(nil, chunk(echo)) }
            for try await e in events {
                switch e {
                case .delta(let s): try await write(nil, chunk(s))
                case .toolCall: break
                case .done(let finish, let usage):
                    try await write(nil, chunk("", finish: finish))
                    if includeUsage {
                        try await write(nil, CompletionWire(id: id, created: created, model: spec.id, choices: [], usage: ChatUsageWire(usage)))
                    }
                }
            }
            try await writeRaw(write, "[DONE]")
        }
    }
}
