# VoiceGum

一款轻量级的 macOS 应用，可使用可配置的 ASR 引擎将音频文件转录为文本，并支持可选的 LLM 润色与摘要功能。同时提供基于管道的命令行转录工具。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![SPM](https://img.shields.io/badge/Build-SPM-green)

## 功能

### 音频转录
- **拖拽**或点选音频文件
- **支持格式**：`wav`、`mp3`、`m4a`、`flac`、`aac`、`alac`、`aiff`、`caf`、`mp4`、`mov`、`m4v`（包括仅含音频的视频容器）
- **文件大小限制**：WAV ≤ 200 MB，其他格式 ≤ 60 MB
- **多语言支持**：中文（简体 / 繁体）、英语、日语、韩语
- 带有取消支持的**实时进度**提示
- **结果导出**：复制到剪贴板，或自动保存至 `~/Library/Application Support/VoiceGum/Result/`

### ASR 引擎

| 类型 | 引擎 | 模型 | 说明 |
|------|--------|-------|-------|
| 在线 | OpenAI | Whisper API (`whisper-1` / `whisper-large`) | 兼容 OpenAI 的接口，API key 存储在钥匙串中 |
| 在线 | 火山引擎 | 流式 ASR | 字节跳动云端 API，需要 App ID / Access Token / Resource ID |
| 本地 | SenseVoice | GGUF (Q8_0 / FP16 / FP32) | 进程内通过 ggml + Metal 运行，支持 5 种语言，空闲后自动卸载 |
| 本地 | FunASR-Nano | GGUF（编码器 + 解码器） | 端到端基于 LLM 的 ASR，支持 31 种语言，解码器为 Qwen3-0.6B |

本地模型按需从 **HuggingFace**（主站）和 **ModelScope**（镜像站）下载，并支持断点续传。

### LLM 后处理
- **文本润色**：自动优化转录文本（标点、格式、错误修正）
- **摘要生成**：为转录内容生成简洁摘要
- **自定义提示词**：两项任务均支持用户自定义系统提示词
- **服务商**：OpenAI 兼容、Anthropic、Ollama（本地）
- **触发方式**：转录完成后自动执行

### 历史记录与管理
- 持久化保存转录历史，包括原始文本、润色文本和摘要
- 每条记录包含元数据：源文件、使用引擎、语言、时长

### 命令行工具（CLI）

```bash
# 转录一个文件
voicegum-cli audio.mp3

# 从标准输入管道传入音频
cat audio.mp3 | voicegum-cli

# 指定语言与输出文件
voicegum-cli audio.mp3 -l zh -o out.txt

# 使用 FunASR-Nano 以支持 31 种语言
voicegum-cli audio.mp3 --engine nano
```

完整用法请查看 `voicegum-cli --help`。使用 `make install-cli` 安装。

## 构建与运行

### 系统要求
- macOS 14+
- Xcode 16+ / Swift 6 工具链
- 本地模型推荐使用 Apple Silicon（M1+）
- 分发签名与公证需要 Apple Developer Program（$99/年）。本地开发无需该资格（`make run-app` 使用临时签名）

### 命令

```bash
make build          # 构建发布版二进制文件（GUI + CLI）
make run            # 从构建产物运行 GUI
make run-app        # 构建、打包、签名并作为 .app 启动
make run-cli        # 从构建产物运行 CLI
make install        # 安装 GUI 应用到 /Applications
make install-cli    # 安装 CLI 到 /usr/local/bin
make clean          # 清理构建产物
```

### 手动构建（SPM）

```bash
swift build -c release
```

构建产物位于 `.build/release/VoiceGum` 和 `.build/release/VoiceGumCLI`。

## 配置

### 首次启动
1. 启动应用以打开主窗口。
2. 拖入音频文件或点击选择。
3. 前往 **设置 → ASR** 选择引擎（在线或本地）。
4. （可选）前往 **设置 → LLM** 配置润色 / 摘要。

### 本地模型
本地模型存储在 `~/Library/Application Support/VoiceGum/Models/<id>/`：

| 模型 | 大小 | 精度 |
|-------|------|-----------|
| SenseVoice Q8_0 | 约 230 MB | 量化 |
| SenseVoice FP16 | 约 350 MB | 半精度 |
| SenseVoice FP32 | 约 700 MB | 全精度 |
| FunASR-Nano | 约 1.1 GB | 编码器 FP16 + 解码器 Q8_0 |

模型在首次使用时从 HuggingFace 下载。转录完成后 5 秒会自动卸载以释放内存。

### LLM 设置
| 服务商 | 基础 URL | 是否需要 API Key |
|----------|----------|------------------|
| OpenAI | `https://api.openai.com/v1` | ✅ |
| Anthropic | `https://api.anthropic.com` | ✅ |
| Ollama | `http://localhost:11434` | ❌ |

API key 存储在 **UserDefaults** 中（按服务商区分，可在设置中配置）。

### 权限
- **麦克风**：为未来的录音功能预留。当前版本未使用。


## 许可

Copyright © 2026 VoiceGum. 保留所有权利。
