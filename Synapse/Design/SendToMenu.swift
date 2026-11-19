import AVKit
import SwiftUI
import SynapseCore

/// A result that can become the input of another generation.
enum SendItem {
    case image(Data)
    case video(URL)
    /// An audio clip, written out on demand (clips live as samples), and the text it was made from, if any.
    case audio(file: () -> URL?, text: String?)
    case text(String)
}

/// "Send To" on every result: each modality can feed every other, directly where a model takes it (an image to
/// animate, a clip's soundtrack to clean up) and through text otherwise (audio is transcribed, then the transcript
/// makes the image). Prompts land in the target pane's composer, where they can be edited before running; Synapse
/// adds no words of its own.
struct SendToMenu: View {
    let item: SendItem
    @Environment(AppState.self) private var state

    var body: some View {
        Menu("Send To", systemImage: "arrowshape.turn.up.right") { items }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).labelStyle(.iconOnly).fixedSize()
            .help("Send to another pane as the input of the next generation")
    }

    private var hasEdit: Bool { state.downloadedImageSpecs.contains(where: \.canEditImages) }
    private var hasImage: Bool { !state.downloadedImageSpecs.isEmpty }
    private var hasVideo: Bool { !state.downloadedVideoSpecs.isEmpty || VideoEngines.mock }
    private var hasChat: Bool { !state.downloadedChatSpecs.isEmpty }
    private var hasSpeech: Bool { !state.downloadedTTSSpecs.isEmpty }
    private var hasSound: Bool { !state.downloadedSoundSpecs.isEmpty }
    private var hasCleanUp: Bool { !state.downloadedEditSpecs.isEmpty }
    private var hasTranscribe: Bool { !state.downloadedSpecs.isEmpty }

    @ViewBuilder private var items: some View {
        switch item {
        case .image(let data):
            Button("Edit in Images") { state.send(.editImage(data)) }.disabled(!hasEdit)
            Button("Animate in Video") { state.send(.animateImage(data)) }.disabled(!hasVideo)
            Button("Ask About It in Chat") { state.send(.chat(text: "", images: [data], videos: [], audios: [])) }.disabled(!hasChat)
        case .video(let url):
            Button("Edit Frame in Images") { Task { if let f = await Self.frame(url) { state.send(.editImage(f)) } } }.disabled(!hasEdit)
            Button("Animate from Frame") { Task { if let f = await Self.frame(url) { state.send(.animateImage(f)) } } }.disabled(!hasVideo)
            Button("Transform in Video") { state.send(.transformVideo(url)) }
            Divider()
            Button("Clean Up Its Sound") { state.send(.cleanUp(url)) }.disabled(!hasCleanUp)
            Button("Transcribe Its Speech") { state.send(.transcribe(url)) }.disabled(!hasTranscribe)
            Button("Ask About It in Chat") { state.send(.chat(text: "", images: [], videos: [url], audios: [])) }.disabled(!hasChat)
        case .audio(let file, let text):
            Button("Clean Up") { if let f = file() { state.send(.cleanUp(f)) } }.disabled(!hasCleanUp)
            Button("Transcribe") { if let f = file() { state.send(.transcribe(f)) } }.disabled(!hasTranscribe)
            Button("Ask About It in Chat") { if let f = file() { state.send(.chat(text: "", images: [], videos: [], audios: [f])) } }
                .disabled(!hasChat)
            if let text, !text.isEmpty {
                Divider()
                prompts(text, speech: false)
            }
        case .text(let text):
            prompts(text, speech: true)
            Button("Ask About It in Chat") { state.send(.chat(text: text, images: [], videos: [], audios: [])) }.disabled(!hasChat)
        }
    }

    /// Text as the prompt of another generation.
    @ViewBuilder private func prompts(_ text: String, speech: Bool) -> some View {
        Button("Make an Image") { state.send(.prompt(text, .image)) }.disabled(!hasImage)
        Button("Make a Video") { state.send(.prompt(text, .video)) }.disabled(!hasVideo)
        if speech { Button("Speak It") { state.send(.prompt(text, .speech)) }.disabled(!hasSpeech) }
        Button("Make a Sound") { state.send(.prompt(text, .sound)) }.disabled(!hasSound)
    }

    /// The frame at the clip's playhead (pause on the frame you want), or its first frame if it never played.
    static func frame(_ url: URL) async -> Data? {
        let at = ClipPlayer.playhead(url) ?? .zero
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let (cg, _) = try? await generator.image(at: at) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
