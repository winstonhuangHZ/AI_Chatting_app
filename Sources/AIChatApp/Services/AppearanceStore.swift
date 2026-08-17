import Foundation
import SwiftUI
import MarkdownUI

// MARK: - 界面外观设置
//
// 提供界面字体预设（serif / sans / mono）与字号分级调整。
// 通过 UserDefaults 持久化，Instant 生效（无需重启）。

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
    var fontPropertiesFamily: FontProperties.Family {
        switch self {
        case .serif:  return .custom("ui-serif")
        case .sans:   return .system(.default)
        case .mono:   return .system(.monospaced)
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

    // MARK: - Published state

    /// 当前字体预设。
    @Published var fontPreset: FontPreset {
        didSet { persist() }
    }

    /// 当前字号分级。
    @Published var fontSizeLevel: FontSizeLevel {
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
    }

    // MARK: - Derived helpers

    /// 当前字号（points）。
    var pointSize: CGFloat {
        fontSizeLevel.pointSize
    }

    /// 当前 markdown 缩放比例。
    var markdownScale: CGFloat {
        fontSizeLevel.markdownScale
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(fontPreset.rawValue, forKey: Self.presetKey)
        defaults.set(fontSizeLevel.rawValue, forKey: Self.sizeKey)
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