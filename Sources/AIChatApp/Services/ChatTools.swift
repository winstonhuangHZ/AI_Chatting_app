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
    let execute: (_ arguments: [String: Any], _ sessionID: UUID?) async throws -> String

    /// Extracts structured source references (title + URL) from a tool result,
    /// so the service can render a "Sources" card under the final answer.
    let extractSources: (_ result: String) -> [ChatSource]

    init(
        name: String,
        description: String,
        parameters: [String: Any],
        extractSources: @escaping (_ result: String) -> [ChatSource] = { _ in [] },
        execute: @escaping (_ arguments: [String: Any], _ sessionID: UUID?) async throws -> String
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

    /// Search backend configuration for the currently running request.
    /// Written by ChatViewModel before a request starts and read by the
    /// `web_search` tool (which runs inside the service's tool loop).
    struct WebSearchConfiguration: Sendable {
        var provider: SearchProvider = .automatic
        var apiKey: String = ""
        var endpoint: String = ""
        var order: [SearchProvider] = []
    }

    private static let searchConfigLock = NSLock()
    private static var _searchConfiguration = WebSearchConfiguration()

    static func setSearchConfiguration(_ configuration: WebSearchConfiguration) {
        searchConfigLock.lock()
        _searchConfiguration = configuration
        searchConfigLock.unlock()
    }

    static var searchConfiguration: WebSearchConfiguration {
        searchConfigLock.lock()
        defer { searchConfigLock.unlock() }
        return _searchConfiguration
    }

    /// 由 ChatViewModel 注入的处理函数：应用 AI 在第一轮对话为会话挑选的
    /// emoji 和标题。工具在后台线程执行，通过 `MainActor.run` 跳回主线程调用。
    @MainActor static var sessionMetadataSink: ((UUID?, String, String) -> String)?

    /// 由 ChatViewModel 注入的个性化块解析器：按名字返回个性化块内容，未找到返回 nil。
    /// 供 `fetch_personalization_block` 工具在主线程查询 PersonalizationStore。
    @MainActor static var personalizationResolver: ((String) -> String?)?

    /// 返回全部个性化块名字（用于“未找到时的可用列表”提示）。
    @MainActor static var personalizationNames: (() -> [String])?

    /// Current sidebar folder names, so the model can classify into them.
    @MainActor static var folderNames: (() -> [String])?

    /// Assigns (or creates) a folder for the originating session.
    @MainActor static var folderAssigner: ((UUID?, String) -> String)?

    /// Returns the originating session's current folder name, if any.
    @MainActor static var sessionFolderName: ((UUID?) -> String?)?

    /// Folder shared-context readers (only return data when the folder has
    /// explicitly enabled sharing).
    @MainActor static var folderSessionIndexResolver: ((String) -> [[String: Any]])?
    @MainActor static var folderSummariesResolver: ((String, [String]) -> [[String: Any]])?
    @MainActor static var folderSummariesAsyncResolver: ((String, [String]) async -> [[String: Any]])?

    /// The base tool set sent on every agent-mode (tool-enabled) request.
    ///
    /// `set_session_metadata` / `fetch_personalization_block` 常驻注册表（保证
    /// `execute` 能解析到它们），但是否**广告**给模型由
    /// `set(latexEnabled:includeSessionMetadata:includeKnowledge:)` 控制。
    static let all: [BuiltinTool] = [
        getTime, calc, webSearch, webFetch, weather,
        setSessionMetadata, fetchPersonalizationBlock,
        listSessionFolders, assignSessionFolder,
        listFolderSessions, getFolderSummaries,
        askUser,
    ]

    /// The full lookup registry: `all` plus the environment-gated
    /// `compile_latex` when a TeX toolchain exists. Used by `execute` /
    /// `sources` so a tool the model was ALLOWED to call (i.e. it was
    /// registered in the request) is also resolvable locally — otherwise the
    /// executor would reply "unknown tool" to a perfectly valid call.
    static var allWithOptional: [BuiltinTool] {
        var tools = all
        if LaTeXService.isAvailable {
            tools.append(compileLaTeX)
        }
        return tools
    }

    /// The tool set for one request.
    ///
    /// `compile_latex` is opt-in **and** environment-gated: the profile toggle
    /// must be on AND a TeX engine must exist. When either is false the tool is
    /// not registered at all, so the model never offers a capability the machine
    /// cannot honour.
    ///
    /// `includeSessionMetadata` is `true` while the session's title has not yet
    /// been chosen by the model. The app keeps offering it (even after several
    /// exchanges) until the model actually picks a title/emoji, so short
    /// greetings do not leave the conversation permanently unlabeled.
    ///
    /// `includeKnowledge` is `true` whenever at least one personalization block exists:
    /// that's when `fetch_personalization_block` is useful.
    static func set(
        latexEnabled: Bool,
        includeSessionMetadata: Bool = false,
        includeKnowledge: Bool = false,
        includeFolders: Bool = false
    ) -> [BuiltinTool] {
        // IMPORTANT (DeepSeek prefix cache): the tool set must be byte-stable
        // for the whole conversation. Conditionally adding/removing tools
        // between turns invalidates the cached prefix and drops the hit rate
        // to just the system prompt. Behavioral limits are enforced at
        // execution time instead (see sessionMetadataSink / folderAssigner).
        var tools = all
        if latexEnabled && LaTeXService.isAvailable {
            tools.append(compileLaTeX)
        }
        return tools
    }

    // MARK: - ask_user

    /// Lightweight human-in-the-loop question. The service intercepts this
    /// call instead of executing it: it ends the current agent run, the app
    /// shows a native question card, and the user's answer arrives as a normal
    /// user message on the next turn.
    static let askUser = BuiltinTool(
        name: "ask_user",
        description: """
        Ask the user a blocking clarification question when the answer changes what you do \
        next and you cannot safely infer it. Provide 2-4 concrete options with short labels. \
        Use allow_custom when a free-form answer is also possible. Ask at most one question per \
        run, then stop and wait — do not guess and do not keep working.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "用户需要回答的问题"],
                "options": [
                    "type": "array",
                    "description": "2-4 个具体选项（可为空，仅自由输入）",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string", "description": "按钮显示的文字"],
                            "value": ["type": "string", "description": "返回给模型的稳定值"],
                            "description": ["type": "string", "description": "可选说明"],
                        ],
                        "required": ["label", "value"],
                    ],
                ],
                "allow_multiple": ["type": "boolean", "description": "是否允许多选"],
                "allow_custom": ["type": "boolean", "description": "是否允许自由输入"],
            ],
            "required": ["question"],
        ]
    ) { _, _ in
        // Normally intercepted by OpenAIService before execution.
        return "The app is showing this question to the user."
    }

    // MARK: - set_session_metadata

    /// First-round-only tool: lets the AI choose the conversation's emoji and
    /// short title, which the sidebar then shows. Kept in the registry so a
    /// (first-round) call always resolves; the sink applies the values to the
    /// active session on the main actor.
    static let setSessionMetadata = BuiltinTool(
        name: "set_session_metadata",
        description: """
        Call this tool when it is offered and the conversation still lacks an AI-chosen title. \
        It is offered whenever the app wants you to give the conversation an identity, usually \
        after the user's first real request becomes clear. Choose a concise title (no more than \
        24 characters, in the user's language, summarizing the conversation topic) and ONE emoji \
        that best captures it. Call it exactly once per conversation, before composing your answer; \
        after you call it the app will stop offering it.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "短标题，≤24字，概括用户第一个问题的主题"],
                "emoji": ["type": "string", "description": "最能代表本对话主题的单个 emoji（如 📚 🧠 💻 🎨 🍜 ⚖️ 🔬 🎬）"],
            ],
            "required": ["title", "emoji"],
        ],
        execute: { arguments, sessionID in
            let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let emoji = (arguments["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return "Error: title must not be empty." }
            let result = await MainActor.run {
                ChatTools.sessionMetadataSink?(sessionID, emoji, title)
            }
            return result ?? "Error: session metadata is unavailable."
        }
    )

    // MARK: - assign_session_folder

    /// Lists existing sidebar folders so the model can reuse one instead of
    /// inventing near-duplicate names.
    static let listSessionFolders = BuiltinTool(
        name: "list_session_folders",
        description: "List the user's existing sidebar folder names. Call this before assign_session_folder when you are unsure which folders already exist.",
        parameters: [
            "type": "object",
            "properties": [:],
        ]
    ) { _, sessionID in
        let names = await MainActor.run { ChatTools.folderNames?() ?? [] }
        let current = await MainActor.run {
            ChatTools.sessionFolderName?(sessionID) ?? "Uncategorized"
        }
        let list = names.isEmpty ? "No folders exist yet." : "Existing folders: " + names.joined(separator: ", ")
        return list + "\nCurrent folder: " + current
    }

    /// Lists the sessions of a folder that has opted into shared context.
    static let listFolderSessions = BuiltinTool(
        name: "list_folder_sessions",
        description: """
        List the sessions in a folder that has shared context enabled. Returns each \
        session's title, timestamp, message count and summary status. Use this before \
        get_folder_summaries when you need cross-conversation context. Omit `folder` to \
        use the current conversation's own folder; do not read other folders unless the \
        user explicitly names them.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "文件夹名称；省略时默认使用当前对话所在文件夹"],
            ],
        ]
    ) { arguments, sessionID in
        var folder = (arguments["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if folder.isEmpty {
            folder = await MainActor.run { ChatTools.sessionFolderName?(sessionID) ?? "" }
        }
        guard !folder.isEmpty else {
            return "This conversation is not in a folder yet, so there is no shared context to list."
        }
        let resolvedFolder = folder
        let rows = await MainActor.run {
            ChatTools.folderSessionIndexResolver?(resolvedFolder) ?? []
        }
        guard !rows.isEmpty else {
            return "No shared sessions found for folder \"\(folder)\". The folder may not exist or folder sharing is disabled."
        }
        return "Current folder: \(folder)\nShared context: enabled\n" + Self.jsonText(rows)
    }

    /// Returns stored summaries for the requested sessions of a shared folder.
    static let getFolderSummaries = BuiltinTool(
        name: "get_folder_summaries",
        description: """
        Retrieve stored summaries for specific sessions in a folder with shared \
        context enabled. Pass session titles (as returned by list_folder_sessions). \
        Omit `folder` to use the current conversation's own folder. Summaries are \
        background context and may be stale — verify before relying on them.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "description": "文件夹名称；省略时默认使用当前对话所在文件夹"],
                "sessions": [
                    "type": "array",
                    "description": "要读取摘要的会话标题（1-3 个）",
                    "items": ["type": "string"],
                ],
            ],
            "required": ["sessions"],
        ]
    ) { arguments, sessionID in
        var folder = (arguments["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if folder.isEmpty {
            folder = await MainActor.run { ChatTools.sessionFolderName?(sessionID) ?? "" }
        }
        let sessions = arguments["sessions"] as? [String] ?? []
        guard !folder.isEmpty, !sessions.isEmpty else {
            return "This conversation is not in a shared folder (or no sessions were requested)."
        }
        let rows = await ChatTools.folderSummariesAsyncResolver?(folder, sessions) ?? []
        guard !rows.isEmpty else {
            return "No summaries available for the requested sessions in \"\(folder)\"."
        }
        return Self.jsonText(rows)
    }

    private static func jsonText(_ rows: [[String: Any]]) -> String {
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// Lets the model file this conversation into one of the user's sidebar
    /// folders. Unknown folder names create a new folder automatically.
    static let assignSessionFolder = BuiltinTool(
        name: "assign_session_folder",
        description: """
        File the current conversation into a sidebar folder. Use an existing folder name \
        when one fits; if none fits, choose a short new folder name (≤16 characters, in the \
        user's language). The app creates the folder automatically when the name is new. \
        Call this at most once per conversation, only while the conversation is still \
        Uncategorized; never move an already-filed conversation, and never reclassify based \
        on a single off-topic message.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "文件夹名称（已有或新名称）"],
            ],
            "required": ["name"],
        ],
        execute: { arguments, sessionID in
            let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return "Error: folder name must not be empty." }
            let result = await MainActor.run {
                ChatTools.folderAssigner?(sessionID, name)
            }
            return result ?? "Error: folder assignment is unavailable."
        }
    )

    // MARK: - fetch_personalization_block

    /// Reads a stored personalization block by exact name. Advertised whenever the user
    /// has saved at least one block, so normal chats can pull the saved facts on
    /// demand. Execution resolves through the injected `personalizationResolver`.
    static let fetchPersonalizationBlock = BuiltinTool(
        name: "fetch_personalization_block",
        description: """
        Retrieve the full stored content of a personalization block by its EXACT name. Knowledge blocks \
        hold durable facts the user explicitly saved (e.g. account & personal info, team constants, \
        a project spec, a checklist). Call this tool whenever the user refers to something that \
        might live in a saved personalization block, or when a detail about the user/org isn't available \
        in this conversation. Pass the exact block name — if it doesn't exist the tool lists the \
        available names so you can retry. Never invent a block name or its content.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "个性化块的名字（必须与创建时完全一致，区分大小写）"],
            ],
            "required": ["name"],
        ],
        execute: { arguments, _ in
            let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return "Error: name must not be empty." }
            let content = await MainActor.run { ChatTools.personalizationResolver?(name) }
            if let content, !content.isEmpty {
                return "个性化块「\(name)」内容如下：\n\n\(content)"
            }
            let names = await MainActor.run { ChatTools.personalizationNames?() } ?? []
            return "没有找到个性化块「\(name)」。可用个性化块：\(names.isEmpty ? "（无）" : names.joined(separator: "、"))"
        }
    )

    // MARK: - compile_latex

    /// Writes a `.tex` document and compiles it to PDF with the local toolchain.
    ///
    /// Returns the produced paths (as a `file://` URL the UI turns into a
    /// clickable card) or the condensed engine errors so the model can fix its
    /// own source and retry.
    static let compileLaTeX = BuiltinTool(
        name: "compile_latex",
        description: """
        Write a LaTeX document to a file and compile it to PDF using the local \
        TeX installation (available engines: \(LaTeXService.installedEngineList)). \
        Pass the COMPLETE document including \\documentclass and \
        \\begin{document}…\\end{document}. Prefer xelatex for Chinese text (use \
        \\usepackage{ctex}). On failure you get the compiler errors — fix the \
        source and call the tool again. Use this when the user asks for a PDF, \
        a paper, a typeset document, or a printable file.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "source": [
                    "type": "string",
                    "description": "The complete LaTeX document source.",
                ],
                "filename": [
                    "type": "string",
                    "description": "Base filename without extension, e.g. \"report\". Letters, digits, - and _ only.",
                ],
                "engine": [
                    "type": "string",
                    "description": "Optional engine: xelatex (default, best for CJK), pdflatex or lualatex.",
                ],
                "project": [
                    "type": "string",
                    "description": "Optional project/subfolder name, e.g. \"AP Research\" or \"线性代数作业\". The app creates LaTeX/<project>/ under its output directory so files from different tasks stay organized.",
                ],
            ],
            "required": ["source"],
        ],
        extractSources: { result in LaTeXService.parseArtifacts(from: result) }
    ) { arguments, _ in
        guard let source = arguments["source"] as? String,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"source\" argument."
        }
        let stem = (arguments["filename"] as? String) ?? "document"
        let engine = arguments["engine"] as? String
        let project = arguments["project"] as? String

        let result: LaTeXService.CompileResult
        do {
            result = try LaTeXService.compile(
                source: source,
                filenameStem: stem,
                engine: engine,
                projectName: project
            )
        } catch {
            return "Error: LaTeX compilation could not start — \(error.localizedDescription)"
        }

        if let pdf = result.pdfURL {
            let pages = result.pageCount.map { " (\($0) pages)" } ?? ""
            return """
            Compiled successfully\(pages).
            PDF: \(pdf.path)
            Source: \(result.sourceURL.path)
            ARTIFACT: \(pdf.absoluteString)
            Tell the user the PDF is ready; the app shows a clickable link. Do NOT paste the whole source again.
            """
        }

        return """
        Compilation FAILED. The .tex was saved at \(result.sourceURL.path).
        Compiler errors:
        \(result.log)
        Fix the source and call compile_latex again.
        """
    }

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
        parameters: [
            "type": "object",
            "properties": [:],
        ]
    ) { _, _ in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// Executes a tool by name. Unknown tools / failures return a plain-text
    /// error string the model can read and adjust to.
    static func execute(name: String, argumentsJSON: String, sessionID: UUID?) async throws -> String {
        guard let tool = allWithOptional.first(where: { $0.name == name }) else {
            return "Error: unknown tool \"\(name)\"."
        }
        var arguments: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object
        }
        return try await tool.execute(arguments, sessionID)
    }

    /// Returns the source references (title + URL) a tool attached to its result,
    /// for the "Sources" card under the final assistant message.
    static func sources(for name: String, result: String) -> [ChatSource] {
        guard let tool = allWithOptional.first(where: { $0.name == name }) else { return [] }
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
    ) { arguments, _ in
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
    ) { arguments, _ in
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
    ) { arguments, _ in
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
    ) { arguments, _ in
        guard let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing \"query\" argument."
        }
        return try await WebSearch.search(query)
    }
}
// MARK: - Web search backend (zero-key Bing RSS + DuckDuckGo fallback)

/// Minimal web search without any API key.
///
/// 1. DuckDuckGo Instant Answer API (structured JSON, often sparse).
/// 2. Bing's RSS endpoint — reliable for programmatic clients without an API key.
/// 3. DuckDuckGo HTML (kept as a final fallback; increasingly anti-bot).
enum WebSearch {

    static func search(_ query: String, maxResults: Int = 5) async throws -> String {
        let configuration = ChatTools.searchConfiguration
        let defaultOrder: [SearchProvider] = [
            .duckduckgo, .bing, .brave, .serper, .tavily, .searxng,
        ]
        let order: [SearchProvider]
        if configuration.provider == .automatic {
            order = configuration.order.isEmpty ? defaultOrder : configuration.order
        } else {
            order = [configuration.provider]
        }

        for provider in order {
            if let result = try await runProvider(
                provider,
                query: query,
                maxResults: maxResults,
                configuration: configuration
            ), !result.isEmpty {
                return result
            }
        }
        return """
        Web search returned no relevant results for "\(query)".
        Check the search backend order in Settings → API → Web Search, or configure a real \
        Search API key. If you use a proxy/VPN in TUN or fake-IP mode, its rules may be \
        intercepting search-engine traffic.
        """
    }

    // MARK: Relevance guard

    /// Reject result sets where the engine clearly searched only the first word
    /// (e.g. "All My Loving …" returning dictionary pages for "all").
    private static func relevantResults(_ query: String, _ results: [ResultItem]) -> Bool {
        let tokens = queryTokens(query)
        guard !tokens.isEmpty else { return !results.isEmpty }
        let required = min(2, tokens.count)

        for result in results {
            let haystack = (result.title + " " + result.snippet + " " + result.url).lowercased()
            let hits = tokens.filter { haystack.contains($0) }.count
            if hits >= required { return true }
        }
        return false
    }

    private static let searchStopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "what", "when",
        "where", "which", "who", "why", "how", "are", "was", "were", "does",
        "did", "you", "your", "about", "into", "out", "over", "under", "vs",
    ]

    private static func queryTokens(_ query: String) -> [String] {
        var tokens = Set<String>()
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words where word.count >= 3 {
            let token = String(word)
            if !searchStopWords.contains(token) {
                tokens.insert(token)
            }
        }
        // CJK queries: add 2-character n-grams so Chinese search is validated too.
        for run in query.split(whereSeparator: { !$0.isLetter }) {
            let chars = Array(run)
            guard chars.count >= 2,
                  chars.contains(where: { $0.unicodeScalars.first.map { $0.value >= 0x3400 } ?? false })
            else { continue }
            for index in 0..<(chars.count - 1) {
                tokens.insert(String(chars[index...index + 1]))
            }
        }
        return Array(tokens)
    }

    // MARK: Configured API providers

    /// Runs one backend in the user's priority order. Missing credentials for
    /// that backend simply skip it (Auto mode) or return a clear error when the
    /// provider was explicitly forced.
    private static func runProvider(
        _ provider: SearchProvider,
        query: String,
        maxResults: Int,
        configuration: ChatTools.WebSearchConfiguration
    ) async throws -> String? {
        let forced = configuration.provider != .automatic
        switch provider {
        case .automatic:
            return nil
        case .duckduckgo:
            return try await htmlSearch(query, maxResults: maxResults)
        case .bing:
            return try await bingSearch(query, maxResults: maxResults)
        case .brave:
            guard !configuration.apiKey.isEmpty else {
                return forced ? "Error: Brave Search selected, but no search API key is configured." : nil
            }
            return try await brave(query, key: configuration.apiKey, maxResults: maxResults)
        case .serper:
            guard !configuration.apiKey.isEmpty else {
                return forced ? "Error: Serper selected, but no search API key is configured." : nil
            }
            return try await serper(query, key: configuration.apiKey, maxResults: maxResults)
        case .tavily:
            guard !configuration.apiKey.isEmpty else {
                return forced ? "Error: Tavily selected, but no search API key is configured." : nil
            }
            return try await tavily(query, key: configuration.apiKey, maxResults: maxResults)
        case .searxng:
            guard !configuration.endpoint.isEmpty else {
                return forced ? "Error: SearXNG selected, but no endpoint URL is configured." : nil
            }
            return try await searxng(query, endpoint: configuration.endpoint, maxResults: maxResults)
        }
    }

    private static func format(_ query: String, _ results: [ResultItem]) -> String {
        guard !results.isEmpty else { return "" }
        var output = "Web search results for \"\(query)\":\n"
        for (index, result) in results.enumerated() {
            output += "\(index + 1). \(result.title)\n   \(result.snippet)\n   \(result.url)\n"
        }
        return output
    }

    private static func brave(_ query: String, key: String, maxResults: Int) async throws -> String {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "\(maxResults)"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = object["web"] as? [String: Any],
              let items = web["results"] as? [[String: Any]] else {
            return "Error: Brave Search request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
        }
        let results = items.prefix(maxResults).compactMap { item -> ResultItem? in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return ResultItem(title: title, snippet: (item["description"] as? String) ?? "", url: url)
        }
        return format(query, results)
    }

    private static func serper(_ query: String, key: String, maxResults: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://google.serper.dev/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": query,
            "num": maxResults,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["organic"] as? [[String: Any]] else {
            return "Error: Serper request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
        }
        let results = items.prefix(maxResults).compactMap { item -> ResultItem? in
            guard let title = item["title"] as? String,
                  let url = item["link"] as? String else { return nil }
            return ResultItem(title: title, snippet: (item["snippet"] as? String) ?? "", url: url)
        }
        return format(query, results)
    }

    private static func tavily(_ query: String, key: String, maxResults: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": key,
            "query": query,
            "max_results": maxResults,
            "search_depth": "basic",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["results"] as? [[String: Any]] else {
            return "Error: Tavily request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
        }
        let results = items.prefix(maxResults).compactMap { item -> ResultItem? in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return ResultItem(title: title, snippet: (item["content"] as? String) ?? "", url: url)
        }
        return format(query, results)
    }

    private static func searxng(_ query: String, endpoint: String, maxResults: Int) async throws -> String {
        var trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        var components = URLComponents(string: trimmed + "/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["results"] as? [[String: Any]] else {
            return "Error: SearXNG request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
        }
        let results = items.prefix(maxResults).compactMap { item -> ResultItem? in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            return ResultItem(title: title, snippet: (item["content"] as? String) ?? "", url: url)
        }
        return format(query, results)
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

    /// Bing's RSS endpoint is far more stable for programmatic clients than
    /// scraping DuckDuckGo's HTML (which now returns an empty anti-bot page to
    /// URLSession). Parsed with a small XML regex because the payload is tiny.
    private static func bingSearch(_ query: String, maxResults: Int) async throws -> String {
        guard var components = URLComponents(string: "https://www.bing.com/search") else {
            return ""
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "rss"),
            URLQueryItem(name: "count", value: "\(maxResults)"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return ""
        }

        let items = matches(in: xml, pattern: #"(?is)<item>(.*?)</item>"#)
        var results: [ResultItem] = []
        for item in items.prefix(maxResults) {
            let title = decodeHTML(
                matches(in: item, pattern: #"(?is)<title>(.*?)</title>"#).first ?? ""
            )
            let url = decodeHTML(
                matches(in: item, pattern: #"(?is)<link>(.*?)</link>"#).first ?? ""
            )
            let snippet = stripTags(
                decodeHTML(matches(in: item, pattern: #"(?is)<description>(.*?)</description>"#).first ?? "")
            )
            guard !url.isEmpty, !title.isEmpty else { continue }
            results.append(ResultItem(title: title, snippet: snippet, url: url))
        }
        guard !results.isEmpty else { return "" }
        guard relevantResults(query, results) else { return "" }

        var output = "Web search results for \"\(query)\":\n"
        for (index, result) in results.enumerated() {
            output += "\(index + 1). \(result.title)\n   \(result.snippet)\n   \(result.url)\n"
        }
        return output
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func stripTags(_ text: String) -> String {
        var result = text
        while let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
            return ""
        }
        guard relevantResults(query, results) else {
            return ""
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
              let host = url.host else {
            return "Error: invalid URL \"\(trimmed)\". Only http(s) URLs are supported."
        }
        if isPrivateHost(host) {
            return "Error: fetching local/private addresses is not allowed."
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

    /// Blocks loopback, private-network, link-local and mDNS hosts so a model
    /// (which may be influenced by untrusted fetched pages) cannot use
    /// `web_fetch` to read local services or router UIs.
    private static func isPrivateHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local") {
            return true
        }

        // IPv6 loopback / unspecified / link-local / ULA prefixes.
        if normalized.contains(":") {
            return normalized == "::1"
                || normalized == "::"
                || normalized.hasPrefix("fe80:")
                || normalized.hasPrefix("fc")
                || normalized.hasPrefix("fd")
                || normalized.hasPrefix("::ffff:127.")
        }

        let octets = normalized.split(separator: ".").prefix(4).compactMap { Int($0) }
        guard octets.count >= 2 else { return false }
        switch octets[0] {
        case 0, 10, 127, 169, 192:
            return true
        case 172:
            return (16...31).contains(octets[1])
        default:
            return false
        }
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
