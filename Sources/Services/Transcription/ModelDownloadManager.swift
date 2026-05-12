import Foundation

public struct ModelInfo: Sendable {
    public let id: String
    public let displayName: String
    public let downloadURL: String
    public let fileSize: Int64
    public let sizeLabel: String
    public let hfRepo: String
    public let hfFiles: [String]
    public let msRepo: String

    public var fileSizeDescription: String {
        if !sizeLabel.isEmpty { return sizeLabel }
        let mb = Double(fileSize) / 1_000_000
        if mb > 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }

    public init(id: String, displayName: String, downloadURL: String = "", fileSize: Int64 = 0, sizeLabel: String = "", hfRepo: String = "", msRepo: String = "", hfFiles: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.fileSize = fileSize
        self.sizeLabel = sizeLabel
        self.hfRepo = hfRepo
        self.hfFiles = hfFiles
        self.msRepo = msRepo
    }
}

public actor ModelDownloadManager {
    public static let shared = ModelDownloadManager()

    public enum DownloadError: LocalizedError {
        case invalidURL
        case downloadFailed(Error)
        case fileListFailed
        case extractionFailed
        case savePathCreationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的下载地址"
            case .downloadFailed(let error): return "下载失败: \(error.localizedDescription)"
            case .fileListFailed: return "无法获取模型文件列表"
            case .extractionFailed: return "文件解压失败"
            case .savePathCreationFailed: return "无法创建存储目录"
            }
        }
    }

    private let modelsDirectory: URL
    private let session: URLSession

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("VoiceGum/Models", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    public func getModelsDirectory() -> URL { modelsDirectory }

    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    public func isModelDownloaded(_ modelId: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent(modelId)
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelPath.path) {
            return contents.contains(where: { !$0.hasSuffix(".part") })
        }
        return false
    }

    public func partialDownloadInfo(_ modelId: String, expectedSize: Int64) -> (downloadedBytes: Int64, progress: Double)? {
        let modelPath = modelsDirectory.appendingPathComponent(modelId)
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelPath.path) else { return nil }
        let partFiles = contents.filter { $0.hasSuffix(".part") }
        guard !partFiles.isEmpty else { return nil }
        var total: Int64 = 0
        for f in partFiles {
            let p = modelPath.appendingPathComponent(f)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        let effectiveTotal = expectedSize > 0 ? expectedSize : 1
        let progress = min(Double(total) / Double(effectiveTotal), 0.99)
        return (total, progress)
    }

    public func deleteModel(_ modelId: String) throws {
        let modelPath = modelsDirectory.appendingPathComponent(modelId)
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
        }
    }

    public func downloadModel(
        _ model: ModelInfo,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try ensureDirectoryExists()

        let modelDir = modelsDirectory.appendingPathComponent(model.id)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let filesToDownload = model.hfFiles
        guard !filesToDownload.isEmpty else {
            await Logger.shared.warn("无文件列表: \(model.id)")
            throw DownloadError.invalidURL
        }

        // ModelScope primary (faster in China), HuggingFace fallback
        let primaryURLs: [String]
        let fallbackURLs: [String]
        if !model.msRepo.isEmpty {
            primaryURLs = filesToDownload.map { "https://www.modelscope.cn/models/\(model.msRepo)/resolve/master/\($0)" }
            fallbackURLs = filesToDownload.map { "https://huggingface.co/\(model.hfRepo)/resolve/main/\($0)" }
        } else {
            primaryURLs = filesToDownload.map { "https://huggingface.co/\(model.hfRepo)/resolve/main/\($0)" }
            fallbackURLs = []
        }

        await Logger.shared.info("""
        开始下载: \(model.displayName) (\(model.fileSizeDescription))
          保存: \(modelDir.path)
          主地址: \(primaryURLs.joined(separator: ", "))
        """)

        let totalFiles = filesToDownload.count

        for (index, fileName) in filesToDownload.enumerated() {
            let destPath = modelDir.appendingPathComponent(fileName)

            let wroteBytes: Int64
            do {
                guard let url = URL(string: primaryURLs[index]) else { throw DownloadError.invalidURL }
                await Logger.shared.info("[\(index+1)/\(totalFiles)] \(primaryURLs[index])")
                wroteBytes = try await downloadSingleFile(url: url, destination: destPath, fileIndex: index, totalFiles: totalFiles, estimatedSize: model.fileSize, progressHandler: progressHandler)
            } catch {
                if index < fallbackURLs.count, let fbURL = URL(string: fallbackURLs[index]) {
                    await Logger.shared.warn("重试备用: \(fallbackURLs[index])")
                    wroteBytes = try await downloadSingleFile(url: fbURL, destination: destPath, fileIndex: index, totalFiles: totalFiles, estimatedSize: model.fileSize, progressHandler: progressHandler)
                } else {
                    await Logger.shared.error("下载失败: \(error.localizedDescription)")
                    throw error
                }
            }
            await Logger.shared.info("[\(index+1)/\(totalFiles)] 完成 (\(ByteCountFormatter.string(fromByteCount: wroteBytes, countStyle: .file)))")
        }

        await Logger.shared.info("下载完成: \(model.displayName)")
    }

    private func downloadSingleFile(
        url: URL,
        destination: URL,
        fileIndex: Int,
        totalFiles: Int,
        estimatedSize: Int64,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let partFile = destination.appendingPathExtension("part")
        let destDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Check for partial download to resume
        let existingSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: partFile.path),
               let size = attrs[.size] as? Int64, size > 0 {
                return size
            }
            return 0
        }()

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        var totalExpectedLength: Int64 = 0
        var receivedLength: Int64 = 0

        if existingSize > 0 {
            // Resume download
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            await Logger.shared.info("断点续传: 已有 \(ByteCountFormatter.string(fromByteCount: existingSize, countStyle: .file))")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed(URLError(.unknown))
        }

        let isResume = httpResponse.statusCode == 206
        guard (200...299).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed(URLError(.init(rawValue: httpResponse.statusCode)))
        }

        if isResume {
            // Server accepted range request
            let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? ""
            if let totalStr = contentRange.components(separatedBy: "/").last,
               let total = Int64(totalStr) {
                totalExpectedLength = total
            }
            receivedLength = existingSize
            await Logger.shared.debug("续传: Content-Range=\(contentRange), total=\(totalExpectedLength)")
        } else {
            // Server doesn't support resume, or no partial file - restart
            if existingSize > 0 {
                try? FileManager.default.removeItem(at: partFile)
                await Logger.shared.debug("服务器不支持续传，重新下载")
            }
            totalExpectedLength = httpResponse.expectedContentLength
            receivedLength = 0
        }

        var lastProgress = 0.0
        let fileHandle: FileHandle
        if isResume {
            fileHandle = try FileHandle(forUpdating: partFile)
            try fileHandle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: partFile.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: partFile)
        }

        for try await byte in asyncBytes {
            try fileHandle.write(contentsOf: [byte])
            receivedLength += 1

            let effectiveTotal = totalExpectedLength > 0 ? totalExpectedLength : estimatedSize
            let fileProgress: Double
            if effectiveTotal > 0 {
                fileProgress = min(Double(receivedLength) / Double(effectiveTotal), 0.99)
            } else {
                fileProgress = min(Double(receivedLength) / Double(max(estimatedSize, 1)), 0.99)
            }
            let overall = (Double(fileIndex) + fileProgress) / Double(totalFiles)

            if overall - lastProgress > 0.01 {
                progressHandler(overall)
                lastProgress = overall
            }
        }
        try fileHandle.close()

        // Move .part to final destination
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partFile, to: destination)

        return receivedLength
    }
}

