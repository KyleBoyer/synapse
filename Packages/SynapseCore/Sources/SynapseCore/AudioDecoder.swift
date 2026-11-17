import Foundation

public enum DecodeError: Error, LocalizedError {
    case ffmpeg(String)
    case noAudioTrack

    public var errorDescription: String? {
        switch self {
        case .ffmpeg(let s): return "ffmpeg failed: \(s)"
        case .noAudioTrack: return "This file has no audio track"
        }
    }
}

public struct AudioDecoder: Sendable {
    public let ffmpegURL: URL

    public init(ffmpegURL: URL) { self.ffmpegURL = ffmpegURL }

    public static func bundled() -> AudioDecoder? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { return AudioDecoder(ffmpegURL: u) }
        // Running from source (tests, the SDK test server): the repo's vendor build.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../vendor/ffmpeg/bin/ffmpeg").standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: repo.path) ? AudioDecoder(ffmpegURL: repo) : nil
    }

    /// Decodes to mono s16le WAV at `<dir>/audio.wav`: 16 kHz for speech recognition, 24 kHz for voice cloning.
    public func decodeToWAV(_ input: AudioInput, into dir: URL, sampleRate: Int = 16000) async throws -> URL {
        let out = dir.appendingPathComponent("audio.wav")
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        if case .pcm16le = input { args += ["-f", "s16le", "-ar", "16000", "-ac", "1"] }
        args += ["-i", input.url.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
                 "-ac", "1", "-ar", String(sampleRate), "-c:a", "pcm_s16le", "-f", "wav", out.path]

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        let buffer = LockedData()
        let reader = errPipe.fileHandleForReading

        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Drain while running so ffmpeg never blocks on a full pipe.
                // An empty read is end of file; left set, the handler would re-fire in a tight loop until exit.
                reader.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil } else { buffer.append(d) }
                }
                process.terminationHandler = { p in
                    reader.readabilityHandler = nil
                    buffer.append((try? reader.readToEnd()) ?? Data())
                    cont.resume(returning: p.terminationStatus)
                }
                do { try process.run() } catch {
                    reader.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        guard status == 0 else {
            let text = String(decoding: buffer.data, as: UTF8.self)
            if text.contains("matches no streams") { throw DecodeError.noAudioTrack }
            let tail = text.split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
            throw DecodeError.ffmpeg(tail)
        }
        return out
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
