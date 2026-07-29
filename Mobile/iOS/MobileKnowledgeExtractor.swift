import DropsiftShared
import Foundation
import PDFKit
import UIKit
import Vision

enum MobileKnowledgeExtractor {
    static func extract(
        from url: URL,
        kind: SharedKnowledgeKind
    ) async throws -> [SharedKnowledgeBlock] {
        switch kind {
        case .note:
            return []
        case .document:
            if url.pathExtension.lowercased() == "pdf" {
                return try extractPDF(url)
            }
            let text: String
            if let attributed = try? NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: nil
            ), !attributed.string.isEmpty {
                text = attributed.string
            } else {
                text = try String(contentsOf: url, encoding: .utf8)
            }
            return chunk(text, locator: "Document")
        case .image:
            return try await extractImage(url)
        }
    }

    private static func extractPDF(_ url: URL) throws -> [SharedKnowledgeBlock] {
        guard let document = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var output: [SharedKnowledgeBlock] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            output += chunk(
                text,
                locator: "Page \(index + 1)",
                page: index + 1
            )
        }
        return output
    }

    private static func extractImage(_ url: URL) async throws -> [SharedKnowledgeBlock] {
        guard UIImage(contentsOfFile: url.path) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let blocks = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .enumerated()
                    .compactMap { index, observation -> SharedKnowledgeBlock? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }
                        let text = candidate.string.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        guard !text.isEmpty else { return nil }
                        return SharedKnowledgeBlock(
                            text: text,
                            locator: "Detected text \(index + 1)"
                        )
                    }
                continuation.resume(returning: blocks)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(url: url).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func chunk(
        _ text: String,
        locator: String,
        page: Int? = nil
    ) -> [SharedKnowledgeBlock] {
        var output: [SharedKnowledgeBlock] = []
        var remaining = text[...]
        var part = 1
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex,
                offsetBy: min(3_500, remaining.count)
            )
            let value = String(remaining[..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                output.append(
                    SharedKnowledgeBlock(
                        text: value,
                        page: page,
                        locator: part == 1 ? locator : "\(locator) · Part \(part)"
                    )
                )
            }
            remaining = remaining[end...]
            part += 1
        }
        return output
    }
}
