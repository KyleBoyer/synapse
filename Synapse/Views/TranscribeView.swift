import SwiftUI
import SynapseCore

struct TranscribeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.paneShown) private var paneShown
    @State private var modelID: String?
    @State private var language: String?
    @State private var task: TaskKind = .transcribe
    @State private var saveSidecar = false
    @State private var diarize = false
    @State private var dropTargeted = false
    @State private var selection: UUID?
    @State private var opened: JobSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            jobs
            ScrollView {
                Group { if let job = focusJob { readout(job) } else { idleReadout } }.padding(16).frame(maxWidth: .infinity)
            }
            .frame(width: 320).scrollClipDisabled()
        }
        .dropDestination(for: URL.self) { urls, _ in submit(urls); return !urls.isEmpty } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.live, lineWidth: 2).padding(10).allowsHitTesting(false)
            }
        }
        .onChange(of: state.tryRequest, initial: true) { if let s = state.takeTry(.transcribe) { modelID = s.id } }
        .toolbar { if paneShown {
            ToolbarItemGroup {
                ChoiceMenu(title: "Model", selection: $modelID,
                           options: [(nil, "Default · \(Catalog.spec(state.settings.defaultModelID)?.displayName ?? state.settings.defaultModelID)")]
                               + state.downloadedSpecs.map { (Optional($0.id), $0.displayName) },
                           detail: { $0 })
                ChoiceMenu(title: "Language", selection: $language,
                           options: [(nil, "Auto-detect language")] + Languages.common.map { (Optional($0), Languages.name($0)) })
                ChoiceMenu(title: "Task", selection: $task,
                           options: [(.transcribe, "Transcribe"), (.translate, "Translate to English")])
                Toggle("Save .srt next to file", systemImage: "doc.badge.plus", isOn: $saveSidecar)
                    .help("Save .srt next to each file")
                Toggle("Label speakers", systemImage: "person.2", isOn: $diarize)
                    .disabled(!state.diarizerReady)
                    .help(state.diarizerReady ? "Label who speaks when" : "Download Speaker diarization in Models to label speakers")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button("Choose Files…", systemImage: "plus") { choose() }
                HistoryButton(kind: .transcript, noun: "transcript") { item in opened = item.decode(TranscriptRecord.self)?.job(item) }
                Button("Clear Finished", systemImage: "trash") { state.clearFinished() }
                    .disabled(!state.jobs.contains { $0.status.isTerminal })
            }
        } }
        .sheet(item: $opened) { TranscriptView(job: $0) }
        .onChange(of: state.handoff, initial: true) {
            guard case .transcribe(let url) = state.handoff else { return }
            state.handoff = nil
            submit([url])
        }
        #if DEBUG
        // `-autoTranscribe <path> [-autoDiarize YES]` submits one file after launch and opens its transcript when done,
        // so the result can be captured without typing.
        .task(id: state.diarizerReady) {
            guard let path = UserDefaults.standard.string(forKey: "autoTranscribe"), state.jobs.isEmpty else { return }
            let wantDiarize = UserDefaults.standard.bool(forKey: "autoDiarize")
            if wantDiarize && !state.diarizerReady { return }
            state.submit(files: [URL(fileURLWithPath: path)], modelID: nil, language: nil, task: .transcribe, saveSidecar: false,
                         diarize: wantDiarize)
        }
        .onChange(of: state.jobs.last?.status) {
            guard UserDefaults.standard.string(forKey: "autoTranscribe") != nil, let job = state.jobs.last,
                  job.status == .done, opened == nil else { return }
            opened = job
        }
        #endif
    }

    /// The job the readout follows: the selected one, else the one running, else the latest.
    private var focusJob: JobSnapshot? {
        state.jobs.first { $0.id == selection }
            ?? state.jobs.last { !$0.status.isTerminal && $0.status != .queued }
            ?? state.jobs.last
    }

    @ViewBuilder private var jobs: some View {
        if state.jobs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(state.downloadedSpecs.isEmpty ? "Download a transcription model in Models first." : "Drop audio or video files or folders anywhere here.")
                    .font(.subtitle)
                Text("Whisper and Parakeet run on the Neural Engine. The first run of a model prepares it, which can take a few minutes.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(state.jobs.reversed()) { job in
                    JobRow(job: job, elapsed: elapsed(job)).tag(job.id)
                        .contextMenu { if job.transcript != nil { Button("Open Transcript") { opened = job } } }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                opened = state.jobs.first { ids.contains($0.id) && $0.transcript != nil }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func elapsed(_ job: JobSnapshot) -> Double? {
        state.jobElapsed[job.id] ?? state.jobStarted[job.id].map { Date().timeIntervalSince($0) }
    }

    private func readout(_ job: JobSnapshot) -> some View {
        let spec = job.modelID.flatMap(Catalog.spec) ?? modelID.flatMap(Catalog.spec)
        let duration = job.transcript?.duration
        let took = state.jobElapsed[job.id]
        let active = !job.status.isTerminal && job.status != .queued
        var readings = [Reading(label: "File", value: job.request.input.url.lastPathComponent)]
        readings.append(Reading(label: "Status", value: job.status.shortLabel, live: active))
        if case .transcribing(let p?) = job.status { readings.append(Reading(label: "Progress", value: "\(Int(p * 100))%", live: true)) }
        readings.append(Reading(label: "Audio", value: duration.map { timecode($0) } ?? "–"))
        readings.append(Reading(label: "Processing", value: (took ?? elapsed(job)).map { String(format: "%.1f s", $0) } ?? "–", live: active))
        if let duration, let took, took > 0 {
            readings.append(Reading(label: "Speed", value: Metric.realtimeSpeed.format(duration / took) + "× realtime"))
        }
        if let lang = job.transcript?.language { readings.append(Reading(label: "Language", value: Languages.name(lang))) }
        let speakers = Set(job.transcript?.segments.compactMap(\.speaker) ?? [])
        if !speakers.isEmpty { readings.append(Reading(label: "Speakers", value: "\(speakers.count)")) }
        if let spec, let r = state.resident(spec.id) { readings.append(Reading(label: "Resident", value: r.memory)) }
        return VStack(spacing: 12) {
            BurnIn(name: spec?.displayName ?? "Default model", modelID: spec?.id ?? state.settings.defaultModelID,
                   readings: readings,
                   history: spec.map { state.metrics.history($0.id, .realtimeSpeed) } ?? [], historyMetric: .realtimeSpeed,
                   running: active,
                   api: "POST /v1/audio/transcriptions\nmodel: \(spec?.id ?? "whisper-1")")
            if job.transcript != nil {
                Button("Open Transcript", systemImage: "text.alignleft") { opened = job }
                    .buttonStyle(.glass).controlSize(.large)
            }
        }
    }

    /// Before any job: the model the next file will use and what it has measured so far.
    private var idleReadout: some View {
        let id = modelID ?? state.settings.defaultModelID
        let spec = Catalog.spec(id)
        return BurnIn(
            name: spec?.displayName ?? id, modelID: id,
            readings: [
                Reading(label: "Speed", value: state.metrics.typical(id, .realtimeSpeed) ?? "no runs yet", muted: true),
                Reading(label: "Languages", value: spec.map { $0.languages.map { $0 == ["en"] ? "English" : "\($0.count)" } ?? "99" } ?? "–"),
                Reading(label: "Translate", value: spec?.canTranslate == true ? "to English" : "no"),
                Reading(label: "Resident", value: state.resident(id).map { $0.memory } ?? "not loaded"),
            ],
            history: state.metrics.history(id, .realtimeSpeed), historyMetric: .realtimeSpeed,
            api: "POST /v1/audio/transcriptions\nmodel: \(id)")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { submit(panel.urls) }
    }

    private func submit(_ urls: [URL]) {
        state.submit(files: urls, modelID: modelID, language: language, task: task, saveSidecar: saveSidecar,
                     diarize: diarize && state.diarizerReady)
    }
}

struct JobRow: View {
    @Environment(AppState.self) private var state
    let job: JobSnapshot
    let elapsed: Double?

    var body: some View {
        let active = !job.status.isTerminal && job.status != .queued
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.request.input.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Text(job.status.label).foregroundStyle(statusColor)
                    if let m = job.modelID { Text(m).font(.mono(.caption)).foregroundStyle(.secondary) }
                    if let out = job.outputURL { Text(out.lastPathComponent).foregroundStyle(.secondary) }
                }
                .font(.caption).lineLimit(1)
                if active {
                    if case .transcribing(let p?) = job.status { ProgressView(value: p).tint(.live) }
                    else { ProgressView().progressViewStyle(.linear).tint(.live) }
                }
            }
            Spacer()
            if let elapsed { Text(timecode(elapsed)).font(.mono(.caption)).foregroundStyle(active ? Color.live : Color.secondary) }
            if !job.status.isTerminal {
                Button("Cancel", systemImage: "xmark.circle") { state.cancel(job.id) }.labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if let out = job.outputURL {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: .red
        case .done: .green
        case .skipped, .cancelled: .secondary
        default: .primary
        }
    }
}
