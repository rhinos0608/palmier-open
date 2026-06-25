import Foundation

extension Notification.Name {
    static let providerConfigChanged = Notification.Name("providerConfigChanged")
}

enum AIService: String, CaseIterable, Identifiable, Sendable {
    case chat, tts, image, video, music, sfx, upscale

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:    "Agent / Chat"
        case .tts:     "Text-to-Speech"
        case .image:   "Image Generation"
        case .video:   "Video Generation"
        case .music:   "Music Generation"
        case .sfx:     "Sound Effects"
        case .upscale: "Upscale"
        }
    }

    var icon: String {
        switch self {
        case .chat:    "bubble.left.and.bubble.right"
        case .tts:     "waveform"
        case .image:   "photo"
        case .video:   "video"
        case .music:   "music.note"
        case .sfx:     "speaker.wave.2"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        }
    }

    var defaultPath: String {
        switch self {
        case .chat:    "chat/completions"
        case .tts:     "audio/speech"
        case .image:   "images/generations"
        case .video:   "videos"
        case .music:   "audio/generations"
        case .sfx:     "audio/sound-effects"
        case .upscale: "images/upscale"
        }
    }
}

/// User-supplied OpenAI-compatible provider configuration.
/// A global base URL + API key serves as the default; per-service overrides
/// are optional. Base URLs live in UserDefaults; keys live in the Keychain.
enum ProviderConfig {
    private static let keychainAccount = "openai-api-key"
    private static let baseURLKey = "providerBaseURL"
    private static let chatModelKey = "agentModel"

    static let defaultBaseURL = "https://api.openai.com/v1"

    // MARK: - Per-service storage keys

    private static func baseURLKey(for service: AIService) -> String {
        service == .chat ? baseURLKey : "\(baseURLKey)_\(service.rawValue)"
    }

    private static func apiKeyAccount(for service: AIService) -> String {
        service == .chat ? keychainAccount : "\(keychainAccount)-\(service.rawValue)"
    }

    // MARK: - Chat model

    static var chatModel: String {
        UserDefaults.standard.string(forKey: chatModelKey) ?? ""
    }

    static func setChatModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: chatModelKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: chatModelKey)
        }
        NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
    }

    // MARK: - Per-service base URL

    static func baseURL(for service: AIService) -> String {
        #if DEBUG
        if service == .chat,
           let env = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]?
               .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        if service != .chat {
            let stored = UserDefaults.standard.string(forKey: baseURLKey(for: service))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty { return stored }
        }
        let fallback = UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "" : fallback
    }

    static func setBaseURL(_ value: String, for service: AIService = .chat) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: baseURLKey(for: service))
        } else {
            UserDefaults.standard.set(trimmed, forKey: baseURLKey(for: service))
        }
        NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
    }

    // MARK: - Per-service API key

    static func apiKey(for service: AIService) -> String {
        #if DEBUG
        if service == .chat,
           let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
               .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        if service != .chat {
            if let key = KeychainStore.load(account: apiKeyAccount(for: service)), !key.isEmpty {
                return key
            }
        }
        return KeychainStore.load(account: keychainAccount) ?? ""
    }

    static func setAPIKey(_ value: String, for service: AIService = .chat) {
        KeychainStore.save(value, account: apiKeyAccount(for: service))
        NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
    }

    static func deleteAPIKey(for service: AIService = .chat) {
        KeychainStore.delete(account: apiKeyAccount(for: service))
        NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
    }

    // MARK: - Convenience (backward-compatible)

    static var baseURL: String { baseURL(for: .chat) }
    static var apiKey: String { apiKey(for: .chat) }
    static func setBaseURL(_ value: String) { setBaseURL(value, for: .chat) }
    static func setAPIKey(_ value: String) { setAPIKey(value, for: .chat) }
    static func deleteAPIKey() { deleteAPIKey(for: .chat) }

    // MARK: - Local AI toggle

    static var isLocalAIEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "localAI.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "localAI.enabled")
            NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
        }
    }

    // MARK: - Local model selection

    private static func localModelKey(for category: ModelCategory) -> String {
        "localModel.\(category.rawValue)"
    }

    static func selectedLocalModel(for category: ModelCategory) -> String? {
        UserDefaults.standard.string(forKey: localModelKey(for: category))
    }

    static func setSelectedLocalModel(_ modelId: String?, for category: ModelCategory) {
        if let modelId, !modelId.isEmpty {
            UserDefaults.standard.set(modelId, forKey: localModelKey(for: category))
        } else {
            UserDefaults.standard.removeObject(forKey: localModelKey(for: category))
        }
        NotificationCenter.default.post(name: .providerConfigChanged, object: nil)
    }

    static func isLocalModelAvailable(for service: AIService) -> Bool {
        selectedLocalModel(for: service.category) != nil
    }

    /// True when a local model is selected AND no remote base URL is configured.
    static func isLocalMode(for service: AIService) -> Bool {
        guard isLocalAIEnabled else { return false }
        return selectedLocalModel(for: service.category) != nil && baseURL(for: service).isEmpty
    }

    // MARK: - Local server URL

    /// URL of the running local inference server, set by PythonServerManager.
    static var localServerURL: String? {
        guard isLocalAIEnabled else { return nil }
        return UserDefaults.standard.string(forKey: "localServer.url")
    }

    static func setLocalServerURL(_ url: String?) {
        if let url {
            UserDefaults.standard.set(url, forKey: "localServer.url")
        } else {
            UserDefaults.standard.removeObject(forKey: "localServer.url")
        }
    }

    // MARK: - Derived state

    static var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }

    static func isConfigured(for service: AIService) -> Bool {
        let url = baseURL(for: service)
        let key = apiKey(for: service)
        if !url.isEmpty && !key.isEmpty { return true }
        guard isLocalAIEnabled else { return false }
        return selectedLocalModel(for: service.category) != nil
    }

    // MARK: - URL building

    static func url(path: String, service: AIService = .chat) -> URL? {
        let base = baseURL(for: service)
        guard !base.isEmpty else { return nil }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(trimmedBase)/\(trimmedPath)")
    }
}

extension AIService {
    var category: ModelCategory {
        switch self {
        case .chat:    return .tts
        case .tts:     return .tts
        case .image:   return .image
        case .video:   return .video
        case .music:   return .music
        case .sfx:     return .sfx
        case .upscale: return .image
        }
    }
}
