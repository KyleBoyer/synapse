import AVFoundation
import XCTest
@testable import SynapseCore

final class AudioEncoderTests: XCTestCase {
    private func encoder() throws -> AudioEncoder {
        let url = try TestSupport.ffmpeg()
        let p = Process()
        p.executableURL = url; p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard text.contains("libmp3lame") else { throw XCTSkip("ffmpeg lacks libmp3lame; run scripts/build-ffmpeg.sh") }
        return AudioEncoder(ffmpegURL: url)
    }

    private func sine(seconds: Double, rate: Int) -> AsyncThrowingStream<[Float], Error> {
        let n = Int(seconds * Double(rate)), chunk = 2400
        return AsyncThrowingStream { c in
            var i = 0
            while i < n {
                let end = min(i + chunk, n)
                c.yield((i..<end).map { 0.5 * sin(2 * .pi * 440 * Float($0) / Float(rate)) })
                i = end
            }
            c.finish()
        }
    }

    func testEveryFormatRoundTripsToOneSecond() async throws {
        let enc = try encoder()
        for format in AudioFormat.allCases {
            var data = Data()
            for try await d in enc.encode(sine(seconds: 1, rate: 24000), sampleRate: 24000, as: format) { data.append(d) }
            if format == .pcm { XCTAssertEqual(data.count, 48000); continue }
            let ext = format == .opus ? "ogg" : format.rawValue
            let file = try TestSupport.tempDir().appending(path: "out.\(ext)")
            try data.write(to: file)
            let f = try AVAudioFile(forReading: file)
            var frames = f.length
            if frames == 0 {  // streamed FLAC has no total-samples field in its header, so count by reading
                let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096)!
                while (try? f.read(into: buf)) != nil, buf.frameLength > 0 { frames += AVAudioFramePosition(buf.frameLength) }
            }
            let seconds = Double(frames) / f.processingFormat.sampleRate
            XCTAssertEqual(seconds, 1.0, accuracy: 0.15, "\(format.rawValue) duration")
        }
    }

    func testSourceErrorSurfaces() async throws {
        struct Boom: Error {}
        let enc = try encoder()
        let bad = AsyncThrowingStream<[Float], Error> { $0.finish(throwing: Boom()) }
        do {
            for try await _ in enc.encode(bad, sampleRate: 24000, as: .mp3) {}
            XCTFail("expected an error")
        } catch is Boom {}
    }
}
