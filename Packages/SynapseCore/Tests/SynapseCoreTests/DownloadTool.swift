import XCTest
@testable import SynapseCore

/// Downloads catalog models into the app's real model store through ModelStore (not a test of behaviour;
/// a way to pre-fetch big weights). SYNAPSE_DOWNLOAD_IDS=z-image-turbo,qwen-image-2.1-q4 swift test --filter DownloadTool
final class DownloadTool: XCTestCase {
    func testDownload() async throws {
        guard let ids = ProcessInfo.processInfo.environment["SYNAPSE_DOWNLOAD_IDS"] else { throw XCTSkip("set SYNAPSE_DOWNLOAD_IDS") }
        let root = ProcessInfo.processInfo.environment["SYNAPSE_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? ModelStore.defaultRoot
        let store = ModelStore(root: root)
        for id in ids.split(separator: ",").map(String.init) {
            let start = Date()
            let url = try await store.download(id) { p in
                if Int(p * 1000) % 50 == 0 { print("[\(id)] \(Int(p * 100))%") }
            }
            print("[\(id)] done in \(Int(Date().timeIntervalSince(start)))s -> \(url.path)")
        }
    }
}
