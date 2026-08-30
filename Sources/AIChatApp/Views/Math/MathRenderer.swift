import AppKit
import SwiftMath

/// Rasterizes LaTeX to `NSImage` using SwiftMath, with memoization.
///
/// The produced images are marked `isTemplate` so SwiftUI tints them with the
/// surrounding text color — math therefore adapts automatically to dark mode,
/// accent colors, and the current font preset without re-rasterizing.
final class MathRenderer {

    static let shared = MathRenderer()

    private let lock = NSLock()

    /// Rendered images keyed by (latex, font size, display mode).
    private var imageCache: [ImageKey: NSImage] = [:]

    /// Quick validity check cache (parse + layout success).
    private var validCache: [String: Bool] = [:]

    private struct ImageKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let display: Bool
    }

    /// Returns `true` when SwiftMath can typeset `latex` without error.
    func canRender(_ latex: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = validCache[latex] { return cached }
        let image = MTMathImage(
            latex: latex,
            fontSize: 14,
            textColor: .black,
            labelMode: .text,
            textAlignment: .center
        )
        let (error, rendered) = image.asImage()
        let ok = error == nil && rendered != nil
        if validCache.count > 1000 { validCache.removeAll() }
        validCache[latex] = ok
        return ok
    }

    /// Renders `latex` to a template `NSImage` at the given point size.
    func image(latex: String, fontSize: CGFloat, display: Bool) -> NSImage? {
        let key = ImageKey(latex: latex, fontSize: fontSize, display: display)
        lock.lock()
        defer { lock.unlock() }
        if let cached = imageCache[key] { return cached }

        let image = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: .black,
            labelMode: display ? .display : .text,
            textAlignment: .center
        )
        let (error, rendered) = image.asImage()
        guard error == nil, let rendered else { return nil }

        rendered.isTemplate = true
        if imageCache.count > 500 { imageCache.removeAll() }
        imageCache[key] = rendered
        return rendered
    }

    /// Empties both caches (used when memory pressure or font settings change).
    func purge() {
        lock.lock()
        defer { lock.unlock() }
        imageCache.removeAll()
        validCache.removeAll()
    }
}
