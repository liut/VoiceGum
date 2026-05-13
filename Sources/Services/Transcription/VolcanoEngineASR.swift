import Foundation

// MARK: - v3 Binary Protocol Constants

private let MSG_CLIENT_FULL_REQUEST: UInt8 = 0b0001
private let MSG_CLIENT_AUDIO_ONLY: UInt8 = 0b0010
private let MSG_SERVER_FULL_RESPONSE: UInt8 = 0b1001
private let MSG_SERVER_ERROR: UInt8 = 0b1111

// Per official doc: client requests use NO_SEQUENCE or NEG_SEQUENCE (for last)
// Server responses use POS_SEQUENCE or NEG_WITH_SEQUENCE
private let FLAG_NO_SEQUENCE: UInt8 = 0b0000
private let FLAG_POS_SEQUENCE: UInt8 = 0b0001
private let FLAG_NEG_SEQUENCE: UInt8 = 0b0010
private let FLAG_NEG_WITH_SEQUENCE: UInt8 = 0b0011

private let SER_NONE: UInt8 = 0b0000
private let SER_JSON: UInt8 = 0b0001

private let COMP_NONE: UInt8 = 0b0000
private let COMP_GZIP: UInt8 = 0b0001

// MARK: - Frame Builder (client → server, no sequence in frames per official doc)

private func buildHeader(type: UInt8, flags: UInt8, serialization: UInt8, compression: UInt8) -> Data {
    Data([0x11, (type << 4) | flags, (serialization << 4) | compression, 0x00])
}

/// Build a client→server frame. Per official doc, client frames do NOT include sequence numbers.
private func buildClientFrame(type: UInt8, flags: UInt8, serialization: UInt8, compression: UInt8, payload: Data) -> Data? {
    let compressed: Data
    let compFlag: UInt8
    if compression == COMP_GZIP {
        guard let gz = Gzip.compress(payload) else { return nil }
        compressed = gz
        compFlag = COMP_GZIP
    } else {
        compressed = payload
        compFlag = COMP_NONE
    }
    var frame = buildHeader(type: type, flags: flags, serialization: serialization, compression: compFlag)
    var size = UInt32(compressed.count).bigEndian
    frame.append(Data(bytes: &size, count: 4))
    frame.append(compressed)
    return frame
}

// MARK: - Volcano Engine ASR (v3 bigmodel_nostream)

