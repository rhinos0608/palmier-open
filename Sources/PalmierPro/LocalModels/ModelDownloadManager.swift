import Foundation

@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var activeDownloads: [String: DownloadState] = [:]

    struct DownloadState {
        var progress: Double
        var bytesWritten: Int64
        var totalBytes: Int64
        var isPaused: Bool
    }

    private let registry: LocalModelRegistry
    private let hfClient: HuggingFaceClient
    private var resumeData: [String: Data] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(registry: LocalModelRegistry, hfClient: HuggingFaceClient) {
        self.registry = registry
        self.hfClient = hfClient
    }

    var isDownloading: Bool { !activeDownloads.isEmpty }

    func downloadModel(_ model: LocalModel, files: [String]) {
        let task = Task { [weak self] in
            guard let self else { return }

            let modelDir = registry.modelDirectory(for: model.id)
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            registry.updateState(model.id, state: ModelState.loading)
            activeDownloads[model.id] = DownloadState(
                progress: 0,
                bytesWritten: 0,
                totalBytes: Int64(model.sizeBytes),
                isPaused: false
            )

            var succeeded = true
            for (index, file) in files.enumerated() {
                let fileProgress = Double(index) / Double(files.count)
                let dest = modelDir.appendingPathComponent(file)

                do {
                    try await hfClient.downloadFile(
                        repoId: model.repoId,
                        filename: file,
                        to: dest
                    ) { [weak self] p in
                        guard let self else { return }
                        let totalProgress = fileProgress + (p / Double(files.count))
                        self.activeDownloads[model.id]?.progress = totalProgress
                        self.registry.updateDownloadProgress(model.id, progress: totalProgress)
                    }
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    succeeded = false
                    break
                }
            }

            if succeeded {
                var installed = model.withState(ModelState.dormant)
                installed.installPath = registry.modelDirectory(for: model.id).path
                registry.addModel(installed)
            } else {
                registry.updateState(model.id, state: ModelState.error)
            }
            registry.updateDownloadProgress(model.id, progress: Optional<Double>.none)
            activeDownloads.removeValue(forKey: model.id)
            tasks.removeValue(forKey: model.id)
        }
        tasks[model.id] = task
    }

    func cancelDownload(_ modelId: String) {
        tasks[modelId]?.cancel()
        tasks.removeValue(forKey: modelId)
        activeDownloads.removeValue(forKey: modelId)
        registry.updateState(modelId, state: ModelState.dormant)
        registry.updateDownloadProgress(modelId, progress: Optional<Double>.none)
    }

    func isDownloaded(_ modelId: String) -> Bool {
        registry.models.first(where: { $0.id == modelId })?.installPath != nil
    }

    func modelSize(for model: HFModel) -> Int64 {
        model.siblings?
            .compactMap(\.size)
            .reduce(0, +) ?? 0
    }
}
