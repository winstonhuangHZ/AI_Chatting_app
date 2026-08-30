import Foundation

/// URL coding for the custom `aichatmath://` image scheme used to smuggle
/// LaTeX through the Markdown parser without cmark mangling it.
///
/// The LaTeX source is stored base64url-encoded in the URL path so the URL
/// itself never contains characters (spaces, parentheses, `%`, …) that would
/// break CommonMark image syntax. Decoding is the mirror image of encoding.
enum MathCoding {

    /// Custom URL scheme used by every math placeholder image.
    static let scheme = "aichatmath"

    /// Host values that distinguish inline from display (block) math.
    static let inlineHost = "inline"
    static let displayHost = "display"

    /// Builds a markdown-embeddable image URL for `latex`.
    static func imageURLString(host: String, latex: String) -> String? {
        guard let b64 = encodeBase64URL(latex) else { return nil }
        return "\(scheme)://\(host)/\(b64)"
    }

    /// Decodes a math placeholder URL back into the original LaTeX string.
    static func decode(url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }
        return decodeBase64URL(path)
    }

    // MARK: - base64url

    static func encodeBase64URL(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
