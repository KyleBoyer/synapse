import Foundation
import Hummingbird
import XCTest
@testable import SynapseCore

final class ChatAudioTests: XCTestCase {
    private func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    func testParams() throws {
        XCTAssertNil(try ChatAudio.params(modalities: nil, audio: nil, stream: false))
        XCTAssertNil(try ChatAudio.params(modalities: ["text"], audio: nil, stream: false))
        let wav = try XCTUnwrap(try ChatAudio.params(modalities: ["text", "audio"], audio: nil, stream: false))
        XCTAssertEqual(wav.format, .wav)
        let pcm = try XCTUnwrap(try ChatAudio.params(modalities: ["text", "audio"],
                                                     audio: try json(#"{"format":"pcm16","voice":"alloy"}"#), stream: true))
        XCTAssertEqual(pcm.format, .pcm)
        XCTAssertEqual(pcm.voice, "alloy")
        for (audio, stream) in [(#"{"format":"mp3"}"#, true), (#"{"format":"pcm"}"#, false), (#"{"format":"ogg"}"#, false)] {
            XCTAssertThrowsError(try ChatAudio.params(modalities: ["audio"], audio: try json(audio), stream: stream)) {
                XCTAssertEqual(($0 as? HTTPError)?.status, .badRequest, audio)
            }
        }
    }

    func testPCM16IsTwoBytesPerSample() async throws {
        let data = try await ChatAudio.encode([Float](repeating: 0.25, count: 2400), as: .pcm,
                                              encoder: AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false")))
        XCTAssertEqual(data.count, 4800)
        // A whole WAV states its real length (the streaming header says 0xFFFFFFFF).
        let wav = try await ChatAudio.encode([Float](repeating: 0.25, count: 2400), as: .wav,
                                             encoder: AudioEncoder(ffmpegURL: URL(fileURLWithPath: "/usr/bin/false")))
        XCTAssertEqual(wav.count, 44 + 4800)
        XCTAssertEqual(wav.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian, 4800)
    }
}
