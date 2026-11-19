import AppKit
import SwiftUI
import SynapseCore
import UniformTypeIdentifiers

/// Images → Cut Out, Depth and Upscale: an image in, a result beside it. Cut-outs use macOS Vision (nothing to
/// download); depth uses Depth Anything V2 through Core ML; upscaling uses Real-ESRGAN on MLX.
struct ImageToolsView: View {
    #if DEBUG
    @MainActor static var autoNextDone = false
    #endif
    enum Tool: String { case cutout = "Cut Out", depth = "Depth", upscale = "Upscale" }
    struct Result: Identifiable {
        var id = UUID()
        let name: String
        let label: String
        let source: Data
        let output: Data
        let seconds: Double
    }

    let tool: Tool
    @Environment(AppState.self) private var state
    @State private var input: (name: String, data: Data)?
    @State private var maskOnly = false
    @State private var results: [Result] = []
    @State private var running = false
    @State private var started: Date?
    @State private var error: String?

    /// The model the tool needs (nil for Cut Out, which uses Vision).
    private var toolSpec: ModelSpec? {
        switch tool {
        case .cutout: nil
        case .depth: state.downloadedImageToolSpecs.first(where: \.isDepth)
        case .upscale: state.downloadedImageToolSpecs.first(where: \.isUpscaler)
        }
    }

