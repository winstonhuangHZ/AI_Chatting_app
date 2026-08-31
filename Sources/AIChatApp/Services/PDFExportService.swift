import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Exports a chat session to a multi-page PDF.
///
/// Zero dependencies: `ImageRenderer` (macOS 13+) draws a real SwiftUI view
/// tree into a `CGPDFContext`, so the export reuses `MarkdownText` verbatim —
/// syntax-highlighted code cards, SwiftMath formulas, tables and the Claude
/// palette all come out exactly as rendered in the app, and the text stays
/// **vector** (selectable / searchable in the PDF) rather than a screenshot.
///
/// Pagination: the conversation is rendered as one tall view, then sliced into
/// page-height bands by translating the CTM once per page.
@MainActor
enum PDFExportService {

    /// US-Letter at 72 dpi (matches SwiftUI's point coordinate space).
    private static let pageSize = CGSize(width: 612, height: 792)

    /// Page margins in points.
    private static let margin: CGFloat = 40

    // MARK: - Public API

    /// Shows a save panel and writes the session as a PDF.
    ///
    /// - Returns: The written file URL, or `nil` when the user cancelled.
    @discardableResult
    static func export(
        session: ChatSession,
        appearance: AppearanceStore,
        localization: LocalizationManager
    ) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = L("export.pdf")
        panel.prompt = L("export.pdf")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(safeFilename(session.title)).pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let data = try pdfData(
            session: session,
            appearance: appearance,
            localization: localization
        )
        try data.write(to: url)
        return url
    }

    // MARK: - Rendering

    /// Renders the session into PDF data.
    static func pdfData(
        session: ChatSession,
        appearance: AppearanceStore,
        localization: LocalizationManager
    ) throws -> Data {
        let contentWidth = pageSize.width - margin * 2

        let document = TranscriptDocument(session: session)
            .environmentObject(appearance)
            .environmentObject(localization)
            .frame(width: contentWidth)
            // A light background keeps dark code cards readable on paper.
            .background(Color.white)

        let renderer = ImageRenderer(content: document)
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else {
            throw ExportError.contextCreationFailed
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }

        // `render` hands us the measured content size plus a closure that draws
        // the whole view into a CGContext. The renderer already emits upright
        // content occupying (0,0)–(width,height) in the PDF's y-up space, so we
        // must NOT flip the CTM (doing so renders everything upside down) — we
        // only translate so that the wanted band lands in the page's text area.
        renderer.render { size, drawInContext in
            let usableHeight = pageSize.height - margin * 2
            let pageCount = max(1, Int(ceil(size.height / usableHeight)))

            for pageIndex in 0..<pageCount {
                context.beginPDFPage(nil)
                context.saveGState()

                // Clip first, while the CTM is still page space, so content can
                // never bleed into the margins.
                context.clip(to: CGRect(
                    x: margin,
                    y: margin,
                    width: contentWidth,
                    height: usableHeight
                ))

                // Align the top of band `pageIndex` with the top of the text
                // area. Content top sits at y = size.height, and band N starts
                // `N * usableHeight` below the content top.
                let dy = margin + usableHeight - size.height
                    + CGFloat(pageIndex) * usableHeight
                context.translateBy(x: margin, y: dy)

                drawInContext(context)

                context.restoreGState()
                context.endPDFPage()
            }
        }

        context.closePDF()
        return output as Data
    }

    // MARK: - Helpers

    /// Strips characters that are illegal (or annoying) in filenames.
    private static func safeFilename(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "AIChat" : String(cleaned.prefix(60))
        return trimmed
    }

    /// Errors surfaced to the UI.
    enum ExportError: LocalizedError {
        case contextCreationFailed

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed:
                return L("export.pdf.failed")
            }
        }
    }
}
