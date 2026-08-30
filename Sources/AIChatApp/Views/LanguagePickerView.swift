import SwiftUI

/// 界面语言选择器：在设置窗口底部提供联合国六种官方语言切换。
struct LanguagePickerView: View {

    // MARK: - Environment

    @EnvironmentObject private var localization: LocalizationManager

    @EnvironmentObject private var appearance: AppearanceStore

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("language.settings"), systemImage: "globe")
                .font(.headline)

            Picker(L("language.settings"), selection: $localization.current) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.localizedName)
                        .tag(language)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280)
            .tint(appearance.accentColor)

            Text(L("language.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}