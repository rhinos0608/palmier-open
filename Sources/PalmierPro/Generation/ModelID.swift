import Foundation

enum ModelID: Hashable, Sendable {
    case remote(String)
    case local(category: ModelCategory, repoId: String)

    var displayString: String {
        switch self {
        case .remote(let id): id
        case .local(_, let repo): repo.split(separator: "/").last.map(String.init) ?? repo
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var remoteID: String? {
        if case .remote(let id) = self { return id }
        return nil
    }

    var localCategory: ModelCategory? {
        if case .local(let cat, _) = self { return cat }
        return nil
    }

    var localRepoId: String? {
        if case .local(_, let repo) = self { return repo }
        return nil
    }

    init(string: String) {
        if string.hasPrefix("local:") {
            let rest = String(string.dropFirst("local:".count))
            if let colonIndex = rest.firstIndex(of: ":") {
                let catStr = String(rest[..<colonIndex])
                let repo = String(rest[rest.index(after: colonIndex)...])
                if let cat = ModelCategory(rawValue: catStr) {
                    self = .local(category: cat, repoId: repo)
                    return
                }
            }
        }
        if ProviderConfig.isLocalAIEnabled {
            for category in ModelCategory.allCases {
                if ProviderConfig.selectedLocalModel(for: category) == string {
                    self = .local(category: category, repoId: string)
                    return
                }
            }
        }
        self = .remote(string)
    }

    var stringValue: String {
        switch self {
        case .remote(let id): id
        case .local(let cat, let repo): "local:\(cat.rawValue):\(repo)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(string: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

extension LocalModel {
    var modelID: ModelID {
        .local(category: category, repoId: repoId)
    }
}
