import SwiftUI
import SynapseCore

enum Languages {
    /// Common subtitle languages; Whisper supports more, which the API accepts as codes.
    static let common = ["en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "sv", "da", "fi", "no",
                         "cs", "el", "hu", "ro", "tr", "ja", "ko", "zh", "ar", "hi", "he", "vi", "th", "id"]
    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

struct LanguagePicker: View {
    let title: String
    @Binding var code: String?
    var body: some View {
        Picker(title, selection: $code) {
            Text("Auto-detect language").tag(String?.none)
            Divider()
            ForEach(Languages.common, id: \.self) { Text(Languages.name($0)).tag(String?.some($0)) }
        }
    }
}

struct ModelPicker: View {
    let title: String
    let specs: [ModelSpec]
    @Binding var id: String?
    var allowDefault = true
    var body: some View {
        Picker(title, selection: $id) {
            if allowDefault { Text("Default model").tag(String?.none) }
            ForEach(specs) { Text($0.displayName).tag(String?.some($0.id)) }
        }
    }
}

extension JobStatus {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .preparingModel: "Preparing model (first run can take a few minutes)"
        case .decoding: "Extracting audio"
        case .diarizing: "Labeling speakers"
        case .transcribing(let p): p.map { "Transcribing \(Int($0 * 100))%" } ?? "Transcribing"
        case .done: "Done"
        case .failed(let m): "Failed: \(m)"
        case .cancelled: "Cancelled"
        case .skipped(let m): "Skipped: \(m)"
        }
    }
}

extension JobStatus {
    /// For the readout, where the long first-run explanation does not fit.
    var shortLabel: String {
        switch self {
        case .preparingModel: "Preparing model"
        case .failed: "Failed"
        case .skipped: "Skipped"
        default: label
        }
    }
}

func timestamp(_ t: Double) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
