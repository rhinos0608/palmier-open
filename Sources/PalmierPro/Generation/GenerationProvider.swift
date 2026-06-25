import Foundation

// MARK: - Response types

struct ImageGenerationResponse: Sendable {
    let images: [ImageOutput]
    struct ImageOutput: Sendable {
        let b64JSON: String?
        let url: String?
    }
}

struct AsyncJob: Sendable {
    let id: String
    let status: JobStatus
    let resultURL: String?
    let error: String?

    enum JobStatus: String, Sendable {
        case queued, inProgress = "in_progress", completed, failed
    }
}

// MARK: - Provider

enum GenerationProvider {

    /// Set by AppState when the local Python server starts.
    nonisolated(unsafe) static var localAdapter: LocalInferenceAdapter?

    /// Returns true when the job ID was produced by the local adapter.
    private static func isLocalJob(_ id: String) -> Bool {
        id.hasPrefix("local-")
    }

    // MARK: TTS — POST /v1/audio/speech → binary audio

    static func speech(
        model: String,
        input: String,
        voice: String,
        responseFormat: String = "mp3",
        speed: Double = 1.0,
        instructions: String? = nil
    ) async throws -> Data {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .tts),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.speech(model: localModel, input: input, voice: voice,
                                            responseFormat: responseFormat, speed: speed)
        }
        let body = buildSpeechBody(model: model, input: input, voice: voice,
                                   responseFormat: responseFormat, speed: speed, instructions: instructions)
        return try await post(path: "audio/speech", body: body, service: .tts, acceptBinary: true)
    }

    // MARK: Image — POST /v1/images/generations → JSON

    static func generateImage(
        model: String,
        prompt: String,
        size: String = "1024x1024",
        n: Int = 1,
        quality: String = "standard",
        imageURLs: [String]? = nil
    ) async throws -> ImageGenerationResponse {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .image),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.generateImage(model: localModel, prompt: prompt, size: size,
                                                    n: n, quality: quality, imageURLs: imageURLs)
        }
        var body: [String: Any] = [
            "model": model, "prompt": prompt,
            "size": size, "n": n, "quality": quality,
            "response_format": "b64_json",
        ]
        if let urls = imageURLs, !urls.isEmpty {
            body["image_url"] = urls.first
        }
        let data = try await post(path: "images/generations", body: body, service: .image)
        return try parseImageResponse(data)
    }

    // MARK: Video — POST /v1/videos → job, poll, download

    static func createVideo(
        model: String,
        prompt: String,
        seconds: Int = 4,
        size: String = "720x1280",
        imageRefBase64: String? = nil,
        imageRefMime: String? = nil
    ) async throws -> AsyncJob {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .video),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.createVideo(model: localModel, prompt: prompt,
                                                  seconds: seconds, size: size)
        }
        var body: [String: Any] = [
            "model": model, "prompt": prompt,
            "seconds": String(seconds), "size": size,
        ]
        if let b64 = imageRefBase64, let mime = imageRefMime {
            body["input_reference"] = ["image_url": "data:\(mime);base64,\(b64)"]
        }
        let data = try await post(path: "videos", body: body, service: .video)
        return try parseAsyncJob(data, kind: "video")
    }

    static func getVideo(jobId: String) async throws -> AsyncJob {
        if isLocalJob(jobId) {
            return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
        }
        let data = try await get(path: "videos/\(jobId)", service: .video)
        return try parseAsyncJob(data, kind: "video")
    }

    static func downloadVideoContent(jobId: String) async throws -> Data {
        if isLocalJob(jobId), let adapter = localAdapter {
            return try await adapter.downloadVideoContent(jobId: jobId)
        }
        return try await getBinary(path: "videos/\(jobId)/content?variant=video", service: .video)
    }

    // MARK: Music — POST /v1/audio/generations (de facto)

    static func createMusic(
        model: String,
        prompt: String,
        durationSeconds: Int = 30,
        instrumental: Bool = false,
        style: String? = nil
    ) async throws -> AsyncJob {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .music),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.createMusic(model: localModel, prompt: prompt,
                                                  durationSeconds: durationSeconds, instrumental: instrumental)
        }
        var body: [String: Any] = [
            "model": model, "prompt": prompt,
            "duration_seconds": durationSeconds,
            "instrumental": instrumental,
            "response_format": "mp3",
        ]
        if let style { body["style"] = style }
        let data = try await post(path: "audio/generations", body: body, service: .music)
        return try parseAsyncJob(data, kind: "music")
    }

    static func getMusicJob(jobId: String) async throws -> AsyncJob {
        if isLocalJob(jobId) {
            return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
        }
        let data = try await get(path: "audio/generations/\(jobId)", service: .music)
        return try parseAsyncJob(data, kind: "music")
    }

    static func downloadMusicContent(jobId: String) async throws -> Data {
        if isLocalJob(jobId), let adapter = localAdapter {
            return try await adapter.downloadMusicContent(jobId: jobId)
        }
        return try await getBinary(path: "audio/generations/\(jobId)/content", service: .music)
    }

    // MARK: SFX — POST /v1/audio/sound-effects (de facto)

    static func generateSFX(
        model: String,
        prompt: String,
        durationSeconds: Double = 5.0
    ) async throws -> Data {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .sfx),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.generateSFX(model: localModel, prompt: prompt, durationSeconds: durationSeconds)
        }
        let body: [String: Any] = [
            "model": model, "prompt": prompt,
            "duration_seconds": durationSeconds,
            "response_format": "mp3",
        ]
        return try await post(path: "audio/sound-effects", body: body, service: .sfx, acceptBinary: true)
    }

    // MARK: Upscale — POST /v1/images/upscale (de facto)

    static func createUpscale(
        model: String,
        imageBase64: String,
        imageMime: String,
        scale: Int = 2
    ) async throws -> AsyncJob {
        if ProviderConfig.isLocalAIEnabled,
           let localModel = ProviderConfig.selectedLocalModel(for: .image),
           let adapter = localAdapter, adapter.serverManager.isRunningValue {
            return try await adapter.createUpscale(model: localModel, imageBase64: imageBase64,
                                                    imageMime: imageMime, scale: scale)
        }
        let body: [String: Any] = [
            "model": model,
            "image_url": "data:\(imageMime);base64,\(imageBase64)",
            "scale": scale,
            "output_format": "png",
        ]
        let data = try await post(path: "images/upscale", body: body, service: .upscale)
        return try parseAsyncJob(data, kind: "upscale")
    }

    static func getUpscaleJob(jobId: String) async throws -> AsyncJob {
        if isLocalJob(jobId) {
            return AsyncJob(id: jobId, status: .completed, resultURL: nil, error: nil)
        }
        let data = try await get(path: "images/upscale/\(jobId)", service: .upscale)
        return try parseAsyncJob(data, kind: "upscale")
    }

    static func downloadUpscaleContent(jobId: String) async throws -> Data {
        if isLocalJob(jobId), let adapter = localAdapter {
            return try await adapter.downloadUpscaleContent(jobId: jobId)
        }
        return try await getBinary(path: "images/upscale/\(jobId)/content", service: .upscale)
    }

    // MARK: - URL resolution

    private static func resolveURL(path: String, service: AIService, model: ModelID?) -> URL? {
        if let model, model.isLocal, let adapter = localAdapter, let baseURL = adapter.serverManager.baseURL {
            return URL(string: "\(baseURL)/v1/\(path)")
        }
        return ProviderConfig.url(path: path, service: service)
    }

    // MARK: - Internal HTTP helpers

    private static func post(path: String, body: [String: Any], service: AIService, acceptBinary: Bool = false, model: ModelID? = nil) async throws -> Data {
        guard let endpoint = resolveURL(path: path, service: service, model: model) else {
            throw ProviderError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ProviderConfig.apiKey(for: service))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if acceptBinary {
            request.setValue("audio/mpeg, application/octet-stream", forHTTPHeaderField: "accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = acceptBinary ? 60 : 30

        let (data, response) = try await URLSession.shared.data(for: request)
        try assertHTTPOK(response, data)
        return data
    }

    private static func get(path: String, service: AIService, model: ModelID? = nil) async throws -> Data {
        guard let endpoint = resolveURL(path: path, service: service, model: model) else {
            throw ProviderError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(ProviderConfig.apiKey(for: service))", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try assertHTTPOK(response, data)
        return data
    }

    private static func getBinary(path: String, service: AIService, model: ModelID? = nil) async throws -> Data {
        guard let endpoint = resolveURL(path: path, service: service, model: model) else {
            throw ProviderError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(ProviderConfig.apiKey(for: service))", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        try assertHTTPOK(response, data)
        return data
    }

    private static func assertHTTPOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if let err = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = err["error"] as? [String: Any],
               let message = msg["message"] as? String {
                throw ProviderError.httpError(status: http.statusCode, message: message)
            }
            throw ProviderError.httpError(status: http.statusCode, message: body.prefix(500).description)
        }
    }

    // MARK: - Body builders

    private static func buildSpeechBody(
        model: String, input: String, voice: String,
        responseFormat: String, speed: Double, instructions: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "input": input, "voice": voice,
            "response_format": responseFormat, "speed": speed,
        ]
        if let inst = instructions, !inst.isEmpty { body["instructions"] = inst }
        return body
    }

    // MARK: - Response parsers

    private static func parseImageResponse(_ data: Data) throws -> ImageGenerationResponse {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let obj = json as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else {
            throw ProviderError.unexpectedResponse("images/generations")
        }
        let images: [ImageGenerationResponse.ImageOutput] = items.map {
            ImageGenerationResponse.ImageOutput(
                b64JSON: $0["b64_json"] as? String,
                url: $0["url"] as? String
            )
        }
        return ImageGenerationResponse(images: images)
    }

    private static func parseAsyncJob(_ data: Data, kind: String) throws -> AsyncJob {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let obj = json as? [String: Any],
              let id = obj["id"] as? String,
              let rawStatus = obj["status"] as? String else {
            throw ProviderError.unexpectedResponse(kind)
        }
        let status: AsyncJob.JobStatus
        switch rawStatus {
        case "queued": status = .queued
        case "in_progress", "processing", "running": status = .inProgress
        case "completed", "succeeded": status = .completed
        case "failed", "cancelled": status = .failed
        default: status = .queued
        }
        let resultURL: String?
        if let output = obj["output"] as? [String: Any] {
            resultURL = output["url"] as? String
        } else if let urls = obj["result_urls"] as? [String] {
            resultURL = urls.first
        } else {
            resultURL = obj["result_url"] as? String
        }
        let error: String?
        if let err = obj["error"] as? [String: Any] {
            error = err["message"] as? String ?? err["code"] as? String
        } else {
            error = obj["error"] as? String
        }
        return AsyncJob(id: id, status: status, resultURL: resultURL, error: error)
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case notConfigured
    case httpError(status: Int, message: String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Set a base URL and API key in Settings to generate."
        case .httpError(let status, let msg): "Provider error (\(status)): \(msg)"
        case .unexpectedResponse(let endpoint): "Unexpected response from \(endpoint)."
        }
    }
}
