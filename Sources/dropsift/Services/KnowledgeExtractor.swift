import AppKit
import Foundation
import PDFKit
import Vision

enum KnowledgeExtractor {
    enum ExtractionError: LocalizedError {
        case unreadableDocument
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .unreadableDocument: "DropSift could not read this document."
            case .unreadableImage: "DropSift could not read this image."
            }
        }
    }

    static func extract(from url: URL, kind: KnowledgeItemKind) throws -> [KnowledgeBlock] {
        switch kind {
        case .note:
            return []
        case .image:
            return try extractImageText(from: url)
        case .document:
            if url.pathExtension.lowercased() == "pdf" {
                return try extractPDF(from: url)
            }
            return try extractDocument(from: url)
        }
    }

    private static func extractPDF(from url: URL) throws -> [KnowledgeBlock] {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument
        }
        var blocks: [KnowledgeBlock] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            blocks += chunk(
                text,
                page: index + 1,
                locator: "Page \(index + 1)"
            )
        }
        return blocks
    }

    private static func extractDocument(from url: URL) throws -> [KnowledgeBlock] {
        let text: String
        if let attributed = try? NSAttributedString(
            url: url,
            options: [:],
            documentAttributes: nil
        ), !attributed.string.isEmpty {
            text = attributed.string
        } else if let plain = try? String(contentsOf: url, encoding: .utf8) {
            text = plain
        } else {
            throw ExtractionError.unreadableDocument
        }
        return chunk(text, page: nil, locator: "Document")
    }

    private static func extractImageText(from url: URL) throws -> [KnowledgeBlock] {
        guard NSImage(contentsOf: url) != nil else {
            throw ExtractionError.unreadableImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])
        return (request.results ?? []).enumerated().compactMap { index, observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return KnowledgeBlock(
                text: text,
                locator: "Detected text \(index + 1)"
            )
        }
    }

    private static func chunk(
        _ text: String,
        page: Int?,
        locator: String
    ) -> [KnowledgeBlock] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var output: [KnowledgeBlock] = []
        var buffer = ""
        var part = 1

        func appendBuffer() {
            guard !buffer.isEmpty else { return }
            let suffix = part == 1 && paragraphs.count < 2 ? "" : " · Part \(part)"
            output.append(
                KnowledgeBlock(
                    text: buffer,
                    page: page,
                    locator: locator + suffix
                )
            )
            buffer = ""
            part += 1
        }

        for paragraph in paragraphs {
            if buffer.count + paragraph.count + 2 > 3_500 {
                appendBuffer()
            }
            if paragraph.count > 3_500 {
                var start = paragraph.startIndex
                while start < paragraph.endIndex {
                    let end = paragraph.index(
                        start,
                        offsetBy: min(3_500, paragraph.distance(from: start, to: paragraph.endIndex))
                    )
                    buffer = String(paragraph[start..<end])
                    appendBuffer()
                    start = end
                }
            } else {
                buffer += buffer.isEmpty ? paragraph : "\n\n" + paragraph
            }
        }
        appendBuffer()
        return output
    }
}
