import Foundation

/// One selectable answer offered by the agent.
struct AgentQuestionOption: Codable, Hashable, Identifiable, Sendable {
    var label: String
    var value: String
    var description: String?

    var id: String { value }
}

/// Structured question emitted by the lightweight `ask_user` tool.
struct AgentQuestionRequest: Codable, Hashable, Sendable {
    var question: String
    var options: [AgentQuestionOption]
    var allowMultiple: Bool
    var allowCustom: Bool
}

/// Persisted state of an agent question (pending / answered / cancelled).
struct AgentQuestion: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case pending
        case answered
        case cancelled
    }

    var id: UUID
    var question: String
    var options: [AgentQuestionOption]
    var allowMultiple: Bool
    var allowCustom: Bool
    var status: Status
    var answer: String?
    var answeredAt: Date?

    init(request: AgentQuestionRequest) {
        self.id = UUID()
        self.question = request.question
        self.options = request.options
        self.allowMultiple = request.allowMultiple
        self.allowCustom = request.allowCustom
        self.status = .pending
        self.answer = nil
        self.answeredAt = nil
    }
}
