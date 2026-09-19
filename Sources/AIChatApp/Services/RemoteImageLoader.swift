import AppKit
import Foundation

/// 一张解码完成的远程图片。
///
/// `NSImage` 没有 `Sendable` 标记，但这里的图在后台线程解码、之后只被主线程
/// 读取渲染（不再改写），所以用这个显式包装声明跨隔离域传递的意图；否则每次
/// 异步返回都会触发并发检查警告（Swift 6 语言模式下会升级成错误）。
struct RemoteImage: @unchecked Sendable {
    let image: NSImage
}

/// 模型回答里 Markdown 网络图片（`![描述](https://…)`）的下载 / 解码 / 缓存中心。
///
/// 为什么不用 `AsyncImage` 或 MarkdownUI 自带的 `DefaultImageProvider`：
///
/// - **重渲染友好**：消息正文在滚动、悬停、切换字号、导出 PDF 时都会被重新
///   求值，缓存（内存 `NSCache` + URLSession 磁盘缓存）保证同一张图只下载一次。
/// - **请求去重**：同一 URL 并发发起多次请求时只保留一个网络任务，其余共享结果。
/// - **失败冷却**：坏链接在 30 秒内直接复用失败结果，避免每次重渲染都重新请求。
/// - **不可信输入防护**：模型给的 URL 可能指向超大文件或不存在的站点，因此限制
///   单张体积、设置请求超时，并要求响应是图片类型。
final class RemoteImageLoader: @unchecked Sendable {

    /// 全局共享实例（视图与 PDF 导出都用它，缓存才能互通）。
    static let shared = RemoteImageLoader()

    /// 单张图片的体积上限（24 MB）——超过即拒绝，避免大图把内存吃光。
    private static let maxBytes = 24 * 1024 * 1024

    /// 失败后的冷却时间：期间同一 URL 直接返回失败，不再发请求。
    private static let failureCooldown: TimeInterval = 30

