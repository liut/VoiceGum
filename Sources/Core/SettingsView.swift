import SwiftUI
import VoiceGumPreferences
import VoiceGumKeychain
import VoiceGumServices

public struct SettingsView: View {
    @State private var selectedTab: Int
    public init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label(String(localized: "通用"), systemImage: "gearshape") }
                .tag(0)
            ASRSettingsTab()
                .tabItem { Label(String(localized: "转写"), systemImage: "waveform") }
                .tag(1)
            LLMSettingsTab()
                .tabItem { Label(String(localized: "润色"), systemImage: "brain") }
                .tag(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

struct ModelFamily: Identifiable {
    let id: String; let name: String; let icon: String
    let description: String; let tags: [String]; let models: [ModelInfo]
}

struct ASRSettingsTab: View {
    @StateObject private var ds = DownloadState.shared
    @State private var providerType = AppPreferences.shared.asrProvider == "online" ? "online" : "local"
    @State private var selectedModel = AppPreferences.shared.asrModel
    @State private var apiURL = AppPreferences.shared.asrAPIURL
    @State private var apiKey = ""
    @State private var onlineService = AppPreferences.shared.onlineASRService
    @State private var volcAppId = AppPreferences.shared.volcAppId
    @State private var volcAccessToken = AppPreferences.shared.volcAccessToken
    @State private var volcResourceId = AppPreferences.shared.volcResourceId
    @State private var expandedFamilies: Set<String> = []

    let onlineModels = [("whisper-1", "Whisper v1"), ("whisper-large", "Whisper Large v3")]
    let onlineServices = [("openai", "OpenAI"), ("volcengine", "火山引擎")]

    let modelFamilies: [ModelFamily] = [
        ModelFamily(id: "sensevoice", name: "SenseVoice", icon: "ear.and.waveform",
            description: "多语言识别 · 中文/英文/粤语/日语/韩语 · Metal加速",
            tags: ["本地", "GPU", "GGUF"],
            models: allModels.filter { $0.id.hasPrefix("sense-voice") }),
        ModelFamily(id: "funasr-nano", name: "FunASR-Nano", icon: "brain.head.profile",
            description: "端到端 31 语言 · Qwen3 0.6B 解码器 · Metal 加速 · 中日英韩粤",
            tags: ["本地", "GPU", "GGUF", "LLM"],
            models: allModels.filter { $0.id.hasPrefix("funasr-nano") }),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: 模式选择
                Picker(String(localized: "模式"), selection: $providerType) {
                    Text(String(localized: "在线 API")).tag("online")
                    Text(String(localized: "本地模型")).tag("local")
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: providerType) {
                    AppPreferences.shared.asrProvider = providerType
                    if providerType == "online" { selectedModel = onlineModels[0].0 }
                    else if ds.downloadedModels.isEmpty { selectedModel = "sense-voice-fp16" }
                    AppPreferences.shared.asrModel = selectedModel
                }

                // MARK: 在线服务配置
                if providerType == "online" {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "在线服务商")).font(.headline)

                        Picker(String(localized: "服务商"), selection: $onlineService) {
                            ForEach(onlineServices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: onlineService) {
                            AppPreferences.shared.onlineASRService = onlineService
                        }

                        if onlineService == "openai" {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("API URL", text: $apiURL)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: apiURL) { AppPreferences.shared.asrAPIURL = apiURL }
                                SecureField("API Key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: apiKey) {
                                        Task {
                                            if apiKey.isEmpty { try? await KeychainManager.shared.deleteASRAPIKey() }
                                            else { try? await KeychainManager.shared.saveASRAPIKey(apiKey) }
                                        }
                                    }
                            }
                        }

                        if onlineService == "volcengine" {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("APP ID", text: $volcAppId)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: volcAppId) { AppPreferences.shared.volcAppId = volcAppId }
                                SecureField("Access Token", text: $volcAccessToken)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: volcAccessToken) { AppPreferences.shared.volcAccessToken = volcAccessToken }
                                TextField("Resource ID (流式识别: volc.seedasr.sauc.duration)", text: $volcResourceId)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: volcResourceId) { AppPreferences.shared.volcResourceId = volcResourceId }
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
                }

                // MARK: 本地模型选择
                if providerType == "local" {
                    Text(String(localized: "模型选择")).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    ForEach(modelFamilies) { family in
                        ModelCard(
                            family: family,
                            selectedModel: $selectedModel,
                            isExpanded: expandedFamilies.contains(family.id),
                            ds: ds,
                            isSelected: selectedModel.hasPrefix(family.id),
                            onToggleExpanded: {
                                if expandedFamilies.contains(family.id) { expandedFamilies.remove(family.id) }
                                else { expandedFamilies.insert(family.id) }
                            }
                        )
                    }
                }

                if let error = ds.downloadError {
                    Text(error).foregroundColor(.red).font(.caption)
                }
            }
            .padding(16)
        }
        .onAppear {
            providerType = AppPreferences.shared.asrProvider == "online" ? "online" : "local"
            selectedModel = AppPreferences.shared.asrModel
            apiURL = AppPreferences.shared.asrAPIURL
            onlineService = AppPreferences.shared.onlineASRService
            volcAppId = AppPreferences.shared.volcAppId
            volcResourceId = AppPreferences.shared.volcResourceId
            volcAccessToken = AppPreferences.shared.volcAccessToken
            loadAPIKey()
            Task { await ds.refreshDownloaded() }
            if let family = modelFamilies.first(where: { f in f.models.contains(where: { $0.id == selectedModel }) }) {
                expandedFamilies.insert(family.id)
            }
        }
    }

    private func loadAPIKey() {
        Task { if let key = try? await KeychainManager.shared.readASRAPIKey() { apiKey = key } }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @State private var selectedLanguage = AppPreferences.shared.language
    @State private var subtitleExport = AppPreferences.shared.subtitleExportEnabled
    @State private var autoSaveHistory = AppPreferences.shared.autoSaveHistory
    @State private var autoTranslate = AppPreferences.shared.autoTranslateEnabled
    @State private var translateTarget = AppPreferences.shared.translateTargetLanguage
    @State private var translateOutput = AppPreferences.shared.translateOutputMode
    @State private var languageSplit = AppPreferences.shared.languageSplitEnabled

    let languageOptions: [(String, String)] = [
        ("zh-CN", "中文普通话"),
        ("zh-TW", "台湾国语"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("yue", "粤语"),
        ("auto", String(localized: "自动检测")),
    ]

    let translateLanguageOptions: [(String, String)] = [
        ("zh-CN", "中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    var isLocal: Bool { AppPreferences.shared.asrProvider != "online" }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(String(localized: "识别语言"), selection: $selectedLanguage) {
                        ForEach(languageOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: selectedLanguage) {
                        AppPreferences.shared.language = selectedLanguage
                    }

                    if isLocal {
                        Toggle(isOn: $subtitleExport) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "自动生成字幕"))
                                Text(String(localized: "转写完成后自动生成 SRT 字幕文件"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: subtitleExport) { AppPreferences.shared.subtitleExportEnabled = $0 }
                    }

                    Divider()

                    Toggle(isOn: $autoTranslate) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "自动翻译"))
                            Text(String(localized: "检测到语言不匹配时自动翻译字幕"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: autoTranslate) { AppPreferences.shared.autoTranslateEnabled = $0 }

                    if autoTranslate {
                        Picker(String(localized: "目标语言"), selection: $translateTarget) {
                            ForEach(translateLanguageOptions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .onChange(of: translateTarget) { AppPreferences.shared.translateTargetLanguage = $0 }

                        Picker(String(localized: "输出模式"), selection: $translateOutput) {
                            Text(String(localized: "双语")).tag(TranslateOutputMode.bilingual)
                            Text(String(localized: "仅译文")).tag(TranslateOutputMode.translationOnly)
                        }
                        .onChange(of: translateOutput) { AppPreferences.shared.translateOutputMode = $0 }

                        if isLocal {
                            Toggle(isOn: $languageSplit) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(localized: "按语言分拆字幕"))
                                    Text(String(localized: "检测到多语言时分别生成字幕文件"))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: languageSplit) { AppPreferences.shared.languageSplitEnabled = $0 }
                        }
                    }

                    Toggle(isOn: $autoSaveHistory) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "自动保存历史"))
                            Text(String(localized: "转写完成后自动保存到历史记录"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: autoSaveHistory) { AppPreferences.shared.autoSaveHistory = $0 }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
            }
            .padding(16)
        }
        .onAppear {
            selectedLanguage = AppPreferences.shared.language
            subtitleExport = AppPreferences.shared.subtitleExportEnabled
            autoSaveHistory = AppPreferences.shared.autoSaveHistory
            autoTranslate = AppPreferences.shared.autoTranslateEnabled
            translateTarget = AppPreferences.shared.translateTargetLanguage
            translateOutput = AppPreferences.shared.translateOutputMode
            languageSplit = AppPreferences.shared.languageSplitEnabled
        }
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let family: ModelFamily
    @Binding var selectedModel: String
    let isExpanded: Bool
    @ObservedObject var ds: DownloadState
    let isSelected: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(family.name).font(.headline).fontWeight(.bold)
                        ForEach(family.tags, id: \.self) { TagBadge(text: $0) }
                        let anyDled = family.models.contains { ds.downloadedModels.contains($0.id) }
                        let anyPartial = family.models.contains { ds.partialProgress[$0.id] != nil }
                        if anyDled { TagBadge(text: String(localized: "已下载"), color: .green) }
                        if anyPartial { TagBadge(text: String(localized: "未完成"), color: .orange) }
                    }
                    Text(family.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    if let v = family.models.first(where: { $0.id == selectedModel }) {
                        Text("\(String(localized: "当前")): \(v.displayName)").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundColor(isSelected ? .yellow : .secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpanded() }

            if isExpanded {
                Divider().padding(.horizontal, 16)
                VStack(spacing: 0) {
                    ForEach(family.models, id: \.id) { model in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.subheadline).fontWeight(selectedModel == model.id ? .semibold : .regular)
                                Text("\(String(localized: "预计下载")): \(model.fileSizeDescription)")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()

                            if selectedModel == model.id {
                                Image(systemName: "checkmark").foregroundColor(.yellow).font(.body.weight(.bold))
                            } else {
                                Image(systemName: "circle").foregroundColor(.secondary).font(.body)
                            }

                            if ds.downloadedModels.contains(model.id) {
                                Button(action: { ds.delete(model) }) {
                                    Image(systemName: "trash").foregroundColor(.red)
                                }.buttonStyle(.plain)
                            } else if ds.downloadingModels.contains(model.id) {
                                let pct = ds.downloadProgress[model.id] ?? 0
                                HStack(spacing: 6) {
                                    VStack(spacing: 2) {
                                        HStack(spacing: 4) {
                                            ProgressView().scaleEffect(0.5)
                                            Text("\(Int(pct * 100))%").font(.caption2.monospacedDigit()).foregroundColor(.yellow)
                                        }
                                        ProgressView(value: pct).frame(width: 50).tint(.yellow)
                                    }
                                    Button(action: { ds.pause(model) }) {
                                        Image(systemName: "pause.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.orange)
                                    }.buttonStyle(.plain)
                                    Button(action: { ds.cancel(model) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.red)
                                    }.buttonStyle(.plain)
                                }
                            } else if let pct = ds.partialProgress[model.id] {
                                HStack(spacing: 4) {
                                    VStack(spacing: 2) {
                                        ProgressView(value: pct).frame(width: 40).tint(.orange)
                                        Text("\(Int(pct * 100))%").font(.caption2).foregroundColor(.orange)
                                    }
                                    Button(String(localized: "继续")) { ds.download(model) }.buttonStyle(.yellowButton)
                                    Button(action: { ds.delete(model) }) {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                    }.buttonStyle(.plain)
                                }
                            } else {
                                Button(String(localized: "下载")) { ds.download(model) }.buttonStyle(.yellowButton)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedModel = model.id; AppPreferences.shared.asrModel = selectedModel }

                        if model.id != family.models.last?.id { Divider().padding(.leading, 16) }
                    }
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 0).fill(Color(.controlBackgroundColor).opacity(0.3)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 2))
    }
}

