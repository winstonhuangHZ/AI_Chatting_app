import Foundation

/// Rewrites assistant markdown so LaTeX math survives MarkdownUI's parser.
///
/// The CommonMark parser aggressively mangles raw LaTeX: `$a_1$` becomes an
/// emphasis with an unmatched `_`, `\frac{1}{2}` keeps its backslashes but
/// turns braces into table-cell-like markup, etc. This segmenter finds math
/// spans *before* parsing and swaps them for custom `aichatmath://` image URLs:
///
///   - `$...$` / `\(...\)`      → inline image  `![](aichatmath://inline/...)`
///   - `$$...$$` / `\[...\]` /
///     `\begin{env}...\end{env}` → block image  `![](aichatmath://display/...)`
///
/// Spans that cannot be rendered (CJK text inside math, unsupported syntax)
/// are converted to a readable Unicode approximation as plain text instead of
/// leaving broken LaTeX in the bubble.
///
/// Fenced code blocks and inline code spans are left completely untouched.
enum MathSegmenter {

    static func rewrite(_ markdown: String) -> String {
        let chars = Array(markdown)
        var out = ""
        var i = 0
        var fence: Character? = nil

        while i < chars.count {
            // ---- fenced code blocks ----
            if fence == nil {
                if let marker = fenceMarker(chars, at: i) {
                    fence = marker
                    copyThroughNewline(chars, &i, &out)
                    continue
                }
            } else {
                if let marker = fenceMarker(chars, at: i), marker == fence {
                    fence = nil
                    copyThroughNewline(chars, &i, &out)
                    continue
                }
                out.append(chars[i])
                i += 1
                continue
            }

            // ---- inline code spans ----
            if chars[i] == "`" {
                let run = backtickRun(chars, at: i)
                var j = i + run
                var closed = false
                while j + run <= chars.count {
                    if chars[j] == "`", backtickRun(chars, at: j) == run {
                        closed = true
                        break
                    }
                    j += 1
                }
                if closed {
                    while i < j + run { out.append(chars[i]); i += 1 }
                    continue
                }
                out.append(chars[i])
                i += 1
                continue
            }

            // ---- backslash-prefixed constructs ----
            if chars[i] == "\\" {
                // `\[ ... \]` block math
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    if let end = findDelimiter(chars, "\\]", from: i + 2), end > i + 2 {
                        let content = String(chars[i + 2..<end])
                        out.append(blockReplacement(for: content))
                        i = end + 2
                        continue
                    }
                }
                // `\( ... \)` inline math
                if i + 1 < chars.count, chars[i + 1] == "(" {
                    if let end = findDelimiter(chars, "\\)", from: i + 2), end > i + 2 {
                        let content = String(chars[i + 2..<end])
                        out.append(replacement(for: content, isDisplay: false))
                        i = end + 2
                        continue
                    }
                }
                // `\begin{env} ... \end{env}` block math
                if starts(with: "\\begin{", chars, at: i) {
                    var nameEnd = i + 7
                    while nameEnd < chars.count, chars[nameEnd] != "}" { nameEnd += 1 }
                    if nameEnd < chars.count {
                        let envName = String(chars[i + 7..<nameEnd])
                        let endMarker = "\\end{" + envName + "}"
                        if let end = findDelimiter(chars, endMarker, from: nameEnd + 1),
                           end > nameEnd + 1 {
                            let content = String(chars[nameEnd + 1..<end])
                            out.append(blockReplacement(for: content))
                            i = end + endMarker.count
                            continue
                        }
                    }
                }
                // `\$` escaped dollar sign
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    out.append("\\$")
                    i += 2
                    continue
                }
                out.append(chars[i])
                i += 1
                continue
            }

