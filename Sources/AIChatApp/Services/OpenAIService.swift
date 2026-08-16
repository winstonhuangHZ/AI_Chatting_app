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

/// A lightweight client for OpenAI-compatible relay servers using the
/// callback-based `URLSessionDataDelegate` API (compatible with older SDKs
/// that predate async/await).
///
/// Responsibilities:
/// - Normalizing user-supplied base URLs (trailing slashes, missing `/v1` path)
/// - Fetching the model list via `GET /v1/models`
/// - Streaming chat completions via `POST /v1/chat/completions` (SSE)
final class OpenAIService: NSObject, URLSessionDataDelegate {

    // MARK: - Nested response types

    /// JSON body returned by `GET /v1/models`.
    ///
    /// Some relays (OpenRouter / one-api / new-api) extend each model entry
    /// with a `pricing` object:
    ///   {"id":"gpt-4o-mini","pricing":{"prompt":0.15,"completion":0.6}}
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
    private var session: URLSession!

    /// Active streaming task bookkeeping.
    private struct StreamContext {
        var buffer = Data()
        var onDelta: (String) -> Void
        var onComplete: () -> Void
        var onError: (Error) -> Void
        var yieldedContent = false
        var accumulatedErrorBody = Data()
    }

    /// Maps a stream task to its callbacks.
    private var streamContexts: [Int: StreamContext] = [:]

    // MARK: - Initializers

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        self.session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    // MARK: - URL normalization

    /// Normalizes a user-supplied base URL string.
    ///
    /// Rules:
    /// 1. Trim whitespace and trailing slashes.
    /// 2. If no scheme is present, default to `https://`.
    /// 3. If the path does not already end in `/v1`, append it.
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
            // Rebuild: scheme://host[:port] + "/v1" + (any original path suffix)
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

