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

    /// Extracts structured source references (title + URL) from a tool result,
    /// so the service can render a "Sources" card under the final answer.
    let extractSources: (_ result: String) -> [ChatSource]

    init(
        name: String,
        description: String,
        parameters: [String: Any],
        extractSources: @escaping (_ result: String) -> [ChatSource] = { _ in [] },
        execute: @escaping (_ arguments: [String: Any]) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.extractSources = extractSources
        self.execute = execute
    }
}

/// Registry + execution for the built-in tools offered to the model.
enum ChatTools {

    /// The full tool set sent on every agent-mode (tool-enabled) request.
    static let all: [BuiltinTool] = [getTime, calc, webSearch, webFetch, weather]

    // MARK: - get_time

    /// Returns the current date & time (server-local).
    ///
    /// The app no longer stamps requests with a timestamp (that broke DeepSeek's
    /// byte-identical prefix cache: ~5% hits). A `get_time` call happens inside
    /// the request — its `tool` result message is NOT persisted to history — so
    /// the next request's `messages` prefix stays byte-identical and the cache
    /// keeps hitting (~67%+). Available in ALL modes when `includeTimestamp` is on.
    static let getTime = BuiltinTool(
        name: "get_time",
        description: "Returns the current date and time in \"yyyy-MM-dd HH:mm:ss\" (server-local). Call it whenever the user asks what time or date it is, or needs a precise \"now\". Never guess the time.",
        parameters: [:]
    ) { _ in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

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

    /// Returns the source references (title + URL) a tool attached to its result,
    /// for the "Sources" card under the final assistant message.
    static func sources(for name: String, result: String) -> [ChatSource] {
        guard let tool = all.first(where: { $0.name == name }) else { return [] }
        return tool.extractSources(result)
    }

    // MARK: - web_fetch

    private static let webFetch = BuiltinTool(
        name: "web_fetch",
        description: "Fetch and read the full text content of a web page by URL. Use it to read the full article behind a search result or to check a specific page. Returns the page title and extracted plain text (max 8000 chars).",
        parameters: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The full http(s) URL to fetch and read"],
            ],
            "required": ["url"],
        ],
        extractSources: { result in WebPageReader.parseSource(from: result) }
    ) { arguments in
        guard let url = arguments["url"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"url\" argument."
        }
        return try await WebPageReader.read(url)
    }

    // MARK: - weather

    private static let weather = BuiltinTool(
        name: "weather",
        description: "Get the current weather and a 3-day forecast for a location (city name like \"Beijing\" or coordinates like \"39.9,116.4\"). Returns temperature, feels-like, humidity, wind, precipitation probability, and condition. ONLY use when the user explicitly asks about the weather or temperature — never fetch it proactively.",
        parameters: [
            "type": "object",
            "properties": [
                "location": [
                    "type": "string",
                    "description": "City name (e.g. \"Beijing\", \"Tokyo\") or \"latitude,longitude\" (e.g. \"39.9,116.4\")",
                ],
            ],
            "required": ["location"],
        ]
    ) { arguments in
        guard let location = arguments["location"] as? String,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"location\" argument."
        }
        return try await Weather.now(location: location)
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
        ],
        extractSources: { result in WebSearch.parseSources(from: result) }
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

    /// Parses the `1. Title / snippet / url` blocks produced by `htmlSearch`
    /// back into structured source references (deduplicated by URL).
    static func parseSources(from result: String) -> [ChatSource] {
        var sources: [ChatSource] = []
        var seen = Set<String>()
        var currentTitle = ""
        for line in result.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numberRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                currentTitle = String(trimmed[numberRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let urlRange = trimmed.range(of: #"https?://[^\s]+"#, options: .regularExpression) else {
                continue
            }
            var url = String(trimmed[urlRange])
            // Strip trailing noise punctuation only (keep legal URL parens).
            let noise = CharacterSet(charactersIn: ".,;:!?\"'`’‘“”»«…")
            while let last = url.unicodeScalars.last, noise.contains(last) {
                url.removeLast()
            }
            // Balance parens: drop surplus closing parens (e.g. "url).").
            let open = url.filter { $0 == "(" }.count
            var close = url.filter { $0 == ")" }.count
            while close > open {
                url.removeLast()
                close -= 1
            }
            guard let parsed = URL(string: url),
                  parsed.scheme == "http" || parsed.scheme == "https",
                  !seen.contains(url) else { continue }
            seen.insert(url)
            sources.append(ChatSource(title: currentTitle, url: url))
            currentTitle = ""
        }
        return sources
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

// MARK: - Web page reader (zero-key fetch + text extraction)

/// Fetches a web page and returns its plain-text content.
enum WebPageReader {
    static let maxContentChars = 8000

    static func read(_ rawURL: String) async throws -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return "Error: invalid URL \"\(trimmed)\". Only http(s) URLs are supported."
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return "Fetch failed: invalid HTTP response."
        }
        guard (200..<300).contains(http.statusCode) else {
            return "Fetch failed: HTTP \(http.statusCode)."
        }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return "Fetch failed: could not decode the page."
        }

        let text = extractText(from: html)
        guard !text.isEmpty else {
            return "Fetch succeeded but the page contains no readable text."
        }
        let truncated = text.count > maxContentChars
            ? String(text.prefix(maxContentChars)) + "\n…[truncated]"
            : text
        return "Page: \(url.absoluteString)\n\n\(truncated)"
    }

    /// Parses the leading `Page: <url>` line of a `read()` result into a source
    /// item (title = host, since the page's own title is not extracted).
    static func parseSource(from result: String) -> [ChatSource] {
        let lines = result.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("Page: ") else { return [] }
        let url = String(first.dropFirst("Page: ".count))
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https" else { return [] }
        return [ChatSource(title: parsed.host ?? url, url: url)]
    }

    /// Strips script/style, removes tags, decodes entities, collapses whitespace.
    private static func extractText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?is)<script[^>]*>.*?</script>|(?is)<style[^>]*>.*?</style>|(?is)<!--.*?-->",
            with: " ",
            options: .regularExpression
        )
        // Turn block-level tags into newlines for readability.
        text = text.replacingOccurrences(
            of: "(?i)<(p|div|h[1-6]|li|br|tr|section|article|blockquote)[^>]*>",
            with: "\n",
            options: .regularExpression
        )
        // Strip any remaining tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let pairs = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " "),
            ("&#8217;", "'"), ("&#8216;", "'"), ("&#8220;", "\""), ("&#8221;", "\""),
            ("&#8211;", "–"), ("&#8212;", "—"), ("&#8230;", "…"),
        ]
        for (from, to) in pairs { result = result.replacingOccurrences(of: from, with: to) }
        return result
    }
}


