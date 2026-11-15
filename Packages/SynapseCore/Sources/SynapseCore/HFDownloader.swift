import Foundation

/// Minimal Hugging Face snapshot downloader. We fetch files ourselves (instead of a hub client) so
/// weights land in Synapse's model folder; hub clients default to ~/Documents or ~/.cache.
public enum HFDownloader {
    struct Entry: Decodable { let type: String; let path: String; let size: Int64? }

    /// Files an MLX model needs: config, tokenizer, chat template, processor configs, weights.
    static func wanted(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        return path.hasSuffix(".json") || path.hasSuffix(".safetensors") || path.hasSuffix(".jinja")
            || path.hasSuffix(".txt") || path.hasSuffix(".model") || path.hasSuffix(".tiktoken")
    }

    /// Downloads `repo` at `main` into `dir`. Files are written to `<name>.partial` then renamed,
    /// and existing complete files are skipped, so a retry resumes at file granularity.
    public static func download(repo: String, to dir: URL, session: URLSession = .shared,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let base = URL(string: "https://huggingface.co")!
        let listURL = base.appending(path: "api/models/\(repo)/tree/main")
        let (data, response) = try await session.data(from: listURL)
        try check(response, listURL)
        let files = try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" && wanted($0.path) }
        guard files.contains(where: { $0.path == "config.json" }) else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "\(repo) has no config.json"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for f in files {
            try Task.checkCancellation()
            let dst = dir.appending(path: f.path)
            if let size = f.size, (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == size {
                done += size; progress(Double(done) / Double(total)); continue
            }
            let src = base.appending(path: "\(repo)/resolve/main/\(f.path)")
            let before = done
            let (tmp, resp) = try await session.download(from: src, delegate: ProgressDelegate { written in
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

    private static func check(_ response: URLResponse, _ url: URL) throws {
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