    /// 加载失败的原因（用于日志与占位提示，界面只区分“成功 / 失败”）。
    enum LoadError: LocalizedError {
        case unsupportedURL
        case badStatus(Int)
        case tooLarge
        case notAnImage
        case recentlyFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedURL:  return "不支持的图片地址"
            case .badStatus(let code): return "服务器返回 \(code)"
            case .tooLarge:        return "图片超出体积上限"
            case .notAnImage:      return "响应不是图片"
            case .recentlyFailed:  return "图片刚刚加载失败"
            }
        }
    }

    private let cache = NSCache<NSURL, NSImage>()
    private let lock = NSLock()

    /// 进行中的请求（URL → 任务），用于并发去重。
    private var inFlight: [URL: Task<RemoteImage, Error>] = [:]
    /// 最近失败的 URL 与时间，用于失败冷却。
    private var failures: [URL: Date] = [:]
    private let session: URLSession

    private init() {
        cache.countLimit = 120
        // 单张最大 24MB，只按条数限制仍可能堆到几百 MB，所以再加一道总量上限。
        cache.totalCostLimit = 128 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["Accept": "image/*,*/*;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    // MARK: - URL 过滤

    /// 是否可以交给本加载器处理：`http(s)://` 绝对地址，或内联的 `data:image/…`。
    ///
    /// 相对路径（模型偶尔会写 `![x](pic.png)`）与 `file://` 一律返回 `false`：
    /// 前者没有可解析的基准地址，后者不该由远端模型决定读取哪个本地文件。
    static func isRenderable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return !(url.host?.isEmpty ?? true)
        case "data":
            return url.absoluteString.lowercased().hasPrefix("data:image/")
        default:
            return false
        }
    }

    // MARK: - 缓存查询

    /// 同步命中内存缓存（视图首帧用，避免已加载过的图片再闪一次占位框）。
    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    // MARK: - 加载

    /// 下载并解码一张图片；命中缓存时立即返回。
    ///
    /// - Parameter ignoringFailureCache: 手动重试时传 `true`，跳过失败冷却。
    func image(for url: URL, ignoringFailureCache: Bool = false) async throws -> RemoteImage {
        guard Self.isRenderable(url) else { throw LoadError.unsupportedURL }
        if let cached = cachedImage(for: url) { return RemoteImage(image: cached) }

        if !ignoringFailureCache, let failedAt = failureDate(for: url),
           Date().timeIntervalSince(failedAt) < Self.failureCooldown {
            throw LoadError.recentlyFailed
        }

        let task = lock.withLock { () -> Task<RemoteImage, Error> in
            if let existing = inFlight[url] { return existing }
            let created = Task<RemoteImage, Error> { [session] in
                RemoteImage(image: try await Self.load(url: url, session: session))
            }
            inFlight[url] = created
            return created
        }

        do {
            let image = try await task.value.image
            lock.withLock {
                inFlight[url] = nil
                failures[url] = nil
            }
            cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
            return RemoteImage(image: image)
        } catch {
            lock.withLock {
                inFlight[url] = nil
                failures[url] = Date()
            }
            throw error
        }
    }

    /// 预加载一批图片（PDF 导出前调用）。
    ///
    /// 导出是同步快照，异步图片来不及下载就会画出占位框，所以先把会话里出现的
    /// 图片灌进缓存；失败的直接忽略（导出的其它内容照常输出）。
    ///
    /// - Parameter timeout: 整体超时——导出不能因为某一两张图卡住而无限等下去，
    ///   超时后取消剩余下载，用已经拿到的图继续渲染。
    func preload(_ urls: [URL], concurrency: Int = 4, timeout: TimeInterval = 15) async {
        let unique = Array(Set(urls.filter(Self.isRenderable)))
        guard !unique.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.downloadAll(unique, concurrency: concurrency) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            // 谁先结束（全部下载完 / 超时）就往下走，剩下的下载直接取消。
            await group.next()
            group.cancelAll()
        }
    }

    /// 以固定并发度下载全部 URL（失败忽略）。
    private func downloadAll(_ urls: [URL], concurrency: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = urls[...]

            for _ in 0..<max(1, concurrency) {
                guard let next = pending.first else { break }
                pending = pending.dropFirst()
                group.addTask { [self] in
                    _ = try? await self.image(for: next)
                }
            }

            while await group.next() != nil {
                guard let next = pending.first else { continue }
                pending = pending.dropFirst()
                group.addTask { [self] in
                    _ = try? await self.image(for: next)
                }
            }
        }
    }

    // MARK: - 网络 / 解码

    private func failureDate(for url: URL) -> Date? {
        lock.withLock { failures[url] }
    }

    /// 缓存开销估算：按像素数 × 4 字节（不再重新编码图片，避免额外开销）。
    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) { total, representation in
            total + max(0, representation.pixelsWide) * max(0, representation.pixelsHigh)
        }
        return max(1, pixels) * 4
    }

    private static func load(url: URL, session: URLSession) async throws -> NSImage {
        let data: Data

        if url.scheme?.lowercased() == "data" {
            guard let decoded = dataURLPayload(url) else { throw LoadError.notAnImage }
            data = decoded
        } else {
            let (payload, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    throw LoadError.badStatus(http.statusCode)
                }
                // 有些图床（CDN）把图片标成 application/octet-stream，所以只对
                // 明确的文本响应（HTML 错误页之类）提前失败，其余一律交给解码器
                // 判断——解不出图才算失败。
                if let mime = http.mimeType?.lowercased(),
                   mime.hasPrefix("text/") || mime.contains("html") {
                    throw LoadError.notAnImage
                }
                // Content-Length 先拦一道，避免把超大文件整份读进内存。
                if http.expectedContentLength > Int64(maxBytes) { throw LoadError.tooLarge }
            }
            data = payload
        }

        guard data.count <= maxBytes else { throw LoadError.tooLarge }
        guard let image = NSImage(data: data) else { throw LoadError.notAnImage }
        return image
    }

    /// 解出 `data:image/png;base64,…` 里的图片数据（模型偶尔会直接内联图片）。
    private static func dataURLPayload(_ url: URL) -> Data? {
        let raw = url.absoluteString
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let header = raw[..<comma]
        let payload = String(raw[raw.index(after: comma)...])

        if header.lowercased().contains(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    // MARK: - Markdown 图片语法扫描

    /// 扫描一段 markdown 里的图片 URL（PDF 导出前预加载用）。
    ///
    /// 只处理标准 `![描述](地址)` / `![描述](<地址>)` 形式，够用且不会误伤
    /// 普通链接；解析失败的位置直接跳过。
    static func markdownImageURLs(in markdown: String) -> [URL] {
        guard markdown.contains("![") else { return [] }
        let pattern = #"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+["'][^)]*["'])?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: markdown) else { return nil }
            let text = String(markdown[captured])
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: text) else { return nil }
            return isRenderable(url) ? url : nil
        }
    }
}
