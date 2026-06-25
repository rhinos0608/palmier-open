import Foundation
import Observation

enum ModelKindFilter: String, Sendable {
    case chat, image, video, tts, music, sfx, transcription, embedding, upscale, other
}

struct ProviderModel: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ModelKindFilter

    static func classify(id: String) -> ModelKindFilter {
        let s = id.lowercased()
        if s.contains("embed") { return .embedding }
        if s.contains("whisper") || s.contains("transcrib") || s.contains("stt") { return .transcription }
        if s.contains("tts") || s.contains("audio-speech") || s.contains("speech") { return .tts }
        if s.contains("music") || s.contains("lyria") || s.contains("minimax") || s.contains("sonilo")
            || s.contains("udio") || s.contains("suno") || s.contains("elevenlabs-music") { return .music }
        if s.contains("sfx") || s.contains("sound-effect") || s.contains("mirelo") { return .sfx }
        if s.contains("upscale") || s.contains("clarity") || s.contains("topaz") || s.contains("real-esrgan")
            || s.contains("seedvr") || s.contains("supir") { return .upscale }
        if s.contains("sora") || s.contains("veo") || s.contains("kling") || s.contains("video")
            || s.contains("wan") || s.contains("ltx") || s.contains("mochi") || s.contains("hunyuan")
            || s.contains("runway") || s.contains("luma") { return .video }
        if s.contains("dall-e") || s.contains("dalle") || s.contains("gpt-image") || s.contains("image")
            || s.contains("flux") || s.contains("sdxl") || s.contains("stable-diffusion")
            || s.contains("imagen") || s.contains("nano-banana") || s.contains("seedream") { return .image }
        return .chat
    }
}

@Observable
@MainActor
final class ModelDirectory {
    static let shared = ModelDirectory()
    private init() {}

    private(set) var models: [ProviderModel] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var hasLoaded = false

    func models(of kind: ModelKindFilter) -> [ProviderModel] {
        models.filter { $0.kind == kind }
    }

    var chatModels: [ProviderModel] { models(of: .chat) }

    func refreshIfNeeded() {
        guard !hasLoaded, !isLoading, ProviderConfig.isConfigured else { return }
        Task { await refresh() }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard ProviderConfig.isConfigured, let endpoint = ProviderConfig.url(path: "models") else {
            lastError = "Set a base URL and API key first."
            return false
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let key = ProviderConfig.apiKey
        do {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let body = String(data: data, encoding: .utf8) ?? ""
                lastError = "Models request failed (\(http.statusCode)): \(body.prefix(200))"
                return false
            }
            let ids = try Self.parseModelIDs(data)
            models = ids.sorted().map { ProviderModel(id: $0, kind: ProviderModel.classify(id: $0)) }
            hasLoaded = true
            return true
        } catch let err as ParseError {
            lastError = err.localizedDescription
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    static func parseModelIDs(_ data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data)
        // OpenAI shape: { "data": [ { "id": "..." } ] }
        if let obj = json as? [String: Any], let list = obj["data"] as? [[String: Any]] {
            let ids = list.compactMap { $0["id"] as? String }
            if ids.isEmpty, !list.isEmpty { throw ParseError.unrecognizedFormat }
            return ids
        }
        // Some servers return a bare array.
        if let list = json as? [[String: Any]] {
            let ids = list.compactMap { $0["id"] as? String }
            if ids.isEmpty, !list.isEmpty { throw ParseError.unrecognizedFormat }
            return ids
        }
        throw ParseError.unrecognizedFormat
    }

    private enum ParseError: LocalizedError {
        case unrecognizedFormat
        var errorDescription: String? { "Unrecognized model list format — provider may not be OpenAI-compatible." }
    }
}
