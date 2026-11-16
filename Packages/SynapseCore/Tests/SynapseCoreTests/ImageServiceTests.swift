import XCTest
@testable import SynapseCore

final class ImageServiceTests: XCTestCase {
    func testRejectsMalformedSizes() {
        for size in ["256xx256", "256xnopex256", "x256x256", "256x256x"] {
            XCTAssertThrowsError(try ImageService.parseSize(size), size)
        }
    }

    func testInvalidRequestsFailBeforeEngineLoad() async throws {
        let store = try TestSupport.store(downloaded: ["z-image-turbo"])
        let service = ImageService(store: store, models: ModelManager(), engineFactory: { _, _ in
            XCTFail("Invalid request reached engine loading")
            return FakeImageEngine()
        })
        let model = try XCTUnwrap(Catalog.spec("z-image-turbo"))
        let invalid = [ImageRequest(prompt: " "), ImageRequest(prompt: "x", width: 0),
                       ImageRequest(prompt: "x", width: 257), ImageRequest(prompt: "x", steps: 0),
                       ImageRequest(prompt: "x", steps: 1001), ImageRequest(prompt: "x", guidance: .nan),
                       ImageRequest(prompt: "x", guidance: -.infinity), ImageRequest(prompt: "x", inputImages: [Data()])]
        for request in invalid {
            do { _ = try await service.generate(model: model, request: request); XCTFail("Expected invalid request") }
            catch { XCTAssertTrue(error is ImageError) }
        }
        do { _ = try await service.generate(model: model, request: ImageRequest(prompt: "x"), count: 0); XCTFail("Expected invalid count") }
        catch { XCTAssertTrue(error is ImageError) }
    }
}
