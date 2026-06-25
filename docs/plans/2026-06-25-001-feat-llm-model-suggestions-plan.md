---
title: feat: LLM settings — reorder fields + model suggestions from API
type: feat
status: active
date: 2026-06-25
---

# feat: LLM 配置优化 — 字段重排 + 模型下拉建议

## Summary

将 LLM 设置面板的 API Key 字段移到 Base URL 之前，与 Provider 选择相邻。Model 输入从纯文本框改为支持下拉建议的 combo box，建议列表通过调用 `{BaseURL}/models`（或对应 provider 的模型列表接口）动态获取。

---

## Requirements

### 界面布局

- R1. API Key 字段排在 Base URL 之前
- R5. 测试和清空 Key 两个按钮移到任务提示词前面

### 模型下拉建议

- R2. Model 输入框支持下拉建议列表
- R3. 建议列表数据来自远程模型列表 API

### Provider 适配

- R4. Ollama provider 使用 `/api/tags` 获取模型列表（非 `/models`）

---

## Scope Boundaries

- 不改变 provider 选项集合（保持 OpenAI / Anthropic / Ollama 三个）
- 不缓存模型列表到本地（每次刷新重新获取）
- 不自动校验用户输入的模型是否在建议列表中
- 不重构 `LLMClient.send()` 的请求分发逻辑

---

## Key Technical Decisions

### Provider 感知的模型列表端点

| Provider | 端点 | 响应解析 |
|----------|------|----------|
| OpenAI 兼容 | `GET {baseURL}/models` | `.data[].id` |
| Anthropic 兼容 | `GET {baseURL}/models` | `.data[].id`（许多代理实现此端点） |
| Ollama | `GET {baseURL}/api/tags` | `.models[].name` |

Anthropic 官方无模型列表 API，但社区代理普遍实现 OpenAI 兼容的 `/models`。若请求失败（404 等），返回空列表，UI 降级为纯文本输入。

### 模型获取触发方式

- 手动触发：Model 输入框旁增加刷新按钮
- 切换 Provider 后自动触发
- Base URL 变更后不自动触发（避免每次输入字符都请求）

---

## Implementation Units

### U1. LLMClient — 添加模型列表获取方法

**Goal:** 为 `LLMClient` 添加 `fetchAvailableModels()` 方法，支持 provider 感知的模型列表获取。

**Requirements:** R3, R4

**Dependencies:** 无

**Files:**
- `Sources/Services/LLM/LLMClient.swift`

**Approach:**
1. 在 `LLMClient` actor 中新增 `fetchAvailableModels()` 方法
2. 方法接受 `provider` 和 `baseURL` 参数（不依赖 actor 内部状态，避免 SettingsView 调用时尚未 configure 的时序问题）
3. 根据 provider 选择端点路径：Ollama → `api/tags`，其他 → `models`
4. 若 baseURL 为空，直接返回空数组（guard 在构造 URLRequest 前）
5. 发起 GET 请求，解析 JSON 返回模型名称数组
6. 失败时返回空数组，不抛异常（保证 UI 降级体验）
7. 复用现有 `URLSession` 配置，5 秒超时避免阻塞

**Patterns to follow:** LLMClient 现有的 `send()` 方法中的 `buildURL` 和 `URLRequest` 构造模式

**Test scenarios:**
- OpenAI provider 调用 `/models`，响应包含 `.data[]` → 返回模型名列表
- Ollama provider 调用 `/api/tags`，响应包含 `.models[]` → 返回模型名列表
- Anthropic provider 调用 `/models` 404 → 返回空数组
- 网络超时 → 返回空数组
- Base URL 为空 → 返回空数组

**Verification:** 构建后可在 Settings UI 点击刷新按钮验证模型列表加载

---

### U2. SettingsView — 字段重排与模型下拉建议

**Goal:** 重排 LLM 设置字段顺序，为 Model 输入添加下拉建议列表。

**Requirements:** R1, R2, R5

**Dependencies:** U1

**Files:**
- `Sources/Core/SettingsView.swift`

**Approach:**
1. 将测试 Section（测试 + 清空 Key 按钮）移到任务提示词 Section 之前
2. 在 API 配置 Section 内，将 `SecureField("API Key", ...)` 移到 `TextField("Base URL", ...)` 之前
3. 添加 `@State private var availableModels: [String] = []` 和 `@State private var isFetchingModels = false`
4. 添加 `modelFetchTask: Task<Void, Never>?` 用于取消进行中的请求
5. Model 输入改为 HStack：`TextField("Model", ...)` + `Menu`（下拉按钮）
6. 点击下拉按钮展开可用模型列表，选中后填入 TextField
7. 添加刷新按钮：fetching 时禁用并显示 ProgressView，期间下拉保留上次结果
8. 调用 `LLMClient.shared.fetchAvailableModels(provider:baseURL:)` 时取消上一个 task 防止竞态
9. 切换 Provider 时取消进行中的请求并自动触发刷新
10. 刷新按钮添加 `.accessibilityLabel`，Model 输入 HStack 添加 `.accessibilityElement(children: .combine)`

**新 Section 顺序：**
```
API 配置 → 测试 → 任务提示词
```
**API 配置内字段顺序：**
```
Provider → API Key → Base URL → Model (+ 下拉按钮 + 刷新按钮)
```

**Patterns to follow:** SettingsView 现有的 `Form` / `Section` / `Picker` 风格，ASRSettingsTab 中的下拉选择模式

**Test scenarios:**
- 默认状态：Model 为纯文本框，无下拉内容
- 输入有效 Base URL + 点刷新 → 按钮转圈 → 模型列表加载 → 下拉菜单显示模型名
- 点击下拉中的某个模型 → TextField 更新为所选模型名
- 切换 Provider → 模型列表自动重新加载
- 网络失败 → 返回空列表，TextField 仍可手动输入
- 字段顺序视觉验证：API Key 在 Base URL 上方
- Section 顺序验证：测试按钮在任务提示词上方
- 快速切换 Provider → 上一个请求被取消 → 仅最后一个 provider 的模型列表展示
- Fetching 中再次点刷新 → 按钮禁用，不发起重复请求

**Verification:** 用 Ollama 本地服务或 OpenAI 兼容端点测试模型列表获取和下拉交互

---

## Sources & References

- `Sources/Core/SettingsView.swift:366-465` — LLMSettingsTab 当前实现
- `Sources/Services/LLM/LLMClient.swift:49-94` — LLMClient configure / buildURL
- `Sources/Preferences/AppPreferences.swift:86-167` — LLM 相关持久化属性
