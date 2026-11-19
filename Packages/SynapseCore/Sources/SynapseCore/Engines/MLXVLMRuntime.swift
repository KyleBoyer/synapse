import Foundation

// Omni models (audio, image and video in) served by mlx-vlm's OpenAI-compatible server, one process per model.
// Request shapes confirmed in mlx-vlm 0.8.0 (server/openai.py, server/schemas.py):
//   text      {"type":"text","text":...}
//   image     {"type":"image_url","image_url":{"url":"data:image/...;base64,..."}}
//   audio     {"type":"input_audio","input_audio":{"data":"<base64>","format":"wav"}}
//   video     {"type":"video_url","video_url":{"url":"<local path>"}}  (the server reads files on this Mac; it is our child)
// `model` is the folder path; streaming returns OpenAI chunks, then a usage chunk, then [DONE].
// The server binds 0.0.0.0 unless told otherwise, so it is always started with --host 127.0.0.1.

/// One running `mlx_vlm.server`; terminating it frees the model's memory.
public final class MLXVLMServer: @unchecked Sendable {
    let base: URL
    let modelPath: String
    private let process: Process
    public var pid: Int32 { process.processIdentifier }
    private let logURL: URL

    private init(base: URL, modelPath: String, process: Process, logURL: URL) {
        self.base = base; self.modelPath = modelPath; self.process = process; self.logURL = logURL
    }

    static let version = "0.8.0"

    /// Runs `mlx_vlm.server` and exits when Synapse does. A child process outlives a parent that quits or crashes,
    /// and this one holds a whole model in memory; once the parent is gone the child is re-parented, so its
    /// parent pid changes.
    static let watchdog = """
        import os, sys, threading, time, runpy
        parent = os.getppid()
        def watch():
            while True:
                time.sleep(1)
                if os.getppid() != parent:
                    os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        sys.argv = ["mlx_vlm.server"] + sys.argv[1:]
        runpy.run_module("mlx_vlm.server", run_name="__main__")
        """

    /// `cacheBytes` caps the prefix cache (APC), matching Synapse's prompt-cache setting.
    static func launch(folder: URL, cacheBytes: Int = ChatService.defaultPromptCacheBytes) async throws -> MLXVLMServer {
        let rt = try await PythonRuntime.shared.ensureInstalled(.init(name: "mlx-vlm", requirements: ["mlx-vlm==\(version)"]),
                                                                storeRoot: try PythonRuntime.storeRoot(above: folder))
        let port = try freePort()
        let p = Process()
        p.executableURL = rt.python
        p.arguments = ["-c", watchdog, "--host", "127.0.0.1", "--port", String(port), "--model", folder.path]
        p.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
            // Automatic prefix caching: follow-up turns reuse the history's KV blocks. Off by default in mlx-vlm.
            "APC_ENABLED": "1", "APC_DISK_ENABLED": "0", "APC_MEMORY_MAX_GB": String(Double(cacheBytes) / Double(1 << 30)),
            "HF_HOME": rt.dir.appending(path: "hf").path,
        ]) { $1 }
        let logURL = FileManager.default.temporaryDirectory.appending(path: "synapse-mlxvlm-\(port).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardOutput = log; p.standardError = log; p.standardInput = FileHandle.nullDevice
        try p.run()
        let server = MLXVLMServer(base: URL(string: "http://127.0.0.1:\(port)")!, modelPath: folder.path, process: p, logURL: logURL)
        do { try await server.waitUntilReady() } catch { server.terminate(); throw error }
        return server
    }

    private func waitUntilReady(timeout: Duration = .seconds(300)) async throws {
        let deadline = ContinuousClock.now + timeout
        let req = URLRequest(url: base.appending(path: "health"), timeoutInterval: 2)
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
                throw EngineError.unsupported("mlx-vlm exited during startup (code \(process.terminationStatus)): \(tail)")
            }
            // /health answers while the model is still preloading; ready means model_ready and no preload left.
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let failures = o["preload_failures"] as? [Any], !failures.isEmpty {
                    throw EngineError.unsupported("mlx-vlm could not load the model: \(failures)")
                }
                if o["model_ready"] as? Bool == true, o["preload_in_progress"] as? Bool != true { return }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw EngineError.unsupported("mlx-vlm did not become ready within \(timeout); log: \(logURL.path)")
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// A port the kernel just handed out on loopback.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.unsupported("Could not open a socket to find a free port.") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw EngineError.unsupported("Could not find a free port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Chat over an mlx-vlm server: builds the OpenAI request and maps its SSE stream to `ChatEvent`s.
enum MLXVLMChat {
    /// `promptProgress` asks llama.cpp for `prompt_progress` objects while it reads the prompt (mlx-vlm has none).
    static func body(_ messages: [ChatMessage], options: ChatOptions, model: String, promptProgress: Bool = false) throws -> Data {
        let wire: [[String: Any]] = try messages.map { m in
            var parts: [[String: Any]] = []
            if !m.text.isEmpty { parts.append(["type": "text", "text": m.text]) }
            for image in m.images {
                parts.append(["type": "image_url", "image_url": ["url": "data:\(imageMime(image));base64," + image.base64EncodedString()]])
            }
            for audio in m.audios {
                parts.append(["type": "input_audio", "input_audio": ["data": try Data(contentsOf: audio).base64EncodedString(),
                                                                       "format": audio.pathExtension.lowercased()]])
            }
            for video in m.videos { parts.append(["type": "video_url", "video_url": ["url": video.path]]) }
            return ["role": m.role.rawValue, "content": parts]
        }
        var o: [String: Any] = ["model": model, "messages": wire, "stream": true, "stream_options": ["include_usage": true],
                                "max_tokens": options.maxTokens ?? ChatService.defaultMaxTokens]
        if let t = options.temperature { o["temperature"] = t }
        if let p = options.topP { o["top_p"] = p }
        if promptProgress { o["return_progress"] = true }
        // Both servers parse calls per model (mlx-vlm's tool parsers, llama.cpp's --jinja templates).
        if !options.tools.isEmpty { o["tools"] = options.tools.map(\.spec) }
        return try JSONSerialization.data(withJSONObject: o)
    }