public actor VolcanoEngineASR: TranscriptionService {
    public let serviceName = "火山引擎"

    private let appId: String
    private let accessToken: String
    private let resourceId: String
    private let wsURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"

    public init(appId: String, accessToken: String, resourceId: String = "volc.seedasr.sauc.duration") {
        self.appId = appId
        self.accessToken = accessToken
        self.resourceId = resourceId
    }

    public func transcribe(file: URL, language: String) async throws -> TranscriptionResult {
        let startedAt = Date()
        let requestId = UUID().uuidString
        let connectId = UUID().uuidString
        await Logger.shared.info("开始转写 requestId=\(requestId) file=\(file.lastPathComponent)")

        let wavFile = try await AudioConverter.convertTo16kHzWav(file)
        let pcmData = try readPCMData(from: wavFile)
        let audioDuration = Double(pcmData.count) / 32000.0
        await Logger.shared.info("音频转换完成 时长=\(String(format: "%.1f", audioDuration))s PCM大小=\(pcmData.count) bytes")

        var wsReq = URLRequest(url: URL(string: wsURL)!)
        wsReq.timeoutInterval = 30
        wsReq.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        wsReq.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        wsReq.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        wsReq.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        wsReq.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")

        let wsTask = URLSession.shared.webSocketTask(with: wsReq)
        wsTask.resume()

        // Wait for handshake
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                wsTask.sendPing { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        } catch {
            let detail = await fetchAuthError()
            await Logger.shared.info("WebSocket 连接失败: \(error.localizedDescription) detail=\(detail)")
            throw TranscriptionError.transcriptionFailed("火山引擎连接失败\(detail)")
        }
        await Logger.shared.info("WebSocket 已连接 connectId=\(connectId)")

        let langCode = languageCode(for: language)
        let totalChunks = (pcmData.count + 6399) / 6400

        let resultText = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                defer { wsTask.cancel(with: .normalClosure, reason: nil) }

                // 1. Full Client Request (flags = NO_SEQUENCE per official doc)
                let config: [String: Any] = [
                    "user": ["uid": "voicegum-app"],
                    "audio": [
                        "format": "pcm",
                        "rate": 16000,
                        "bits": 16,
                        "channel": 1,
                        "language": langCode
                    ],
                    "request": [
                        "model_name": "bigmodel",
                        "enable_itn": true,
                        "enable_punc": true,
                        "show_utterances": true
                    ]
                ]
                let configJSON = try JSONSerialization.data(withJSONObject: config)
                guard let frame = buildClientFrame(type: MSG_CLIENT_FULL_REQUEST, flags: FLAG_NO_SEQUENCE,
                                                     serialization: SER_JSON, compression: COMP_GZIP,
                                                     payload: configJSON) else {
                    throw TranscriptionError.transcriptionFailed("火山引擎: gzip 压缩失败")
                }
                try await wsTask.send(.data(frame))
                await Logger.shared.info("已发送配置帧")

                // 2. Audio chunks (flags = NO_SEQUENCE or NEG_SEQUENCE for last)
                let bytesPerChunk = 6400
                var sentChunks = 0
                var offset = 0
                while offset < pcmData.count {
                    if Task.isCancelled { return "" }
                    let end = min(offset + bytesPerChunk, pcmData.count)
                    let chunk = pcmData.subdata(in: offset..<end)
                    let isLast = end >= pcmData.count
                    let flags: UInt8 = isLast ? FLAG_NEG_SEQUENCE : FLAG_NO_SEQUENCE

                    guard let af = buildClientFrame(type: MSG_CLIENT_AUDIO_ONLY, flags: flags,
                                                     serialization: SER_NONE, compression: COMP_GZIP,
                                                     payload: chunk) else {
                        throw TranscriptionError.transcriptionFailed("火山引擎: gzip 压缩失败")
                    }
                    try await wsTask.send(.data(af))
                    offset = end
                    sentChunks += 1
                    if !isLast {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                await Logger.shared.info("音频发送完成 chunks=\(sentChunks)/\(totalChunks)")

                // 3. Receive results
                var finalText = ""
                var receivedCount = 0
                while true {
                    if Task.isCancelled { break }
                    let msg: URLSessionWebSocketTask.Message
                    do { msg = try await wsTask.receive() } catch {
                        await Logger.shared.info("WebSocket 接收结束: \(error.localizedDescription)")
                        break
                    }

                    guard case .data(let rawFrame) = msg else { continue }
                    guard let parsed = parseFrame(rawFrame) else { continue }

                    if parsed.type == MSG_SERVER_ERROR {
                        if let payload = parsed.payload,
                           let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                            await Logger.shared.info("服务端错误: \(String(describing: json))")
                        }
                        throw TranscriptionError.transcriptionFailed("火山引擎服务端错误")
                    }

                    guard parsed.type == MSG_SERVER_FULL_RESPONSE, let payload = parsed.payload else { continue }

                    receivedCount += 1
                    if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                       let result = json["result"] as? [String: Any],
                       let text = result["text"] as? String {
                        finalText = text
                    }
                    if parsed.isLast {
                        await Logger.shared.info("收到最终结果 chunks=\(receivedCount) textLen=\(finalText.count)")
                        break
                    }
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                await Logger.shared.info("转写完成 耗时=\(String(format: "%.1f", elapsed))s requestId=\(requestId)")
                return finalText
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000) // 5 min timeout for long audio
                await Logger.shared.info("转写超时 requestId=\(requestId)")
                wsTask.cancel(with: .normalClosure, reason: nil)
                throw TranscriptionError.transcriptionFailed("火山引擎: 转写超时")
            }

            let text = try await group.next()!
            group.cancelAll()
            return text
        }

        guard !resultText.isEmpty else {
            throw TranscriptionError.transcriptionFailed("火山引擎: 未收到识别结果")
        }
        await Logger.shared.info("转写成功 requestId=\(requestId) textLen=\(resultText.count)")
        return TranscriptionResult(text: resultText, timestamps: nil, language: language, confidence: nil)
    }

    private nonisolated func fetchAuthError() async -> String {
        let requestId = UUID().uuidString
        var req = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        req.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        req.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        req.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        req.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        let body: [String: Any] = [
            "user": ["uid": "voicegum"],
            "audio": ["format": "mp3", "url": "https://example.com/test.mp3"],
            "request": ["model_name": "bigmodel"]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            await Logger.shared.info("鉴权探测 HTTP \(statusCode)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                return ": \(error)"
            }
        } catch {
            await Logger.shared.info("鉴权探测失败: \(error.localizedDescription)")
        }
        return "，请检查 APP ID / Access Token / Resource ID"
    }

    private nonisolated func readPCMData(from wavURL: URL) throws -> Data {
        let data = try Data(contentsOf: wavURL)
        guard data.count > 44 else { throw TranscriptionError.invalidAudioFormat }
        return data.subdata(in: 44..<data.count)
    }

    private nonisolated func languageCode(for language: String) -> String {
        switch language {
        case "zh-CN": return "zh-CN"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return "zh-CN"
        }
    }
}

// MARK: - Frame Parser (server → client, responses DO have sequence numbers)

private struct ParsedFrame {
    let type: UInt8
    let isLast: Bool
    let payload: Data?
}

private func parseFrame(_ data: Data) -> ParsedFrame? {
    guard data.count >= 4 else { return nil }
    let headerSize = Int(data[0] & 0x0F) * 4
    guard data.count >= headerSize else { return nil }

    let msgType = data[1] >> 4
    let flags = data[1] & 0x0F
    let serialization = data[2] >> 4
    let compression = data[2] & 0x0F

    var offset = headerSize
    let hasSeq = (flags & 0x01) != 0
    if hasSeq {
        guard data.count >= offset + 4 else { return nil }
        offset += 4
    }
    let isLast = (flags & 0x02) != 0

    guard data.count >= offset + 4 else { return nil }
    let payloadSize = Int(data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
    offset += 4

    guard data.count >= offset + payloadSize else { return nil }
    var payload = data.subdata(in: offset..<offset+payloadSize)

    if compression == COMP_GZIP, let decompressed = Gzip.decompress(payload) {
        payload = decompressed
    }

    return ParsedFrame(type: msgType, isLast: isLast, payload: payload)
}