// MARK: - Weather backend (zero-key Open-Meteo)

/// Current weather + 3-day forecast via Open-Meteo (no API key).
enum Weather {
    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    static func now(location: String) async throws -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Error: missing \"location\" argument." }

        // Resolve coordinates: "lat,lon" directly, otherwise geocode the name.
        let lat: Double
        let lon: Double
        let displayName: String
        if let comma = trimmed.firstIndex(of: ","),
           let l1 = Double(trimmed[..<comma].trimmingCharacters(in: .whitespaces)),
           let l2 = Double(trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)),
           (-90...90).contains(l1), (-180...180).contains(l2) {
            lat = l1
            lon = l2
            displayName = "\(l1),\(l2)"
        } else if let place = try await geocode(trimmed) {
            lat = place.latitude
            lon = place.longitude
            displayName = place.name
        } else {
            return "Error: could not find location \"\(trimmed)\". Try a city name like \"Beijing\" or coordinates like \"39.9,116.4\"."
        }

        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            return "Error: weather service unavailable."
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: weather service unavailable."
        }
        guard let current = object["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int else {
            return "Error: weather service returned no data."
        }

        let feelsLike = current["apparent_temperature"] as? Double
        let humidity = current["relative_humidity_2m"] as? Double
        let wind = current["wind_speed_10m"] as? Double
        let condition = Self.condition(for: code)

        var lines: [String] = ["Current weather in \(displayName):"]
        lines.append("  \(condition), \(Self.fmt(temp))°C" + (feelsLike.map { ", 体感 \(Self.fmt($0))°C" } ?? ""))
        lines.append("  湿度 \(humidity.map { "\(Int($0))%" } ?? "—"), 风速 \(wind.map { "\(Self.fmt($0)) km/h" } ?? "—")")

        if let daily = object["daily"] as? [String: Any],
           let dates = daily["time"] as? [String],
           let maxes = daily["temperature_2m_max"] as? [Double],
           let mins = daily["temperature_2m_min"] as? [Double] {
            let probs = daily["precipitation_probability_max"] as? [Double] ?? []
            lines.append("3-day forecast:")
            for (i, date) in dates.enumerated() where i < maxes.count && i < mins.count {
                let day = date.suffix(5)
                let rain = i < probs.count ? "\(Int(probs[i]))%" : "—"
                lines.append("  \(day): \(Self.fmt(mins[i]))°C ~ \(Self.fmt(maxes[i]))°C, 降水概率 \(rain)")
            }
        }
        return lines.joined(separator: "\n")
    }


    private static func geocode(_ name: String) async throws -> Place? {
        guard var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "zh"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double else {
            return nil
        }
        let city = first["name"] as? String ?? name
        let country = first["country"] as? String ?? ""
        return Place(name: country.isEmpty ? city : "\(city), \(country)", latitude: latitude, longitude: longitude)
    }

    private static func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func condition(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1: return "基本晴朗"
        case 2: return "局部多云"
        case 3: return "阴天"
        case 45, 48: return "有雾"
        case 51, 53, 55: return "毛毛雨"
        case 56, 57: return "冻毛毛雨"
        case 61, 63, 65: return "下雨"
        case 66, 67: return "冻雨"
        case 71, 73, 75: return "下雪"
        case 77: return "雪粒"
        case 80, 81, 82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95: return "雷暴"
        case 96, 99: return "雷暴伴冰雹"
        default: return "天气码 \(code)"
        }
    }
}

