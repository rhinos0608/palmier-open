import Foundation

/// Sends inference requests to the local Python server.
/// Operations that return content directly (speech, SFX, generate*)
/// are synchronous. Operations wrapped as AsyncJob (create* / download*)
/// cache the result in-memory for the poll-and-finalize path.
@MainActor
final class LocalInferenceAdapter {
    let serverManager: PythonServerManager

    var isAvailable: Bool { serverManager.isRunning }

    init(serverManager: PythonServerManager) {
        self.serverManager = serverManager
    }

    // MARK: - Caches for async-job-compatible methods

    private var videoContentCache: [String: Data] = [:]
    private var musicContentCache: [String: Data] = [:]
    private var upscaleContentCache: [String: Data] = [:]

    // MARK: - Internal HTTP helpers

    private func postJSON(path: String, body: [String: Any]) async throws -> Data {
        guard let baseURL = serverManager.baseURL else { throw AdapterError.serverNotRunning }
        let payload = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "\(baseURL)/v1/\(path)") else { throw AdapterError.serverNotRunning }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw AdapterError.inferenceFailed("HTTP \(statusCode): \(body.prefix(200))")
        }
        return responseData
    }

    // MARK: - TTS

    func speech(model: String, input: String, voice: String,
                responseFormat: String = "mp3", speed: Double = 1.0) async throws -> Data {
        let body: [String: Any] = [
            "model": model, "input": input, "voice": voice,
            "response_format": responseFormat, "speed": speed,
        ]
        return try await postJSON(path: "audio/speech", body: body)
    }

    // MARK: - Image

    func generateImage(model: String, prompt: String, size: String = "1024x1024",
                       n: Int = 1, quality: String = "standard",
                       imageURLs: [String]? = nil) async throws -> ImageGenerationResponse {
        var body: [String: Any] = [
            "model": model, "prompt": prompt,
            "size": size, "n": n, "quality": quality,
            "response_format": "b64_json",
        ]
        if let urls = imageURLs, !urls.isEmpty {
            body["image_url"] = urls.first
        }
        let data = try await postJSON(path: "images/generations", body: body)
        return try Self.parseImageResponse(data)
    }

    // MARK: - Video — sync result (returns ready-to-use Data)

    /// Generate video and return the file content directly (no job polling).
    func generateVideo(model: String, prompt: String, seconds: Int, size: String) async throws -> Data {
        let body: [String: Any] = [
            "model": model, "prompt": prompt,
            "seconds": seconds, "size": size,
        ]
        return try await postJSON(path: "videos", body: body)
    }

    /// Generate, cache, and return a completed AsyncJob.
    func createVideo(model: String, prompt: String, seconds: Int = 4,
                     size: String = "720x1280") async throws -> AsyncJob {
        let data = try await generateVideo(model: model, prompt: prompt, seconds: seconds, size: size)
        let jobId = "local-" + UUID().uuidString
        videoContentCache[jobId] = data
        if videoContentCache.count > 10 {
            videoContentCache.removeAll()
        }
        return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
    }

    func downloadVideoContent(jobId: String) async throws -> Data {
        guard let cached = videoContentCache.removeValue(forKey: jobId) else {
            throw AdapterError.contentNotFound
        }
        return cached
    }

    // MARK: - Music — sync result (returns ready-to-use Data)

    func generateMusic(model: String, prompt: String, durationSeconds: Int,
                       instrumental: Bool) async throws -> Data {
        let body: [String: Any] = [
            "model": model, "prompt": prompt,
            "duration_seconds": durationSeconds, "instrumental": instrumental,
        ]
        return try await postJSON(path: "audio/generations", body: body)
    }

    func createMusic(model: String, prompt: String, durationSeconds: Int = 30,
                     instrumental: Bool = false) async throws -> AsyncJob {
        let data = try await generateMusic(model: model, prompt: prompt,
                                           durationSeconds: durationSeconds, instrumental: instrumental)
        let jobId = "local-" + UUID().uuidString
        musicContentCache[jobId] = data
        if musicContentCache.count > 10 {
            musicContentCache.removeAll()
        }
        return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
    }

    func downloadMusicContent(jobId: String) async throws -> Data {
        guard let cached = musicContentCache.removeValue(forKey: jobId) else {
            throw AdapterError.contentNotFound
        }
        return cached
    }

    // MARK: - SFX

    func generateSFX(model: String, prompt: String, durationSeconds: Double = 5.0) async throws -> Data {
        let body: [String: Any] = [
            "model": model, "prompt": prompt,
            "duration_seconds": durationSeconds,
        ]
        return try await postJSON(path: "audio/sound-effects", body: body)
    }

    // MARK: - Upscale — sync result (returns ready-to-use Data)

    func generateUpscale(model: String, imageBase64: String, imageMime: String,
                         scale: Int = 2) async throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "image_url": "data:\(imageMime);base64,\(imageBase64)",
            "scale": scale, "output_format": "png",
        ]
        return try await postJSON(path: "images/upscale", body: body)
    }

    func createUpscale(model: String, imageBase64: String, imageMime: String,
                       scale: Int = 2) async throws -> AsyncJob {
        let data = try await generateUpscale(model: model, imageBase64: imageBase64,
                                             imageMime: imageMime, scale: scale)
        let jobId = "local-" + UUID().uuidString
        upscaleContentCache[jobId] = data
        if upscaleContentCache.count > 10 {
            upscaleContentCache.removeAll()
        }
        return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
    }

    func downloadUpscaleContent(jobId: String) async throws -> Data {
        guard let cached = upscaleContentCache.removeValue(forKey: jobId) else {
            throw AdapterError.contentNotFound
        }
        return cached
    }

    // MARK: - Parsing

    private static func parseImageResponse(_ data: Data) throws -> ImageGenerationResponse {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let obj = json as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else {
            throw AdapterError.inferenceFailed()
        }
        let images: [ImageGenerationResponse.ImageOutput] = items.map {
            ImageGenerationResponse.ImageOutput(
                b64JSON: $0["b64_json"] as? String,
                url: $0["url"] as? String
            )
        }
        return ImageGenerationResponse(images: images)
    }

    // MARK: - Errors

    enum AdapterError: LocalizedError {
        case serverNotRunning
        case inferenceFailed(String = "Inference failed")
        case contentNotFound

        var errorDescription: String? {
            switch self {
            case .serverNotRunning: "Local inference server not running"
            case .inferenceFailed(let msg): msg
            case .contentNotFound: "Local inference content not found"
            }
        }
    }
}
