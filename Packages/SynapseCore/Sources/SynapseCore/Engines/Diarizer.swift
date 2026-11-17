import Foundation
@preconcurrency import FluidAudio

/// One stretch of audio attributed to a speaker.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Who spoke when in a 16 kHz WAV. Speakers are labelled "A", "B", ... in order of first appearance.
public protocol SpeakerDiarizing: Actor {
    func diarize(wav: URL) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline pipeline (segmentation, speaker embeddings, clustering) on Core ML.
public actor FluidDiarizer: SpeakerDiarizing {
    private let manager: OfflineDiarizerManager

    public init(folder: URL) async throws {
        manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: folder)
    }

    public func diarize(wav: URL) async throws -> [SpeakerTurn] {
        let result = try await manager.process(wav)
        let turns = result.segments.map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        return SpeakerAssigner.relabel(turns.sorted { $0.start < $1.start })
    }
}

/// Merges diarization turns into a transcript (pure, tested).
public enum SpeakerAssigner {
    /// Renames raw speaker ids to "A", "B", ... by order of first appearance.
    public static func relabel(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var names: [String: String] = [:]
        return turns.map { t in
            if names[t.speaker] == nil { names[t.speaker] = label(names.count) }
            return SpeakerTurn(speaker: names[t.speaker]!, start: t.start, end: t.end)
        }
    }

    static func label(_ i: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return i < letters.count ? String(letters[i]) : "S\(i + 1)"
    }

    /// The speaker of a time span: the turn overlapping it most, else the nearest turn, else nil.
    static func speaker(_ start: Double, _ end: Double, turns: [SpeakerTurn]) -> String? {
        let overlaps = turns.map { ($0.speaker, min(end, $0.end) - max(start, $0.start)) }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        let mid = (start + end) / 2
        return turns.min { distance(mid, $0) < distance(mid, $1) }?.speaker
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : t > turn.end ? t - turn.end : 0
    }

    /// Gives every word a speaker and splits segments where the speaker changes; wordless segments take one
    /// speaker for their whole span. No turns leaves the transcript unchanged.
    public static func assign(_ t: Transcript, turns: [SpeakerTurn]) -> Transcript {
        guard !turns.isEmpty else { return t }
        var out = t
        out.segments = t.segments.flatMap { seg -> [Segment] in
            guard !seg.words.isEmpty else {
                var s = seg
                s.speaker = speaker(seg.start, seg.end, turns: turns)
                return [s]
            }
            var runs: [(speaker: String?, words: [Word])] = []
            for w in seg.words {
                let who = speaker(w.start, w.end, turns: turns)
                if let last = runs.last, last.speaker == who { runs[runs.count - 1].words.append(w) } else { runs.append((who, [w])) }
            }
            if runs.count == 1 {
                var s = seg
                s.speaker = runs[0].speaker
                return [s]
            }
            return runs.map { run in
                Segment(start: run.words.first!.start, end: run.words.last!.end,
                        text: run.words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                        words: run.words, speaker: run.speaker)
            }
        }
        return out
    }
}
