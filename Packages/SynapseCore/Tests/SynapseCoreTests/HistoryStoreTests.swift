import XCTest
@testable import SynapseCore

final class HistoryStoreTests: XCTestCase {
    private func store() throws -> (HistoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (HistoryStore(root: root), root)
    }

    func testSaveListAndDeleteRemoveTheFolder() async throws {
        let (h, root) = try store()
        let item = HistoryItem(kind: .image, title: "A fox", model: "flux2-klein-4b")
        try await h.save(item, files: ["image-0.png": Data([1, 2, 3])])
        var listed = await h.list(.image)
        XCTAssertEqual(listed.map(\.id), [item.id])
        XCTAssertEqual(listed[0].files, ["image-0.png"])
        let png = await h.data(listed[0], "image-0.png")
        XCTAssertEqual(png, Data([1, 2, 3]))
        // A fresh store reads the same from disk.
        let reread = await HistoryStore(root: root).list(.image)
        XCTAssertEqual(reread.map(\.title), ["A fox"])
        await h.delete([item.id], kind: .image)
        listed = await h.list(.image)
        XCTAssertTrue(listed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "image/\(item.id.uuidString)").path))
    }

    func testSavingAgainReplacesTheItemAndDropsUnlistedFiles() async throws {
        let (h, _) = try store()
        var chat = HistoryItem(kind: .chat, title: "Hello", model: "qwen3.5-0.8b")
        try await h.save(chat, files: ["a.png": Data([1])])
        chat.title = "Hello again"
        chat.files = []
        try await h.save(chat, files: ["b.png": Data([2])])
        let listed = await h.list(.chat)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].title, "Hello again")
        XCTAssertEqual(listed[0].files, ["b.png"])
        let gone = await h.data(listed[0], "a.png")
        XCTAssertNil(gone)
    }

    func testDeleteAllOfOneKindLeavesTheOthers() async throws {
        let (h, _) = try store()
        try await h.save(HistoryItem(kind: .speech, title: "s", model: "pocket-tts"))
        try await h.save(HistoryItem(kind: .call, title: "c", model: "qwen3.5-0.8b"))
        await h.deleteAll(.speech)
        let speech = await h.list(.speech), calls = await h.list(.call)
        XCTAssertTrue(speech.isEmpty); XCTAssertEqual(calls.count, 1)
        await h.deleteAll()
        let none = await h.list(.call)
        XCTAssertTrue(none.isEmpty)
    }

    func testPruneRemovesOldItemsAndHalfWrittenFolders() async throws {
        let (h, root) = try store()
        try await h.save(HistoryItem(kind: .embed, title: "new", model: "m"))
        let half = root.appending(path: "embed/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try Data([0]).write(to: half.appending(path: "x.bin"))
        await h.prune(olderThan: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: half.path), "no meta.json: a save that never finished")
        var kept = await h.list(.embed)
        XCTAssertEqual(kept.count, 1)
        await h.prune(olderThan: Date().addingTimeInterval(60))
        kept = await h.list(.embed)
        XCTAssertTrue(kept.isEmpty)
    }

    func testFileNamesCannotLeaveTheItemFolder() async throws {
        let (h, root) = try store()
        let item = HistoryItem(kind: .image, title: "t", model: "m")
        try await h.save(item, files: ["../../escape.png": Data([9]), "meta.json": Data([7])])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "escape.png").path))
        let listed = await h.list(.image)
        XCTAssertEqual(listed.first?.title, "t", "meta.json was not overwritten by a file")
    }

    /// History is for work done in the app: no route or service may save API requests into it.
    func testOnlyTheAppSavesHistory() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/SynapseCore")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "HistoryStore.swift" }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains("HistoryStore") || text.contains("HistoryItem"), "\(f.lastPathComponent) references history")
        }
    }
}
