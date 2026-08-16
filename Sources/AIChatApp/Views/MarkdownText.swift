import SwiftUI

/// Lightweight Markdown renderer backed by SwiftUI's native
/// `AttributedString(markdown:)` (macOS 12+). Renders headings, bold, italic,
/// code, and links from assistant messages.
struct MarkdownText: View {

    /// Raw Markdown source.
    let text: String

    /// Base font size.
    var fontSize: CGFloat = 13

    // MARK: - Body

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(styleCodeRuns(attributed))
                .textSelection(.enabled)
        } else {
            // Input is not parseable Markdown — show as plain text.
            Text(text)
                .font(.system(size: fontSize))
        }
    }

    // MARK: - Helpers

    /// Pre-processes the attributed string so code runs use a monospaced font
    /// and a light background. This runs *before* the ViewBuilder so no
    /// control flow is needed inside it.
    private func styleCodeRuns(_ attributed: AttributedString) -> AttributedString {
        var styled = attributed
        styled.font = .systemFont(ofSize: fontSize)

        for run in styled.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].font = .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
                styled[run.range].backgroundColor = .gray.opacity(0.15)
            }
        }

        return styled
    }
}