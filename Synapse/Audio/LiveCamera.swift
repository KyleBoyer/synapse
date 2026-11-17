import AVFoundation
import CoreImage
import SwiftUI

/// The default camera, keeping only its latest frame. Live sends one frame when the user starts talking.
// @unchecked Sendable: AVFoundation calls the delegate on its own queue; `latest` is guarded by `lock`, as in LiveAudio.
final class LiveCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "synapse.camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let context = CIContext()

    enum CameraError: LocalizedError {
        case denied, noCamera
        var errorDescription: String? {
            switch self {
            case .denied: "Camera access is denied. Allow Synapse under System Settings > Privacy & Security > Camera."
            case .noCamera: "No camera is available."
            }
        }
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.denied }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { throw CameraError.noCamera }
        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
        lock.withLock { latest = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock { latest = buffer }
    }

    /// The newest frame as JPEG, scaled so its longer side is at most `maxSide` (keeps the prompt small).
    func latestJPEG(maxSide: CGFloat = 512) -> Data? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    }
}

/// Live camera preview.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
