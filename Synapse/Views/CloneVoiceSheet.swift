import AVFoundation
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

/// Clone a voice from a clip of one person speaking. PocketTTS reads up to 10 seconds; 5 to 10 works best.
struct CloneVoiceSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Called with the new voice so the pane can select it.
    var onCloned: (CustomVoice) -> Void = { _ in }

    @State private var sample: URL?
    @State private var seconds: Double?
    @State private var name = ""
    @State private var permitted = false
    @State private var cloning = false
    @State private var error: String?

    private var ready: Bool {
        sample != nil && permitted && !cloning && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone a Voice").font(.title2.weight(.semibold))
                Text("Use 5 to 10 seconds of one person speaking clearly, with no music or other voices.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                PanelRow("Sample") {
                    HStack(spacing: 8) {
                        if let sample {
                            Text(sample.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let seconds { Text(String(format: "%.1f s", seconds)).font(.mono()).foregroundStyle(.secondary) }
                        }
                        Button(sample == nil ? "Choose…" : "Change…") { choose() }
                    }
                }
                if let seconds, seconds < 3 {
                    Label("Short samples clone poorly; 5 to 10 seconds works best.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else if let seconds, seconds > 10 {
                    Label("Only the first 10 seconds are used.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                PanelRow("Name") {
                    TextField("Voice name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Toggle("This is my voice, or I have the speaker's permission to clone it.", isOn: $permitted)
                    .toggleStyle(.checkbox)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            if cloning {
                LiveProgress(label: "Cloning the voice")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Clone Voice", action: clone).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in pick(url) } }
            }
            return true
        }
        #if DEBUG
        // `-cloneSample <path>` fills the sheet, and `-cloneConfirm YES` clones it, so the flow can be captured.
        .task {
            guard let path = UserDefaults.standard.string(forKey: "cloneSample"), sample == nil else { return }
            pick(URL(fileURLWithPath: path))
            if UserDefaults.standard.bool(forKey: "cloneConfirm") {
                permitted = true
                try? await Task.sleep(for: .seconds(1))
                clone()
            }
        }
        #endif
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { pick(url) }
    }

    private func pick(_ url: URL) {
        sample = url; seconds = nil; error = nil
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        Task {
            let d = try? await AVURLAsset(url: url).load(.duration)
            seconds = d.map(\.seconds).flatMap { $0.isFinite ? $0 : nil }
        }
    }

    private func clone() {
        guard ready, let sample else { return }
        cloning = true; error = nil
        let speech = state.speech, name = name
        Task {
            defer { cloning = false }
            do {
                let voice = try await speech.createVoice(name: name, sample: sample, consentID: nil)
                onCloned(voice)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
