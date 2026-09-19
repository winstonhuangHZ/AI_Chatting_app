import SwiftUI
import AppKit

/// Settings window (macOS 14+): manages API relay profiles + user profile
/// (learned personalization preferences).
struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var editingConfig: APIServerConfig?
    @State private var isAddingNew = false
    @State private var showStatusAlert = false
    @State private var selectedSection = SettingsSection.account

    private enum SettingsSection: Hashable {
        case account
        case api
        case appearance
        case memory
        case documents
        case data
        case language
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label(L("settings.account"), systemImage: "person.crop.circle")
                    .tag(SettingsSection.account)
                Label(L("api.relay.profiles"), systemImage: "server.rack")
                    .tag(SettingsSection.api)
                Divider()
                Label(L("settings.appearance"), systemImage: "textformat")
                    .tag(SettingsSection.appearance)
                Label(L("user.profile"), systemImage: "brain")
                    .tag(SettingsSection.memory)
                Label(L("pdf.settings.title"), systemImage: "doc.richtext")
                    .tag(SettingsSection.documents)
                Label(L("backup.title"), systemImage: "externaldrive")
                    .tag(SettingsSection.data)
                Label(L("language.settings"), systemImage: "globe")
                    .tag(SettingsSection.language)
            }
            .listStyle(.sidebar)
            .navigationTitle(L("settings"))
        } detail: {
            Group {
                switch selectedSection {
                case .account:
                    AccountSettingsView()
                case .api:
                    apiProfileContent
                case .appearance:
                    AppearanceSettingsPage()
                case .memory:
                    MemorySettingsPage()
                case .documents:
                    DocumentsSettingsPage()
                case .data:
                    DataSettingsPage()
                case .language:
                    LanguageSettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560)
        .alert(
            appSettingViewModel.statusIsError ? L("operation.failed") : L("success"),
            isPresented: $showStatusAlert
        ) {
            Button("OK", role: .cancel) { appSettingViewModel.clearStatus() }
        } message: {
            Text(appSettingViewModel.statusMessage ?? "")
        }
        .onChange(of: appSettingViewModel.statusMessage) { _, message in
            if message != nil { showStatusAlert = true }
        }
    }

    private var apiProfileContent: some View {
        Group {
            if let config = editingConfig {
                ProfileEditView(
                    config: config,
                    isNew: isAddingNew,
                    onSave: { updated in
                        if isAddingNew {
                            appSettingViewModel.add(updated)
                        } else {
                            appSettingViewModel.update(updated)
                        }
                        editingConfig = nil
                        isAddingNew = false
                    },
                    onCancel: {
                        editingConfig = nil
                        isAddingNew = false
                    }
                )
            } else {
                ProfileListView(
                    onAdd: {
                        isAddingNew = true
                        editingConfig = APIServerConfig(name: "New Profile")
                    },
                    onEdit: { editingConfig = $0 }
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 520)
    }
}

// MARK: - Account settings

/// Shared page scaffold: title + scrollable content.
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title2.bold())
                    .padding(16)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}

private struct AppearanceSettingsPage: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        SettingsPage(L("settings.appearance")) {
            AppearancePickerView()
                .environmentObject(appearanceStore)
        }
    }
}

private struct MemorySettingsPage: View {
    @EnvironmentObject private var userProfileStore: UserProfileStore

    var body: some View {
        SettingsPage(L("user.profile")) {
            UserProfileSection()
                .environmentObject(userProfileStore)
        }
    }
}

private struct DocumentsSettingsPage: View {
    var body: some View {
        SettingsPage(L("pdf.settings.title")) {
            PDFSettingsSection()
        }
    }
}

private struct DataSettingsPage: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var userProfileStore: UserProfileStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var chatViewModel: ChatViewModel

    var body: some View {
        SettingsPage(L("backup.title")) {
            BackupRestoreView()
                .environmentObject(configStore)
                .environmentObject(sessionStore)
                .environmentObject(userProfileStore)
                .environmentObject(appearanceStore)
                .environmentObject(chatViewModel)
        }
    }
}

private struct LanguageSettingsPage: View {
    var body: some View {
        SettingsPage(L("language.settings")) {
            LanguagePickerView()
        }
    }
}

// MARK: - Account settings

