import Foundation

struct LocalLLMConnection: Sendable {
    let baseURL: URL
    let serverName: String
    let models: [String]
}

actor LocalLLMClient {
    enum ClientError: LocalizedError {
        case noServer
        case noChatModel
        case invalidResponse
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .noServer:
                return "No local AI server found. Start LM Studio, llama.cpp, or mlx_lm.server."
            case .noChatModel:
                return "The local server did not report a chat model."
            case .invalidResponse:
                return "The local AI server returned an unreadable response."
            case .server(let status, let message):
                return "Local AI server error \(status): \(message)"
            }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }

    private struct CompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    func discover(preferredEndpoint: String?) async throws -> LocalLLMConnection {
        var candidates: [(String, String)] = []
        if let preferredEndpoint, !preferredEndpoint.isEmpty {
            candidates.append((preferredEndpoint, "Custom local server"))
        }
        candidates += [
            ("http://127.0.0.1:1234/v1", "LM Studio"),
            ("http://127.0.0.1:8080/v1", "llama.cpp / MLX"),
            ("http://127.0.0.1:8000/v1", "Local OpenAI server"),
        ]

        var seen: Set<String> = []
        for (candidate, name) in candidates where seen.insert(candidate).inserted {
            guard let baseURL = normalizedBaseURL(candidate) else { continue }
            do {
                let response: ModelsResponse = try await get(
                    baseURL.appendingPathComponent("models")
                )
                return LocalLLMConnection(
                    baseURL: baseURL,
                    serverName: name,
                    models: response.data.map(\.id)
                )
            } catch {
                continue
            }
        }
        throw ClientError.noServer
    }

    func complete(
        connection: LocalLLMConnection,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let requestMessages = [
            CompletionRequest.Message(role: "system", content: systemPrompt),
        ] + messages.suffix(16).map {
            CompletionRequest.Message(role: $0.role.rawValue, content: $0.content)
        }
        let body = CompletionRequest(
            model: model,
            messages: requestMessages,
            temperature: 0.25,
            maxTokens: 1_200,
            stream: false
        )

        var request = URLRequest(
            url: connection.baseURL.appendingPathComponent("chat/completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty
        else { throw ClientError.invalidResponse }
        return content
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClientError.server(http.statusCode, message)
        }
    }

    private func normalizedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed) else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        } else if !components.path.hasSuffix("/v1") {
            components.path += "/v1"
        }
        return components.url
    }
}
