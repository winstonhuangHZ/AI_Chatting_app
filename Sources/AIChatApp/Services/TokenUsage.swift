import Foundation

/// Approximate token counting + cost estimation for the active conversation.
///
/// Token counting is heuristic (no full tokenizer dependency):
/// - ASCII text:  ~4 characters ≈ 1 token
/// - CJK / wide chars: ~1 character ≈ 1 token (CJK often ~1–1.5 tok/char)
/// - Each image attachment: 765 tokens (OpenAI 1024×1024 tile reference)
///
/// Costs use a small built-in price table (USD per 1M tokens). Unknown models
/// report `nil` so the UI can hide the estimate.
enum TokenUsage {

    // MARK: - Token counting

    /// Heuristically estimates the token count of a text string.
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var weightedUnits = 0
        for scalar in text.unicodeScalars {
            // ASCII (letters/digits/space/punct) counts 1 unit.
            if scalar.isASCII {
                weightedUnits += 1
            } else {
                // CJK / emoji / full-width — treat as 4 units (≈1 token).
                weightedUnits += 4
            }
        }
        return max(1, Int((Double(weightedUnits) / 4.0).rounded()))
    }

    /// Heuristic tokens for one image attachment.
    static let tokensPerImage = 765

    /// Counts input (user/system/history) and output (assistant) tokens.
    static func summarize(_ messages: [ChatMessage]) -> (input: Int, output: Int) {
        var input = 0
        var output = 0
        for message in messages {
            let textTokens = estimateTokens(message.content)
            let imageTokens = message.attachments.count * tokensPerImage

            switch message.role {
            case .assistant:
                output += textTokens
            case .user, .system:
                input += textTokens + imageTokens
            }
        }
        return (input, output)
    }

    // MARK: - Cost estimation (USD per 1M tokens)

    /// Price entries: known model-keywords → (input, output) per 1M tokens.
    /// Used as a **fallback** when the relay does not expose dynamic pricing.
    private static let priceTable: [(keywords: [String], input: Double, output: Double)] = [
        (["gpt-4o-mini"],       0.15, 0.60),
        (["gpt-4o"],            2.50, 10.00),
        (["gpt-4.1-mini"],      0.40, 1.60),
        (["gpt-4.1"],           2.00, 8.00),
        (["gpt-4-turbo"],       10.00, 30.00),
        (["gpt-4"],             30.00, 60.00),
        (["gpt-3.5"],           0.50, 1.50),
        (["claude-3-7"],        3.00, 15.00),
        (["claude-3-5-sonnet"], 3.00, 15.00),
        (["claude-3-5-haiku"],  0.80, 4.00),
        (["claude-3-opus"],     15.00, 75.00),
        (["claude-3"],          3.00, 15.00),
        (["gemini-2.5"],        1.25, 10.00),
        (["gemini-2.0"],        0.10, 0.40),
        (["gemini-1.5"],        1.25, 5.00),
        (["deepseek-chat"],     0.27, 1.10),
        (["deepseek-reasoner"], 0.55, 2.19),
    ]

    /// Resolves effective prices for a model id.
    ///
    /// Priority:
    /// 1. Dynamic prices fetched from the relay (`modelPrices` dict).
    /// 2. Built-in fallback table (keyword match on model id).
    static func prices(
        for modelID: String,
        dynamicPrices: [String: ModelPrice] = [:]
    ) -> (input: Double, output: Double)? {
        // 1) Relay-provided dynamic price (exact model id match).
        if let price = dynamicPrices[modelID], price.isValid {
            return (price.prompt, price.completion)
        }

        // 2) Built-in fallback.
        let lower = modelID.lowercased()
        for entry in priceTable {
            let matched = entry.keywords.contains { lower.contains($0) }
            if matched {
                return (entry.input, entry.output)
            }
        }
        return nil
    }

    /// Computes estimated cost in USD for a model + token counts, preferring
    /// relay-provided dynamic prices.
    static func estimatedCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        dynamicPrices: [String: ModelPrice] = [:]
    ) -> Double? {
        guard let prices = prices(for: model, dynamicPrices: dynamicPrices) else { return nil }
        let inputCost = Double(inputTokens) / 1_000_000.0 * prices.input
        let outputCost = Double(outputTokens) / 1_000_000.0 * prices.output
        return inputCost + outputCost
    }

    // MARK: - Formatting

    /// Formats a token count compactly (e.g. 1,234).
    static func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// Formats a USD cost (e.g. $0.0012, $1.25).
    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}