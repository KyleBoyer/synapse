import Foundation

public struct Cue: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var lines: [String]
    /// Set on diarized transcripts. SRT prefixes the first line with it; WebVTT uses a voice tag.
    public var speaker: String?
    public init(start: Double, end: Double, lines: [String], speaker: String? = nil) {
        self.start = start; self.end = end; self.lines = lines; self.speaker = speaker
    }
}

public struct CueOptions: Codable, Sendable, Equatable {
    public var maxLineChars: Int
    public var maxLines: Int
    public var maxDuration: Double
    public var maxGap: Double
    public var minDuration: Double
    public init(maxLineChars: Int = 42, maxLines: Int = 2, maxDuration: Double = 7, maxGap: Double = 1, minDuration: Double = 0.5) {
        self.maxLineChars = maxLineChars; self.maxLines = maxLines; self.maxDuration = maxDuration
        self.maxGap = maxGap; self.minDuration = minDuration
    }
}

public enum Subtitles {
    private static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func makeCues(_ t: Transcript, _ o: CueOptions = .init()) -> [Cue] {
        var words: [(word: Word, speaker: String?)] = []
        for s in t.segments {
            if s.words.isEmpty {
                // Whisper words carry a leading space; give wordless segments one so they don't glue together.
                let text = s.text.first?.isWhitespace == true ? s.text : " " + s.text
                words.append((Word(start: s.start, end: s.end, text: text), s.speaker))
            } else {
                words += s.words.map { ($0, s.speaker) }
            }
        }

        typealias Pending = (start: Double, end: Double, text: String, speaker: String?)
        var cues: [Pending] = []
        var cur: Pending?
        for (w, speaker) in words {
            if let c = cur {
                let budget = o.maxLineChars * o.maxLines - (speaker.map { $0.count + 2 } ?? 0)
                let appended = clean(c.text + w.text)
                let prevEnded = c.text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
                let split = appended.count > budget
                    || w.end - c.start > o.maxDuration
                    || w.start - c.end > o.maxGap
                    || (prevEnded && clean(c.text).count >= 20)
                    || speaker != c.speaker
                if split { cues.append(c); cur = (w.start, w.end, w.text, speaker) } else { cur = (c.start, w.end, c.text + w.text, speaker) }
            } else {
                cur = (w.start, w.end, w.text, speaker)
            }
        }
        if let c = cur { cues.append(c) }

        var out = cues.compactMap { c -> Cue? in
            let text = clean(c.text)
            guard !text.isEmpty else { return nil }
            guard let speaker = c.speaker else { return Cue(start: c.start, end: c.end, lines: wrap(text, o)) }
            // Wrap with the SRT prefix in place so the prefixed first line still fits maxLineChars.
            let prefix = "\(speaker): "
            var lines = wrap(prefix + text, o)
            lines[0] = String(lines[0].dropFirst(prefix.count))
            return Cue(start: c.start, end: c.end, lines: lines.filter { !$0.isEmpty }, speaker: speaker)
        }
        for i in out.indices {
            out[i].end = max(out[i].end, out[i].start + o.minDuration)
            if i + 1 < out.count { out[i].end = min(out[i].end, out[i + 1].start) }
        }
        return out
    }

    private static func wrap(_ text: String, _ o: CueOptions) -> [String] {
        if text.count <= o.maxLineChars || o.maxLines < 2 { return [text] }
        let chars = Array(text)
        let mid = chars.count / 2
        let spaces = chars.indices.filter { chars[$0] == " " }
        if let i = spaces.min(by: { abs($0 - mid) < abs($1 - mid) }) {
            let a = String(chars[..<i]), b = String(chars[(i + 1)...])
            if a.count <= o.maxLineChars && b.count <= o.maxLineChars { return [a, b] }
        }
        // Oversize text is never dropped: greedy wrap, long words stay whole.
        var lines: [String] = []
        for word in text.split(separator: " ") {
            if let last = lines.last, last.count + 1 + word.count <= o.maxLineChars { lines[lines.count - 1] = last + " " + word }
            else { lines.append(String(word)) }
        }
        return lines
    }

    private static func ts(_ seconds: Double, _ sep: String) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            let lines = c.speaker.map { s in [(c.lines.first.map { "\(s): \($0)" } ?? "\(s):")] + c.lines.dropFirst() } ?? c.lines
            return "\(i + 1)\n\(ts(c.start, ",")) --> \(ts(c.end, ","))\n\(lines.joined(separator: "\n"))\n\n"
        }.joined()
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            let voice = c.speaker.map { "<v Speaker \($0)>" } ?? ""
            return "\(ts(c.start, ".")) --> \(ts(c.end, "."))\n\(voice)\(c.lines.joined(separator: "\n"))\n\n"
        }.joined()
    }

    public static func txt(_ t: Transcript) -> String {
        t.segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
    }

    public static func tsv(_ t: Transcript) -> String {
        "start\tend\ttext\n" + t.segments.map {
            "\(Int(($0.start * 1000).rounded()))\t\(Int(($0.end * 1000).rounded()))\t\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined()
    }

    private static func json(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    public static func openAIJSON(_ t: Transcript) -> String { json(["text": t.text]) }

    public static func verboseJSON(_ t: Transcript, task: TaskKind) -> String {
        var o: [String: Any] = [
            "task": task.rawValue, "duration": t.duration, "text": t.text,
            "segments": t.segments.enumerated().map { i, s in
                var seg: [String: Any] = ["id": i, "start": s.start, "end": s.end, "text": s.text]
                if let speaker = s.speaker { seg["speaker"] = speaker }
                return seg
            },
            "words": t.segments.flatMap(\.words).map { ["word": $0.text.trimmingCharacters(in: .whitespaces), "start": $0.start, "end": $0.end] as [String: Any] },
        ]
        if let l = t.language { o["language"] = l }
        return json(o)
    }

    /// OpenAI's `diarized_json` (TranscriptionDiarized). Segments without a speaker are attributed to "A".
    public static func diarizedJSON(_ t: Transcript, task: TaskKind) -> String {
        json([
            "task": task.rawValue, "duration": t.duration, "text": t.text,
            "segments": t.segments.enumerated().map { i, s in
                ["id": "seg_\(i)", "type": "transcript.text.segment", "start": s.start, "end": s.end,
                 "text": s.text.trimmingCharacters(in: .whitespaces), "speaker": s.speaker ?? "A"] as [String: Any]
            },
            "usage": ["type": "duration", "seconds": Int(t.duration.rounded(.up))] as [String: Any],
        ])
    }

    public static func render(_ t: Transcript, as f: OutputFormat, task: TaskKind = .transcribe,
                              cueOptions: CueOptions = .init()) -> (body: String, contentType: String) {
        switch f {
        case .srt: return (srt(makeCues(t, cueOptions)), "application/x-subrip")
        case .vtt: return (vtt(makeCues(t, cueOptions)), "text/vtt")
        case .json: return (openAIJSON(t), "application/json")
        case .verboseJSON: return (verboseJSON(t, task: task), "application/json")
        case .diarizedJSON: return (diarizedJSON(t, task: task), "application/json")
        case .tsv: return (tsv(t), "text/plain; charset=utf-8")
        case .txt, .text: return (txt(t), "text/plain; charset=utf-8")
        }
    }
}
