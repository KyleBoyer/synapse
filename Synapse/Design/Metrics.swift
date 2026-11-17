import Foundation
import Observation

/// A measured characteristic of a model. Each case carries its datasheet row: label, unit, test conditions,
/// and how to print it, so every pane and the Models datasheet read from one table.
enum Metric: String, Codable, CaseIterable, Identifiable {
    case firstToken, decodeRate, prefillRate, realtimeSpeed, secondsPerStep, imageTime, firstAudio, ttsFirstAudio, ttsSpeed, embedRate, videoTime
    var id: String { rawValue }

    var label: String {
        switch self {
        case .firstToken: "Time to first token"
        case .decodeRate: "Decode rate"
        case .prefillRate: "Prompt rate"
        case .realtimeSpeed: "Transcription speed"
        case .secondsPerStep: "Denoising step"
        case .imageTime: "Image time"
        case .firstAudio: "First audio"
        case .ttsFirstAudio: "Time to first audio"
        case .ttsSpeed: "Speech speed"
        case .embedRate: "Embedding rate"
        case .videoTime: "Video time"
        }
    }

    var unit: String {
        switch self {
        case .firstToken, .secondsPerStep, .imageTime, .firstAudio, .ttsFirstAudio, .videoTime: "s"
        case .decodeRate, .prefillRate, .embedRate: "tok/s"
        case .realtimeSpeed, .ttsSpeed: "× realtime"
        }
    }

    var conditions: String {
        switch self {
        case .firstToken: "from send, includes prompt processing"
        case .decodeRate: "output tokens after the first"
        case .prefillRate: "prompt tokens ÷ time to first token"
        case .realtimeSpeed: "audio length ÷ processing time, decode included"
        case .secondsPerStep: "wall time per step, after model load"
        case .imageTime: "one image, after model load"
        case .firstAudio: "end of speech to first reply audio"
        case .ttsFirstAudio: "from request to first audio chunk"
        case .ttsSpeed: "audio length ÷ synthesis time"
        case .embedRate: "prompt tokens ÷ wall time, model already loaded"
        case .videoTime: "one clip, model load included (each clip runs in a fresh process)"
        }
    }

    var higherIsBetter: Bool { self == .decodeRate || self == .prefillRate || self == .realtimeSpeed || self == .ttsSpeed || self == .embedRate }

    func format(_ v: Double) -> String {
        switch self {
        case .decodeRate, .prefillRate, .realtimeSpeed, .ttsSpeed, .embedRate: v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        default: v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        }
    }
}

/// Measurements from runs in this app, per model id. Kept small and persisted so a model's datasheet survives relaunch.
@MainActor @Observable
final class MetricsStore {
    struct Stats { let min: Double, typ: Double, max: Double, count: Int }
    private static let key = "metrics.v1", keep = 40

    private(set) var runs: [String: [Metric: [Double]]]

    init() {
        runs = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([String: [Metric: [Double]]].self, from: $0) } ?? [:]
    }

    func record(_ model: String, _ metric: Metric, _ value: Double) {
        guard value.isFinite, value > 0 else { return }
        runs[model, default: [:]][metric, default: []].append(value)
        if let n = runs[model]?[metric]?.count, n > Self.keep { runs[model]?[metric]?.removeFirst(n - Self.keep) }
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func history(_ model: String, _ metric: Metric) -> [Double] { runs[model]?[metric] ?? [] }

    /// Typ is the median of the kept runs.
    func stats(_ model: String, _ metric: Metric) -> Stats? {
        let v = history(model, metric).sorted()
        guard let lo = v.first, let hi = v.last else { return nil }
        let mid = v.count / 2
        return Stats(min: lo, typ: v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2, max: hi, count: v.count)
    }

    /// "typ 0.77 s" for a readout at rest, or nil when there are no runs yet.
    func typical(_ model: String, _ metric: Metric) -> String? {
        stats(model, metric).map { "typ \(metric.format($0.typ)) \(metric.unit)" }
    }

    func clear(_ model: String) {
        runs[model] = nil
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