// MARK: - Shared Components

struct TagBadge: View {
    let text: String; var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15)).foregroundColor(color).cornerRadius(4)
    }
}

struct YellowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.yellow.opacity(configuration.isPressed ? 0.7 : 0.9))
            .foregroundColor(.black).cornerRadius(8)
    }
}

extension ButtonStyle where Self == YellowButtonStyle {
    static var yellowButton: YellowButtonStyle { YellowButtonStyle() }
}

// MARK: - LLM Settings Tab

struct LLMSettingsTab: View {
    @State private var autoRefineEnabled = AppPreferences.shared.autoRefineEnabled
    @State private var autoSummaryEnabled = AppPreferences.shared.autoSummaryEnabled
    @State private var llmProvider = AppPreferences.shared.llmProvider
    @State private var llmBaseURL = AppPreferences.shared.llmBaseURL()
    @State private var llmModel = AppPreferences.shared.llmModel()
    @State private var refinePrompt = AppPreferences.shared.refinePrompt
    @State private var summaryPrompt = AppPreferences.shared.summaryPrompt
    @State private var translateMode = AppPreferences.shared.translateMode
    @State private var translatePrompt = AppPreferences.shared.translatePrompt
    @State private var apiKey = ""
    @State private var testSuccess = false
    @State private var testError = ""
    @State private var modelMissingError: String? = nil
    @FocusState private var modelFieldFocused: Bool
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchStatus: String? = nil
    @State private var llamaCLIThreads = AppPreferences.shared.llamaCLIThreads
    private var modelFetchTask = ModelFetchTask()

