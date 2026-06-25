import Foundation

enum ModelCategory: String, CaseIterable, Codable, Sendable {
    case tts
    case image
    case music
    case sfx
    case video
    case upscale

    var displayName: String {
        switch self {
        case .tts: "Text-to-Speech"
        case .image: "Image Generation"
        case .music: "Music Generation"
        case .sfx: "Sound Effects"
        case .video: "Video Generation"
        case .upscale: "Upscale"
        }
    }

    var hfFilter: String {
        switch self {
        case .tts: "text-to-speech"
        case .image: "text-to-image"
        case .music: "text-to-audio"
        case .sfx: "text-to-audio"
        case .video: "text-to-video"
        case .upscale: "text-to-image"
        }
    }

    var icon: String {
        switch self {
        case .tts: "waveform"
        case .image: "photo.stack"
        case .music: "music.note"
        case .sfx: "speaker.wave.2"
        case .video: "film"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        }
    }

    var memoryPriority: Int {
        switch self {
        case .video: 0
        case .image: 1
        case .music: 1
        case .tts: 2
        case .sfx: 2
        case .upscale: 1
        }
    }
}

enum ModelState: String, Codable, Sendable {
    case dormant
    case active
    case pinned
    case loading
    case error
}

struct LocalModel: Identifiable, Codable, Sendable {
    let id: String
    let repoId: String
    let category: ModelCategory
    let displayName: String
    var state: ModelState
    let sizeBytes: Int64
    let quantization: String?
    let architecture: String?
    var installPath: String?
    var lastUsed: Date?
    var downloadProgress: Double?
    let isGated: Bool
    let license: String?

    var sizeDisplay: String {
        let gb = Double(sizeBytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(sizeBytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

struct HFModel: Identifiable, Sendable {
    let id: String
    let author: String?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]
    let downloads: Int
    let likes: Int
    let gated: Bool
    let lastModified: String?
    let siblings: [HFSibling]?

    var displayName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var isMLX: Bool {
        tags.contains("mlx") || author == "mlx-community"
    }
}

struct HFSibling: Codable, Sendable {
    let rfilename: String
    let size: Int64?
}

struct ModelManifest: Codable {
    var models: [LocalModel]
    var lastUpdated: Date
}

enum ModelSortOption: String, CaseIterable {
    case downloads
    case likes
    case trending
    case recentlyUpdated
    case sizeAsc
    case sizeDesc

    var displayName: String {
        switch self {
        case .downloads: "Most Downloaded"
        case .likes: "Most Liked"
        case .trending: "Trending"
        case .recentlyUpdated: "Recently Updated"
        case .sizeAsc: "Smallest First"
        case .sizeDesc: "Largest First"
        }
    }
}

extension LocalModel {
    static let recommendedModels: [LocalModel] = [
        LocalModel(
            id: "kokoro-82m",
            repoId: "mlx-community/Kokoro-82M",
            category: .tts,
            displayName: "Kokoro 82M",
            state: .dormant,
            sizeBytes: 350_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
        LocalModel(
            id: "ace-step-1.5",
            repoId: "ACE-Step/Ace-Step1.5",
            category: .music,
            displayName: "ACE-Step 1.5",
            state: .dormant,
            sizeBytes: 4_000_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
        LocalModel(
            id: "tangoflux",
            repoId: "declare-lab/TangoFlux",
            category: .sfx,
            displayName: "TangoFlux",
            state: .dormant,
            sizeBytes: 2_000_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
        LocalModel(
            id: "pipersr-2x",
            repoId: "ModelPiper/PiperSR-2x",
            category: .upscale,
            displayName: "PiperSR 2×",
            state: .dormant,
            sizeBytes: 1_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
        LocalModel(
            id: "realesrgan-4x",
            repoId: "xinntao/RealESRGAN_x4plus",
            category: .upscale,
            displayName: "Real-ESRGAN 4×",
            state: .dormant,
            sizeBytes: 65_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
        LocalModel(
            id: "ltx-video-2b",
            repoId: "Lightricks/LTX-Video",
            category: .video,
            displayName: "LTX-Video 2B",
            state: .dormant,
            sizeBytes: 8_000_000_000,
            quantization: nil,
            architecture: nil,
            installPath: nil,
            lastUsed: nil,
            downloadProgress: nil,
            isGated: false,
            license: nil
        ),
    ]
}
