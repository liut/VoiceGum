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
            ASRSettingsTab()
                .tabItem { Label("ASR", systemImage: "waveform") }
                .tag(0)
            LLMSettingsTab()
                .tabItem { Label("LLM", systemImage: "brain") }
                .tag(1)
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
        ModelFamily(id: "qwen3asr", name: "Qwen3-ASR", icon: "brain.head.profile",
            description: "通义千问语音识别 · 16头注意力 · 752M参数 · 更高精度",
            tags: ["本地", "CPU", "Safetensors"],
            models: allModels.filter { $0.id.hasPrefix("qwen3") }),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Current engine status
                HStack(spacing: 8) {
                    Image(systemName: providerType == "online" ? "cloud" : "internaldrive")
                        .foregroundColor(.secondary)
                    Text(providerType == "online" ? String(localized: "在线 API") : String(localized: "本地模型"))
                        .font(.subheadline).fontWeight(.medium)
                    if providerType == "local", let m = allModels.first(where: { $0.id == selectedModel }),
                       let family = modelFamilies.first(where: { $0.models.contains(where: { $0.id == selectedModel }) }) {
                        Text("·").foregroundColor(.secondary)
                        Text("\(family.name) \(m.displayName)").font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                HStack {
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
                }

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
                                Text(String(localized: "OpenAI 配置")).font(.subheadline).foregroundColor(.secondary)
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
                                Text(String(localized: "火山引擎配置")).font(.subheadline).foregroundColor(.secondary)
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

                if providerType == "local" {
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
    @State private var llmEnabled = AppPreferences.shared.llmEnabled
    @State private var llmProvider = AppPreferences.shared.llmProvider
    @State private var llmBaseURL = AppPreferences.shared.llmBaseURL()
    @State private var llmModel = AppPreferences.shared.llmModel()
    @State private var refinePrompt = AppPreferences.shared.refinePrompt
    @State private var summaryPrompt = AppPreferences.shared.summaryPrompt
    @State private var apiKey = ""
    @State private var testSuccess = false
    @State private var testError = ""

    let providers = [("openai", "OpenAI 兼容"), ("anthropic", "Anthropic 兼容"), ("ollama", "Ollama")]

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "启用 LLM 优化"), isOn: $llmEnabled)
                    .onChange(of: llmEnabled) { AppPreferences.shared.llmEnabled = llmEnabled }
            }
            Section(String(localized: "API 配置")) {
                Picker(String(localized: "提供商"), selection: $llmProvider) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                }.onChange(of: llmProvider) { _, newProvider in
                    AppPreferences.shared.llmProvider = newProvider
                    loadProviderConfig()
                }
                TextField("Base URL", text: $llmBaseURL).textFieldStyle(.roundedBorder)
                    .onChange(of: llmBaseURL) { AppPreferences.shared.setLLMBaseURL(llmBaseURL) }
                TextField("Model", text: $llmModel).textFieldStyle(.roundedBorder)
                    .onChange(of: llmModel) { AppPreferences.shared.setLLMModel(llmModel) }
                SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { saveAPIKey() }
            }
            Section(String(localized: "任务提示词")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Refine — 润色转写文字")).font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $refinePrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .onChange(of: refinePrompt) { AppPreferences.shared.refinePrompt = refinePrompt }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Summary — 生成全文摘要")).font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $summaryPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 60)
                        .onChange(of: summaryPrompt) { AppPreferences.shared.summaryPrompt = summaryPrompt }
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
        }
        .formStyle(.grouped)
        .onAppear {
            llmEnabled = AppPreferences.shared.llmEnabled
            llmProvider = AppPreferences.shared.llmProvider
            refinePrompt = AppPreferences.shared.refinePrompt
            summaryPrompt = AppPreferences.shared.summaryPrompt
            loadProviderConfig()
        }
    }

    private func loadProviderConfig() {
        llmBaseURL = AppPreferences.shared.llmBaseURL()
        llmModel = AppPreferences.shared.llmModel()
        apiKey = AppPreferences.shared.llmAPIKey()
    }

    private func saveAPIKey() {
        AppPreferences.shared.setLLMAPIKey(apiKey)
    }

    private func testConnection() {
        testError = ""; testSuccess = false
        guard !llmBaseURL.isEmpty else { testError = "请输入 Base URL"; return }
        guard let baseURL = URL(string: llmBaseURL) else { testError = "无效的 URL: \(llmBaseURL)"; return }
        Task {
            do {
                let provider: LLMProvider = switch llmProvider {
                case "anthropic": .anthropic
                case "ollama": .ollama
                default: .openai
                }
                await LLMClient.shared.configure(provider: provider, baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: llmModel)
                let result = try await LLMClient.shared.refine(text: "测试", customPrompt: refinePrompt.isEmpty ? nil : refinePrompt)
                testSuccess = true
                testError = "成功: \(result.prefix(100))"
            } catch let err as LLMClientError {
                testError = "\(err.localizedDescription)"
            } catch {
                let nsErr = error as NSError
                testError = "失败: \(error.localizedDescription)\nDomain: \(nsErr.domain) Code: \(nsErr.code)\nURL: \(llmBaseURL)\nProvider: \(llmProvider)\nModel: \(llmModel)"
            }
        }
    }
}
