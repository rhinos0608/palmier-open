import Foundation

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }

    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    private var didConfigure = false

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        Task { await rebuildFromDirectory() }
    }

    func refresh() async {
        let ok = await ModelDirectory.shared.refresh()
        if ok { await rebuildFromDirectory() }
    }

    private func rebuildFromDirectory() async {
        let directory = ModelDirectory.shared
        guard directory.hasLoaded else {
            lastError = "Model list not yet fetched. Open Settings → Agent and fetch models."
            return
        }

        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]

        for model in directory.models {
            let entry = CatalogEntry(from: model)
            switch model.kind {
            case .video:
                let caps = VideoCaps.defaults
                let m = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(m)
                newById[m.id] = .video(m)
            case .image:
                let caps = ImageCaps.defaults
                let m = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(m)
                newById[m.id] = .image(m)
            case .tts, .transcription:
                let caps = AudioCaps.defaults(for: .tts)
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .music:
                let caps = AudioCaps.defaults(for: .music)
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .sfx:
                let caps = AudioCaps.defaults(for: .sfx)
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .upscale:
                let caps = UpscaleCaps.defaults
                let m = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(m)
                newById[m.id] = .upscale(m)
            case .chat, .embedding, .other:
                continue
            }
        }

        self.video = newVideo
        self.image = newImage
        self.audio = newAudio
        self.upscale = newUpscale
        self.byId = newById
        self.isLoaded = true
        self.lastError = nil
    }
}

// MARK: - CatalogEntry (simplified — no longer Convex-driven)

struct CatalogEntry: Sendable {
    let id: String
    let displayName: String
    let creditsPerSecond: [String: Double]?
    let audioDiscountRate: [String: Double]?
    let creditsPerImage: [String: Double]?
    let audioPricing: AudioPricing?
    let creditsPerSecondUpscale: Double?

    init(from model: ProviderModel) {
        self.id = model.id
        self.displayName = model.id
        self.creditsPerSecond = nil
        self.audioDiscountRate = nil
        self.creditsPerImage = nil
        self.audioPricing = nil
        self.creditsPerSecondUpscale = nil
    }

    enum AudioPricing: Sendable {
        case perThousandChars(rate: Double)
        case perSecond(rate: Double)
        case flat(price: Double)
    }
}

// MARK: - Capability structs with static defaults

struct VideoCaps: Sendable {
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let requiresReferenceImage: Bool

    static let defaults = VideoCaps(
        durations: GenerationCapabilities.videoDurations,
        resolutions: GenerationCapabilities.videoSizes,
        aspectRatios: ["16:9", "9:16", "1:1"],
        supportsFirstFrame: false,
        supportsLastFrame: false,
        maxReferenceImages: 1,
        maxReferenceVideos: 0,
        maxReferenceAudios: 0,
        maxTotalReferences: 1,
        maxCombinedVideoRefSeconds: nil,
        maxCombinedAudioRefSeconds: nil,
        framesAndReferencesExclusive: true,
        referenceTagNoun: "image",
        requiresSourceVideo: false,
        requiresReferenceImage: false
    )
}

struct ImageCaps: Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int

    static let defaults = ImageCaps(
        resolutions: GenerationCapabilities.imageSizes,
        aspectRatios: ["1:1", "16:9", "9:16"],
        qualities: GenerationCapabilities.imageQualities,
        supportsImageReference: false,
        maxImages: GenerationCapabilities.imageMaxN
    )
}

struct AudioCaps: Sendable {
    let category: String
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let minPromptLength: Int
    let inputs: [String]?
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?

    static func defaults(for category: AudioModelConfig.Category) -> AudioCaps {
        switch category {
        case .tts:
            return AudioCaps(
                category: "tts",
                voices: GenerationCapabilities.ttsVoices,
                defaultVoice: GenerationCapabilities.ttsDefaultVoice,
                supportsLyrics: false,
                supportsInstrumental: false,
                supportsStyleInstructions: true,
                durations: nil,
                minPromptLength: 1,
                inputs: ["text"],
                promptLabel: "Text to speak",
                minSeconds: 1,
                maxSeconds: 60
            )
        case .music:
            return AudioCaps(
                category: "music",
                voices: nil,
                defaultVoice: nil,
                supportsLyrics: false,
                supportsInstrumental: true,
                supportsStyleInstructions: true,
                durations: GenerationCapabilities.musicDurations,
                minPromptLength: 1,
                inputs: ["text"],
                promptLabel: "Describe the music style or mood",
                minSeconds: GenerationCapabilities.musicDurations.first ?? 8,
                maxSeconds: GenerationCapabilities.musicDurations.last ?? 60
            )
        case .sfx:
            return AudioCaps(
                category: "sfx",
                voices: nil,
                defaultVoice: nil,
                supportsLyrics: false,
                supportsInstrumental: false,
                supportsStyleInstructions: false,
                durations: GenerationCapabilities.sfxDurations,
                minPromptLength: 1,
                inputs: ["text"],
                promptLabel: "Describe the sound effect",
                minSeconds: GenerationCapabilities.sfxDurations.first ?? 1,
                maxSeconds: GenerationCapabilities.sfxDurations.last ?? 10
            )
        }
    }
}

struct UpscaleCaps: Sendable {
    let speed: String
    let p75DurationSeconds: Int
    let supportedTypes: [String]

    static let defaults = UpscaleCaps(
        speed: "Medium",
        p75DurationSeconds: 30,
        supportedTypes: ["image", "video"]
    )
}