private struct AccountSettingsView: View {
    @EnvironmentObject private var userProfileStore: UserProfileStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draftName = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    avatarView
                        .frame(width: 96, height: 96)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(userProfileStore.displayName.isEmpty
                             ? L("account.default.name")
                             : userProfileStore.displayName)
                            .font(.title2.weight(.semibold))
                        Text(L("account.avatar.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L("account.choose.avatar"), action: chooseAvatar)
                            if userProfileStore.avatarData != nil {
                                Button(L("account.remove.avatar"), role: .destructive) {
                                    userProfileStore.avatarData = nil
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(L("account.profile"))
            }

            Section {
                TextField(L("account.username"), text: $draftName)
                    .onSubmit(saveName)
            } header: {
                Text(L("account.details"))
            } footer: {
                Text(L("account.username.hint"))
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(L("save"), action: saveName)
                    .buttonStyle(.borderedProminent)
                    .tint(appearanceStore.prominentButtonColor)
                    .disabled(draftName == userProfileStore.displayName)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("settings.account"))
        .padding(12)
        .onAppear { draftName = userProfileStore.displayName }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let data = userProfileStore.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(appearanceStore.prominentButtonColor.opacity(0.18))
                Image(systemName: "person.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(appearanceStore.prominentButtonColor)
            }
        }
    }

    private func saveName() {
        userProfileStore.displayName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = userProfileStore.displayName
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.title = L("account.choose.avatar")
        panel.prompt = L("account.choose.avatar")
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        userProfileStore.avatarData = png
    }
}

// MARK: - Profile list

private struct ProfileListView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var userProfileStore: UserProfileStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var sessionStore: SessionStore

    /// 界面本地化——语言切换时即时刷新全部文本。
    @EnvironmentObject private var localization: LocalizationManager

    let onAdd: () -> Void
    let onEdit: (APIServerConfig) -> Void

    var body: some View {
        // 外层 ScrollView：保证所有分区（外观/备份/语言）在窗口缩小时仍可滚动到。
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text(L("api.relay.profiles")).font(.title2.bold())
                    Spacer()
                    Button(action: onAdd) { Label(L("add.profile"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .tint(appearanceStore.prominentButtonColor)
                }
                .padding(16)

                Divider()

                if configStore.configs.isEmpty {
                    ContentUnavailableView {
                        Label(L("no.profiles"), systemImage: "network.slash")
                    } description: {
                        Text(L("no.profiles.description"))
                    } actions: {
                        Button(L("add.profile"), action: onAdd)
                            .buttonStyle(.borderedProminent)
                            .tint(appearanceStore.prominentButtonColor)
                    }
                    .frame(height: 220)
                } else {
                    // 配置列表：多条时限制高度（外层 ScrollView 可继续滚动下面的分区）。
                    List(configStore.configs) { config in
                        ProfileRow(
                            config: config,
                            isActive: configStore.activeConfigID == config.id,
                            isTesting: appSettingViewModel.isTestingConnection
                                && configStore.activeConfigID == config.id,
                            onActivate: { configStore.activeConfigID = config.id },
                            onEdit: { onEdit(config) },
                            onDelete: { appSettingViewModel.delete(config) },
                            onFetchModels: {
                                Task { await appSettingViewModel.fetchModels(for: config.id) }
                            },
                            onTest: {
                                Task { await appSettingViewModel.testConnection(for: config) }
                            },
                            onBalance: {
                                Task { await appSettingViewModel.fetchBalance(for: config) }
                            },
                            balanceText: configStore.activeConfigID == config.id
                                ? appSettingViewModel.balanceText
                                : nil,
                            isFetchingBalance: appSettingViewModel.isFetchingBalance
                                && configStore.activeConfigID == config.id
                        )
                    }
                    .frame(height: CGFloat(min(configStore.configs.count, 4)) * 100 + 16)
                }

            }
        }
    }
}

// MARK: - PDF settings section

