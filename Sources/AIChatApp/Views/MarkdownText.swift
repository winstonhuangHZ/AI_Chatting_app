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
///
/// 文本选择：纯散文（无代码块 / 表格 / LaTeX / 图片 / 标题 / 引用）走单个
/// `Text(AttributedString)` 渲染——整条消息是一个可选中整体，光标可以跨段落
/// 拖选复制（MarkdownUI 把每个段落渲染成独立 `Text`，macOS 上拖不过下一段）。
/// 富内容仍走 MarkdownUI，保留代码卡片、表格与数学渲染。
struct MarkdownText: View {

    /// Raw Markdown source.
    let text: String

    /// Base font size for the rendered content (uses AppearanceStore when nil).
    var fontSize: CGFloat? = nil

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore

    /// 刚复制的代码块内容——用于定位到具体代码块做视觉反馈（整块轻微
    /// 高斯模糊 + 中央「已复制」气泡）。内容相同的两个块会同时反馈（罕见）。
    @State private var copiedContent: String?

    /// 复制反馈自动复位任务（复制新块 / 视图消失时取消）。
    @State private var copyResetTask: Task<Void, Never>?

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
        Group {
            if isPlainProse, let plain = plainAttributedText {
                // 纯散文：单个 Text(AttributedString)，整条消息一个可选中整体。
                Text(plain)
                    .textSelection(.enabled)
            } else {
                markdownBody
            }
        }
        // Recreate the Markdown subtree when the font size changes so cached
        // inline math images are re-rasterized at the new scale.
        .id("markdown-math-\(effectiveFontSize)")
        // 视图消失时取消复制反馈复位任务（避免残留引用）。
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    // MARK: - Plain-prose path (cross-paragraph text selection)

    /// `true` 时用单个 `Text(AttributedString)` 渲染：内容不含任何会被
    /// `AttributedString(markdown:)` 错误处理的块级语法。
    private var isPlainProse: Bool {
        guard !text.isEmpty else { return true }
        // 含 LaTeX 数学（MathSegmenter 改写过的内容 != 原文）。
        guard rewrittenSource == text else { return false }
        // 含围栏代码块（```）。
        guard !text.contains("```") else { return false }
        // 含图片。
        guard !text.contains("![") else { return false }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // 标题 / 引用块 / 表格 / 主题分隔线 → 回退 MarkdownUI。
            if trimmed.hasPrefix("#") { return false }
            if trimmed.hasPrefix(">") { return false }
            if line.filter({ $0 == "|" }).count >= 2 { return false }
            if trimmed.filter({ $0 == "-" }).count >= 3
                && trimmed.allSatisfy({ $0 == "-" }) { return false }
        }
        return true
    }

    /// 纯散文路径的富文本：与界面字体预设 / 字号一致，行内代码用等宽小号字。
    private var plainAttributedText: AttributedString? {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        ) else { return nil }

        var result = parsed
        let base = appearance.fontPreset.font(size: effectiveFontSize)
        for run in result.runs {
            var container = AttributeContainer()
            let intent = run.inlinePresentationIntent
            if intent?.contains(.code) == true {
                container.font = .system(size: effectiveFontSize * 0.9,
                                         design: .monospaced)
                container.foregroundColor = inlineCodeTextColor
            } else {
                var font = base
                if intent?.contains(.stronglyEmphasized) == true { font = font.bold() }
                if intent?.contains(.emphasized) == true { font = font.italic() }
                container.font = font
            }
            result[run.range].mergeAttributes(container)
        }
        return result
    }

    // MARK: - Rich markdown path (MarkdownUI)

    private var markdownBody: some View {
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
        .markdownCodeSyntaxHighlighter(ThemeCodeSyntaxHighlighter())
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
        // Fenced code blocks: dark card (Claude-style) with a language bar and
        // copy button; content is syntax-highlighted via ThemeCodeSyntaxHighlighter.
        .markdownBlockStyle(\.codeBlock) { configuration in
            // 复制反馈：只对刚复制的那一块生效。
            let isCopied = copiedContent == configuration.content
            VStack(spacing: 0) {
                HStack {
                    Text(configuration.language ?? "text")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x9A9A96))
                    Spacer()
                    Button {
                        copyCode(configuration.content)
                    } label: {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(minWidth: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isCopied ? Color.green : Color(hex: 0x9A9A96))
                    .help(L(isCopied ? "codeblock.copied" : "msg.copy"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(hex: 0x212120))

                Divider()
                    .overlay(Color(hex: 0x3A3A36))

                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.88))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .background(AppearanceStore.claudeCodeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // 复制反馈：整块轻微高斯模糊（overlay 在 blur 之后，气泡保持清晰）。
            .blur(radius: isCopied ? 2.5 : 0)
            .animation(.easeOut(duration: 0.18), value: isCopied)
            .overlay {
                if isCopied {
                    Label(L("codeblock.copied"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .markdownMargin(top: .em(0.6), bottom: .em(0.6))
        }
        .markdownBlockStyle(\.table) { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.5))
        }
        .textSelection(.enabled)
    }

    /// The markdown source with every LaTeX span swapped for a math image URL.
    private var rewrittenSource: String {
        MathSegmenter.rewrite(text)
    }

    /// 复制代码块并触发「整块高斯模糊 + 已复制气泡」反馈，1 秒后自动复原。
    private func copyCode(_ string: String) {
        Self.copyToClipboard(string)

        // 取消上一次的复位，连续复制多个块时反馈不闪烁。
        copyResetTask?.cancel()

        withAnimation(.easeOut(duration: 0.15)) {
            copiedContent = string
        }

        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                copiedContent = nil
            }
        }
    }

    /// Copies the raw code-block source to the pasteboard (code card button).
    private static func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

