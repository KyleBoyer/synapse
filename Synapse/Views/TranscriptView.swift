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
            HStack {
                Text(job.request.input.url.lastPathComponent).font(.headline).lineLimit(1)
                if let l = transcript.language { Text(Languages.name(l)).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.text, forType: .string)
                }
                Menu("Export") {
                    ForEach([OutputFormat.srt, .vtt, .txt, .json], id: \.self) { f in
                        Button(f.rawValue.uppercased()) { export(transcript, as: f) }
                    }
                }.fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            List(Array(transcript.segments.enumerated()), id: \.offset) { _, seg in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timestamp(seg.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(seg.text.trimmingCharacters(in: .whitespaces)).textSelection(.enabled)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
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
