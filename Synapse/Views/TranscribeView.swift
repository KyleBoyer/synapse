import SwiftUI
import SynapseCore

struct TranscribeView: View {
    @Environment(AppState.self) private var state
    @State private var modelID: String?
    @State private var language: String?
    @State private var task: TaskKind = .transcribe
    @State private var saveSidecar = false
    @State private var dropTargeted = false
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ModelPicker(title: "Model", specs: state.downloadedSpecs, id: $modelID).frame(maxWidth: 260)
                LanguagePicker(title: "Language", code: $language).frame(maxWidth: 200)
                Picker("Task", selection: $task) {
                    Text("Transcribe").tag(TaskKind.transcribe)
                    Text("Translate to English").tag(TaskKind.translate)
                }.frame(maxWidth: 240)
                Toggle("Save .srt next to file", isOn: $saveSidecar)
            }
            .padding()

            dropZone.padding(.horizontal)

            List(selection: $selection) {
                ForEach(state.jobs.reversed()) { job in
                    JobRow(job: job).tag(job.id)
                }
            }
            .overlay { if state.jobs.isEmpty { ContentUnavailableView("No jobs yet", systemImage: "waveform") } }
        }
        .navigationTitle("Transcribe")
        .toolbar {
            Button("Choose Files…", systemImage: "plus") { choose() }
            Button("Clear Finished", systemImage: "trash") { state.clearFinished() }
                .disabled(!state.jobs.contains { $0.status.isTerminal })
        }
        .sheet(item: selectedDoneJob) { job in TranscriptView(job: job) }
    }

    private var selectedDoneJob: Binding<JobSnapshot?> {
        Binding(
            get: { state.jobs.first { $0.id == selection && $0.transcript != nil } },
            set: { if $0 == nil { selection = nil } })
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title)
                    Text(state.downloadedSpecs.isEmpty ? "Download a model first (Models)" : "Drop audio or video files or folders here")
                }.foregroundStyle(.secondary)
            }
            .dropDestination(for: URL.self) { urls, _ in
                submit(urls)
                return !urls.isEmpty
            } isTargeted: { dropTargeted = $0 }
            .accessibilityLabel("Drop zone for media files")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { submit(panel.urls) }
    }

    private func submit(_ urls: [URL]) {
        state.submit(files: urls, modelID: modelID, language: language, task: task, saveSidecar: saveSidecar)
    }
}

struct JobRow: View {
    @Environment(AppState.self) private var state
    let job: JobSnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.request.input.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(job.status.label).foregroundStyle(statusColor)
                    if let m = job.modelID, let spec = Catalog.spec(m) { Text(spec.displayName).foregroundStyle(.tertiary) }
                    if let out = job.outputURL { Text(out.lastPathComponent).foregroundStyle(.tertiary) }
                }.font(.caption)
                if !job.status.isTerminal, job.status != .queued {
                    if case .transcribing(let p?) = job.status { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Spacer()
            if !job.status.isTerminal {
                Button("Cancel", systemImage: "xmark.circle") { state.cancel(job.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if let out = job.outputURL {
                Button("Show in Finder", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: .red
        case .done: .green
        default: .secondary
        }
    }
}