            // ---- dollar-sign math ----
            if chars[i] == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = findDoubleDollarEnd(chars, from: i + 2), end > i + 2 {
                        let content = String(chars[i + 2..<end])
                        out.append(blockReplacement(for: content))
                        i = end + 2
                        continue
                    }
                } else if let end = findSingleDollarEnd(chars, from: i + 1) {
                    let content = String(chars[i + 1..<end])
                    if isValidInlineMath(content) {
                        out.append(replacement(for: content, isDisplay: false))
                        i = end + 1
                        continue
                    }
                }
                out.append(chars[i])
                i += 1
                continue
            }

            out.append(chars[i])
            i += 1
        }
        return out
    }


    // MARK: - Character scanning helpers

    private static func findDelimiter(_ chars: [Character], _ marker: String, from start: Int) -> Int? {
        let m = Array(marker)
        guard !m.isEmpty else { return nil }
        var j = start
        while j + m.count <= chars.count {
            if String(chars[j..<j + m.count]) == marker { return j }
            j += 1
        }
        return nil
    }

    private static func starts(with marker: String, _ chars: [Character], at i: Int) -> Bool {
        let m = Array(marker)
        guard i + m.count <= chars.count else { return false }
        return String(chars[i..<i + m.count]) == marker
    }

    /// Detects a CommonMark fence opener/closer at `i` (line start, ≥3 backticks or tildes).
    private static func fenceMarker(_ chars: [Character], at i: Int) -> Character? {
        if i > 0, chars[i - 1] != "\n" { return nil }
        guard chars[i] == "`" || chars[i] == "~" else { return nil }
        let marker = chars[i]
        var j = i
        while j < chars.count, chars[j] == marker { j += 1 }
        guard j - i >= 3 else { return nil }
        return marker
    }

    private static func backtickRun(_ chars: [Character], at i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] == "`" { j += 1 }
        return j - i
    }

    private static func copyThroughNewline(_ chars: [Character], _ i: inout Int, _ out: inout String) {
        while i < chars.count, chars[i] != "\n" {
            out.append(chars[i])
            i += 1
        }
    }

    // MARK: - Replacement

    /// Produces the placeholder for `content`: either an image link or, when
    /// SwiftMath cannot handle it, an escaped Unicode approximation.
    private static func replacement(for content: String, isDisplay: Bool) -> String {
        let sanitized = MathSanitizer.sanitize(content)

        if MathSanitizer.containsUnsupportedScript(sanitized) || !MathRenderer.shared.canRender(sanitized) {
            return MathUnicodeFallback.fallback(content).markdownEscaped
        }
        guard let url = MathCoding.imageURLString(
            host: isDisplay ? MathCoding.displayHost : MathCoding.inlineHost,
            latex: sanitized
        ) else {
            return MathUnicodeFallback.fallback(content).markdownEscaped
        }
        return "![](\(url))"
    }

    /// Block math that spans multiple lines is surrounded by blank lines so it
    /// becomes its own Markdown paragraph (a standalone block image).
    private static func blockReplacement(for content: String) -> String {
        let placeholder = replacement(for: content, isDisplay: true)
        if content.contains("\n") {
            return "\n\n" + placeholder + "\n\n"
        }
        return placeholder
    }

    // MARK: - `$` heuristics

    private static func isValidInlineMath(_ content: String) -> Bool {
        guard !content.isEmpty, content.count <= 400 else { return false }
        guard !content.contains("\n"), !content.contains("$") else { return false }
        guard let first = content.first, let last = content.last else { return false }
        // `$ x$` / `$x $` are almost never math.
        guard !first.isWhitespace, !last.isWhitespace else { return false }
        // `$5.99` is a price, not math.
        guard !first.isNumber else { return false }
        return true
    }

    private static func findSingleDollarEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "$", j == 0 || chars[j - 1] != "\\" { return j }
            j += 1
        }
        return nil
    }

    private static func findDoubleDollarEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "$", chars[j + 1] == "$", j == 0 || chars[j - 1] != "\\" {
                return j
            }
            j += 1
        }
        return nil
    }
}

// MARK: - Markdown escaping

extension String {
    /// Escapes every ASCII punctuation character so the string renders as
    /// literal plain text when embedded in Markdown (e.g. Unicode math
    /// fallbacks that must not become emphasis, links, tables, …).
    var markdownEscaped: String {
        var out = ""
        for scalar in unicodeScalars {
            if scalar.value < 128, isASCIIPunctuation(scalar) {
                out.append("\\")
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        return (33...47).contains(code) || (58...64).contains(code)
            || (91...96).contains(code) || (123...126).contains(code)
    }
}