/// PDF 文档发送设置：视觉模型渲染 PNG 的页数上限（0 = 全部页）。
///
/// 该参数全局生效（`PDFProcessor.maxRenderPages`），作用于「转成 PNG 发送」
/// 与「图片 + 文字都发送」两种模式；渲染结果缓存按 `(attachment, maxPages)`
/// 区分，改参数不会复用旧缓存。
private struct PDFSettingsSection: View {
    @AppStorage(PDFProcessor.maxRenderPagesKey) private var maxPages = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("pdf.settings.title"), systemImage: "doc.richtext")
                .font(.headline)

            HStack(spacing: 8) {
                Text(L("pdf.settings.maxPages"))
                Stepper(value: $maxPages, in: 0...100, step: 1) {
                    Text(maxPages == 0
                         ? L("pdf.settings.all")
                         : L("pdf.settings.count", maxPages))
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 90, alignment: .leading)
                }
                .frame(maxWidth: 240)
            }

            Text(L("pdf.settings.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - User profile section

/// Editable list of learned personalization preferences.
private struct UserProfileSection: View {
    @EnvironmentObject private var userProfileStore: UserProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("user.profile"), systemImage: "person")
                .font(.headline)

            Text(L("user.profile.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if userProfileStore.preferences.isEmpty {
                Text(L("no.preferences.learned"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                List {
                    ForEach($userProfileStore.preferences) { $pref in
                        HStack(spacing: 8) {
                            TextField("category", text: $pref.category)
                                .font(.caption)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)

                            TextField("value", text: $pref.value)
                                .font(.body)
                                .textFieldStyle(.roundedBorder)

                            Spacer()

                            Button(role: .destructive) {
                                userProfileStore.remove(pref)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(height: CGFloat(min(userProfileStore.preferences.count, 6)) * 30 + 14)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let config: APIServerConfig
    let isActive: Bool
    let isTesting: Bool

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onFetchModels: () -> Void
    let onTest: () -> Void
    let onBalance: () -> Void
    let balanceText: String?
    let isFetchingBalance: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(config.displayName).font(.headline)
                if isActive {
                    Text(L("active")).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(config.baseURL.isEmpty ? L("no.base.url") : config.baseURL)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(config.apiKey.isEmpty ? L("no.api.key") : "API key: ••••••••")
                    .font(.caption).foregroundStyle(.secondary)
                Text(config.selectedModel.isEmpty
                     ? L("no.model.selected")
                     : "Model: \(config.selectedModel)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(config.availableModels.isEmpty
                       ? L("fetch.models")
                       : L("models.count", config.availableModels.count),
                       action: onFetchModels)
                    .buttonStyle(.bordered)
                Button(L("test"), action: onTest).buttonStyle(.bordered)
                Button(L("balance"), action: onBalance).buttonStyle(.bordered)
                    .disabled(isFetchingBalance)
                Button(L("edit"), action: onEdit).buttonStyle(.bordered)
                Spacer()
                Button(L("delete"), role: .destructive, action: onDelete).buttonStyle(.bordered)
            }
            .font(.callout)

            if let balanceText {
                Text(balanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isFetchingBalance {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Profile editor

private struct ProfileEditView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var appSettingViewModel: AppSettingViewModel
    @EnvironmentObject private var appearanceStore: AppearanceStore

    /// 界面本地化——语言切换时即时刷新。
    @EnvironmentObject private var localization: LocalizationManager

    @State private var draft: APIServerConfig
    let isNew: Bool
    let onSave: (APIServerConfig) -> Void
    let onCancel: () -> Void

    init(
        config: APIServerConfig,
        isNew: Bool,
        onSave: @escaping (APIServerConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // MARK: - Custom price bindings

    /// Enables/disables the user-defined price (creates the struct on demand).
    private var customPriceEnabled: Binding<Bool> {
        Binding(
            get: { draft.customPrice != nil },
            set: { enabled in
                if enabled {
                    if draft.customPrice == nil {
                        draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                    }
                } else {
                    draft.customPrice = nil
                }
            }
        )
    }

    private var customPriceInput: Binding<Double> {
        Binding(
            get: { draft.customPrice?.input ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.input = value
            }
        )
    }

    private var customPriceOutput: Binding<Double> {
        Binding(
            get: { draft.customPrice?.output ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.output = value
            }
        )
    }

    private var customPriceCached: Binding<Double> {
        Binding(
            get: { draft.customPrice?.cachedInput ?? 0 },
            set: { value in
                if draft.customPrice == nil {
                    draft.customPrice = CustomPrice(input: 0, output: 0, cachedInput: nil)
                }
                draft.customPrice?.cachedInput = value > 0 ? value : nil
            }
        )
    }

    private var contextWindowBinding: Binding<Int> {
        Binding(
            get: { draft.contextWindowOverride ?? 0 },
            set: { value in
                draft.contextWindowOverride = value > 0 ? value : nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? L("add.profile.title") : L("edit.profile.title")).font(.title2.bold())

            Form {
                TextField(L("profile.name"), text: $draft.name)
                TextField(L("base.url"), text: $draft.baseURL)
                SecureField(L("api.key"), text: $draft.apiKey)

                Section {
                    Toggle(L("streaming.on"), isOn: $draft.streamEnabled)

                    Toggle(L("timestamp.on"), isOn: $draft.includeTimestamp)
                        .help(L("timestamp.warning"))

                    Toggle(L("agent.mode"), isOn: $draft.toolsEnabled)

                    Toggle(L("latex.on"), isOn: $draft.latexEnabled)
                        .disabled(!LaTeXService.isAvailable)
                        .help(
                            LaTeXService.isAvailable
                                ? L("latex.help", LaTeXService.installedEngineList)
                                : L("latex.not.installed")
                        )
                } header: {
                    Text(L("generation"))
                } footer: {
                    Text(L("generation.footer"))
                }

                Section {
                    TextField(
                        L("context.window"),
                        value: contextWindowBinding,
                        format: .number
                    )
                    .help(L("context.window.help"))
                } header: {
                    Text(L("context.section"))
                } footer: {
                    Text(L("context.window.footer"))
                }

                if !draft.modelVisionOverrides.isEmpty {
                    Section {
                        ForEach(draft.modelVisionOverrides.keys.sorted(), id: \.self) { model in
                            HStack {
                                Label(model, systemImage: "photo")
                                Spacer()
                                Button(role: .destructive) {
                                    draft.modelVisionOverrides.removeValue(forKey: model)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text(L("vision.overrides"))
                    } footer: {
                        Text(L("vision.overrides.footer"))
                    }
                }

                Section {
                    Picker(L("search.provider"), selection: $draft.searchProvider) {
                        ForEach(SearchProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    SecureField(L("search.api.key"), text: $draft.searchAPIKey)
                    TextField(L("search.endpoint"), text: $draft.searchEndpoint)
                        .help(L("search.endpoint.help"))

                    if draft.searchProvider == .automatic {
                        Text(L("search.order"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(draft.searchProviderOrder.enumerated()), id: \.element) { index, provider in
                            HStack {
                                Text("\(index + 1). \(provider.displayName)")
                                    .font(.caption)
                                Spacer()
                                Button {
                                    moveSearchProvider(index, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    moveSearchProvider(index, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= draft.searchProviderOrder.count - 1)
                            }
                        }
                    }
                } header: {
                    Text(L("search.section"))
                } footer: {
                    Text(L("search.footer"))
                }

                Section {
                    Toggle(L("custom.price.enable"), isOn: customPriceEnabled)
                    if customPriceEnabled.wrappedValue {
                        TextField(L("custom.price.input"), value: customPriceInput, format: .number)
                        TextField(L("custom.price.output"), value: customPriceOutput, format: .number)
                        TextField(L("custom.price.cached"), value: customPriceCached, format: .number)
                            .help(L("custom.price.cached.help"))
                    }
                } header: {
                    Text(L("custom.price"))
                } footer: {
                    Text(L("custom.price.footer"))
                }

                Section {
                    TextEditor(text: $draft.systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Label(L("system.prompt.hint"),
                          systemImage: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // 应用会在发送前临时追加自己的说明（记忆协议 / 时间 / 图片等），
                    // 但不会写回上面这份文本。展开即看到模型真正收到的那一份。
                    DisclosureGroup(L("system.prompt.preview")) {
                        ScrollView {
                            Text(ChatViewModel.effectiveSystemPrompt(for: draft))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 200)
                    }
                    .font(.caption)
                } header: {
                    Text(L("system.prompt"))
                } footer: {
                    Text(L("system.prompt.footer"))
                }

                if !isNew {
                    Section(L("models")) {
                        Picker(L("selected.model"), selection: $draft.selectedModel) {
                            if draft.availableModels.isEmpty {
                                Text(L("no.models.yet")).tag("")
                            }
                            ForEach(draft.availableModels, id: \.self) { model in
                                HStack(spacing: 4) {
                                    Text(model)
                                    if MultimodalSupport.isMultimodal(model) {
                                        Image(systemName: "photo")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(model)
                            }
                        }
                        .tint(appearanceStore.accentColor)
                        .disabled(draft.availableModels.isEmpty)

                        Label(L("multimodal.hint"),
                              systemImage: "photo.on.rectangle")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Button {
                                Task {
                                    await appSettingViewModel.fetchModels(for: draft.id)
                                    if let updated = configStore.configs.first(where: { $0.id == draft.id }) {
                                        draft = updated
                                    }
                                }
                            } label: {
                                Label(L("fetch.models.button"), systemImage: "arrow.clockwise")
                            }
                            .disabled(appSettingViewModel.isLoadingModels)

                            if appSettingViewModel.isLoadingModels {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(L("cancel"), role: .cancel, action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button(action: save) {
                    Text(isNew ? L("add") : L("save"))
                }
                .buttonStyle(.borderedProminent)
                .tint(appearanceStore.prominentButtonColor)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .onAppear {
            if let existing = configStore.configs.first(where: { $0.id == draft.id }) {
                draft = existing
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
    }

    private func moveSearchProvider(_ index: Int, by delta: Int) {
        let target = index + delta
        guard index >= 0,
              index < draft.searchProviderOrder.count,
              target >= 0,
              target < draft.searchProviderOrder.count else { return }
        draft.searchProviderOrder.swapAt(index, target)
    }
}
