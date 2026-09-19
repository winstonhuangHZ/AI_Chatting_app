import SwiftUI
import MarkdownUI

/// Markdown 图片的统一入口。
///
/// MarkdownUI 的 `Markdown` 视图只允许挂**一个** block provider 和一个 inline
/// provider，而本 App 的图片有两个来源：
///
/// 1. `aichatmath://` —— `MathSegmenter` 把 LaTeX 藏进图片 URL 里偷渡过来的
///    公式（见 `MathCoding`），由 SwiftMath 栅格化成 template 图；
/// 2. `http(s)://` / `data:image/…` —— 模型在回答里直接给出的图片链接
///    （设置 → 外观「渲染回答中的网络图片」控制是否下载显示）。
///
/// 因此这里的 provider 是「数学公式 + 网络图片」的分发器：URL 决定走哪条路，
/// 都不匹配时保持原来的行为（什么都不画）。

/// Block (display) image provider.
///
/// MarkdownUI's block `ImageProvider` returns a live SwiftUI view, so display
/// math is placed into the paragraph as a centered image. The NSImage is a
/// template, so it inherits the surrounding text color automatically.
struct MediaBlockImageProvider: ImageProvider {

    let fontSize: CGFloat
    /// 设置 → 外观：「渲染回答中的网络图片」。关闭时只显示可手动打开的提示条。
    let rendersRemoteImages: Bool

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, url.scheme == MathCoding.scheme, url.host == MathCoding.displayHost,
           let latex = MathCoding.decode(url: url) {
            if let image = MathRenderer.shared.image(latex: latex, fontSize: fontSize, display: true) {
                Image(nsImage: image)
                    .accessibilityLabel("math")
            } else {
                // Should be unreachable: MathSegmenter validates before linking.
                Text(latex).font(.system(size: fontSize)).foregroundStyle(.secondary)
            }
        } else if let url, RemoteImageLoader.isRenderable(url) {
            if rendersRemoteImages {
                RemoteImageView(url: url, fontSize: fontSize)
            } else {
                RemoteImageNotice(url: url, style: .hidden, fontSize: fontSize)
            }
        } else {
            EmptyView()
        }
    }
}

/// Inline image provider.
///
/// MarkdownUI's inline provider must return a SwiftUI `Image`, so inline math
/// is rasterized via SwiftMath (memoized) and embedded in the surrounding
/// text. Template tinting keeps it correct in both light and dark mode.
///
/// 行内网络图片（`文字 ![x](url) 文字`）同样要返回 `Image`，但行内没法放占位
/// 框或按钮，因此：能加载就等比缩成行内小图；加载不了 / 被关闭时退回一个
/// `photo` 小图标——至少让用户看到“这里原本有一张图”，而不是整段文字里凭空
/// 少了一块。
struct MediaInlineImageProvider: InlineImageProvider {

    let fontSize: CGFloat
    let rendersRemoteImages: Bool

    func image(with url: URL, label: String) async throws -> Image {
        if url.scheme == MathCoding.scheme, url.host == MathCoding.inlineHost,
           let latex = MathCoding.decode(url: url) {
            if let image = MathRenderer.shared.image(latex: latex, fontSize: fontSize, display: false) {
                return Image(nsImage: image)
            }
            return Image(nsImage: NSImage(size: .zero))
        }

        guard RemoteImageLoader.isRenderable(url), rendersRemoteImages,
              let image = try? await RemoteImageLoader.shared.image(for: url).image else {
            return Self.placeholderImage(label: label, fontSize: fontSize)
        }
        return Image(nsImage: Self.inlineSized(image, fontSize: fontSize))
    }

    // MARK: - Helpers

    /// 行内图片的高度上限（`1 em` ≈ 字号，这里放宽到 4 行高，兼顾可辨识与不撑行）。
    private static func inlineSized(_ image: NSImage, fontSize: CGFloat) -> NSImage {
        let maxHeight = max(12, fontSize * 4)
        let size = image.size
        guard size.height > maxHeight, size.height > 0, size.width > 0 else { return image }

        let scale = maxHeight / size.height
        let target = NSSize(width: max(1, size.width * scale), height: maxHeight)
        return NSImage(size: target, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: target))
            return true
        }
    }

    /// 行内占位：一个 `photo` 符号（template，跟随正文颜色）。
    private static func placeholderImage(label: String, fontSize: CGFloat) -> Image {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: max(10, fontSize),
            weight: .regular
        )
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) {
            symbol.isTemplate = true
            return Image(nsImage: symbol)
        }
        return Image(nsImage: NSImage(size: NSSize(width: 1, height: 1)))
    }
}
