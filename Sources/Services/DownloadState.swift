import Foundation

@MainActor
public final class DownloadState: ObservableObject {
    public static let shared = DownloadState()

    @Published public var downloadedModels: Set<String> = []
    @Published public var downloadingModels: Set<String> = []
    @Published public var downloadProgress: [String: Double] = [:]
    @Published public var partialProgress: [String: Double] = [:]
    @Published public var downloadError: String?

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private init() {
        Task { await refreshDownloaded() }
    }

    public func refreshDownloaded() async {
        var downloaded: Set<String> = []
        var partial: [String: Double] = [:]
        for model in allModels {
            if model.id.hasPrefix("qwen3") {
                if isQwenModelDownloaded(model.id) {
                    downloaded.insert(model.id)
                }
            } else if await ModelDownloadManager.shared.isModelDownloaded(model.id) {
                downloaded.insert(model.id)
            } else if let info = await ModelDownloadManager.shared.partialDownloadInfo(model.id, expectedSize: model.fileSize) {
                partial[model.id] = info.progress
            }
        }
        downloadedModels = downloaded
        partialProgress = partial
    }

    private func isQwenModelDownloaded(_ modelId: String) -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VoiceGum/Models/\(modelId)")
        let required = ["config.json", "vocab.json", "merges.txt"]
        let hasSafetensors = FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
        let hasIndex = FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors.index.json").path)
        guard hasSafetensors || hasIndex else { return false }
        return required.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    public func download(_ model: ModelInfo) {
        downloadingModels.insert(model.id)
        downloadProgress[model.id] = 0
        partialProgress.removeValue(forKey: model.id)
        downloadError = nil

        let task = Task {
            do {
                try await ModelDownloadManager.shared.downloadModel(model) { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress[model.id] = progress }
                }
                guard !Task.isCancelled else { return }
                downloadingModels.remove(model.id)
                downloadProgress.removeValue(forKey: model.id)
                downloadedModels.insert(model.id)
                downloadTasks.removeValue(forKey: model.id)
            } catch {
                guard !Task.isCancelled else { return }
                downloadingModels.remove(model.id)
                downloadProgress[model.id] = nil
                downloadError = error.localizedDescription
                downloadTasks.removeValue(forKey: model.id)
                // Refresh partial progress after error
                if let info = await ModelDownloadManager.shared.partialDownloadInfo(model.id, expectedSize: model.fileSize) {
                    partialProgress[model.id] = info.progress
                }
            }
        }
        downloadTasks[model.id] = task
    }

    public func pause(_ model: ModelInfo) {
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)
        downloadingModels.remove(model.id)
        downloadProgress.removeValue(forKey: model.id)
        // Refresh partial progress so UI shows the pause state
        Task {
            if let info = await ModelDownloadManager.shared.partialDownloadInfo(model.id, expectedSize: model.fileSize) {
                partialProgress[model.id] = info.progress
            }
        }
    }

    public func cancel(_ model: ModelInfo) {
        downloadTasks[model.id]?.cancel()
        downloadTasks.removeValue(forKey: model.id)
        downloadingModels.remove(model.id)
        downloadProgress.removeValue(forKey: model.id)
        partialProgress.removeValue(forKey: model.id)
        Task {
            try? await ModelDownloadManager.shared.deleteModel(model.id)
        }
    }

    public func delete(_ model: ModelInfo) {
        Task {
            try? await ModelDownloadManager.shared.deleteModel(model.id)
            downloadedModels.remove(model.id)
            partialProgress.removeValue(forKey: model.id)
        }
    }
}
