import SwiftUI
import SynapseCore

struct MemoryView: View {
    @Environment(AppState.self) private var state

    private var budget: Int { state.settings.modelManagerConfig.budgetBytes }
    private var used: Int { state.residents.reduce(0) { $0 + $1.bytes } }
    private var ram: Int { Int(ProcessInfo.processInfo.physicalMemory) }
    private var over: Bool { state.memoryOvercommitted || used > budget }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(gigabytes(used)).font(.mono(.largeTitle, weight: .bold))
                        Text("of \(gigabytes(budget)) budget · \(gigabytes(ram)) in this Mac").font(.mono(.callout)).foregroundStyle(.secondary)
                    }
                    budgetBar
                    if over {
                        Label("Over budget: macOS will page memory to disk and everything may slow down.",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Text("Idle models unload after \(state.settings.idleUnloadMinutes == 0 ? "never" : "\(state.settings.idleUnloadMinutes) min").")
                        SettingsLink { Text("Change budget…") }.buttonStyle(.borderless)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Loaded models").font(.headline)
                        Spacer()
                        Button("Unload All Idle") { state.unloadAllIdle() }.buttonStyle(.glass)
                            .disabled(!state.residents.contains { $0.leases == 0 })
                    }
                    .padding(.bottom, 10)
                    if state.residents.isEmpty {
                        Text("No models are loaded. They load on first use and stay until idle or evicted.")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(state.residents) { r in
                        Divider()
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Catalog.spec(r.id)?.displayName ?? r.id)
                                Text(r.id).font(.mono(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.leases > 0 { Label("in use", systemImage: "circle.fill").labelStyle(.titleOnly).foregroundStyle(Color.live) }
                            else { (Text("idle, used ") + Text(r.lastUsed, format: .relative(presentation: .named))).foregroundStyle(.secondary) }
                            Text(gigabytes(r.bytes)).font(.mono(.body, weight: .medium)).frame(width: 80, alignment: .trailing)
                            Button("Unload") { state.unloadModel(r.id) }.buttonStyle(.glass).disabled(r.leases > 0)
                        }
                        .font(.callout)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Memory")
    }

    /// The budget as a bar, one segment per loaded model, so the biggest consumer is obvious.
    private var budgetBar: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Double(max(budget, used, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 2) {
                    ForEach(state.residents) { r in
                        Rectangle()
                            .fill(r.leases > 0 ? Color.live : Color.primary.opacity(0.55))
                            .frame(width: max(2, Double(r.bytes) * scale - 2))
                            .help("\(Catalog.spec(r.id)?.displayName ?? r.id): \(gigabytes(r.bytes))")
                    }
                }
                .clipShape(Capsule())
                if used > budget {
                    Rectangle().fill(.orange).frame(width: 2).offset(x: Double(budget) * scale)
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gigabytes(used)) of \(gigabytes(budget)) memory budget used by \(state.residents.count) models")
    }
}
