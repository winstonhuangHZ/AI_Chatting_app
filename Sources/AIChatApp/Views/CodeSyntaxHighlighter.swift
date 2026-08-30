import SwiftUI
import MarkdownUI

// MARK: - Zero-dependency syntax highlighter

/// Lightweight, zero-dependency syntax highlighter for fenced code blocks.
///
/// Tokenizes comments / strings / numbers / keywords and colors them on the
/// dark `#262624` code card. Colors follow the Claude palette (clay keyword,
/// soft green strings, muted comments) and work on every theme.
struct ThemeCodeSyntaxHighlighter: CodeSyntaxHighlighter {

    func highlightCode(_ content: String, language: String?) -> Text {
        Text(Self.attributedCode(content, language: language))
    }

    // MARK: - Token model

    private struct Token {
        let text: String
        let color: Color
    }

    private enum Palette {
        static let plain = Color(hex: 0xECECE9)
        static let keyword = Color(hex: 0xD97757)
        static let string = Color(hex: 0xA8C686)
        static let comment = Color(hex: 0x8A8A86)
        static let number = Color(hex: 0xD8A657)
    }

    /// Languages where `#` starts a comment (would false-positive in C).
    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "bash", "sh", "shell", "zsh", "yaml", "yml",
        "sql", "ruby", "rb", "php", "makefile",
    ]

    private static func attributedCode(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for token in tokenize(code, language: language) {
            var part = AttributedString(token.text)
            part.foregroundColor = token.color
            result += part
        }
        return result
    }

    // MARK: - Tokenizing

    private static func tokenize(_ code: String, language: String?) -> [Token] {
        let lang = (language ?? "").lowercased()
        let keywords = keywordSet(for: lang)

        let stringPattern = #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`"#
        let commentPattern = #"//[^\n]*|/\*.*?\*/|<!--.*?-->"#
        let numberPattern = #"\b\d+(?:\.\d+)?\b"#
        let hashPattern = #"#[^\n]*"#

        // Alternation order matters: strings first, then comments, then numbers.
        var groups: [(String, Color)] = [
            (stringPattern, Palette.string),
            (commentPattern, Palette.comment),
            (numberPattern, Palette.number),
        ]
        if hashCommentLanguages.contains(lang) {
            groups.insert((hashPattern, Palette.comment), at: 1)
        }
        let pattern = groups.map { "(" + $0.0 + ")" }.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])

        var tokens: [Token] = []
        let nsRange = NSRange(code.startIndex..<code.endIndex, in: code)
        let matches = regex.matches(in: code, options: [], range: nsRange)

        var cursor = code.startIndex
        for match in matches {
            guard let range = Range(match.range, in: code) else { continue }
            if range.lowerBound > cursor {
                tokens.append(contentsOf: keywordSplit(
                    String(code[cursor..<range.lowerBound]),
                    keywords: keywords
                ))
            }
            var color = Palette.plain
            for (index, group) in groups.enumerated()
            where match.range(at: index + 1).location != NSNotFound {
                color = group.1
                break
            }
            tokens.append(Token(text: String(code[range]), color: color))
            cursor = range.upperBound
        }
        if cursor < code.endIndex {
            tokens.append(contentsOf: keywordSplit(String(code[cursor...]), keywords: keywords))
        }
        return tokens
    }

    private static func keywordSplit(_ text: String, keywords: Set<String>) -> [Token] {
        guard !keywords.isEmpty else {
            return [Token(text: text, color: Palette.plain)]
        }
        let pattern = "\\b(?:" + keywords.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")\\b"
        let regex = try! NSRegularExpression(pattern: pattern)

        var tokens: [Token] = []
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var cursor = text.startIndex
        for match in regex.matches(in: text, options: [], range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            if range.lowerBound > cursor {
                tokens.append(Token(text: String(text[cursor..<range.lowerBound]), color: Palette.plain))
            }
            tokens.append(Token(text: String(text[range]), color: Palette.keyword))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            tokens.append(Token(text: String(text[cursor...]), color: Palette.plain))
        }
        return tokens
    }

    // MARK: - Keyword tables
    private static func keywordSet(for language: String) -> Set<String> {
        switch language {
        case "swift":
            return Set(["let", "var", "func", "return", "if", "else", "guard", "for",
                        "while", "repeat", "switch", "case", "default", "break",
                        "continue", "fallthrough", "class", "struct", "enum", "protocol",
                        "extension", "import", "init", "deinit", "self", "super", "nil",
                        "true", "false", "in", "where", "as", "is", "try", "catch",
                        "throw", "throws", "async", "await", "actor", "private", "public",
                        "internal", "fileprivate", "open", "static", "final", "override",
                        "weak", "unowned", "defer", "typealias", "associatedtype"])
        case "python", "py":
            return Set(["def", "return", "if", "elif", "else", "for", "while", "in",
                        "not", "and", "or", "import", "from", "class", "try", "except",
                        "finally", "with", "as", "pass", "break", "continue", "None",
                        "True", "False", "lambda", "global", "nonlocal", "yield",
                        "assert", "del", "is", "raise", "self", "async", "await"])
        case "javascript", "js", "javascriptreact", "typescript", "ts", "tsx", "jsx":
            return Set(["function", "return", "if", "else", "for", "while", "switch",
                        "case", "break", "continue", "const", "let", "var", "class",
                        "extends", "new", "import", "export", "default", "from", "try",
                        "catch", "finally", "throw", "async", "await", "yield", "typeof",
                        "instanceof", "this", "super", "null", "undefined", "true",
                        "false", "interface", "type", "enum", "namespace", "declare",
                        "public", "private", "protected", "readonly", "static", "void"])
        case "java":
            return Set(["public", "private", "protected", "static", "final", "void",
                        "int", "long", "double", "float", "boolean", "char", "byte",
                        "short", "String", "class", "interface", "extends", "implements",
                        "return", "if", "else", "for", "while", "switch", "case",
                        "break", "continue", "new", "try", "catch", "finally", "throw",
                        "throws", "import", "package", "this", "super", "null", "true",
                        "false", "abstract", "volatile", "synchronized"])

        case "c", "cpp", "c++", "objectivec", "objc":
            return Set(["int", "char", "float", "double", "void", "long", "short",
                        "unsigned", "signed", "const", "static", "extern", "return",
                        "if", "else", "for", "while", "switch", "case", "break",
                        "continue", "new", "delete", "class", "struct", "enum", "union",
                        "namespace", "using", "typedef", "define", "include", "pragma",
                        "try", "catch", "throw", "public", "private", "protected",
                        "virtual", "override", "template", "typename", "true", "false",
                        "this", "nullptr", "NULL"])
        case "go", "golang":
            return Set(["package", "import", "func", "var", "const", "type", "struct",
                        "interface", "map", "chan", "go", "defer", "return", "if",
                        "else", "for", "range", "switch", "case", "break", "continue",
                        "select", "default", "fallthrough", "true", "false", "nil"])
        case "rust", "rs":
            return Set(["fn", "let", "mut", "return", "if", "else", "for", "while",
                        "loop", "match", "move", "ref", "pub", "use", "mod", "struct",
                        "enum", "trait", "impl", "where", "as", "in", "async", "await",
                        "dyn", "const", "static", "true", "false", "self", "Self"])
        case "bash", "sh", "shell", "zsh":
            return Set(["if", "then", "else", "elif", "fi", "for", "while", "do",
                        "done", "case", "esac", "function", "return", "echo", "export",
                        "local", "readonly", "set", "unset", "select", "in"])
        case "sql":
            return Set(["select", "from", "where", "insert", "into", "values", "update",
                        "set", "delete", "join", "inner", "left", "right", "full",
                        "outer", "on", "group", "by", "order", "having", "limit", "as",
                        "and", "or", "not", "null", "distinct", "create", "table",
                        "index", "view", "drop", "alter", "primary", "key", "foreign",
                        "references", "count", "sum", "avg", "min", "max"])
        case "kotlin", "kt":
            return Set(["fun", "val", "var", "return", "if", "else", "when", "for",
                        "while", "class", "object", "interface", "data", "enum",
                        "sealed", "companion", "import", "package", "null", "true",
                        "false", "is", "in", "as", "private", "public", "internal",
                        "protected", "override", "suspend", "open", "abstract"])
        case "ruby", "rb":
            return Set(["def", "return", "if", "elsif", "else", "unless", "for",
                        "while", "until", "do", "end", "case", "when", "class", "module",
                        "require", "include", "extend", "new", "true", "false", "nil",
                        "and", "or", "not", "yield", "begin", "rescue", "ensure"])
        case "php":
            return Set(["echo", "if", "else", "elseif", "foreach", "as", "for",
                        "while", "switch", "case", "break", "continue", "function",
                        "return", "class", "extends", "implements", "interface", "new",
                        "namespace", "use", "public", "private", "protected", "static",
                        "try", "catch", "finally", "throw", "true", "false", "null",
                        "array", "isset", "empty", "unset"])
        case "json":
            return Set(["true", "false", "null"])
        case "yaml", "yml":
            return Set(["true", "false", "null", "yes", "no", "on", "off"])
        case "html", "xml":
            return Set(["html", "head", "body", "div", "span", "script", "style",
                        "link", "meta", "title", "p", "h1", "h2", "h3", "h4", "table",
                        "tr", "td", "th", "ul", "ol", "li", "a", "img", "input",
                        "button", "form", "section", "article", "header", "footer",
                        "nav", "main", "aside", "br", "hr", "iframe", "video"])
        case "css":
            return Set(["import", "media", "keyframes", "important", "hover",
                        "active", "focus", "first", "child", "before", "after",
                        "root", "not", "nth"])
        default:
            return Set([])
        }
    }
}