    var body: some View {
        Group {
            if tool == .depth, toolSpec == nil {
                ContentUnavailableView("No depth model", systemImage: "square.3.layers.3d",
                                       description: Text("Download Depth Anything V2 small (50 MB) in Models."))
            } else if tool == .upscale, toolSpec == nil {
                ContentUnavailableView("No upscaling model", systemImage: "arrow.up.left.and.arrow.down.right",
                                       description: Text("Download Real-ESRGAN x4plus (33 MB) in Models."))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    canvas
                    ScrollView {
                        VStack(spacing: 12) {
                            readout
                            if tool == .cutout { options }
                        }
                        .padding(16).frame(maxWidth: .infinity)
                    }
                    .frame(width: 320)
                    .scrollClipDisabled()
                }
                .safeAreaInset(edge: .bottom) { bar.padding([.horizontal, .bottom], 16) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            load(u); return true
        }
        .onChange(of: running) { state.setActive(.images, running) }
        #if DEBUG
        // `-autoImageTool <path>` runs the current tool on that image once, for captures.
        .task(id: tool) {
            guard let path = UserDefaults.standard.string(forKey: "autoImageTool"), results.isEmpty, !running else { return }
            load(URL(fileURLWithPath: path)); run()
        }
        #endif
        .task(id: state.historyRevision) { await loadHistory() }
        #if DEBUG
        // `-autoNext edit|animate` presses that button on the first result, for checks.
        .onChange(of: results.first?.id) {
            guard let next = UserDefaults.standard.string(forKey: "autoNext"), let out = results.first?.output, !Self.autoNextDone else { return }
            Self.autoNextDone = true
            if next == "edit" { state.send(.editImage(out)) } else if next == "animate" { state.send(.animateImage(out)) }
        }
        #endif
    }

    private var readout: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let last = results.first
            BurnIn(
                name: toolSpec?.displayName ?? "Vision subject lifting",
                modelID: toolSpec?.id ?? "built into macOS",
                readings: [
                    Reading(label: "Status", value: running ? "working" : "idle", live: running),
                    Reading(label: "Elapsed", value: running ? started.map { String(format: "%.1f s", ctx.date.timeIntervalSince($0)) } ?? "–"
                                : last.map { String(format: "%.2f s", $0.seconds) } ?? "–", live: running),
                    Reading(label: "Size", value: last.flatMap { NSImage(data: $0.output) }.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? "–"),
                    Reading(label: "Runs on", value: tool == .depth ? "Core ML" : tool == .upscale ? "MLX" : "Vision"),
                ],
                running: running,
                api: tool == .cutout ? "POST /v1/images/cutout\noutput: \(maskOnly ? "mask" : "cutout")"
                    : "POST /v1/images/\(tool == .depth ? "depth" : "upscale")\nmodel: \(toolSpec?.id ?? "")")
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow("Output") {
                Picker("Output", selection: $maskOnly) {
                    Text("Subject").tag(false)
                    Text("Mask").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .disabled(running)
        .padding(14)
        .frame(width: 288, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                if results.isEmpty && !running {
                    Text(tool == .depth ? "Choose or drop an image to see its depth."
                         : tool == .upscale ? "Choose or drop an image, up to 1024 px on a side, to make it four times larger."
                         : "Choose or drop an image to lift its subject out.")
                        .font(.subtitle).foregroundStyle(.secondary).padding(.top, 40)
                }
                if running { LiveProgress(label: tool == .depth ? "Estimating depth" : tool == .upscale ? "Upscaling" : "Finding the subject") }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.name).font(.title3).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(r.label) · \(String(format: "%.2f s", r.seconds))").font(.mono(.caption)).foregroundStyle(.secondary)
                            DeleteItemMenu(noun: "result") { results.removeAll { $0.id == r.id }; state.deleteHistory([r.id], kind: .imageTool) }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            picture(r.source, checker: false)
                            picture(r.output, checker: r.label == "subject")
                                .overlay(alignment: .bottomTrailing) { actions(r.output) }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func picture(_ data: Data, checker: Bool) -> some View {
        Group {
            if let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFit()
                    .background { if checker { Checkerboard() } }
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actions(_ data: Data) -> some View {
        HStack(spacing: 4) {
            Button("Edit", systemImage: "wand.and.sparkles") { state.send(.editImage(data)) }
                .disabled(!state.downloadedImageSpecs.contains(where: \.canEditImages))
                .help("Edit this result in Generate: describe a change")
            AnimateButton(image: data)
            Button("Save…", systemImage: "square.and.arrow.down") { save(data) }
            Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png) }
        }
        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small).padding(8)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button(input == nil ? "Choose Image…" : "Change…", systemImage: "photo") { choose() }.buttonStyle(.glass)
            if let input { Text(input.name).lineLimit(1).truncationMode(.middle).font(.title3) }
            Spacer(minLength: 0)
            Button(tool == .depth ? "Estimate Depth" : tool == .upscale ? "Upscale" : "Cut Out",
                   systemImage: tool == .depth ? "square.3.layers.3d" : tool == .upscale ? "arrow.up.left.and.arrow.down.right" : "person.crop.rectangle",
                   action: run)
                .buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(input == nil || running)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .glassBar()
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let url = p.url { load(url) }
    }

    private func load(_ url: URL) {
        guard let d = try? Data(contentsOf: url), NSImage(data: d) != nil else { error = "\(url.lastPathComponent) is not an image."; return }
        input = (url.lastPathComponent, d); error = nil
    }

    private func run() {
        guard let input, !running else { return }
        let images = state.images, tool = tool, mask = maskOnly
        running = true; error = nil; started = Date()
        Task {
            defer { running = false }
            do {
                let out = switch tool {
                case .depth: try await images.depth(input.data, model: nil).1
                case .upscale: try await images.upscale(input.data, model: nil).1
                case .cutout: try await images.cutout(input.data, output: mask ? .mask : .cutout)
                }
                let label = tool == .depth ? "depth" : tool == .upscale ? "×4" : mask ? "mask" : "subject"
                let r = Result(name: input.name, label: label, source: input.data, output: out,
                               seconds: Date().timeIntervalSince(started ?? Date()))
                results.insert(r, at: 0)
                state.saveHistory(HistoryItem(id: r.id, kind: .imageTool, title: r.name, model: tool.rawValue,
                                              payload: (try? JSONEncoder().encode(Saved(label: label, seconds: r.seconds))) ?? Data()),
                                  files: ["source.png": r.source, "output.png": r.output])
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct Saved: Codable { var label: String; var seconds: Double }

    /// This tool's saved results, newest first. Tools share one history kind; `model` holds the tool's name.
    // shortcut: the newest 50 load (both images held in memory); page older ones in if a long history matters.
    private func loadHistory() async {
        guard state.savesHistory else { return }
        var loaded: [Result] = []
        for item in await state.history.list(.imageTool).filter({ $0.model == tool.rawValue }).prefix(50) {
            guard let s = item.decode(Saved.self), let src = await state.history.data(item, "source.png"),
                  let out = await state.history.data(item, "output.png") else { continue }
            loaded.append(Result(id: item.id, name: item.title, label: s.label, source: src, output: out, seconds: s.seconds))
        }
        results = loaded
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = tool == .depth ? "depth.png" : tool == .upscale ? "upscaled.png" : "cutout.png"
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Grey squares behind a transparent cut-out, so its edges show.
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
