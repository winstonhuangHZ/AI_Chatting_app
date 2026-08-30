import Foundation

// MARK: - Built-in tools (function calling)
//
// The model can ask to invoke these tools mid-conversation. Each tool
// receives parsed JSON arguments and returns a plain-text result that is
// appended to the conversation as a `role: tool` message (OpenAI wire
// format). All tools run off the main thread inside the service's
// `streamChatWithTools` loop.

/// One built-in tool the model can call.
struct BuiltinTool {
    let name: String
    let description: String

    /// JSON-schema `parameters` object (OpenAI `tools[].function.parameters`).
    let parameters: [String: Any]

    /// Executes the tool and returns a plain-text result.
    let execute: (_ arguments: [String: Any]) async throws -> String
}

/// Registry + execution for the built-in tools offered to the model.
enum ChatTools {

    /// The full tool set sent on every tool-enabled request.
    ///
    /// Note: a `get_time` tool is deliberately NOT included — the app already
    /// injects the current time as a `[yyyy-MM-dd HH:mm:ss]` prefix on the
    /// newest user message when `includeTimestamp` is on, and the system
    /// prompt tells the model to treat it as ground truth.
    static let all: [BuiltinTool] = [calc, webSearch]

    /// Executes a tool by name. Unknown tools / failures return a plain-text
    /// error string the model can read and adjust to.
    static func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = all.first(where: { $0.name == name }) else {
            return "Error: unknown tool \"\(name)\"."
        }
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        }
        return try await tool.execute(arguments)
    }

    // MARK: - calc

    private static let calc = BuiltinTool(
        name: "calc",
        description: "Evaluate a mathematical expression using + - * / % and parentheses. Returns the numeric result.",
        parameters: [
            "type": "object",
            "properties": [
                "expression": [
                    "type": "string",
                    "description": "The math expression to evaluate, e.g. (12 + 3) * 4 / 5",
                ],
            ],
            "required": ["expression"],
        ]
    ) { arguments in
        guard let expression = arguments["expression"] as? String,
              !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"expression\" argument."
        }
        let allowed = CharacterSet(charactersIn: "0123456789+-*/%(). ")
        guard expression.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Error: expression contains unsupported characters."
        }
        let math = NSExpression(format: expression)
        guard let result = math.expressionValue(with: nil, context: nil) as? NSNumber else {
            return "Error: could not evaluate the expression."
        }
        return String(format: "%g", result.doubleValue)
    }

    // MARK: - web_search

    private static let webSearch = BuiltinTool(
        name: "web_search",
        description: "Search the web for up-to-date information. Returns matching results with titles, snippets, and links. Use it for current events, recent news, or facts you are unsure about.",
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "The search query"],
            ],
            "required": ["query"],
        ]
    ) { arguments in
        guard let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"query\" argument."
        }
        return try await WebSearch.search(query)
    }
}


// MARK: - Web search backend (zero-key DuckDuckGo)

/// Minimal web search without any API key.
///
/// 1. DuckDuckGo Instant Answer API (structured JSON, often sparse).
/// 2. Falls back to DuckDuckGo HTML results (titles + snippets + links).
enum WebSearch {

    static func search(_ query: String, maxResults: Int = 5) async throws -> String {
        if let result = try? await instantAnswer(query), !result.isEmpty {
            return result
        }
        return try await htmlSearch(query, maxResults: maxResults)
    }

    // MARK: Instant Answer API

    private static func instantAnswer(_ query: String) async throws -> String {
        guard var components = URLComponents(string: "https://api.duckduckgo.com/") else { return "" }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        var lines: [String] = []
        if let answer = object["Answer"] as? String, !answer.isEmpty {
            lines.append("Answer: \(answer)")
        }
        if let abstract = object["AbstractText"] as? String, !abstract.isEmpty {
            lines.append(abstract)
            if let url = object["AbstractURL"] as? String {
                lines.append(url)
            }
        }
        if let topics = object["RelatedTopics"] as? [[String: Any]] {
            for topic in topics.prefix(3) {
                if let text = topic["Text"] as? String, !text.isEmpty {
                    lines.append(text)
                    if let url = topic["FirstURL"] as? String {
                        lines.append(url)
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: HTML results

    private struct ResultItem {
        let title: String
        let snippet: String
        let url: String
    }

    private static func htmlSearch(_ query: String, maxResults: Int) async throws -> String {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return "Search failed: invalid URL."
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return "Search failed: no results."
        }

        let results = parseResults(from: html, maxResults: maxResults)
        guard !results.isEmpty else {
            return "No web results found for \"\(query)\"."
        }

        var output = "Web search results for \"\(query)\":\n"
        for (index, result) in results.enumerated() {
            output += "\(index + 1). \(result.title)\n   \(result.snippet)\n   \(result.url)\n"
        }
        return output
    }

    private static func parseResults(from html: String, maxResults: Int) -> [ResultItem] {
        let blocks = html.components(separatedBy: #"<div class="result "#).dropFirst()
        var results: [ResultItem] = []
        for block in blocks.prefix(maxResults) {
            let title = extract(block, from: #"class="result__a"[^>]*>"#, to: "</a>")
                .map(decodeHTML) ?? ""
            let snippet = extract(block, from: #"class="result__snippet"[^>]*>"#, to: "</a>")
                .map(decodeHTML) ?? ""
            let url = extract(block, from: #"class="result__a" href="[^"]+"#, to: "\"")
                .map { raw -> String in
                    // DDG wraps real URLs in `//duckduckgo.com/l/?uddg=<encoded>`.
                    let value = raw.contains("uddg=")
                        ? (raw.components(separatedBy: "uddg=").last ?? raw)
                        : raw
                    return value.removingPercentEncoding ?? value
                } ?? ""
            guard !title.isEmpty || !snippet.isEmpty else { continue }
            results.append(ResultItem(title: title, snippet: snippet, url: url))
        }
        return results
    }

    private static func extract(_ text: String, from prefixPattern: String, to terminator: String) -> String? {
        guard let range = text.range(of: prefixPattern, options: .regularExpression) else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.range(of: terminator) else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func decodeHTML(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
        // Strip any remaining tags.
        if let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }
}
