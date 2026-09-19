import AppKit
import SwiftUI

/// 模型回答里的网络图片（Markdown 的 `![描述](https://…)`）。
///
/// 与 MarkdownUI 自带 provider 的差异：自带 provider 只负责把图拉回来，
/// 失败就是一片空白。这里补齐了占位 / 失败 / 被关闭三种状态，并复用
/// `RemoteImageLoader` 的缓存，让列表重渲染不会重复下载。
struct RemoteImageView: View {

    let url: URL
    /// 当前正文字号——占位框与提示条按它缩放，和消息其它部分保持一致。
    let fontSize: CGFloat

    /// 单张图片的最大显示高度（避免长图霸占整屏；宽度由气泡决定）。
    private static let maxDisplayHeight: CGFloat = 420

    @State private var phase: Phase
    /// `phase` 对应的 URL——视图被复用（同一位置换了图片）时用来判定要不要重开。
    @State private var phaseKey: String

    private enum Phase {
        case loading
        case loaded(NSImage)
        case failed
    }

    init(url: URL, fontSize: CGFloat) {
        self.url = url
        self.fontSize = fontSize
        // 命中缓存时首帧直接出图：切换字号 / 导出 PDF 重建视图都不会闪占位框。
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            _phase = State(initialValue: .loaded(cached))
        } else {
            _phase = State(initialValue: .loading)
        }
        _phaseKey = State(initialValue: url.absoluteString)
    }

    var body: some View {
        content
            .task(id: url.absoluteString) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            placeholder
        case .loaded(let image):
            imageView(image)
        case .failed:
            RemoteImageNotice(url: url, style: .failed, fontSize: fontSize, onRetry: retry)
        }
    }

    // MARK: - States

    /// 加载占位框：固定尺寸的浅色圆角块，避免图片到达时列表跳动太大。
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.08))
            .frame(width: 240, height: 130)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("image.loading"))
                        .font(.system(size: max(10, fontSize - 3)))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18))
            }
            .accessibilityLabel(L("image.loading"))
    }

    /// 加载成功：按原图比例显示，**不放大**（小图标保持小），超出即等比缩小，
    /// 点一下用系统默认浏览器打开原图。
    private func imageView(_ image: NSImage) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: max(image.size.width, 1),
                    maxHeight: min(Self.maxDisplayHeight, max(image.size.height, 1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15))
                }
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .accessibilityLabel(url.lastPathComponent)
    }

    // MARK: - Loading

    /// 注意 `@MainActor`：状态更新必须回到主线程，否则 SwiftUI 可能收不到
    /// 重新渲染的通知（图片下载完成后界面仍停在占位框）。
    @MainActor
    private func load() async {
        let key = url.absoluteString

        if phaseKey != key {
            // 视图被复用到了另一张图：先把状态切回去（命中缓存则直接出图）。
            phaseKey = key
            if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
                phase = .loaded(cached)
                return
            }
            phase = .loading
        }

        if case .loaded = phase { return }

        do {
            let image = try await RemoteImageLoader.shared.image(for: url).image
            guard !Task.isCancelled else { return }
            phase = .loaded(image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    /// 手动重试：跳过失败冷却，重新发起一次请求。
    @MainActor
    private func retry() {
        phase = .loading
        Task {
            do {
                let image = try await RemoteImageLoader.shared.image(
                    for: url,
                    ignoringFailureCache: true
                ).image
                phase = .loaded(image)
            } catch {
                phase = .failed
            }
        }
    }
}

// MARK: - 图片不可用时的提示条

/// 图片没显示出来时的一行提示（加载失败 / 设置里关掉了网络图片）。
///
/// 关键是**不要静默空白**：用户至少要知道这里原本有一张图，并且能：
/// 直接打开原图、重试加载。
struct RemoteImageNotice: View {

    enum Style {
        /// 下载失败（链接失效 / 网络不通 / 不是图片）。
        case failed
        /// 用户在设置里关掉了「渲染回答中的网络图片」。
        case hidden
    }

    let url: URL
    let style: Style
    let fontSize: CGFloat
    var onRetry: (() -> Void)? = nil

    private var title: String {
        switch style {
        case .failed: return L("image.failed")
        case .hidden: return L("image.hidden")
        }
    }

    private var symbol: String {
        switch style {
        case .failed: return "photo.badge.exclamationmark"
        case .hidden: return "photo"
        }
    }

    /// 展示「站点 + 文件名」，让用户判断要不要打开。
    private var subtitle: String {
        let host = url.host() ?? url.absoluteString
        let file = url.lastPathComponent
        return file.isEmpty ? host : "\(host)/\(file)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: max(14, fontSize)))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: max(11, fontSize - 2), weight: .medium))
                Text(subtitle)
                    .font(.system(size: max(10, fontSize - 3)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let onRetry {
                Button(L("image.retry"), action: onRetry)
                    .buttonStyle(.borderless)
                    .font(.system(size: max(11, fontSize - 2)))
            }

            Button(L("image.open")) { NSWorkspace.shared.open(url) }
                .buttonStyle(.borderless)
                .font(.system(size: max(11, fontSize - 2)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
        .frame(maxWidth: 420, alignment: .leading)
        .help(url.absoluteString)
    }
}
