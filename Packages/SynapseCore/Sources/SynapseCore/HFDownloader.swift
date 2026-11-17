import Foundation

/// Minimal Hugging Face snapshot downloader. We fetch files ourselves (instead of a hub client) so
/// weights land in Synapse's model folder; hub clients default to ~/Documents or ~/.cache.
public enum HFDownloader {
    struct Entry: Decodable { let type: String; let path: String; let size: Int64? }

    static func snapshotFiles(_ data: Data, exclude: [String] = [], only: [String] = []) throws -> [Entry] {
        let files = try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.type == "file" && wanted($0.path, exclude: exclude) && (only.isEmpty || only.contains(where: $0.path.hasPrefix))
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
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
            let (tmp, resp) = try await session.download(for: authorized(src, token), delegate: ProgressDelegate { written in
                progress(Double(before + written) / Double(total))
            })
            try check(resp, src)
            let partial = dir.appending(path: f.path + ".partial")
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.moveItem(at: tmp, to: partial)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: partial)
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
                "\(url.host() ?? "") refused access (HTTP \(http.statusCode)). This model is gated: accept its license on huggingface.co and add a Hugging Face token in Settings."])
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.absoluteString)"])
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onWritten: @Sendable (Int64) -> Void
        init(_ onWritten: @escaping @Sendable (Int64) -> Void) { self.onWritten = onWritten }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) { onWritten(totalBytesWritten) }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
