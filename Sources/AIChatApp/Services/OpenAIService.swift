import Foundation

/// Errors thrown by `OpenAIService`.
enum OpenAIServiceError: LocalizedError, Equatable {
    /// The base URL string could not be parsed into a URL.
    case invalidBaseURL(String)

    /// The required API key is missing or empty.
    case missingAPIKey

    /// The HTTP response was not a 2xx status code.
    case httpError(statusCode: Int, message: String)

    /// The response body could not be decoded as JSON.
    case decodingFailed(String)

    /// The stream ended before any content was received.
    case emptyStream

    /// A transport-level error occurred (timeout, no network, etc.).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid base URL: \(url)"
        case .missingAPIKey:
            return "Missing API key. Add one in the profile settings."
        case .httpError(let statusCode, let message):
            let preview = message.count > 300 ? String(message.prefix(300)) + "…" : message
            return "Server returned HTTP \(statusCode). \(preview)"
        case .decodingFailed(let detail):
            return "Failed to decode server response: \(detail)"
        case .emptyStream:
            return "The model returned an empty response."
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}

/// A lightweight, actor-isolated client for OpenAI-compatible relay servers.
///
/// All network work uses `URLSession` with the modern async/await APIs:
/// - Base URL normalization (trailing slashes, missing `/v1`)
/// - `GET /v1/models` (returns model list **and** dynamic prices, if any)
/// - `POST /v1/chat/completions` with **SSE streaming** exposed via
///   `AsyncThrowingStream<String, Error>`.
actor OpenAIService {

    // MARK: - Nested response types

    /// JSON body returned by `GET /v1/models`.
    private struct ModelsResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
            struct Pricing: Decodable {
                let prompt: Double?
                let completion: Double?
            }
            let pricing: Pricing?
        }
        let data: [ModelItem]
    }

    /// A single SSE `data:` chunk from a streaming response.
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
        }
        let choices: [Choice]?

        /// Extracts the delta text for this chunk, if any.
        var contentDelta: String? {
            choices?.first?.delta?.content
        }
    }

    /// JSON error body returned by the relay on non-2xx responses.
    private struct APIErrorBody: Decodable {
        struct ErrorDetail: Decodable {
            let message: String?
        }
        let error: ErrorDetail?
    }

    // MARK: - Private state

    /// Ephemeral session that does not persist cookies across launches.
    private let session: URLSession

    // MARK: - Initializers

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - URL normalization

    /// Normalizes a user-supplied base URL string.
    ///
    /// Rules:
    /// 1. Trim whitespace and trailing slashes.
    /// 2. If no scheme is present, default to `https://`.
    /// 3. If the path does not already end in `/v1`, append it.
    ///
    /// Examples:
    /// - `api.example.com`            → `https://api.example.com/v1`
    /// - `https://api.example.com/`   → `https://api.example.com/v1`
    /// - `https://api.example.com/v1` → unchanged
    func normalizedBaseURL(from raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing slashes.
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw OpenAIServiceError.invalidBaseURL(raw)
        }

        // Default to https when no scheme is provided.
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }

        guard let candidate = URL(string: trimmed),
              let scheme = candidate.scheme,
              let host = candidate.host else {
            throw OpenAIServiceError.invalidBaseURL(raw)
        }

        var url = candidate
        let pathIsV1 = candidate.path == "/v1" || candidate.path.hasPrefix("/v1/")
        if !pathIsV1 {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = candidate.port

            var newPath = candidate.path
            if !newPath.hasSuffix("/") {
                newPath += "/"
            }
            newPath += "v1"
            components.path = newPath
            components.query = candidate.query
            components.fragment = candidate.fragment

            guard let rebuilt = components.url else {
                throw OpenAIServiceError.invalidBaseURL(raw)
            }
            url = rebuilt
        }

        return url
    }

    // MARK: - Fetch models

    /// Fetches the model list (and relay-provided dynamic prices) for a profile.
    ///
    /// - Parameter config: The relay profile to query.
    /// - Returns: Sorted model ids and a dictionary of model-id → price.
    func fetchModels(
        config: APIServerConfig
    ) async throws -> ([String], [String: ModelPrice]) {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }

        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAIServiceError.transport("Request timed out.")
        } catch {
            throw OpenAIServiceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.transport("Invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.decodeErrorMessage(from: data)
            throw OpenAIServiceError.httpError(
                statusCode: http.statusCode,
                message: message
            )
        }

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let models = Array(Set(decoded.data.map { $0.id })).sorted()
            var prices: [String: ModelPrice] = [:]
            for item in decoded.data {
                guard let pricing = item.pricing,
                      let prompt = pricing.prompt,
                      let completion = pricing.completion,
                      prompt >= 0, completion >= 0 else { continue }
                prices[item.id] = ModelPrice(prompt: prompt, completion: completion)
            }
            return (models, prices)
        } catch {
            throw OpenAIServiceError.decodingFailed(
                "Expected {\"data\":[{\"id\":\"model\"}]}. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Streaming chat completion

    /// Streams a chat completion for the given profile and message history.
    ///
    /// - Parameters:
    ///   - config: Relay profile to use.
    ///   - model: Model identifier to chat with.
    ///   - messages: Full message history (text + optional image attachments).
    /// - Returns: An `AsyncThrowingStream` yielding incremental text deltas.
    ///
    /// The stream completes gracefully on `data: [DONE]` (or when the HTTP
    /// body ends — some relays omit the DONE marker) and propagates HTTP /
    /// decoding / cancellation errors to the consumer.
    func streamChat(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage]
    ) throws -> AsyncThrowingStream<String, Error> {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.transport("No model selected.")
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Build the wire-format message payload.
        let payloadMessages: [[String: Any]] = messages.map { message -> [String: Any] in
            var result: [String: Any] = ["role": message.role.rawValue]

            if !message.attachments.isEmpty {
                var contentParts: [[String: Any]] = []
                if !message.content.isEmpty {
                    contentParts.append([
                        "type": "text",
                        "text": message.content
                    ])
                }
                for attachment in message.attachments {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": attachment.dataURI
                        ]
                    ])
                }
                result["content"] = contentParts
            } else {
                result["content"] = message.content
            }

            return result
        }

        let body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "stream": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw OpenAIServiceError.transport(
                "Failed to encode request body: \(error.localizedDescription)"
            )
        }

        return AsyncThrowingStream { continuation in
            // Run network work in a child task so the stream is returned
            // to the caller immediately.
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAIServiceError.transport("Invalid HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count > 8192 { break }
                        }
                        throw OpenAIServiceError.httpError(
                            statusCode: http.statusCode,
                            message: Self.decodeErrorMessage(from: errorData)
                        )
                    }

                    var yieldedAnyContent = false

                    for try await line in bytes.lines {
                        // Honour cancellation while streaming.
                        try Task.checkCancellation()

                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }
                        guard trimmed.hasPrefix("data:") else { continue }

                        let payload = String(trimmed.dropFirst("data:".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        // Graceful termination marker (with tolerance to
                        // relays that append extra whitespace / casing).
                        if payload == "[DONE]" || payload.uppercased().contains("[DONE]") {
                            break
                        }

                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        do {
                            let chunk = try JSONDecoder().decode(StreamChunk.self, from: chunkData)
                            if let delta = chunk.contentDelta, !delta.isEmpty {
                                yieldedAnyContent = true
                                continuation.yield(delta)
                            }
                        } catch {
                            // Skip malformed chunks (keep-alive / metadata).
                            continue
                        }
                    }

                    if !yieldedAnyContent {
                        throw OpenAIServiceError.emptyStream
                    }
                    continuation.finish()

                } catch let error as URLError where error.code == .cancelled {
                    // User cancelled streaming — treat as a clean finish.
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport("Request timed out.")
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as OpenAIServiceError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: OpenAIServiceError.transport(error.localizedDescription)
                    )
                }
            }

            // When the consumer stops iterating, cancel the network work.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Non-streaming chat completion

    /// Sends a chat completion with `stream: false` and returns the full text
    /// once. Used when the user disables streaming in a profile.
    func chatOnce(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage]
    ) async throws -> String {
        let baseURL = try normalizedBaseURL(from: config.baseURL)
        guard !config.apiKey.isEmpty else {
            throw OpenAIServiceError.missingAPIKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAIServiceError.transport("No model selected.")
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payloadMessages: [[String: Any]] = messages.map { message -> [String: Any] in
            var result: [String: Any] = ["role": message.role.rawValue]
            if !message.attachments.isEmpty {
                var contentParts: [[String: Any]] = []
                if !message.content.isEmpty {
                    contentParts.append(["type": "text", "text": message.content])
                }
                for attachment in message.attachments {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": attachment.dataURI]
                    ])
                }
                result["content"] = contentParts
            } else {
                result["content"] = message.content
            }
            return result
        }

        let body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw OpenAIServiceError.transport("Failed to encode body: \(error.localizedDescription)")
        }

        // Decode a full (non-stream) completion response.
        struct CompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message?
            }
            let choices: [Choice]?
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAIServiceError.transport("Request timed out.")
        } catch {
            throw OpenAIServiceError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.transport("Invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIServiceError.httpError(
                statusCode: http.statusCode,
                message: Self.decodeErrorMessage(from: data)
            )
        }

        do {
            let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
            if let content = decoded.choices?.first?.message?.content, !content.isEmpty {
                return content
            }
            throw OpenAIServiceError.emptyStream
        } catch let error as OpenAIServiceError {
            throw error
        } catch {
            throw OpenAIServiceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Extracts a human-readable message from a non-2xx JSON error body.
    private static func decodeErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "Unknown server error."
    }
}