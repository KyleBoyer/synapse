import Foundation

/// Turns Parakeet's subword token timings into words and sentence-ish segments.
public enum ParakeetWords {
    public struct Token: Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    /// A token beginning with "▁" (SentencePiece) or a space starts a new word.
    public static func words(from tokens: [Token]) -> [Word] {
        var words: [Word] = []
        for t in tokens {
            let startsWord = t.text.hasPrefix("▁") || t.text.hasPrefix(" ")
            let piece = t.text.replacingOccurrences(of: "▁", with: " ")
            if startsWord || words.isEmpty {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                words.append(Word(start: t.start, end: t.end, text: " " + trimmed))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = t.end
            }
        }
        return words
    }

    /// Split at sentence-final punctuation or pauses longer than `maxGap`.
    public static func segments(from words: [Word], maxGap: Double = 1.0) -> [Segment] {
        var segments: [Segment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(Segment(start: first.start, end: last.end,
                                    text: current.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                                    words: current))
            current = []
        }
        for w in words {
            if let prev = current.last, w.start - prev.end > maxGap { flush() }
            current.append(w)
            if let c = w.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(c) { flush() }
        }
        flush()
        return segments
    }
}
