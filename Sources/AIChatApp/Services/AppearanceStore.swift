import Foundation
import SwiftUI
import MarkdownUI

// MARK: - 界面外观设置
//
// 提供界面字体预设（serif / sans / mono）与字号分级调整。
// 通过 UserDefaults 持久化，Instant 生效（无需重启）。

/// 界面主题（配色）。
///
/// - `.system`: 跟随系统深浅色（默认，现状不变）。
/// - `.claude`: Claude 风格——暖米白背景 + 粘土橙用户气泡（强制浅色）。
enum ChatTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case claude = "claude"

    var id: String { rawValue }

    /// 本地化显示名。
    var displayName: String {
        switch self {
        case .system: return L("theme.system")
        case .claude: return L("theme.claude")
        }
    }
}

/// SwiftUI `Color` from a hex value (e.g. `0xF9F9F7`).
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// 字体预设类型。
enum FontPreset: String, CaseIterable, Identifiable {
    /// 衬线字体（美观正文）。
    case serif = "serif"
    /// 无衬线字体（默认现代界面）。
    case sans = "sans"
    /// 等宽字体（代码/表格友好）。
    case mono = "mono"

    /// `Identifiable` conformance。
    var id: String { rawValue }

    /// 提供该预设下的主要字体（中文优先回退系统字体）。
    var uiFont: Font {
        switch self {
        case .serif:
            // 衬线：优先经典衬线字体，中文回退系统衬线。
            return .system(.body, design: .serif)
        case .sans:
            return .system(.body, design: .default)
        case .mono:
            return .system(.body, design: .monospaced)
        }
    }

    /// 设置在 SwiftUI Text 上的字体（供 MessageBubble/Markdown 使用）。
    var textFont: Font {
        switch self {
        case .serif:  return .system(.body, design: .serif)
        case .sans:   return .system(.body, design: .default)
        case .mono:   return .system(.body, design: .monospaced)
        }
    }

    /// MarkdownUI 可用的字体族（按预设注入）。
    ///
    /// serif 使用 `.system(.serif)` 而非 `.custom("ui-serif")`：custom 只映射
    /// 拉丁字体（New York/Times），中文会回退到默认无衬线；system serif 设计
    /// 会让系统自动为中文选择衬线字体（宋体 Songti SC），与用户消息一致。
    var fontPropertiesFamily: FontProperties.Family {
        switch self {
        case .serif:  return .system(.serif)
        case .sans:   return .system(.default)
        case .mono:   return .system(.monospaced)
        }
    }

    /// 返回指定字号的 SwiftUI Font（供 Label/Text/TextField 等任何视图使用）。
    func font(size: CGFloat) -> Font {
        switch self {
        case .serif:  return .system(size: size, design: .serif)
        case .sans:   return .system(size: size, design: .default)
        case .mono:   return .system(size: size, design: .monospaced)
        }
    }
}

/// 字号分级（小 / 中 / 大 / 特大）。
enum FontSizeLevel: Int, CaseIterable, Identifiable {
    case small = 1
    case medium = 2
    case large = 3
    case extraLarge = 4

    var id: Int { rawValue }

