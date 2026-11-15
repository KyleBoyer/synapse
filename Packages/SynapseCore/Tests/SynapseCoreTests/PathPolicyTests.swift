import XCTest
@testable import SynapseCore

final class PathPolicyTests: XCTestCase {
    func testPolicy() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = base.appendingPathComponent("media"), media2 = base.appendingPathComponent("media2"), outside = base.appendingPathComponent("outside")
        for d in [media, media2, outside] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: base) }
        try "s".write(to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
        try "m".write(to: media.appendingPathComponent("a.mkv"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: media.appendingPathComponent("link"), withDestinationURL: outside)
        let roots = [media.path]

        XCTAssertTrue(PathPolicy.isAllowed(media.appendingPathComponent("a.mkv").path, roots: roots))
        XCTAssertTrue(PathPolicy.isAllowed(media.path, roots: roots))
        XCTAssertFalse(PathPolicy.isAllowed(media.path + "/../outside/secret", roots: roots))
        XCTAssertFalse(PathPolicy.isAllowed(media.appendingPathComponent("link/secret").path, roots: roots))
        XCTAssertFalse(PathPolicy.isAllowed(media2.path, roots: roots))
        XCTAssertFalse(PathPolicy.isAllowed(media.path, roots: []))
    }
}
