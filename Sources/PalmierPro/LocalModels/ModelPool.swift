import Foundation
import Dispatch

@MainActor
final class ModelPool: ObservableObject {
    @Published private(set) var activeModels: [ModelCategory: PooledModel] = [:]
    @Published private(set) var memoryUsageMB: Int = 0
    @Published private(set) var systemMemoryPressure: MemoryPressure = .normal

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let memoryBudgetBytes: Int64

    struct PooledModel {
        var model: LocalModel
        let loadedAt: Date
        var lastUsed: Date
    }

    enum MemoryPressure {
        case normal, warning, critical
    }

    init(budgetGB: Double? = nil) {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let budget = budgetGB ?? Double(totalMemory) * 0.6 / 1_073_741_824
        self.memoryBudgetBytes = Int64(budget * 1_073_741_824)
        startMemoryPressureMonitoring()
    }

    var activeModelCount: Int { activeModels.count }

    func isActive(_ modelId: String) -> Bool {
        activeModels.values.contains { $0.model.id == modelId }
    }

    func activeModel(for category: ModelCategory) -> LocalModel? {
        activeModels[category]?.model
    }

    func loadModel(_ model: LocalModel) async throws {
        if let existing = activeModels[model.category], existing.model.id == model.id {
            activeModels[model.category]?.lastUsed = Date()
            return
        }

        let neededBytes = model.sizeBytes
        let currentUsage = currentMemoryUsage()
        let available = memoryBudgetBytes - currentUsage

        if neededBytes > available {
            await evictToFit(neededBytes: neededBytes)
        }

        if let existing = activeModels[model.category] {
            if existing.model.state == .pinned { return }
            await performEvict(model: existing.model)
        }

        let updated = model.withState(.loading)
        activeModels[model.category] = PooledModel(
            model: updated,
            loadedAt: Date(),
            lastUsed: Date()
        )

        try await performLoad(model: updated)

        let loaded = updated.withState(.active)
        activeModels[model.category] = PooledModel(
            model: loaded,
            loadedAt: Date(),
            lastUsed: Date()
        )
        memoryUsageMB = Int(currentMemoryUsage() / 1_048_576)
    }

    func evictModel(_ modelId: String) async {
        guard let (category, pooled) = activeModels.first(where: { $0.value.model.id == modelId }) else { return }
        activeModels.removeValue(forKey: category)
        await performEvict(model: pooled.model)
        memoryUsageMB = Int(currentMemoryUsage() / 1_048_576)
    }

    func evictAll() async {
        let models = activeModels
        activeModels.removeAll()
        for (_, pooled) in models {
            await performEvict(model: pooled.model)
        }
        memoryUsageMB = Int(currentMemoryUsage() / 1_048_576)
    }

    func togglePin(_ modelId: String) {
        guard let (category, pooled) = activeModels.first(where: { $0.value.model.id == modelId }) else { return }
        var model = pooled.model
        switch model.state {
        case .active: model.state = .pinned
        case .pinned: model.state = .active
        default: break
        }
        activeModels[category] = PooledModel(model: model, loadedAt: pooled.loadedAt, lastUsed: pooled.lastUsed)
    }

    private func evictToFit(neededBytes: Int64) async {
        let unpinned = activeModels
            .filter { $0.value.model.state != .pinned }
            .sorted { a, b in
                if a.value.model.category.memoryPriority != b.value.model.category.memoryPriority {
                    return a.value.model.category.memoryPriority < b.value.model.category.memoryPriority
                }
                return a.value.lastUsed < b.value.lastUsed
            }

        var freed: Int64 = 0
        for (category, pooled) in unpinned {
            guard freed < neededBytes else { break }
            freed += pooled.model.sizeBytes
            activeModels.removeValue(forKey: category)
            await performEvict(model: pooled.model)
        }
    }

    private func performLoad(model: LocalModel) async {
        // Actual MLX model loading will be implemented per-category
    }

    private func performEvict(model: LocalModel) async {
        // MLX cache clearing will be wired when MLX dependency is added
    }

    private func currentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.critical) {
                self.systemMemoryPressure = .critical
                Task { await self.evictForPressure(.critical) }
            } else if event.contains(.warning) {
                self.systemMemoryPressure = .warning
                Task { await self.evictForPressure(.warning) }
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    private func evictForPressure(_ pressure: MemoryPressure) async {
        let unpinned = activeModels
            .filter { $0.value.model.state != .pinned }
            .sorted { $0.value.model.category.memoryPriority < $1.value.model.category.memoryPriority }

        switch pressure {
        case .warning:
            if let first = unpinned.first {
                activeModels.removeValue(forKey: first.key)
                await performEvict(model: first.value.model)
            }
        case .critical:
            for (category, pooled) in unpinned {
                activeModels.removeValue(forKey: category)
                await performEvict(model: pooled.model)
            }
        case .normal:
            break
        }
        memoryUsageMB = Int(currentMemoryUsage() / 1_048_576)
    }
}

extension LocalModel {
    func withState(_ state: ModelState) -> LocalModel {
        var copy = self
        copy.state = state
        return copy
    }
}
