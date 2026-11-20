import Foundation
import XCTest
@testable import SynapseCore

final class HFModelInspectorTests: XCTestCase {
    func testRepoIDFromInputs() {
        XCTAssertEqual(HFModelInspector.repoID(from: "mlx-community/Qwen3-4B-4bit"), "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(HFModelInspector.repoID(from: " https://huggingface.co/LiquidAI/LFM3-Omni-2B "), "LiquidAI/LFM3-Omni-2B")
        XCTAssertEqual(HFModelInspector.repoID(from: "https://huggingface.co/org/name/tree/main/text_encoder"), "org/name")
        XCTAssertEqual(HFModelInspector.repoID(from: "hf.co/org/name.v2"), "org/name.v2")
        XCTAssertNil(HFModelInspector.repoID(from: "just-a-name"))
        XCTAssertNil(HFModelInspector.repoID(from: "https://huggingface.co/datasets/org/data"))
        XCTAssertNil(HFModelInspector.repoID(from: "org/na me"))
    }

    private func files(_ f: [(String, Int64)]) -> [String: Any] {
        ["siblings": f.map { ["rfilename": $0.0, "size": $0.1] }]
    }

    private func classify(_ info: [String: Any], _ config: [String: Any]?, inProcess: Set<String> = ["qwen3", "llama"],
                          embedders: Set<String> = ["qwen3"]) async throws -> HFModelInspector.Report {
        try await HFModelInspector.classify(repo: "org/model", info: info, config: config,
                                            chatInProcess: { inProcess.contains($0) }, embedder: { embedders.contains($0) })
    }

    func testChatModelsRunInProcessOrThroughMLXVLM() async throws {
        let mlx = try await classify(files([("model.safetensors", 2_000_000_000), ("config.json", 1000), ("README.md", 5)]),
                                     ["model_type": "llama", "quantization": ["bits": 4]])
        XCTAssertEqual(mlx.model.engine, .mlx)
        XCTAssertEqual(mlx.model.repo, "org/model")
        XCTAssertEqual(mlx.model.displayName, "model")
        XCTAssertEqual(mlx.model.approxMB, 2000, "README is not downloaded, so it does not count")
        XCTAssertEqual(mlx.model.ramGB, 3)
        let other = try await classify(files([("model.safetensors", 10)]), ["model_type": "lfm3_omni"])
        XCTAssertEqual(other.model.engine, .mlxvlm)
        XCTAssertTrue(other.notes.contains { $0.contains("mlx-vlm") })
    }

    func testEmbeddingsNotesAndRefusals() async throws {
        var info = files([("model.safetensors", 600_000_000)]); info["pipeline_tag"] = "feature-extraction"
        let emb = try await classify(info, ["model_type": "qwen3"])
        XCTAssertEqual(emb.model.engine, .embedding)
        info["gated"] = "manual"
        let gated = try await classify(info, ["model_type": "qwen3"])
        XCTAssertTrue(gated.notes.contains { $0.contains("Gated") })
        let big = try await classify(files([("model.safetensors", 16_000_000_000)]), ["model_type": "llama"])
        XCTAssertTrue(big.notes.contains { $0.contains("Not quantized") })

        for (info, config, phrase) in [
            (files([("model_index.json", 1), ("unet/model.safetensors", 1)]), nil, "diffusers"),
            (files([("pytorch_model.bin", 1)]), ["model_type": "llama"], "no safetensors or GGUF"),
            (files([("model.safetensors", 1), ("config.json", 1)]), nil, "model_type"),
            (files([("1068055/3373587/style_epoch_10.safetensors", 1), ("1068055/3373587/README.md", 1)]), nil, "LoRA adapters"),
        ] as [([String: Any], [String: Any]?, String)] {
            do { _ = try await classify(info, config); XCTFail("expected refusal: \(phrase)") } catch {
                XCTAssertTrue(error.localizedDescription.contains(phrase), error.localizedDescription)
            }
        }
        var tts = files([("model.safetensors", 1)]); tts["pipeline_tag"] = "text-to-speech"
        do { _ = try await classify(tts, ["model_type": "x"]); XCTFail("expected refusal") } catch {
            XCTAssertTrue(error.localizedDescription.contains("text-to-speech"))
        }
    }

    func testGGUFReposOfferQuantizationsAndPickAFittingDefault() async throws {
        let gb: Int64 = 1_000_000_000
        let info = files([("Model-Q8_0.gguf", 8 * gb), ("Model-Q4_K_M.gguf", 4 * gb), ("Model-IQ2_XXS.gguf", 2 * gb),
                          ("Q6_K/Model-Q6_K-00001-of-00002.gguf", 3 * gb), ("Q6_K/Model-Q6_K-00002-of-00002.gguf", 3 * gb),
                          ("mmproj-Model-Q8_0.gguf", gb / 2), ("mmproj-Model-f16.gguf", gb), ("README.md", 1)])
        let r = try await classify(info, nil)
        XCTAssertEqual(r.model.engine, .gguf)
        XCTAssertEqual(r.ggufChoices.map(\.label), ["IQ2_XXS", "Q4_K_M", "Q6_K", "Q8_0"])
        XCTAssertEqual(r.ggufChoices.first { $0.label == "Q6_K" }?.files.count, 2, "split parts form one choice")
        XCTAssertEqual(r.model.files, ["Model-Q4_K_M.gguf", "mmproj-Model-f16.gguf"], "Q4_K_M, plus the f16 projector")
        XCTAssertEqual(r.model.approxMB, 5000)
        let q8 = r.choosing(try XCTUnwrap(r.ggufChoices.last))
        XCTAssertEqual(q8.model.files, ["Model-Q8_0.gguf", "mmproj-Model-f16.gguf"])
        XCTAssertEqual(q8.model.approxMB, 9000)
        XCTAssertEqual(q8.model.spec.files, q8.model.files)
        // On a small Mac, Q4_K_M (4 GB) is too big and the largest that fits is picked.
        let small = try HFModelInspector.gguf(repo: "org/m", files: [("a-Q4_K_M.gguf", 4 * gb), ("a-Q2_K.gguf", 2 * gb)],
                                              gated: false, physicalMemory: 6 << 30)
        XCTAssertEqual(small.model.files, ["a-Q2_K.gguf"])
        XCTAssertNil(small.projector)
    }

    func testCustomModelsJoinTheCatalogButNeverShadowBuiltIns() {
        defer { Catalog.setCustom([]) }
        Catalog.setCustom([CustomModel(repo: "org/new", engine: .mlx, displayName: "new", approxMB: 10, ramGB: 1),
                           CustomModel(repo: "qwen3.5-0.8b", engine: .mlxvlm, displayName: "x", approxMB: 1, ramGB: 1)])
        XCTAssertEqual(Catalog.spec("org/new")?.engine, .mlx)
        XCTAssertEqual(Catalog.spec("qwen3.5-0.8b")?.engine, .mlx, "built-in wins")
        XCTAssertEqual(Catalog.custom.map(\.id), ["org/new"])
        XCTAssertTrue(Catalog.spec("org/new")!.isChat)
    }

    func testOldSettingsWithoutCustomModelsDecode() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"port": 9000}"#.utf8))
        XCTAssertEqual(s.customModels, [])
    }
}
