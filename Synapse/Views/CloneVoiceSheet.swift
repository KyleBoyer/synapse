import os
import AVFoundation
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

/// Clone a voice from a clip of one person speaking, chosen or recorded. PocketTTS reads up to 10 seconds; 5 to 10
/// works best.
struct CloneVoiceSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Called with the new voice so the pane can select it.
    var onCloned: (CustomVoice) -> Void = { _ in }

    @State private var sample: URL?
    @State private var seconds: Double?
    @State private var name = ""
    @State private var cloning = false
    @State private var error: String?
    @State private var recording = false
    @State private var stopRequested = false
    @State private var recorded: TimeInterval = 0
    @AppStorage(AudioDevices.inputKey) private var inputUID = ""
    @AppStorage(AudioDevices.outputKey) private var outputUID = ""

    private var ready: Bool {
        sample != nil && !cloning && !recording &&  !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone a Voice").font(.title2.weight(.semibold))
                Text("Choose or record 5 to 10 seconds of one person speaking clearly, with no music or other voices. The clip is transcribed, and every model that clones can speak the voice.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                PanelRow("Sample") {
                    HStack(spacing: 8) {
                        if recording {
                            Label(String(format: "Recording %.1f s", recorded), systemImage: "record.circle")
                                .font(.mono()).foregroundStyle(Color.live)
                            Button("Stop") { stopRecording() }
                        } else {
                            if let sample {
                                Text(sample.lastPathComponent.hasPrefix("Synapse-voice-") ? "Microphone recording" : sample.lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                                if let seconds { Text(String(format: "%.1f s", seconds)).font(.mono()).foregroundStyle(.secondary) }
                            }
                            Button(sample == nil ? "Choose…" : "Change…") { choose() }
                            Button("Record", systemImage: "mic") { Task { await record() } }
                        }
                    }
                }
                AudioDevicePicker("Microphone", input: true).disabled(recording)
                if let seconds, seconds < 3 {
                    Label("Short samples clone poorly; 5 to 10 seconds works best.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else if let seconds, seconds > 10 {
                    Label("Only the first 10 seconds are used.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                PanelRow("Name") {
                    TextField("Voice name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .onDisappear { stopRequested = true }
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
        // `-cloneSample <path>` fills the sheet (`mic` records instead), and `-cloneConfirm YES` clones it, so the flow can be captured.
        .task {
            guard let path = UserDefaults.standard.string(forKey: "cloneSample"), sample == nil else { return }
            if path == "mic" { await record(); return }
            pick(URL(fileURLWithPath: path))
            if UserDefaults.standard.bool(forKey: "cloneConfirm") {
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

    /// Records up to 10 seconds (all PocketTTS reads) from the chosen mic, through the app's shared audio link, to a
    /// WAV in the temp folder; Stop ends it sooner.
    private func record() async {
        error = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Synapse can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        let samples = OSAllocatedUnfairLock(initialState: [Int16]())
        let link: LiveAudio
        do {
            link = try await LiveAudio.acquire(.init(input: inputUID, output: outputUID, voiceProcessing: false),
                                         onChunk: { pcm in samples.withLock { $0 += pcm } }, onLevel: { _ in },
                                         onLost: { message in stopRequested = true; error = message })
        } catch {
            self.error = "Recording failed: \(error.localizedDescription)"
            return
        }
        recording = true; stopRequested = false; recorded = 0
        if name.isEmpty { name = "My voice" }
        while !stopRequested && recorded < 10 {
            try? await Task.sleep(for: .milliseconds(100))
            recorded = Double(samples.withLock { $0.count }) / 24000
        }
        link.release()
        recording = false
        let pcm = samples.withLock { $0 }
        let url = FileManager.default.temporaryDirectory.appending(path: "Synapse-voice-\(UUID().uuidString).wav")
        do {
            try SpeakModel.writeWAV(.init(text: "", model: "", voice: "", samples: pcm.map { Float($0) / 32768 }, rate: 24000), to: url)
            pick(url, keepName: true)
        } catch {
            self.error = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func stopRecording() { stopRequested = true }

    private func pick(_ url: URL, keepName: Bool = false) {
        sample = url; seconds = nil; error = nil
        if name.isEmpty && !keepName { name = url.deletingPathExtension().lastPathComponent }
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
                let voice = try await speech.createVoice(name: name, sample: sample)
                onCloned(voice)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
