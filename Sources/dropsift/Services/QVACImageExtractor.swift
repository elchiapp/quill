import Foundation

actor QVACImageExtractor {
    static let shared = QVACImageExtractor()

    private let runtime: QVACRuntime
    private var prepared = false

    init(runtime: QVACRuntime = .shared) {
        self.runtime = runtime
    }

    func extract(from image: URL) async throws -> [KnowledgeBlock] {
        if !prepared {
            _ = try await runtime.request("prepareOCR")
            prepared = true
        }
        let response = try await runtime.request(
            "extractImageText",
            params: QVACBridgeParams(imagePath: image.path)
        )
        return (response.blocks ?? []).enumerated().compactMap {
            index, block in
            let text = block.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else { return nil }
            return KnowledgeBlock(
                text: text,
                locator: "QVAC detected text \(index + 1)"
            )
        }
    }

    func unload() async {
        if prepared {
            _ = try? await runtime.request("unloadOCR")
        }
        prepared = false
    }
}
