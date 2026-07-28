import Foundation

struct ChatStore {
    let directory: URL

    private var fileURL: URL {
        directory.appendingPathComponent("threads.json")
    }

    func load() -> [ChatThread] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatThread].self, from: data)) ?? []
    }

    func save(_ threads: [ChatThread]) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(threads).write(to: fileURL, options: .atomic)
    }
}