    /// Fetches the list of available model IDs for the given profile.
    ///
    /// - Parameters:
    ///   - config: The relay profile to query.
    ///   - completion: Called on the main queue with the sorted model list,
    ///     or an error.
    func fetchModels(
        config: APIServerConfig,
        completion: @escaping (Result<([String], [String: ModelPrice]), Error>) -> Void
    ) {
        do {
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

            session.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        completion(.failure(OpenAIServiceError.transport(error.localizedDescription)))
                        return
                    }

                    guard let http = response as? HTTPURLResponse else {
                        completion(.failure(OpenAIServiceError.transport("Invalid HTTP response.")))
                        return
                    }

                    guard let data = data else {
                        completion(.failure(OpenAIServiceError.transport("No data received.")))
                        return
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        let message = Self.decodeErrorMessage(from: data)
                        completion(.failure(OpenAIServiceError.httpError(
                            statusCode: http.statusCode,
                            message: message
                        )))
                        return
                    }

                    do {
                        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
                        let models = Array(Set(decoded.data.map { $0.id })).sorted()
                        // Extract relay-provided dynamic prices (OpenRouter-style).
                        var prices: [String: ModelPrice] = [:]
                        for item in decoded.data {
                            guard let pricing = item.pricing,
                                  let prompt = pricing.prompt,
                                  let completion = pricing.completion,
                                  prompt >= 0, completion >= 0 else { continue }
                            prices[item.id] = ModelPrice(prompt: prompt, completion: completion)
                        }
                        completion(.success((models, prices)))
                    } catch {
                        completion(.failure(OpenAIServiceError.decodingFailed(
                            "Expected {\"data\":[{\"id\":\"model\"}]}. \(error.localizedDescription)"
                        )))
                    }
                }
            }.resume()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Streaming chat completion

    /// Starts a streaming chat completion for the given profile and message history.
    ///
    /// The server's SSE `data:` lines are parsed incrementally; text deltas are
    /// delivered through `onDelta`. When the stream finishes (via `[DONE]` or
    /// connection close), `onComplete` is called. On failure, `onError` is called.
    ///
    /// - Returns: The underlying data task so the caller can cancel streaming.
    @discardableResult
    func streamChat(
        config: APIServerConfig,
        model: String,
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> URLSessionDataTask? {
        let baseURL: URL
        do {
            baseURL = try normalizedBaseURL(from: config.baseURL)
            guard !config.apiKey.isEmpty else {
                throw OpenAIServiceError.missingAPIKey
            }
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAIServiceError.transport("No model selected.")
            }
        } catch {
            DispatchQueue.main.async {
                onError(error)
            }
            return nil
        }

        let url = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Build the wire-format message payload.
        //
        // Multimodal messages carry images as an OpenAI `content` array:
        //   content = [
        //     {"type":"text","text":"..."},
        //     {"type":"image_url","image_url":{"url":"data:image/png;base64,..."}}
        //   ]
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
            DispatchQueue.main.async {
                onError(OpenAIServiceError.transport("Failed to encode request body: \(error.localizedDescription)"))
            }
            return nil
        }

        let task = session.dataTask(with: request)
        streamContexts[task.taskIdentifier] = StreamContext(
            onDelta: onDelta,
            onComplete: onComplete,
            onError: onError
        )
        task.resume()
        return task
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              var context = streamContexts[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }

        if (200..<300).contains(http.statusCode) {
            completionHandler(.allow)
        } else {
            // Non-2xx: buffer up to 8KB of the error body, then fail.
            context.accumulatedErrorBody = Data()
            streamContexts[dataTask.taskIdentifier] = context
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard var context = streamContexts[dataTask.taskIdentifier],
              let http = dataTask.response as? HTTPURLResponse else {
            return
        }

        // Handle non-2xx error bodies.
        if !(200..<300).contains(http.statusCode) {
            context.accumulatedErrorBody.append(data)
            if context.accumulatedErrorBody.count > 8192 {
                // Stop buffering; the task will fail on completion.
            }
            streamContexts[dataTask.taskIdentifier] = context
            return
        }

        context.buffer.append(data)
        streamContexts[dataTask.taskIdentifier] = context

        // Parse complete SSE lines from the buffer and forward deltas.
        let deltas = Self.parseSSEBuffer(from: &context.buffer)
        if !deltas.isEmpty {
            context.yieldedContent = true
            streamContexts[dataTask.taskIdentifier] = context
            DispatchQueue.main.async {
                for delta in deltas {
                    context.onDelta(delta)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard var context = streamContexts.removeValue(forKey: task.taskIdentifier),
              let http = task.response as? HTTPURLResponse else {
            return
        }

        if let error = error {
            DispatchQueue.main.async {
                context.onError(OpenAIServiceError.transport(error.localizedDescription))
            }
            return
        }

        if !(200..<300).contains(http.statusCode) {
            let message = Self.decodeErrorMessage(from: context.accumulatedErrorBody)
            DispatchQueue.main.async {
                context.onError(OpenAIServiceError.httpError(
                    statusCode: http.statusCode,
                    message: message
                ))
            }
            return
        }

        // Flush any remaining buffered SSE lines (some relays omit [DONE]).
        let deltas = Self.parseSSEBuffer(from: &context.buffer)
        if !deltas.isEmpty {
            context.yieldedContent = true
            DispatchQueue.main.async {
                for delta in deltas {
                    context.onDelta(delta)
                }
            }
        }

        if !context.yieldedContent {
            DispatchQueue.main.async {
                context.onError(OpenAIServiceError.emptyStream)
            }
        } else {
            DispatchQueue.main.async {
                context.onComplete()
            }
        }
    }

    // MARK: - SSE parsing

    /// Parses complete `\n`-delimited lines from the streaming buffer.
    ///
    /// `data:` payload lines are decoded and non-empty content deltas are
    /// returned. Returns `true` when a `[DONE]` marker is encountered so the
    /// caller can finish early.
    @discardableResult
    private static func parseSSEBuffer(
        from buffer: inout Data
    ) -> [String] {
        var deltas: [String] = []

        // Split buffer into complete lines (terminated by \n).
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip blank lines and SSE comment lines.
            guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }
            // Only process `data:` prefixed lines.
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = String(trimmed.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Graceful termination marker.
            if payload == "[DONE]" || payload.uppercased().contains("[DONE]") {
                break
            }

            guard let chunkData = payload.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(StreamChunk.self, from: chunkData)
                if let delta = chunk.contentDelta, !delta.isEmpty {
                    deltas.append(delta)
                }
            } catch {
                // Skip malformed chunks; some relays send keep-alive JSON.
                continue
            }
        }

        return deltas
    }

    // MARK: - Helpers

    /// Extracts a human-readable message from a non-2xx JSON error body.
    private static func decodeErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        // Try the standard OpenAI error shape first.
        if let decoded = try? JSONDecoder().decode(APIErrorBody.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        // Fall back to raw text (relay-specific error formats).
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "Unknown server error."
    }
}