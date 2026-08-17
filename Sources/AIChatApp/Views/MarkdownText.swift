import SwiftUI
import MarkdownUI

/// Lightweight GFM (GitHub Flavored Markdown) renderer built on
/// `swift-markdown-ui` (MarkdownUI). Supports tables, headings, code blocks,
/// lists, links — unlike Apple's native `Text(LocalizedStringKey)`, which
/// does not render Markdown tables.
struct MarkdownText: View {

    /// Raw Markdown source.
    let text: String

    /// Base font size for the rendered content.
    var fontSize: CGFloat = 13

    // MARK: - Body

    var body: some View {
        Markdown(
            // The block quote prefix instructs the parser to keep the raw
            // source untouched (no trimming of newlines).
            """
            \(text)
            """,
            baseURL: nil
        )
        .markdownTextStyle {
            FontSize(fontSize)
        }
        .markdownBlockStyle(\.table) { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.5))
        }
        .textSelection(.enabled)
    }
}