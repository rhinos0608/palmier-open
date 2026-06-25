import Foundation

struct HFSearchResponse: Codable {
    let id: String
    let author: String?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]?
    let downloads: Int?
    let likes: Int?
    let gated: Bool?
    let lastModified: String?
    let siblings: [HFSibling]?
}

extension HFSearchResponse {
    func toHFModel() -> HFModel {
        HFModel(
            id: id,
            author: author,
            pipelineTag: pipelineTag,
            libraryName: libraryName,
            tags: tags ?? [],
            downloads: downloads ?? 0,
            likes: likes ?? 0,
            gated: gated ?? false,
            lastModified: lastModified,
            siblings: siblings
        )
    }
}

actor HuggingFaceClient {
    private let baseURL = "https://huggingface.co/api/models"
    private let session: URLSession
    private var authToken: String?

    init(session: URLSession = .shared) {
        self.session = session
        self.authToken = Self.loadToken()
    }

    func setToken(_ token: String?) {
        self.authToken = token
    }

    func searchModels(
        query: String = "",
        filter: String? = nil,
        author: String? = nil,
        sort: ModelSortOption = .downloads,
        limit: Int = 30
    ) async throws -> [HFModel] {
        var components = URLComponents(string: baseURL)!
        var items = [URLQueryItem]()

        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        if let filter { items.append(URLQueryItem(name: "filter", value: filter)) }
        if let author { items.append(URLQueryItem(name: "author", value: author)) }

        switch sort {
        case .downloads: items.append(contentsOf: [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ])
        case .likes: items.append(contentsOf: [
            URLQueryItem(name: "sort", value: "likes"),
            URLQueryItem(name: "direction", value: "-1")
        ])
        case .trending: items.append(URLQueryItem(name: "sort", value: "trendingScore"))
        case .recentlyUpdated: items.append(contentsOf: [
            URLQueryItem(name: "sort", value: "lastModified"),
            URLQueryItem(name: "direction", value: "-1")
        ])
        case .sizeAsc:
            items.append(contentsOf: [
                URLQueryItem(name: "sort", value: "lastModified"),
                URLQueryItem(name: "direction", value: "asc")
            ])
        case .sizeDesc:
            items.append(contentsOf: [
                URLQueryItem(name: "sort", value: "lastModified"),
                URLQueryItem(name: "direction", value: "desc")
            ])
        }

        items.append(URLQueryItem(name: "limit", value: "\(limit)"))
        items.append(URLQueryItem(name: "full", value: "true"))
        components.queryItems = items

        guard let url = components.url else { throw HFError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HFError.serverError
        }

        let decoded = try JSONDecoder().decode([HFSearchResponse].self, from: data)
        return decoded.map { $0.toHFModel() }
    }

    func modelDetails(repoId: String) async throws -> HFModel {
        let encodedRepoId = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        guard let url = URL(string: "\(baseURL)/\(encodedRepoId)?full=true") else {
            throw HFError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HFError.serverError
        }

        let decoded = try JSONDecoder().decode(HFSearchResponse.self, from: data)
        return decoded.toHFModel()
    }

    func downloadFile(
        repoId: String,
        filename: String,
        to destination: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let encodedRepo = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        let encodedFile = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let urlStr = "https://huggingface.co/\(encodedRepo)/resolve/main/\(encodedFile)"
        guard let url = URL(string: urlStr) else { throw HFError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let delegate = DownloadDelegate(progress: progress)
        let dlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { dlSession.invalidateAndCancel() }

        let (tempURL, response) = try await dlSession.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HFError.serverError
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        await progress(1.0)
    }

    func downloadSnapshot(
        repoId: String,
        files: [String],
        to directory: URL,
        progress: @escaping @MainActor @Sendable (String, Double) -> Void
    ) async throws {
        for file in files {
            let dest = directory.appendingPathComponent(file)
            try await downloadFile(repoId: repoId, filename: file, to: dest) { p in
                MainActor.assumeIsolated { progress(file, p) }
            }
        }
    }

    private static func loadToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["HF_TOKEN"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        let tokenPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
        if let data = try? Data(contentsOf: tokenPath),
           let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        return nil
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @MainActor @Sendable (Double) -> Void

    init(progress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.progress(p)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {}
}

enum HFError: LocalizedError {
    case serverError
    case invalidURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverError: "HuggingFace server error"
        case .invalidURL: "Invalid URL"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        }
    }
}
