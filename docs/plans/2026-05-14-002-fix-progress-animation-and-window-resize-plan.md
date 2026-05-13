---
title: Replace Progress Bar with Animation and Support Window Resize
type: fix
status: active
date: 2026-05-14
---

# Replace Progress Bar with Animation + Window Resize

## 1. 进度条 → 动画

**当前**：`TranscriptionProgressView` 分两路 — 本地模型显示圆形 `ProgressView`，在线 API 显示线形进度条。线形进度条对 WebSocket 流式识别无实际意义。

**改动**：统一为动画指示器。取消线形进度条，全部场景用圆形旋转动画 + 文字提示。

**文件**：`Sources/Core/StateViews.swift:63-107`（`TranscriptionProgressView`）

## 2. 窗口缩放时文本区域跟随

**当前**：`MainView` 有 `.frame(width: 480, height: 420)` 硬编码固定尺寸，窗口不可缩放。

**改动**：移除 MainView 的固定尺寸，只保留 `VoiceGumApp` 中的 `minWidth/minHeight`。DropZone 高度保持 120，下方内容区域自动填充剩余空间。

**文件**：
- `Sources/Core/MainView.swift:88` — 移除 `.frame(width: 480, height: 420)`
- `Sources/App/VoiceGumApp.swift:10-13` — 已有 `minWidth: 400, idealWidth: 480, minHeight: 360, idealHeight: 420`，无需修改

## Acceptance Criteria

- [ ] 在线转写时不再显示线形进度条，改为旋转动画
- [ ] 缩放窗口时文本区域跟随变大/变小
- [ ] DropZone 区域高度固定，不被压缩
