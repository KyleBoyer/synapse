import SwiftUI
import UniformTypeIdentifiers
import SynapseCore

struct TranscriptView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let job: JobSnapshot

    var body: some View {
        let transcript = job.transcript ?? Transcript(language: nil, duration: 0, segments: [])
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.request.input.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        if let l = transcript.language { Text(Languages.name(l)) }
                        Text(timecode(transcript.duration)).font(.mono(.caption))
                        Text("\(transcript.segments.count) segments")
                        let speakers = Set(transcript.segments.compactMap(\.speaker))
                        if !speakers.isEmpty { Text("\(speakers.count) speakers") }
                        if let m = job.modelID { Text(m).font(.mono(.caption)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Text", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.text, forType: .string)
                }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ForEach([OutputFormat.srt, .vtt, .txt, .json], id: \.self) { f in
                        Button(f.rawValue.uppercased()) { export(transcript, as: f) }
                    }
                }
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
            .buttonStyle(.glass)
            .padding(16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { i, seg in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(timecode(seg.start)).font(.mono(.caption)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                // The speaker label opens each run of segments by the same speaker, as Chat labels turns.
                                if let s = seg.speaker, i == 0 || transcript.segments[i - 1].speaker != s {
                                    Text("Speaker \(s)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(seg.text.trimmingCharacters(in: .whitespaces)).font(.subtitle).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private func export(_ t: Transcript, as format: OutputFormat) {
        let rendered = Subtitles.render(t, as: format, task: job.request.task, cueOptions: state.settings.cue)
        let panel = NSSavePanel()
        let base = job.request.input.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base).\(format.rawValue)"
        if let type = UTType(filenameExtension: format.rawValue) { panel.allowedContentTypes = [type] }
        panel.directoryURL = job.request.input.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(rendered.body.utf8).write(to: url, options: .atomic)
    }
}
