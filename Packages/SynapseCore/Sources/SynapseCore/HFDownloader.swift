import Foundation

/// Minimal Hugging Face snapshot downloader. We fetch files ourselves (instead of a hub client) so
/// weights land in Synapse's model folder; hub clients default to ~/Documents or ~/.cache.
public enum HFDownloader {
    struct Entry: Decodable { let type: String; let path: String; let size: Int64? }

    static func snapshotFiles(_ data: Data, exclude: [String] = [], only: [String] = []) throws -> [Entry] {
        let files = try JSONDecoder().decode([Entry].self, from: data).filter {
            // Named files are taken whatever their type (a GGUF quantization); otherwise the model-file filter applies.
            $0.type == "file" && (only.isEmpty ? wanted($0.path, exclude: exclude) : only.contains(where: $0.path.hasPrefix)
                && (wanted($0.path, exclude: exclude) || $0.path.hasSuffix(".gguf") || $0.path.contains(".mlpackage/")))
        }
        // A whole model needs weights; a few borrowed folders (a tokenizer) need not have any.
        guard !only.isEmpty || files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Model snapshot has no safetensors weights."])
        }
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !file.path.contains("\\") else {
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Invalid model file path."])
            }
        }
        return files
    }

    /// Files a model needs: configs, tokenizers, chat templates and weights, in any subfolder
    /// (diffusion repos keep transformer/, text_encoder/, vae/ separately). `exclude` drops exact paths
    /// or folder prefixes ending in "/".
    static func wanted(_ path: String, exclude: [String] = []) -> Bool {
        if exclude.contains(where: { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }) { return false }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard !name.hasPrefix(".") else { return false }
        return name.hasSuffix(".json") || name.hasSuffix(".safetensors") || name.hasSuffix(".jinja")
            || name.hasSuffix(".txt") || name.hasSuffix(".model") || name.hasSuffix(".tiktoken")
    }

    /// The token the Hugging Face CLI uses, so `hf auth login` once is enough: HF_TOKEN or HUGGING_FACE_HUB_TOKEN,
    /// then `$HF_HOME/token` (default `~/.cache/huggingface/token`). An app opened from Finder sees only the file.
    public static func cliToken(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        for key in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] {
            if let t = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        let hfHome = environment["HF_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".cache/huggingface")
        let t = (try? String(contentsOf: hfHome.appending(path: "token"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    /// Downloads `repo` at `main` into `dir`. Files are written to `<name>.partial` then renamed,
    /// and existing complete files are skipped, so a retry resumes at file granularity.
    /// `only`, when set, keeps just the paths under these prefixes (a few folders borrowed from another repo).
    public static func download(repo: String, to dir: URL, exclude: [String] = [], only: [String] = [], token: String? = nil,
                                session: URLSession = .shared,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let base = URL(string: "https://huggingface.co")!
        var listURL = base.appending(path: "api/models/\(repo)/tree/main")
        listURL.append(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        let (data, response) = try await session.data(for: authorized(listURL, token))
        try check(response, listURL)
        let files = try snapshotFiles(data, exclude: exclude, only: only)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for f in files {
            try Task.checkCancellation()
            let dst = dir.appending(path: f.path)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = f.size, (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == size {
                done += size; progress(Double(done) / Double(total)); continue
            }
            let src = base.appending(path: "\(repo)/resolve/main/\(f.path)")
            let before = done
            try await fetch(src, to: dst, token: token, configuration: session.configuration) { written in
                progress(Double(before + written) / Double(total))
            }
            done += f.size ?? 0
            progress(Double(done) / Double(total))
        }
        return dir
    }

    private static func authorized(_ url: URL, _ token: String?) -> URLRequest {
        var r = URLRequest(url: url)
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func check(_ response: URLResponse, _ url: URL) throws {
        if let http = response as? HTTPURLResponse, [401, 403].contains(http.statusCode) {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey:
                "\(url.host() ?? "") refused access (HTTP \(http.statusCode)). This model is gated: accept its license on huggingface.co, then run `hf auth login` or add a token in Settings."])
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.absoluteString)"])
        }
    }

    /// Streams one file into `<dst>.partial` beside it, so large weights never stage on the boot disk, then renames it.
    /// A `.partial` left by an interrupted attempt is resumed with a Range request. `onBytes` gets bytes written so far.
    static func fetch(_ src: URL, to dst: URL, token: String?, configuration: URLSessionConfiguration = .default,
                      onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let partial = dst.appendingPathExtension("partial")
        let fm = FileManager.default
        let have = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        var request = authorized(src, token)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let writer = try PartialWriter(partial, resumeAt: have, onBytes: onBytes)
        let session = URLSession(configuration: configuration, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writer.done = c
                task.resume()
            }
        } onCancel: { task.cancel() }
        if let response = writer.response { try check(response, src) }
        _ = try fm.replaceItemAt(dst, withItemAt: partial)
    }

    /// Appends a response body to a file as it arrives; a 200 to a Range request starts the file over.
    private final class PartialWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private var written: Int64
        private var lastReport: Int64 = 0
        private let onBytes: @Sendable (Int64) -> Void
        var response: URLResponse?
        var done: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(_ url: URL, resumeAt: Int64, onBytes: @escaping @Sendable (Int64) -> Void) throws {
            handle = try FileHandle(forWritingTo: url)
            written = resumeAt
            self.onBytes = onBytes
            super.init()
            try handle.seekToEnd()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { completionHandler(.cancel); return }
            if status == 200, written > 0 {   // the server ignored the Range: start over
                do { try handle.truncate(atOffset: 0) } catch { failure = error; completionHandler(.cancel); return }
                written = 0
            }
            onBytes(written)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do { try handle.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
            written += Int64(data.count)
            if written - lastReport >= 4 << 20 { lastReport = written; onBytes(written) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A refused status is reported by `check` with its message, not as the cancellation it caused.
            if let failure { done?.resume(throwing: failure) }
            else if let error, (200..<300).contains(status) || response == nil { done?.resume(throwing: error) }
            else { onBytes(written); done?.resume() }
            done = nil
        }
    }
}