    private static func imageMime(_ d: Data) -> String {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if d.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        return "image/png"
    }

    /// A chunk that is only a control token, such as MiniCPM-o's `<|tts_eos|>`, which mlx-vlm's server passes through.
    static func isSpecialToken(_ s: String) -> Bool {
        s.wholeMatch(of: /\s*<\|[A-Za-z0-9_]+\|>\s*/) != nil
    }

    private struct APCBusy: Error { let message: String }

    /// Reads `data:` lines until `[DONE]`; usage comes in the last chunk (include_usage).
    static func stream(base: URL, body: Data, onFinish: @escaping @Sendable () -> Void) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                defer { onFinish() }
                var produced = false
                /// One POST; returns the finish reason and usage after the stream ends.
                func once() async throws -> (String, ChatUsage) {
                    var req = URLRequest(url: base.appending(path: "v1/chat/completions"), timeoutInterval: 600)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw EngineError.unsupported("mlx-vlm returned \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(text.prefix(400))")
                    }
                    var finish = "stop", usage = ChatUsage(promptTokens: 0, completionTokens: 0)
                    var reading = true
                    var calls: [Int: (name: String, arguments: String)] = [:]   // streamed in pieces, by index
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let o = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        // A failure after the 200 (out of GPU memory, say) arrives as a data line, not a status code.
                        if let e = o["error"] {
                            let message = (e as? String) ?? ((e as? [String: Any])?["message"] as? String) ?? "\(e)"
                            if message.contains("APC prefill memory budget"), !produced { throw APCBusy(message: message) }
                            throw EngineError.unsupported("mlx-vlm failed: \(message)")
                        }
                        if reading, let pp = o["prompt_progress"] as? [String: Any], let total = pp["total"] as? Int,
                           let done = pp["processed"] as? Int {
                            let cache = pp["cache"] as? Int ?? 0
                            if total > cache { c.yield(.progress(.prompt(fraction: Double(done - cache) / Double(total - cache)))) }
                            continue
                        }
                        if let u = o["usage"] as? [String: Any], let p = u["prompt_tokens"] as? Int {
                            // llama.cpp and mlx-vlm (APC) both report prefix-cache reuse here.
                            let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                            usage = ChatUsage(promptTokens: p, completionTokens: u["completion_tokens"] as? Int ?? 0, cachedTokens: cached)
                        }
                        guard let choice = (o["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any]
                        let content = delta?["content"] as? String
                        let f = choice["finish_reason"] as? String
                        let toolCalls = delta?["tool_calls"] as? [[String: Any]] ?? []
                        if reading, (content?.isEmpty == false) || f != nil || !toolCalls.isEmpty { reading = false; c.yield(.progress(.promptDone)) }
                        for tc in toolCalls {
                            let i = tc["index"] as? Int ?? 0, fn = tc["function"] as? [String: Any]
                            if let n = fn?["name"] as? String { calls[i, default: ("", "")].name += n }
                            if let a = fn?["arguments"] as? String { calls[i, default: ("", "")].arguments += a }
                        }
                        if let d = content, !d.isEmpty, !isSpecialToken(d) { produced = true; c.yield(.delta(d)) }
                        if let f { finish = f }
                    }
                    for i in calls.keys.sorted() where !calls[i]!.name.isEmpty {
                        c.yield(.toolCall(name: calls[i]!.name, arguments: calls[i]!.arguments.isEmpty ? "{}" : calls[i]!.arguments))
                    }
                    return (finish, usage)
                }
                do {
                    c.yield(.progress(.promptStarted))
                    var result: (String, ChatUsage)
                    do {
                        result = try await once()
                    } catch is APCBusy {
                        // mlx-vlm's prefix cache admits a request only when free RAM covers its reserve; without the
                        // cache the request would just run. Wait for memory to settle and try once more.
                        try await Task.sleep(for: .seconds(1))
                        do { result = try await once() } catch let busy as APCBusy {
                            throw EngineError.unsupported("mlx-vlm failed: \(busy.message) (memory is too full; unload a model and retry)")
                        }
                    }
                    let (finish, usage) = result
                    c.yield(.done(finishReason: finish == "tool_calls" ? "stop" : finish, usage: usage))
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
