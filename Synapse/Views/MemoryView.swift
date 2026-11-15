import SwiftUI
import SynapseCore

struct MemoryView: View {
    @Environment(AppState.self) private var state

    private var budgetBytes: Int { state.settings.modelManagerConfig.budgetBytes }
    private var totalBytes: Int { state.residents.reduce(0) { $0 + $1.bytes } }
    private func gb(_ b: Int) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    var body: some View {
        Form {
            Section("Budget") {
                Gauge(value: min(Double(totalBytes), Double(budgetBytes)), in: 0...Double(max(budgetBytes, 1))) {
                    Text("Loaded models")
                } currentValueLabel: {
                    Text("\(gb(totalBytes)) of \(gb(budgetBytes))")
                }
                .tint(totalBytes > budgetBytes ? .orange : .accentColor)
                if state.memoryOvercommitted || totalBytes > budgetBytes {
                    Label("Over budget: macOS will page memory to disk and everything may slow down.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text("This Mac has \(gb(Int(ProcessInfo.processInfo.physicalMemory))). Change the budget in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Loaded models") {
                if state.residents.isEmpty {
                    Text("No models are loaded.").foregroundStyle(.secondary)
                }
                ForEach(state.residents) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Catalog.spec(r.id)?.displayName ?? r.id)
                            HStack(spacing: 4) {
                                Text("\(gb(r.bytes)) ·")
                                Text(r.leases > 0 ? "in use" : "idle")
                                Text("· last used")
                                Text(r.lastUsed, format: .relative(presentation: .named))
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unload") { state.unloadModel(r.id) }.disabled(r.leases > 0)
                    }
                }
                Button("Unload All Idle") { state.unloadAllIdle() }
                    .disabled(!state.residents.contains { $0.leases == 0 })
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Memory")
        .task {
            while !Task.isCancelled {
                await state.refreshResidents()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
