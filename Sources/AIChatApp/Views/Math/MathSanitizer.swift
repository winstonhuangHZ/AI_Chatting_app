import Foundation

/// Normalizes LLM-generated LaTeX so the bundled SwiftMath (iosMath) engine can
/// parse it.
///
/// The upstream iosMath engine only knows a subset of TeX. Real model output
/// frequently uses commands it rejects — `\dfrac`, `\operatorname`,
/// `\begin{align}`, `\implies`, `\Bigl(` … — so we rewrite those to an
/// equivalent supported form before rendering. Anything that still fails (or
/// that contains CJK glyphs the math font cannot draw) falls back to
/// `MathUnicodeFallback`.
enum MathSanitizer {

    /// Rewrites `latex` into a form SwiftMath can render.
    static func sanitize(_ latex: String) -> String {
        var result = latex
        result = stripComments(result)
        result = rewriteEnvironments(result)
        result = applyCommandRewrites(result)
        return result
    }

    /// True when the expression contains characters whose script the bundled
    /// math fonts cannot draw (CJK, Arabic, …). Rendering those would produce
    /// tofu boxes, so the caller should use the plain-text fallback instead.
    ///
    /// (Latin Modern Math only covers Latin / Greek / Cyrillic-range math
    /// glyphs. `Unicode.Scalar.Properties.script` is not available on this
    /// SDK, so unsupported scripts are detected by their scalar ranges.)
    static func containsUnsupportedScript(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            let code = scalar.value
            let unsupported: Bool =
                // CJK Unified Ideographs + Extension A/B + Compatibility
                (0x3400...0x4DBF).contains(code)
                || (0x4E00...0x9FFF).contains(code)
                || (0xF900...0xFAFF).contains(code)
                || (0x20000...0x2FA1F).contains(code)
                // Hiragana / Katakana
                || (0x3040...0x30FF).contains(code)
                || (0x31F0...0x31FF).contains(code)
                || (0x1B000...0x1B16F).contains(code)
                // Hangul
                || (0x1100...0x11FF).contains(code)
                || (0xA960...0xA97F).contains(code)
                || (0xAC00...0xD7AF).contains(code)
                || (0xD7B0...0xD7FF).contains(code)
                // Arabic
                || (0x0600...0x06FF).contains(code)
                || (0x0750...0x077F).contains(code)
                || (0x08A0...0x08FF).contains(code)
                // Hebrew
                || (0x0590...0x05FF).contains(code)
                // Thai / Lao / Myanmar / Khmer
                || (0x0E00...0x0E7F).contains(code)
                || (0x0E80...0x0EFF).contains(code)
                || (0x1000...0x109F).contains(code)
                || (0x1780...0x17FF).contains(code)
                // Indic scripts
                || (0x0900...0x097F).contains(code)   // Devanagari
                || (0x0980...0x09FF).contains(code)   // Bengali
                || (0x0A00...0x0A7F).contains(code)   // Gurmukhi
                || (0x0A80...0x0AFF).contains(code)   // Gujarati
                || (0x0B00...0x0B7F).contains(code)   // Oriya
                || (0x0B80...0x0BFF).contains(code)   // Tamil
                || (0x0C00...0x0C7F).contains(code)   // Telugu
                || (0x0C80...0x0CFF).contains(code)   // Kannada
                || (0x0D00...0x0D7F).contains(code)   // Malayalam
                || (0x0D80...0x0DFF).contains(code)   // Sinhala
                // Georgian / Armenian
                || (0x10A0...0x10FF).contains(code)
                || (0x0530...0x058F).contains(code)
                // Fullwidth forms
                || (0xFF00...0xFFEF).contains(code)
            if unsupported { return true }
        }
        return false
    }

    // MARK: - Comments

    /// Drops TeX comments (`%` up to end of line), honoring `\%` escapes.
    private static func stripComments(_ string: String) -> String {
        let chars = Array(string)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                out.append(chars[i])
                if i + 1 < chars.count {
                    out.append(chars[i + 1])
                    i += 1
                }
            } else if chars[i] == "%" {
                while i < chars.count, chars[i] != "\n" {
                    i += 1
                }
                continue
            } else {
                out.append(chars[i])
            }
            i += 1
        }
        return out
    }

    // MARK: - Environments

    /// Maps environment names SwiftMath does not know to supported ones.
    private static let environmentAliases: [String: String] = [
        "align": "aligned",
        "align*": "aligned",
        "alignat": "aligned",
        "alignat*": "aligned",
        "flalign": "aligned",
        "flalign*": "aligned",
        "multline": "aligned",
        "multline*": "aligned",
        "gathered": "gather",
        "smallmatrix": "matrix",
        "array": "matrix",
        "dcases": "cases",
        "dcases*": "cases",
        "rcases": "cases",
        "rcases*": "cases",
        "equation": "matrix",
        "equation*": "matrix",
        "displaymath": "matrix",
        "math": "matrix",
    ]

    /// Rewrites `\begin{align}…`/`\end{align}` (plus optional `{2}` / `[t]`
    /// arguments) into environments SwiftMath understands.
    private static func rewriteEnvironments(_ string: String) -> String {
        let pattern = #"\\(begin|end)\{([^}]*)\}(\s*(?:\{[^}]*\}|\[[^\]]*\]))*"#
        return replacing(regex: pattern, in: string) { match, full, _ in
            // NSTextCheckingResult ranges are relative to the ORIGINAL input,
            // so translate them before slicing the (much shorter) `full` string.
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                let relative = NSRange(
                    location: range.location - match.range.location,
                    length: range.length
                )
                guard relative.location + relative.length <= (full as NSString).length else { return nil }
                return (full as NSString).substring(with: relative)
            }
            guard let kind = group(1), let name = group(2) else { return full }
            let base = name.hasSuffix("*") ? String(name.dropLast()) : name
            let alias: String?
            if let direct = environmentAliases[name] {
                alias = direct
            } else if let fallback = environmentAliases[base] {
                alias = fallback
            } else {
                alias = nil
            }
            if let alias {
                return "\\\(kind){\(alias)}"
            }
            return full
        }
    }


    // MARK: - Command rewrites

    /// Ordered list of (regex, replacement) pairs. `$1`/`$2` capture groups
    /// are preserved through `replacing(regex:in:)`.
    private static let commandRewrites: [(String, String)] = [
        // --- fraction aliases ---
        (#"\\(dfrac|tfrac)\b"#, #"\frac"#),

        // --- function / operator names ---
        (#"\\operatorname\*?\{([^{}]*)\}"#, #"\mathrm{$1}"#),
        (#"\\operatorname\*?"#, ""),
        (#"\\argmax\b"#, #"\mathrm{argmax}"#),
        (#"\\argmin\b"#, #"\mathrm{argmin}"#),
        (#"\\(arg|max|min)\\{1,2}(?:argmax|argmin|max|min)"#, #"\mathrm{$1}"#),

        // --- font families ---
        (#"\\boxed\{([^{}]*)\}"#, #"\left[ $1 \right]"#),
        (#"\\(mathfrak|mathscr|mathds)\{([^{}]*)\}"#, #"$2"#),
        (#"\\boldsymbol\{([^{}]*)\}"#, #"\mathbf{$1}"#),
        (#"\\bm\{([^{}]*)\}"#, #"\mathbf{$1}"#),
        (#"\\textnormal\*?\{([^{}]*)\}"#, #"\text{$1}"#),
        (#"\\textrm\{([^{}]*)\}"#, #"\text{$1}"#),
        (#"\\textsf\*?\{([^{}]*)\}"#, #"\text{$1}"#),
        (#"\\texttt\*?\{([^{}]*)\}"#, #"\text{$1}"#),
        (#"\\textsc\*?\{([^{}]*)\}"#, #"\text{$1}"#),
        (#"\\textup\*?\{([^{}]*)\}"#, #"\text{$1}"#),

        // --- decorations ---
        (#"\\overrightarrow\{([^{}]*)\}"#, #"\vec{$1}"#),
        (#"\\overleftarrow\{([^{}]*)\}"#, #"\vec{$1}"#),
        (#"\\overleftrightarrow\{([^{}]*)\}"#, #"\vec{$1}"#),
        (#"\\underbrace\{([^{}]*)\}"#, #"\underline{$1}"#),
        (#"\\overbrace\{([^{}]*)\}"#, #"\overline{$1}"#),
        (#"\\substack\{([^{}]*)\}"#, #"\begin{matrix}$1\end{matrix}"#),
        (#"\\stackrel\{([^{}]*)\}\{([^{}]*)\}"#, #"$2^{$1}"#),
        (#"\\overset\{([^{}]*)\}\{([^{}]*)\}"#, #"$2^{$1}"#),
        (#"\\underset\{([^{}]*)\}\{([^{}]*)\}"#, #"$2_{$1}"#),

        // --- arrows ---
        (#"\\xrightarrow\[[^\]]*\]\{[^{}]*\}"#, #"\rightarrow"#),
        (#"\\xrightarrow\{[^{}]*\}"#, #"\rightarrow"#),
        (#"\\xrightarrow\b"#, #"\rightarrow"#),
        (#"\\xleftarrow\[[^\]]*\]\{[^{}]*\}"#, #"\leftarrow"#),
        (#"\\xleftarrow\{[^{}]*\}"#, #"\leftarrow"#),
        (#"\\xleftarrow\b"#, #"\leftarrow"#),
        (#"\\implies\b"#, #"\Longrightarrow"#),
        (#"\\impliedby\b"#, #"\Longleftarrow"#),
        (#"\\iff\b"#, #"\Longleftrightarrow"#),

        // --- dots ---
        (#"\\dots[a-z]*\b"#, #"\cdots"#),
        (#"\\ldots\b"#, #"\cdots"#),

        // --- delimiters ---
        (#"\\(?:lVert|rVert|Vert)\b"#, #"\|"#),
        (#"\\lbrace\b"#, #"\{"#),
        (#"\\rbrace\b"#, #"\}"#),
        (#"\\lbrack\b"#, #"["#),
        (#"\\rbrack\b"#, #"]"#),
        (#"\\colon\b"#, #":"#),
        (#"\\(?:Bigl|bigl|Biggl|biggl)\{?([()\[\]{}|.])\}?"#, #"\left$1"#),
        (#"\\(?:Bigr|bigr|Biggr|biggr)\{?([()\[\]{}|.])\}?"#, #"\right$1"#),
        (#"\\(?:big|Big|bigg|Bigg)(?=[()\[\]{}|.])"#, ""),
        (#"\\(?:big|Big|bigg|Bigg)\b"#, ""),

        // --- modulo ---
        (#"\\pmod\{([^{}]*)\}"#, #"\;(\mathrm{mod} $1)"#),
        (#"\\bmod\b"#, #"\mathrm{mod}"#),
        (#"\\mod\b"#, #"\mathrm{mod}"#),

        // --- symbols ---
        (#"\\varnothing\b"#, #"\emptyset"#),
        (#"\\iint\b"#, #"\int\!\!\int"#),
        (#"\\iiint\b"#, #"\int\!\!\int\!\!\int"#),
        (#"\\oiint\b"#, #"\oint\!\!\oint"#),
        (#"\\not="#, #"\neq"#),
        (#"\\(?:le)\b"#, #"\leq"#),
        (#"\\(?:ge)\b"#, #"\geq"#),
        (#"\\(?:ne)\b"#, #"\neq"#),

        // --- spacing / misc ---
        (#"\\hspace\*?\{[^{}]*\}"#, #"\quad"#),
        (#"\\vspace\*?\{[^{}]*\}"#, #"\quad"#),
        (#"\\hfill\b"#, #"\quad"#),
        (#"\\enspace\b"#, #"\,"#),
        (#"\\medspace\b"#, #"\,"#),
        (#"\\thinspace\b"#, #"\,"#),
        (#"\\negthinspace\b"#, #"\,"#),
        (#"\\negmedspace\b"#, #"\,"#),
        (#"\\negthickspace\b"#, #"\,"#),
        (#"\\newline\b"#, #"\\"#),
        // `\ ` (backslash + space) → `\quad`. Negative lookbehind keeps the
        // row-break `\\` (two backslashes) from being mangled.
        (##"(?<!\\)\\ "##, #"\quad"#),
        (#"\\phantom\{[^{}]*\}"#, ""),
        (#"\\hphantom\{[^{}]*\}"#, ""),
        (#"\\vphantom\{[^{}]*\}"#, ""),
        (#"\\smash\{[^{}]*\}"#, ""),
        (#"\\hbox\{([^{}]*)\}"#, #"$1"#),
        (#"\\mbox\{([^{}]*)\}"#, #"$1"#),
        (#"\\cancel\{([^{}]*)\}"#, #"$1"#),
        (#"\\bcancel\{([^{}]*)\}"#, #"$1"#),

        // --- tags / labels / numbering ---
        (#"\\tag\*?\{[^{}]*\}"#, ""),
        (#"\\label\{[^{}]*\}"#, ""),
        (#"\\ref\{[^{}]*\}"#, ""),
        (#"\\eqref\{[^{}]*\}"#, ""),
        (#"\\nonumber\b"#, ""),
        (#"\\notag\b"#, ""),

        // --- escapes SwiftMath rejects ---
        (##"\\#\b"##, "#"),
    ]

    private static func applyCommandRewrites(_ string: String) -> String {
        var result = string
        for (pattern, template) in commandRewrites {
            result = replacing(regex: pattern, in: result) { match, _, original in
                expand(template, match: match, in: original)
            }
        }
        return result
    }

    /// Expands `$1` / `$2` … capture-group references in a template using the
    /// actual captured substrings (relative to the original NSString).
    private static func expand(
        _ template: String,
        match: NSTextCheckingResult,
        in original: NSString
    ) -> String {
        var result = template
        for index in (1..<match.numberOfRanges).reversed() {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { continue }
            let captured = original.substring(with: range)
            result = result.replacingOccurrences(of: "$\(index)", with: captured)
        }
        return result
    }

    // MARK: - Regex helper

    /// Replaces every match of `regex` in `input`. `transform` receives the
    /// `NSTextCheckingResult`, the full matched string, and the original
    /// NSString, and returns the replacement (or `nil` to keep the original).
    private static func replacing(
        regex: String,
        in input: String,
        _ transform: @escaping (NSTextCheckingResult, String, NSString) -> String?
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: regex) else {
            return input
        }
        let ns = input as NSString
        var result = ""
        var cursor = 0
        let range = NSRange(location: 0, length: ns.length)
        for match in expression.matches(in: input, options: [], range: range) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let full = ns.substring(with: match.range)
            if let replacement = transform(match, full, ns) {
                result += replacement
            } else {
                result += full
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

