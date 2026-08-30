import SwiftUI
import MarkdownUI

/// Block (display) math provider.
///
/// MarkdownUI's block `ImageProvider` returns a live SwiftUI view, so display
/// math is placed into the paragraph as a centered image. The NSImage is a
/// template, so it inherits the surrounding text color automatically.
struct MathBlockImageProvider: ImageProvider {

    let fontSize: CGFloat

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
        } else {
            EmptyView()
        }
    }
}

/// Inline math provider.
///
/// MarkdownUI's inline provider must return a SwiftUI `Image`, so inline math
/// is rasterized via SwiftMath (memoized) and embedded in the surrounding
/// text. Template tinting keeps it correct in both light and dark mode.
struct MathInlineImageProvider: InlineImageProvider {

    let fontSize: CGFloat

    func image(with url: URL, label: String) async throws -> Image {
        guard url.scheme == MathCoding.scheme, url.host == MathCoding.inlineHost,
              let latex = MathCoding.decode(url: url) else {
            return Image(nsImage: NSImage(size: .zero))
        }
        if let image = MathRenderer.shared.image(latex: latex, fontSize: fontSize, display: false) {
            return Image(nsImage: image)
        }
        return Image(nsImage: NSImage(size: .zero))
    }
}