    /// 字号名称（本地化显示）。
    var label: String {
        switch self {
        case .small:      return "Small"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// 字号倍数 / 实际 points。
    var pointSize: CGFloat {
        switch self {
        case .small:      return 12
        case .medium:     return 14
        case .large:      return 16
        case .extraLarge: return 18
        }
    }

    /// 与 Markdown 默认字号（13）的缩放因子。
    var markdownScale: CGFloat {
        pointSize / 13.0
    }
}

/// 全局外观设置管理器。
/// - 设置窗口修改；`@EnvironmentObject` 注入使整个 UI 即时刷新。
final class AppearanceStore: ObservableObject {

    // MARK: - Constants

    private static let presetKey = "appearance.fontPreset"
    private static let sizeKey = "appearance.fontSizeLevel"
    private static let themeKey = "appearance.theme"

    // MARK: - Claude palette
    //
    // Warm neutrals + clay accent, matching Claude.ai's "cream & clay" look
    // (values cross-checked against community Claude-inspired themes).

    /// 米白背景 `#F9F9F7`.
    static let claudeBackground = Color(hex: 0xF9F9F7)

    /// 侧栏 / 面板 `#F4F4F2`.
    static let claudeSurface = Color(hex: 0xF4F4F2)

    /// 抬升表面（assistant 气泡）`#FFFFFF`.
    static let claudeElevated = Color(hex: 0xFFFFFF)

    /// 粘土橙（用户气泡 / 强调）`#CC7D5E`.
    static let claudeAccent = Color(hex: 0xCC7D5E)

    /// 深橙（hover / 文字）`#A95639`.
    static let claudeAccentDeep = Color(hex: 0xA95639)

    /// 主文本（暖黑）`#2D2D2B`.
    static let claudeText = Color(hex: 0x2D2D2B)

    /// 次要文本 `#6B6B67`.
    static let claudeMutedText = Color(hex: 0x6B6B67)

    // MARK: - Published state

    /// 当前字体预设。
    ///
    /// > TODO: Markdown 渲染引擎（swift-markdown-ui）对中文 serif 映射不理想
    /// > （custom 字体族只影响拉丁文字）。后续可尝试自定义 Theme 或替换渲染器。
    /// > 目前 UI 暂不开放选择（`isFontPresetSelectionEnabled = false`），
    /// > 默认使用 `.sans` 保证界面一致；相关代码全部保留，仅隐藏入口。
    @Published var fontPreset: FontPreset {
        didSet { persist() }
    }

    /// 当前字号分级。
    @Published var fontSizeLevel: FontSizeLevel {
        didSet { persist() }
    }

    /// 当前界面主题（跟随系统 / Claude 米白橙）。
    @Published var theme: ChatTheme {
        didSet { persist() }
    }

    // MARK: - Initializers

    init() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: Self.presetKey),
           let preset = FontPreset(rawValue: raw) {
            fontPreset = preset
        } else {
            fontPreset = .sans
        }

        let storedSize = defaults.integer(forKey: Self.sizeKey)
        if let level = FontSizeLevel(rawValue: storedSize) {
            fontSizeLevel = level
        } else {
            fontSizeLevel = .medium
        }

        if let raw = defaults.string(forKey: Self.themeKey),
           let theme = ChatTheme(rawValue: raw) {
            self.theme = theme
        } else {
            self.theme = .system
        }
    }

    // MARK: - Derived helpers

    /// `true` when the Claude cream & clay theme is active.
    var isClaudeTheme: Bool {
        theme == .claude
    }

    /// 聊天区背景色（Claude 主题为米白，否则跟随系统）。
    var chatBackground: Color {
        isClaudeTheme ? Self.claudeBackground : Color(nsColor: .textBackgroundColor)
    }

    /// 用户消息气泡背景（Claude 主题为粘土橙，否则为现有强调色淡底）。
    var userBubbleColor: Color {
        isClaudeTheme ? Self.claudeAccent : Color.accentColor.opacity(0.15)
    }

    /// 用户消息气泡文字颜色（Claude 主题下橙色底配白字）。
    var userBubbleTextColor: Color {
        isClaudeTheme ? .white : .primary
    }

    /// AI 消息气泡背景（Claude 主题为透明——回答直接铺在米白背景上，
    /// 与 Claude.ai 一致，避免白色卡片显得突兀；否则跟随系统）。
    var assistantBubbleColor: Color {
        isClaudeTheme ? .clear : Color(nsColor: .controlBackgroundColor)
    }

    /// 侧栏背景（Claude 主题为米灰表面，否则跟随系统）。
    var sidebarBackground: Color {
        isClaudeTheme ? Self.claudeSurface : Color(nsColor: .windowBackgroundColor)
    }

    /// 当前字号（points）。
    var pointSize: CGFloat {
        fontSizeLevel.pointSize
    }

    /// 当前 markdown 缩放比例。
    var markdownScale: CGFloat {
        fontSizeLevel.markdownScale
    }

    /// 根据备份恢复外观设置。
    func apply(from backup: BackupAppearance) {
        if let preset = FontPreset(rawValue: backup.fontPreset) {
            fontPreset = preset
        }
        if let level = FontSizeLevel(rawValue: backup.fontSizeLevel) {
            fontSizeLevel = level
        }
    }

    /// 是否在设置界面开放字体预设选择。
    ///
    /// 当前为 `false`（隐藏入口，默认 sans）。实现 serif 中文映射后可改为 `true`。
    var isFontPresetSelectionEnabled = false

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(fontPreset.rawValue, forKey: Self.presetKey)
        defaults.set(fontSizeLevel.rawValue, forKey: Self.sizeKey)
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        defaults.synchronize()
    }
}

// MARK: - SwiftUI helper: apply preset to Text

extension Text {
    /// 应用当前字体预设 + 字号到 Text。
    func appearanceFont(_ preset: FontPreset, size: CGFloat) -> Text {
        switch preset {
        case .serif:  return self.font(.system(size: size, design: .serif))
        case .sans:   return self.font(.system(size: size, design: .default))
        case .mono:   return self.font(.system(size: size, design: .monospaced))
        }
    }
}