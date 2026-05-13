---
title: Add Transcription History Feature
type: feat
status: active
date: 2026-05-14
---

# Add Transcription History Feature

## Overview

添加转录历史功能。所有完成的转录结果持久化到 JSON 索引文件，用户可在独立窗口中浏览、查看、拷贝历史记录。标题优先取摘要前若干字符，无摘要则用原文件名。每条记录显示文件名、转录日期、引擎、时长等属性。

## Problem Statement

当前 `saveResults()` 将结果写入 `Result/` 目录的 `.txt` 文件后就再也没有被读取过。用户无法在应用内回顾之前的转录结果——文件在磁盘上但应用完全不可见。Summary 也仅在内存中，`reset()` 后即丢失。

## Proposed Solution

**数据层**：新增 `HistoryManager` actor，管理 `~/Library/Application Support/VoiceGum/Result/history.json` 索引文件。每条记录为 `HistoryEntry`（Codable），包含完整转录文本、摘要、元数据。

**UI 层**：主窗口新增"历史"按钮，打开独立 `NSWindow`（复用 Settings 窗口模式）。窗口内为 SwiftUI `List` + 详情视图，支持查看全文和拷贝。

**集成**：转录完成（含可选 Refine + Summary）后，`TranscriptionViewModel` 将完整结果写入 HistoryManager。音频时长通过 `AVAsset.duration` 在转录前获取。

## Technical Approach

### Data Model (`TranscriptionTypes.swift`)

新增 `HistoryEntry`：

```swift
struct HistoryEntry: Codable, Identifiable, Sendable {
    let id: String          // UUID
    let sourceFileName: String
    let timestamp: Date
    let engineDescription: String
    let language: String?
    let duration: TimeInterval?
    let text: String
    let summaryText: String?
    let resultFileName: String  // 对应 .txt 文件名

    var displayTitle: String {
        if let s = summaryText, !s.isEmpty {
            return String(s.prefix(30))
        }
        return sourceFileName
    }
}
```

`TranscriptionResult` 加 `Codable` conformance。

### HistoryManager (`Sources/Services/History/HistoryManager.swift`)

- Actor 单例，管理 `history.json` 的读写
- `entries: [HistoryEntry]` 内存缓存
- `add(_:)` 追加记录并写盘
- `load()` 启动时从 JSON 加载
- JSON 文件位于 `Result/history.json`

### Duration Capture (`TranscriptionViewModel.swift`)

在 `startTranscription()` 开始前，通过 `AVAsset(url: fileURL).duration` 获取时长，转换为秒，传递给 `saveToHistory()`。

### UI (`Sources/Core/HistoryView.swift`)

- `HistoryView` — 主视图，SwiftUI `List` 中每行显示标题、日期、引擎、时长
- `HistoryDetailView` — 选中条目后显示完整文本，支持拷贝和查看摘要
- 搜索/过滤（可选，按文件名或日期）

### Navigation (`MainView.swift` + `AppDelegate.swift`)

- `MainView` 标题栏加"历史"按钮
- `AppDelegate.openHistory()` 创建独立 `NSWindow`，`NSHostingController(rootView: HistoryView())`

### Integration Flow

```
Transcription complete → saveResults() (.txt file)
                       → [optional] LLM refine
                       → [optional] summarize
                       → HistoryManager.shared.add(entry)
```

## System-Wide Impact

### Interaction Graph
```
MainView "历史" button → AppDelegate.openHistory() → NSWindow + HistoryView
HistoryView.onAppear → HistoryManager.shared.load() → read history.json
TranscriptionViewModel.startTranscription() → AVAsset.duration
TranscriptionViewModel completion → HistoryManager.shared.add(entry) → write history.json
```

### Error Propagation
- `history.json` 读失败 → 空列表，不阻塞
- `history.json` 写失败 → Logger 记录，不阻塞转录流程
- AVAsset duration 读取失败 → `duration: nil`

### State Lifecycle Risks
- 转录中途取消：不写入历史（仅 `.completed` 状态写入）
- 摘要失败：summaryText 为 nil，不影响历史记录写入

### API Surface Parity
- `HistoryManager` 模式与 `AppPreferences` / `KeychainManager` 一致：actor 单例

## Acceptance Criteria

- [ ] 转录完成后自动保存到历史，含完整文本和摘要
- [ ] 历史窗口可打开，列出所有历史记录
- [ ] 标题优先取摘要前 30 字符，无摘要用原文件名
- [ ] 每条记录显示：标题、转录日期、引擎名称、时长
- [ ] 点击条目可查看全文，支持拷贝
- [ ] 摘要（如有）在详情中显示
- [ ] 关闭历史窗口后重新打开，数据仍在

## Dependencies & Risks

- **风险**：`history.json` 文件损坏。处理：加载失败时打印警告，返回空列表，下次写入覆盖。
- **风险**：历史条目过多导致 JSON 文件过大。处理：当前场景下单条转录 ~几 KB，1000 条也仅几 MB，无需分页。
- **前置**：无外部依赖，纯 Swift 标准库 + Foundation + SwiftUI。

## Files

| 操作 | 文件 |
|------|------|
| 新增 | `Sources/Services/History/HistoryManager.swift` |
| 新增 | `Sources/Core/HistoryView.swift` |
| 修改 | `Sources/Services/Transcription/TranscriptionTypes.swift` |
| 修改 | `Sources/Core/TranscriptionViewModel.swift` |
| 修改 | `Sources/Core/MainView.swift` |
| 修改 | `Sources/App/AppDelegate.swift` |

## Sources & References

### Internal
- saveResults 实现: `Sources/Core/TranscriptionViewModel.swift:224-253`
- TranscriptionResult 模型: `Sources/Services/Transcription/TranscriptionTypes.swift:3-15`
- Settings 独立窗口模式: `Sources/App/AppDelegate.swift:24-42`
- AppPreferences 单例模式: `Sources/Preferences/AppPreferences.swift`
- summarize 流程: `Sources/Core/TranscriptionViewModel.swift:194-213`
