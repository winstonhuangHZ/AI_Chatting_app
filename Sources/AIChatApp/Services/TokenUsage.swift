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
    ///
    /// Uses `AccurateTokenCounter` (cl100k_base approximate) instead of the
    /// old flat "4 ASCII chars = 1 token" heuristic — much closer to what the
    /// relay bills, especially for mixed CJK/English chat text.
    static func estimateTokens(_ text: String) -> Int {
        AccurateTokenCounter.count(text)
    }

    /// Heuristic tokens for one image attachment.
    static let tokensPerImage = 765

    /// Counts input (user/system/history) and output (assistant) tokens.
    ///
    /// - Parameters:
    ///   - messages: The conversation history shown in the UI.
    ///   - systemPrompt: The editable system prompt (may be empty).
    ///   - profileJSON: User-profile JSON attached to the prompt (may be empty).
    /// - Returns: Estimated input and output token counts **for the next
    ///   request**, i.e. history + system prompt + user profile count as
    ///   input context (they are all re-sent on every call — which is exactly
    ///   how OpenAI billing works).
    static func summarize(
        _ messages: [ChatMessage],
        systemPrompt: String = "",
        profileJSON: String? = nil
    ) -> (input: Int, output: Int) {
        var input = 0
        var output = 0

        // The system prompt + user profile are part of the prompt context.
        if !systemPrompt.isEmpty {
            input += estimateTokens(systemPrompt)
        }
        if let profileJSON, !profileJSON.isEmpty {
            input += estimateTokens(profileJSON)
        }

        for message in messages {
            let textTokens = estimateTokens(message.content)
            let imageTokens = message.attachments.count * tokensPerImage
            // PDFs are rendered to page images for vision models.
            let documentTokens = message.documentAttachments
                .reduce(0) { $0 + $1.pageCount } * tokensPerImage

            switch message.role {
            case .assistant:
                output += textTokens
            case .user, .system:
                input += textTokens + imageTokens + documentTokens
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
    /// Resolved pricing for a model (input / output / optional cached-input).
    struct ModelPricing: Equatable {
        let input: Double
        let output: Double
        let cachedInput: Double?
    }

    /// Cost estimate: `full` assumes no prompt-cache hit; `cached` (when the
    /// model/prices expose a cached-input rate) assumes the whole input
    /// prefix is served from the cache.
    struct CostEstimate: Equatable {
        let full: Double
        let cached: Double?
    }

    /// Resolves effective prices for a model id.
    ///
    /// Priority:
    /// 1. User-defined custom price (`customPrice`).
    /// 2. Dynamic prices fetched from the relay (`modelPrices` dict).
    /// 3. Built-in fallback table (keyword match on model id).
    static func pricing(
        for modelID: String,
        dynamicPrices: [String: ModelPrice] = [:],
        customPrice: CustomPrice? = nil
    ) -> ModelPricing? {
        // 1) User-defined custom price wins (manual overrides for relays
        //    that do not expose pricing data).
        if let customPrice, customPrice.isValid {
            return ModelPricing(
                input: customPrice.input,
                output: customPrice.output,
                cachedInput: customPrice.cachedInput
            )
        }

        // 2) Relay-provided dynamic price (exact model id match).
        if let price = dynamicPrices[modelID], price.isValid {
            return ModelPricing(input: price.prompt, output: price.completion, cachedInput: nil)
        }

        // 3) Built-in fallback.
        let lower = modelID.lowercased()
        for entry in priceTable {
            let matched = entry.keywords.contains { lower.contains($0) }
            if matched {
                return ModelPricing(input: entry.input, output: entry.output, cachedInput: nil)
            }
        }
        return nil
    }

    /// Tuple convenience variant of `pricing` (legacy callers).
    static func prices(
        for modelID: String,
        dynamicPrices: [String: ModelPrice] = [:],
        customPrice: CustomPrice? = nil
    ) -> (input: Double, output: Double)? {
        guard let pricing = pricing(for: modelID, dynamicPrices: dynamicPrices, customPrice: customPrice) else {
            return nil
        }
        return (pricing.input, pricing.output)
    }

    /// Computes estimated cost in USD for a model + token counts, preferring
    /// user-defined custom price, then relay dynamic prices.
    static func estimatedCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        dynamicPrices: [String: ModelPrice] = [:],
        customPrice: CustomPrice? = nil
    ) -> CostEstimate? {
        guard let prices = pricing(
            for: model,
            dynamicPrices: dynamicPrices,
            customPrice: customPrice
        ) else { return nil }

        let full = Double(inputTokens) / 1_000_000.0 * prices.input
            + Double(outputTokens) / 1_000_000.0 * prices.output

        var cached: Double?
        if let cachedRate = prices.cachedInput, cachedRate >= 0 {
            cached = Double(inputTokens) / 1_000_000.0 * cachedRate
                + Double(outputTokens) / 1_000_000.0 * prices.output
        }
        return CostEstimate(full: full, cached: cached)
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