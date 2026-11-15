import XCTest
@testable import SynapseCore

final class SidecarTests: XCTestCase {
    func testNames() {
        let m = URL(fileURLWithPath: "/media/Movie.mkv")
        XCTAssertEqual(Sidecar.url(for: m, language: "en").path, "/media/Movie.en.srt")
        XCTAssertEqual(Sidecar.url(for: m, language: nil).path, "/media/Movie.srt")
    }

    func testExisting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = dir.appendingPathComponent("Movie.mkv")
        XCTAssertNil(Sidecar.existing(for: m, language: nil))
        try "x".write(to: dir.appendingPathComponent("Movie.fr.srt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Sidecar.existing(for: m, language: nil)?.lastPathComponent, "Movie.fr.srt")
        XCTAssertNotNil(Sidecar.existing(for: m, language: "fr"))
        XCTAssertNil(Sidecar.existing(for: m, language: "en"))
    }
}
