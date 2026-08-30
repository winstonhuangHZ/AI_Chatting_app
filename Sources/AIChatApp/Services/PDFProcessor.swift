import Foundation
import PDFKit
import AppKit

/// Prepares uploaded PDF documents for an AI request.
///
/// Depending on the active model:
/// - **Vision models** receive rendered page images as OpenAI `image_url`
///   content parts, so the model can actually "read" the document layout,
///   tables, diagrams, math, etc.
/// - **Text-only models** receive the extracted text, injected into the
///   message content.
///
/// Both paths are CPU-heavy, so callers should run them off the main thread
/// (see `OpenAIService` which wraps them in `Task.detached`).
enum PDFProcessor {

    /// Maximum number of pages rendered for vision models (cost / context limit).
    static let maxVisionPages = 5

    /// Longest edge (points) used when rasterizing a page for vision models.
    static let maxImageDimension: CGFloat = 1200

    // MARK: - Public API

    /// Number of pages in the PDF (0 when the data is not a valid PDF).
    static func pageCount(from data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? 0
    }

    /// Extracts the document's text layer (fast; used by text-only models).
    static func extractText(from data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return document.string ?? ""
    }

    /// Renders up to `maxPages` pages to PNG `Data` (downscaled for vision
    /// models). Returns an empty array for invalid PDFs.
    static func renderPages(from data: Data, maxPages: Int = maxVisionPages) -> [Data] {
        guard let document = PDFDocument(data: data) else { return [] }
        let count = min(document.pageCount, maxPages)
        var images: [Data] = []
        for index in 0..<count {
            guard let page = document.page(at: index),
                  let png = render(page) else { continue }
            images.append(png)
        }
        return images
    }

    // MARK: - Page rendering

    private static func render(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        let scale = min(1, maxImageDimension / longest)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: CGFloat(width), height: CGFloat(height))

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context

        // White background (PDF pages are transparent by default).
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()

        let cg = context.cgContext
        cg.saveGState()
        // PDFKit draws in bottom-up coordinates; flip to match the bitmap.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
