import XCTest
@testable import SynapseCore

final class ResolverTests: XCTestCase {
    private let all = Set(Catalog.all.map(\.id))

    func testWhisper1MapsToDefault() throws {
        XCTAssertEqual(try ModelResolver.resolve(requested: "whisper-1", task: .transcribe, language: nil, defaultID: "whisper-small", downloaded: all).id, "whisper-small")
        XCTAssertEqual(try ModelResolver.resolve(requested: nil, task: .transcribe, language: nil, defaultID: "whisper-base", downloaded: all).id, "whisper-base")
    }

    func testTranslateFallsBack() throws {
        let s = try ModelResolver.resolve(requested: "parakeet-v3", task: .translate, language: nil, defaultID: "whisper-small", downloaded: all)
        XCTAssertEqual(s.id, "whisper-large-v3-turbo")
    }

    func testJapaneseFallsBack() throws {
        let s = try ModelResolver.resolve(requested: "parakeet-v3", task: .transcribe, language: "ja", defaultID: "whisper-small", downloaded: ["parakeet-v3", "whisper-small", "whisper-tiny"])
        XCTAssertEqual(s.id, "whisper-small")
    }

    func testErrors() {
        XCTAssertThrowsError(try ModelResolver.resolve(requested: "whisper-medium", task: .transcribe, language: nil, defaultID: "whisper-small", downloaded: ["whisper-small"])) {
            XCTAssertEqual($0 as? ResolveError, .notDownloaded("whisper-medium"))
        }
        XCTAssertThrowsError(try ModelResolver.resolve(requested: "nope", task: .transcribe, language: nil, defaultID: "whisper-small", downloaded: all)) {
            XCTAssertEqual($0 as? ResolveError, .unknownModel("nope"))
        }
        XCTAssertThrowsError(try ModelResolver.resolve(requested: "parakeet-v3", task: .translate, language: nil, defaultID: "whisper-small", downloaded: ["parakeet-v3"])) {
            XCTAssertEqual($0 as? ResolveError, .noCapableModel)
        }
    }

    func testSmallestDetector() {
        XCTAssertEqual(ModelResolver.smallestDetector(downloaded: ["whisper-large-v3", "whisper-small", "distil-large-v3"])?.id, "whisper-small")
        XCTAssertNil(ModelResolver.smallestDetector(downloaded: ["parakeet-v3"]))
    }
}
