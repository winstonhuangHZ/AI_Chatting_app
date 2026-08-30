import SwiftUI
import MarkdownUI

/// Lightweight GFM (GitHub Flavored Markdown) renderer built on
/// `swift-markdown-ui` (MarkdownUI). Supports tables, headings, code blocks,
/// lists, links — unlike Apple's native `Text(LocalizedStringKey)`, which
/// does not render Markdown tables.
///
/// LaTeX math returned by the model (`$...$`, `$$...$$`, `\(...\)`,
/// `\begin{align}…`, …) is rendered natively via SwiftMath:
/// `MathSegmenter` extracts the spans before Markdown parsing (protecting them
/// from CommonMark mangling), and the custom image providers below rasterize
/// them into template images that inherit the current text color and font size.
///
/// Font scaling: reads `AppearanceStore` from the environment so the UI font
/// preset (serif / sans / mono) and size level (small→extra large) apply
/// instantly to the rendered markdown.
struct MarkdownText: View {

    /// Raw Markdown source.
    let text: String

    /// Base font size for the rendered content (uses AppearanceStore when nil).
    var fontSize: CGFloat? = nil

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore

    // MARK: - Body

    private var effectiveFontSize: CGFloat {
        fontSize ?? appearance.pointSize
    }

    /// Inline-code background: clay tint on the Claude theme, neutral gray
    /// otherwise — enough contrast on both light and dark system themes.
    private var inlineCodeBackgroundColor: Color {
        appearance.isClaudeTheme
            ? AppearanceStore.claudeAccent.opacity(0.14)
            : Color.secondary.opacity(0.14)
    }

    private var inlineCodeTextColor: Color {
        appearance.isClaudeTheme
            ? AppearanceStore.claudeAccentDeep
            : .primary
    }

    var body: some View {
        Markdown(
            // The block quote prefix instructs the parser to keep the raw
            // source untouched (no trimming of newlines).
            """
            \(rewrittenSource)
            """,
            baseURL: nil
        )
        // Math is smuggled through the parser as `aichatmath://` image URLs;
        // these providers turn them back into rendered LaTeX.
        .markdownImageProvider(MathBlockImageProvider(fontSize: effectiveFontSize))
        .markdownInlineImageProvider(MathInlineImageProvider(fontSize: effectiveFontSize))
        .markdownTextStyle {
            FontSize(effectiveFontSize)
            // Apply the preset font family to the whole markdown body.
            FontFamily(appearance.fontPreset.fontPropertiesFamily)
        }
        // Inline code: subtle tinted background so it stands off the bubble.
        .markdownTextStyle(\.code) {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            ForegroundColor(inlineCodeTextColor)
            BackgroundColor(inlineCodeBackgroundColor)
        }
        // Fenced code blocks: dark card (Claude-style) for strong contrast on
        // both the cream Claude background and the system one.
        .markdownBlockStyle(\.codeBlock) { configuration in
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppearanceStore.claudeCodeBlockBackground)
                )
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.88))
                    ForegroundColor(AppearanceStore.claudeCodeBlockText)
                }
                .markdownMargin(top: .em(0.6), bottom: .em(0.6))
        }
        .markdownBlockStyle(\.table) { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.5))
        }
        .textSelection(.enabled)
        // Recreate the Markdown subtree when the font size changes so cached
        // inline math images are re-rasterized at the new scale.
        .id("markdown-math-\(effectiveFontSize)")
    }

    /// The markdown source with every LaTeX span swapped for a math image URL.
    private var rewrittenSource: String {
        MathSegmenter.rewrite(text)
    }
}
