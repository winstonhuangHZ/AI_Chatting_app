import SwiftUI

/// Print/PDF layout for one chat session.
///
/// Deliberately **not** the on-screen bubble layout: no avatars, no action
/// bars, no scroll views (a ScrollView would clip to one screen inside a PDF
/// context). Content is rendered with the same `MarkdownText` used in the chat
/// so code highlighting, tables and math match the app exactly.
struct TranscriptDocument: View {

    let session: ChatSession

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    private var exportedAt: String {
        Date().formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ForEach(session.messages) { message in
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messageBlock(message)
                }
            }

            footer
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize + 6)
                .bold()
                .foregroundStyle(.black)

            Text("\(session.createdAt.formatted(date: .long, time: .shortened))  ·  \(L("msg.count", session.messages.count))")
                .font(.caption)
                .foregroundStyle(.gray)

            Divider()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            Text(L("export.pdf.footer", L("app.name"), exportedAt))
                .font(.caption2)
                .foregroundStyle(.gray)
        }
    }

    /// One message: role + time header, then the rendered body.
    @ViewBuilder
    private func messageBlock(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(roleLabel(message.role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == .user ? Color.gray : Color.black)
                Text(message.timestamp.formatted(date: .numeric, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.gray)
                if let model = message.model, !model.isEmpty, message.role == .assistant {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }

            if message.role == .assistant {
                MarkdownText(text: message.content, fontSize: nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // User messages are plain text in the app; keep them verbatim
                // (a light card makes the turn boundaries scannable on paper).
                Text(message.content)
                    .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.gray.opacity(0.12))
                    )
            }

            // Web sources collected by the agent tools.
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("sources.title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.gray)
                    ForEach(message.sources) { source in
                        Text("· \(source.title) — \(source.url)")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func roleLabel(_ role: ChatMessageRole) -> String {
        switch role {
        case .user: return L("you")
        case .assistant: return L("assistant")
        case .system: return L("system")
        }
    }
}
