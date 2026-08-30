import Foundation

/// Converts LaTeX into a readable plain-text approximation for cases the
/// bundled math engine cannot handle: CJK inside math (`\text{速度}`), exotic
/// commands, or syntax that fails to parse.
///
/// This is deliberately simple: `\frac{a}{b}` → `(a)/(b)`, `\sqrt{x}` → `√(x)`,
/// Greek letters and common operators become Unicode, and unknown commands are
/// stripped. The result is never pretty, but it is always readable.
enum MathUnicodeFallback {

    static func fallback(_ latex: String) -> String {
        var scanner = Scanner(Array(latex))
        let rendered = render(&scanner)
        return cleanup(rendered)
    }

    // MARK: - Symbol tables

    private static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ",
        "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // binary operators / relations
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "ast": "∗",
        "star": "⋆", "circ": "∘", "bullet": "•", "oplus": "⊕", "otimes": "⊗",
        "ominus": "⊖", "oslash": "⊘", "odot": "⊙", "wedge": "∧", "vee": "∨",
        "cap": "∩", "cup": "∪", "sqcap": "⊓", "sqcup": "⊔", "uplus": "⊎",
        "setminus": "∖", "triangleleft": "◁", "triangleright": "▷",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡",
        "propto": "∝", "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰",
        "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃", "subseteq": "⊆",
        "supseteq": "⊇", "subsetneq": "⊊", "supsetneq": "⊋", "in": "∈",
        "notin": "∉", "ni": "∋", "mid": "∣", "nmid": "∤", "parallel": "∥",
        "perp": "⊥", "models": "⊨", "vdash": "⊢", "dashv": "⊣", "bowtie": "⋈",
        // arrows
        "leftarrow": "←", "rightarrow": "→", "leftrightarrow": "↔",
        "Leftarrow": "⇐", "Rightarrow": "⇒", "Leftrightarrow": "⇔",
        "mapsto": "↦", "hookleftarrow": "↩", "hookrightarrow": "↪",
        "leftharpoonup": "↼", "rightharpoonup": "⇀", "uparrow": "↑",
        "downarrow": "↓", "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓",
        "Longleftarrow": "⟸", "Longrightarrow": "⟹", "Longleftrightarrow": "⟺",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "to": "→", "gets": "←",
        "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
        // miscellaneous
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "Σ", "prod": "∏",
        "coprod": "∐", "int": "∫", "oint": "∮", "iint": "∬", "iiint": "∭",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "land": "∧", "lor": "∨", "emptyset": "∅", "varnothing": "∅",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "wp": "℘", "angle": "∠", "triangle": "△", "square": "□", "Diamond": "◇",
        "clubsuit": "♣", "diamondsuit": "♦", "heartsuit": "♥", "spadesuit": "♠",
        "top": "⊤", "bot": "⊥", "prime": "′", "degree": "°",
        "dots": "…", "cdots": "…", "ldots": "…", "vdots": "⋮", "ddots": "⋱",
        "checkmark": "✓", "surd": "√", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "langle": "⟨", "rangle": "⟩",
        "asymp": "≍", "doteq": "≐", "smile": "⌣", "frown": "⌢",
    ]

    // MARK: - Scanner

    private struct Scanner {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        /// Reads `{...}` (nesting-aware); advances past it on success.
        mutating func group() -> String? {
            guard i < chars.count, chars[i] == "{" else { return nil }
            var depth = 1
            var j = i + 1
            let start = j
            while j < chars.count, depth > 0 {
                if chars[j] == "{" { depth += 1 }
                else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard depth == 0 else { i = chars.count; return nil }
            let content = String(chars[start..<j])
            i = j + 1
            return content
        }

        /// Reads `[...]` (optional argument); advances past it on success.
        mutating func optGroup() -> String? {
            guard i < chars.count, chars[i] == "[" else { return nil }
            var j = i + 1
            while j < chars.count, chars[j] != "]" { j += 1 }
            guard j < chars.count else { i = chars.count; return nil }
            let content = String(chars[i + 1..<j])
            i = j + 1
            return content
        }

        /// Reads a command name starting at `\`; advances past it (+ optional `*`).
        mutating func commandName() -> String? {
            guard i < chars.count, chars[i] == "\\", i + 1 < chars.count else { return nil }
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j].isLetter {
                name.append(chars[j])
                j += 1
            }
            guard !name.isEmpty else { return nil }
            i = j
            if i < chars.count, chars[i] == "*" { i += 1 }
            return name
        }
    }

    private static let textCommands: Set<String> = [
        "text", "textnormal", "textup", "textrm", "textsf", "texttt", "textsc",
        "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathbb", "mathcal",
        "mathscr", "mathfrak", "boldsymbol", "bm", "operatorname", "mbox", "hbox",
    ]

    private static let dropCommands: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "biggl",
        "biggr", "Bigl", "Bigr", "Biggl", "Biggr",
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
        "limits", "nolimits", "quad", "qquad", "enspace", "thinspace",
        "medspace", "negthinspace", "hfill", "phantom", "vphantom", "hphantom",
        "smash", "nonumber", "notag", "hspace", "vspace", "hskip", "vskip",
        "newline", "centering", "huge", "Huge", "large", "Large", "small",
        "tiny", "footnotesize", "normalsize", "tag", "label", "ref", "eqref",
    ]

    private static let accentCommands: [String: String] = [
        "hat": "^", "widehat": "^", "bar": "-", "overline": "-",
        "underline": "_", "tilde": "~", "widetilde": "~", "vec": "→",
        "dot": "˙", "ddot": "¨", "check": "ˇ", "breve": "˘", "acute": "´",
        "grave": "`", "mathring": "˚",
    ]



    // MARK: - Subscripts / superscripts

    private static let superDigits = "⁰¹²³⁴⁵⁶⁷⁸⁹"
    private static let superLower: [Character: Character] = [
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]
    private static let subLower: [Character: Character] = [
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    static func convertSuperSubscripts(_ string: String) -> String {
        let chars = Array(string)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if (c == "^" || c == "_"), i + 1 < chars.count {
                let isSuper = c == "^"
                var content = ""
                var j = i + 1
                if chars[j] == "{" {
                    var depth = 1
                    j += 1
                    let start = j
                    while j < chars.count, depth > 0 {
                        if chars[j] == "{" { depth += 1 }
                        else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                        j += 1
                    }
                    content = String(chars[start..<min(j, chars.count)])
                    j = min(j + 1, chars.count)
                } else {
                    content = String(chars[j])
                    j += 1
                }
                out.append(isSuper ? superScript(content) : subScript(content))
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    private static func superScript(_ s: String) -> String {
        var out = ""
        var allConverted = true
        for ch in s {
            if let digit = ch.wholeNumberValue, digit < 10 {
                out.append(Array(superDigits)[digit])
            } else if let mapped = superLower[ch] {
                out.append(mapped)
            } else {
                out.append(ch)
                allConverted = false
            }
        }
        return allConverted ? out : "^(\(s))"
    }

    private static func subScript(_ s: String) -> String {
        var out = ""
        var allConverted = true
        for ch in s {
            if let digit = ch.wholeNumberValue, digit < 10 {
                out.append(Array("₀₁₂₃₄₅₆₇₈₉")[digit])
            } else if let mapped = subLower[ch] {
                out.append(mapped)
            } else {
                out.append(ch)
                allConverted = false
            }
        }
        return allConverted ? out : "_(\(s))"
    }

    // MARK: - Cleanup

    private static func cleanup(_ string: String) -> String {
        var out = convertSuperSubscripts(string)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "()", with: "")
        out = out.replacingOccurrences(of: "  ", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rendering

    private static func render(_ scanner: inout Scanner) -> String {
        var out = ""
        while scanner.i < scanner.chars.count {
            let c = scanner.chars[scanner.i]
            if c == "\\" {
                // Escaped literal characters: `\`, `{`, `}`, `(`, `)`, `%`, …
                if scanner.i + 1 < scanner.chars.count,
                   "()[]{}$%#_&|;,!:.~'`".contains(scanner.chars[scanner.i + 1]) {
                    out.append(scanner.chars[scanner.i + 1])
                    scanner.i += 2
                    continue
                }
                guard let name = scanner.commandName() else {
                    scanner.i += 1
                    continue
                }
                if let mapped = symbols[name] {
                    out.append(mapped)
                    continue
                }
                if name == "frac" || name == "dfrac" || name == "tfrac" {
                    if let num = scanner.group(), let den = scanner.group() {
                        out.append("(\(inner(num)))/(\(inner(den)))")
                    }
                    continue
                }
                if name == "binom" || name == "choose" {
                    if let top = scanner.group(), let bottom = scanner.group() {
                        out.append("C(\(inner(top)),\(inner(bottom)))")
                    }
                    continue
                }
                if name == "sqrt" {
                    let root = scanner.optGroup()
                    if let body = scanner.group() {
                        let radical: String
                        switch root {
                        case "3": radical = "∛"
                        case "4": radical = "∜"
                        default: radical = "√"
                        }
                        out.append(radical + "(\(inner(body)))")
                    }
                    continue
                }
                if textCommands.contains(name) {
                    if let innerGroup = scanner.group() {
                        out.append(inner(innerGroup))
                    }
                    continue
                }
                if name == "begin" || name == "end" {
                    _ = scanner.group()
                    continue
                }
                if name == "overset" || name == "underset" || name == "stackrel" {
                    _ = scanner.group()   // stack content
                    if let base = scanner.group() { out.append(inner(base)) }
                    continue
                }
                if name == "substack" {
                    if let g = scanner.group() {
                        out.append(g.replacingOccurrences(of: "\\\\", with: "; "))
                    }
                    continue
                }
                if name == "underbrace" || name == "overbrace" {
                    if let g = scanner.group() { out.append(inner(g)) }
                    continue
                }
                if dropCommands.contains(name) {
                    if name == "left" || name == "right" {
                        if scanner.i < scanner.chars.count {
                            if scanner.chars[scanner.i] == "\\" {
                                _ = scanner.commandName()
                                _ = scanner.group()
                            } else {
                                scanner.i += 1
                            }
                        }
                    } else {
                        _ = scanner.group()
                    }
                    continue
                }
                if let accent = accentCommands[name] {
                    if let g = scanner.group() {
                        out.append("\(inner(g))\(accent)")
                    }
                    continue
                }
                // Unknown command: keep a braced argument if present.
                if let g = scanner.group() {
                    out.append(inner(g))
                }
                continue
            }
            out.append(c)
            scanner.i += 1
        }
        return out
    }

    /// Renders a group's content in a fresh scanner.
    private static func inner(_ string: String) -> String {
        var scanner = Scanner(Array(string))
        return render(&scanner)
    }
}

