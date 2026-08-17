import SwiftUI

/// 界面外观设置：字体预设（serif / sans / mono）+ 字号分级（小/中/大/特大）。
/// 修改即时生效，无需重启。
struct AppearancePickerView: View {

    // MARK: - Environment

    @EnvironmentObject private var appearance: AppearanceStore

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("appearance.font"), systemImage: "textformat")
                .font(.headline)

            Picker(L("appearance.font"), selection: $appearance.fontPreset) {
                ForEach(FontPreset.allCases) { preset in
                    Text(preset.displayName)
                        .tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)

            Picker(L("appearance.fontsize"), selection: $appearance.fontSizeLevel) {
                ForEach(FontSizeLevel.allCases) { level in
                    Text(level.localizedName)
                        .tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)

            // 字号预览
            Text(L("appearance.sample"))
                .appearanceFont(appearance.fontPreset, size: appearance.pointSize)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(L("appearance.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 本地化显示名

extension FontPreset {
    /// 界面显示名称（本地化）。
    var displayName: String {
        switch self {
        case .serif: return L("appearance.serif")
        case .sans:  return L("appearance.sans")
        case .mono:  return L("appearance.mono")
        }
    }
}

extension FontSizeLevel {
    /// 本地化字号名称。
    var localizedName: String {
        switch self {
        case .small:      return L("appearance.size.small")
        case .medium:     return L("appearance.size.medium")
        case .large:      return L("appearance.size.large")
        case .extraLarge: return L("appearance.size.xlarge")
        }
    }
}
