import Foundation

@MainActor
final class LocalModelRegistry: ObservableObject {
    @Published private(set) var models: [LocalModel] = []

    private let manifestURL: URL
    private let hfClient: HuggingFaceClient
    private let modelsDirectory: URL

    init(hfClient: HuggingFaceClient = .init()) {
        self.hfClient = hfClient
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory = appSupport.appendingPathComponent("PalmierPro/Models", isDirectory: true)
        self.manifestURL = modelsDirectory.appendingPathComponent("manifest.json")
        loadManifest()
    }

    func models(for category: ModelCategory) -> [LocalModel] {
        models.filter { $0.category == category }
    }

    func activeModels(for category: ModelCategory) -> [LocalModel] {
        models.filter { $0.category == category && ($0.state == .active || $0.state == .pinned) }
    }

    func localModels(for category: ModelCategory) -> [LocalModel] {
        models.filter { $0.category == category && $0.installPath != nil }
    }

    func addModel(_ model: LocalModel) {
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
        } else {
            models.append(model)
        }
        saveManifest()
    }

    func removeModel(_ modelId: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelId }) else { return }
        let model = models[idx]
        if let path = model.installPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        models.remove(at: idx)
        saveManifest()
    }

    func updateState(_ modelId: String, state: ModelState) {
        guard let idx = models.firstIndex(where: { $0.id == modelId }) else { return }
        models[idx].state = state
        saveManifest()
    }

    func updateDownloadProgress(_ modelId: String, progress: Double?) {
        guard let idx = models.firstIndex(where: { $0.id == modelId }) else { return }
        models[idx].downloadProgress = progress
    }

    func modelDirectory(for modelId: String) -> URL {
        modelsDirectory.appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "_"))
    }

    func searchModels(
        query: String = "",
        category: ModelCategory,
        sort: ModelSortOption = .downloads,
        mlxOnly: Bool = true
    ) async throws -> [HFModel] {
        var fullQuery = query
        if mlxOnly {
            fullQuery = fullQuery.isEmpty ? "mlx" : "\(query) mlx"
        }
        let filter = category.hfFilter
        return try await hfClient.searchModels(
            query: fullQuery,
            filter: filter,
            sort: sort,
            limit: 30
        )
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        if let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) {
            self.models = manifest.models
        }
    }

    private func saveManifest() {
        let manifest = ModelManifest(models: models, lastUpdated: Date())
        if let data = try? JSONEncoder().encode(manifest) {
            try? FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: manifestURL)
        }
    }
}
