import SwiftUI
import SynapseCore

/// Add any model from Hugging Face: paste `org/name` or a link, Synapse checks what it is and how it would run it.
struct AddModelSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Called with the added model's id, so the list can select it.
    var onAdded: (String) -> Void = { _ in }

    @State private var input = ""
    @State private var checking = false
    @State private var report: HFModelInspector.Report?
    @State private var error: String?
    @FocusState private var focused: Bool

    private var alreadyListed: Bool {
        guard let id = report?.model.id else { return false }
        return Catalog.spec(id) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add from Hugging Face").font(.title2.weight(.semibold))
                Text("Chat, vision, omni and embedding models in safetensors or MLX format.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                TextField("org/name or huggingface.co link", text: $input)
                    .textFieldStyle(.roundedBorder).font(.mono())
                    .focused($focused)
                    .onSubmit(check)
                    .onChange(of: input) { report = nil; error = nil }
                Button("Check", action: check)
                    .buttonStyle(.glass)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
            if checking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the repo…").foregroundStyle(.secondary) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = report { card(r) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Add") { add(download: false) }.buttonStyle(.glass).disabled(report == nil || alreadyListed)
                Button("Add and Download") { add(download: true) }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(report == nil || alreadyListed)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .onAppear {
            focused = true
            #if DEBUG
            if let repo = UserDefaults.standard.string(forKey: "addModel"), input.isEmpty { input = repo; check() }
            #endif
        }
    }

    private func card(_ r: HFModelInspector.Report) -> some View {
        let m = r.model
        let tooBig = m.ramGB.map { UInt64($0) << 30 > ProcessInfo.processInfo.physicalMemory } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayName).font(.headline)
                Text(m.repo).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            PanelRow("Kind") { Text(kind(m.engine)) }
            PanelRow("Download") { Text(sizeText(m.spec)).font(.mono()) }
            PanelRow("Memory") { Text(m.ramGB.map { "about \($0) GB" } ?? "–").font(.mono()) }
            ForEach(r.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tooBig {
                Label("More than this Mac's memory: it will page heavily and run slowly.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if alreadyListed {
                Label("Already in your models list.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func kind(_ engine: EngineKind) -> String {
        switch engine {
        case .mlx: "Chat · runs in Synapse"
        case .mlxvlm: "Chat · runs through mlx-vlm"
        case .embedding: "Embeddings"
        default: "\(engine)"
        }
    }

    private func check() {
        let text = input
        checking = true; report = nil; error = nil
        Task {
            defer { checking = false }
            do {
                report = try await HFModelInspector.inspect(text, token: state.settings.hfToken ?? HFDownloader.cliToken())
            } catch { self.error = error.localizedDescription }
        }
    }

    private func add(download: Bool) {
        guard let m = report?.model else { return }
        state.addCustom(m)
        onAdded(m.id)
        if download { state.download(m.id) }
        dismiss()
    }
}