// MARK: - Model Catalog

public let allModels: [ModelInfo] = [
    ModelInfo(
        id: "sense-voice-q8-0", displayName: "Small Q8_0",
        fileSize: 230_000_000, sizeLabel: "~230 MB",
        hfRepo: "lovemefan/sense-voice-gguf",
        msRepo: "lovemefan/SenseVoiceGGUF",
        hfFiles: ["sense-voice-small-q8_0.gguf"]
    ),
    ModelInfo(
        id: "sense-voice-fp16", displayName: "Small FP16",
        fileSize: 350_000_000, sizeLabel: "~350 MB",
        hfRepo: "lovemefan/sense-voice-gguf",
        msRepo: "lovemefan/SenseVoiceGGUF",
        hfFiles: ["sense-voice-small-fp16.gguf"]
    ),
    ModelInfo(
        id: "sense-voice-fp32", displayName: "Small FP32 (最高精度)",
        fileSize: 700_000_000, sizeLabel: "~700 MB",
        hfRepo: "lovemefan/sense-voice-gguf",
        msRepo: "lovemefan/SenseVoiceGGUF",
        hfFiles: ["sense-voice-small-fp32.gguf"]
    ),
]


public func model(for id: String) -> ModelInfo? {
    allModels.first { $0.id == id }
}