    /// Mutable box so we can cancel in-flight fetch without @State concurrency warnings.
    @MainActor
    final class ModelFetchTask {
        var current: Task<Void, Never>?
        func cancel() { current?.cancel(); current = nil }
    }

    private var providers: [(String, String)] {
        var list: [(String, String)] = [("openai", "OpenAI 兼容"), ("anthropic", "Anthropic 兼容"), ("ollama", "Ollama")]
        if AppPreferences.shared.isLLaMACLIAvailable {
            list.append(("llamacli", "llama-cli (Local)"))
        }
        return list
    }

    var body: some View {
        Form {
            Section(String(localized: "API 配置")) {
                Picker(String(localized: "提供商"), selection: $llmProvider) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                }.onChange(of: llmProvider) { _, newProvider in
                    AppPreferences.shared.llmProvider = newProvider
                    loadProviderConfig()
                    modelMissingError = llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "请输入模型名称")
                        : nil
                    fetchModels()
                }
                if llmProvider != "llamacli" {
                    SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { saveAPIKey() }
                    TextField("Base URL", text: $llmBaseURL).textFieldStyle(.roundedBorder)
                        .onChange(of: llmBaseURL) { AppPreferences.shared.setLLMBaseURL(llmBaseURL) }
                }

                if llmProvider == "llamacli" {
                    TextField(String(localized: "HF Repo 或模型路径"), text: $llmModel).textFieldStyle(.roundedBorder)
                        .onChange(of: llmModel) { AppPreferences.shared.setLLMModel(llmModel) }
                    Stepper(String(localized: "线程数: \(llamaCLIThreads)"), value: $llamaCLIThreads, in: 1...16)
                        .onChange(of: llamaCLIThreads) { AppPreferences.shared.llamaCLIThreads = llamaCLIThreads }
                } else {
                    HStack(spacing: 4) {
                        TextField("Model", text: $llmModel).textFieldStyle(.roundedBorder)
                            .focused($modelFieldFocused)
                            .onChange(of: llmModel) {
                                AppPreferences.shared.setLLMModel(llmModel)
                                if !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    modelMissingError = nil
                                }
                            }
                            .onChange(of: modelFieldFocused) { _, focused in
                                if !focused {
                                    modelMissingError = llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? String(localized: "请输入模型名称")
                                        : nil
                                }
                            }
                        Menu {
                            if availableModels.isEmpty {
                                Text(String(localized: "请先点击刷新按钮获取模型列表")).foregroundColor(.secondary)
                            } else {
                                ForEach(availableModels, id: \.self) { m in
                                    Button(m) { llmModel = m }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down").frame(width: 20)
                        }
                        .frame(width: 24)

                        Button { fetchModels() } label: {
                            if isFetchingModels {
                                ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise").frame(width: 16)
                            }
                        }
                        .disabled(isFetchingModels)
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "刷新可用模型列表"))
                        .frame(width: 20)
                    }
                    .accessibilityElement(children: .combine)
                    if let status = fetchStatus {
                        Text(status).foregroundColor(availableModels.isEmpty ? .orange : .green).font(.caption)
                    }
                    if let err = modelMissingError {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }
            }
            Section {
                HStack {
                    Button(String(localized: "测试")) { testConnection() }.buttonStyle(.bordered)
                    Spacer()
                    Button(String(localized: "清空 Key")) { apiKey = ""; saveAPIKey() }.buttonStyle(.bordered)
                }
                if testSuccess { Text(String(localized: "连接成功!")).foregroundColor(.green).font(.caption) }
                if !testError.isEmpty { Text(testError).foregroundColor(.red).font(.caption).textSelection(.enabled) }
            }
            Section(String(localized: "任务提示词")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "自动润色"), isOn: $autoRefineEnabled)
                        .onChange(of: autoRefineEnabled) { AppPreferences.shared.autoRefineEnabled = autoRefineEnabled }
                    Text(String(localized: "Refine — 润色转写文字")).font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $refinePrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .onChange(of: refinePrompt) { AppPreferences.shared.refinePrompt = refinePrompt }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "自动摘要"), isOn: $autoSummaryEnabled)
                        .onChange(of: autoSummaryEnabled) { AppPreferences.shared.autoSummaryEnabled = autoSummaryEnabled }
                    Text(String(localized: "Summary — 生成全文摘要")).font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $summaryPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .onChange(of: summaryPrompt) { AppPreferences.shared.summaryPrompt = summaryPrompt }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "自动翻译")).font(.headline)
                        Spacer()
                    }
                    Text(String(localized: "Translate — 翻译字幕文本")).font(.caption).foregroundColor(.secondary)
                    Picker(String(localized: "翻译模式"), selection: $translateMode) {
                        Text(String(localized: "逐条翻译")).tag(TranslateMode.perSegment)
                        Text(String(localized: "整批翻译")).tag(TranslateMode.batch)
                    }
                    .onChange(of: translateMode) { AppPreferences.shared.translateMode = $0 }
                    TextEditor(text: $translatePrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .onChange(of: translatePrompt) { AppPreferences.shared.translatePrompt = translatePrompt }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            autoRefineEnabled = AppPreferences.shared.autoRefineEnabled
            autoSummaryEnabled = AppPreferences.shared.autoSummaryEnabled
            llmProvider = AppPreferences.shared.llmProvider
            refinePrompt = AppPreferences.shared.refinePrompt
            summaryPrompt = AppPreferences.shared.summaryPrompt
            translateMode = AppPreferences.shared.translateMode
            translatePrompt = AppPreferences.shared.translatePrompt
            llamaCLIThreads = AppPreferences.shared.llamaCLIThreads
            loadProviderConfig()
            fetchModels()
        }
    }

    private func loadProviderConfig() {
        llmBaseURL = AppPreferences.shared.llmBaseURL()
        llmModel = AppPreferences.shared.llmModel()
        apiKey = AppPreferences.shared.llmAPIKey()
        llamaCLIThreads = AppPreferences.shared.llamaCLIThreads
    }

    private func fetchModels() {
        guard llmProvider != "llamacli" else { return }
        modelFetchTask.cancel()
        isFetchingModels = true
        fetchStatus = nil
        let provider = llmProvider
        let baseURL = AppPreferences.shared.llmBaseURL(for: provider)
        let key = AppPreferences.shared.llmAPIKey(for: provider)
        modelFetchTask.current = Task { @MainActor in
            let models = await LLMClient.shared.fetchAvailableModels(provider: provider, baseURL: baseURL, apiKey: key)
            guard !Task.isCancelled else { return }
            self.availableModels = models
            self.isFetchingModels = false
            if models.isEmpty {
                self.fetchStatus = baseURL.isEmpty
                    ? String(localized: "请先填写 Base URL")
                    : String(localized: "未找到可用模型")
            } else {
                self.fetchStatus = String(localized: "已加载 \(models.count) 个模型")
            }
        }
    }

    private func saveAPIKey() {
        AppPreferences.shared.setLLMAPIKey(apiKey)
    }

    private func testConnection() {
        testError = ""; testSuccess = false
        if llmProvider == "llamacli" {
            guard !llmModel.isEmpty else { testError = "请输入 HF Repo 或模型路径"; return }
            Task {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/llama-cli")
                proc.arguments = ["--version"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    testSuccess = true
                    testError = out.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    testError = "llama-cli 启动失败: \(error.localizedDescription)"
                }
            }
            return
        }
        guard !llmBaseURL.isEmpty else { testError = "请输入 Base URL"; return }
        guard let baseURL = URL(string: llmBaseURL) else { testError = "无效的 URL: \(llmBaseURL)"; return }
        Task {
            do {
                let provider: LLMProvider = switch llmProvider {
                case "anthropic": .anthropic
                case "ollama": .ollama
                case "llamacli": .llamaCLI
                default: .openai
                }
                await LLMClient.shared.configure(provider: provider, baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: llmModel)
                let result = try await LLMClient.shared.refine(text: "hello", customPrompt: "Reply with just 'OK'")
                testSuccess = true
                testError = "连接成功"
            } catch let err as LLMClientError {
                testError = "\(err.localizedDescription)"
            } catch {
                let nsErr = error as NSError
                testError = "失败: \(error.localizedDescription)\nDomain: \(nsErr.domain) Code: \(nsErr.code)\nURL: \(llmBaseURL)\nProvider: \(llmProvider)\nModel: \(llmModel)"
            }
        }
    }
}
