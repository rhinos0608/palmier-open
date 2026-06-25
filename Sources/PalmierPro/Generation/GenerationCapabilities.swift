import Foundation

/// Static capability defaults for each generation kind, grounded in
/// OpenAI API specs and open-source provider research. Used as fallback
/// when the provider's /v1/models response doesn't include capability metadata.
enum GenerationCapabilities {

    // MARK: - Embedded default model info for local/OFF inference

    enum LocalModelDefaults {
        struct ModelInfo {
            let repoId: String
            let displayName: String
            let category: ModelCategory
            let sizeGB: Double
            let license: String
            let description: String
        }

        static let tts = ModelInfo(
            repoId: "mlx-community/Kokoro-82M",
            displayName: "Kokoro 82M",
            category: .tts,
            sizeGB: 0.35,
            license: "Apache 2.0",
            description: "Fast, high-quality TTS"
        )

        static let music = ModelInfo(
            repoId: "ACE-Step/Ace-Step1.5",
            displayName: "ACE-Step 1.5",
            category: .music,
            sizeGB: 4.0,
            license: "Apache 2.0",
            description: "Commercial-grade music generation"
        )

        static let sfx = ModelInfo(
            repoId: "declare-lab/TangoFlux",
            displayName: "TangoFlux",
            category: .sfx,
            sizeGB: 2.0,
            license: "MIT",
            description: "Fast SFX generation"
        )

        static let imageUpscale2x = ModelInfo(
            repoId: "ModelPiper/PiperSR-2x",
            displayName: "PiperSR 2×",
            category: .upscale,
            sizeGB: 0.001,
            license: "CC BY 4.0",
            description: "ANE-native 2× upscale, real-time"
        )

        static let imageUpscale4x = ModelInfo(
            repoId: "xinntao/RealESRGAN_x4plus",
            displayName: "Real-ESRGAN 4×",
            category: .upscale,
            sizeGB: 0.065,
            license: "BSD-3",
            description: "Quality 4× image upscale"
        )

        static let videoGen = ModelInfo(
            repoId: "Lightricks/LTX-Video",
            displayName: "LTX-Video 2B",
            category: .video,
            sizeGB: 8.0,
            license: "Apache 2.0",
            description: "Text-to-video (experimental, heavy)"
        )

        static let all = [tts, music, sfx, imageUpscale2x, imageUpscale4x, videoGen]
    }

    // MARK: - TTS

    static let ttsVoices: [String] = [
        "alloy", "ash", "ballad", "coral", "echo", "fable",
        "onyx", "nova", "sage", "shimmer", "verse",
    ]
    static let ttsDefaultVoice = "alloy"
    static let ttsFormats = ["mp3", "opus", "aac", "flac", "wav", "pcm"]
    static let ttsDefaultFormat = "mp3"
    static let ttsSpeedRange: ClosedRange<Double> = 0.25...4.0
    static let ttsDefaultSpeed = 1.0
    static let ttsMaxInputChars = 4096
    static let ttsDefaultModel = LocalModelDefaults.tts

    // MARK: - Image generation

    static let imageSizes = ["1024x1024", "1792x1024", "1024x1792"]
    static let imageDefaultSize = "1024x1024"
    static let imageQualities = ["standard", "hd"]
    static let imageDefaultQuality = "standard"
    static let imageDefaultN = 1
    static let imageMaxN = 10

    // MARK: - Video generation

    static let videoDurations: [Int] = [4, 8, 12]
    static let videoDefaultDuration = 4
    static let videoSizes = ["720x1280", "1280x720", "1024x1792", "1792x1024"]
    static let videoDefaultSize = "720x1280"
    static let videoDefaultModel = LocalModelDefaults.videoGen

    // MARK: - Music (de facto contract)

    static let musicDurations: [Int] = [8, 15, 30, 60]
    static let musicDefaultDuration = 30
    static let musicFormats = ["mp3", "wav"]
    static let musicDefaultFormat = "mp3"
    static let musicDefaultModel = LocalModelDefaults.music

    // MARK: - Sound effects (de facto contract)

    static let sfxDurations: [Int] = [1, 2, 5, 10]
    static let sfxDefaultDuration = 5
    static let sfxFormats = ["mp3", "wav"]
    static let sfxDefaultFormat = "mp3"
    static let sfxDefaultModel = LocalModelDefaults.sfx

    // MARK: - Upscale (de facto contract)

    static let upscaleScales: [Int] = [2, 4]
    static let upscaleDefaultScale = 2
    static let upscaleFormats = ["png", "jpg", "webp"]
    static let upscaleDefaultFormat = "png"
    static let upscaleDefaultModel = LocalModelDefaults.imageUpscale2x
}
