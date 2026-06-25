import Foundation

enum GenerationEvent: Sendable {
    case progress(Double)
    case completed(Data)
    case failed(String)
}

struct GenerationResult: AsyncSequence {
    typealias Element = GenerationEvent

    let id: String
    let source: Source

    enum Source: @unchecked Sendable {
        case remote(polling: RemotePollingConfig)
        case local(adapter: LocalInferenceAdapter, category: ModelCategory, model: ModelID, params: [String: Any])
    }

    struct RemotePollingConfig: Sendable {
        let service: AIService
        let jobId: String
        let pollPath: String
        let contentPath: String
        let interval: TimeInterval
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: Source
        var hasCompleted = false

        mutating func next() async throws -> GenerationEvent? {
            guard !hasCompleted else { return nil }

            switch source {
            case .remote(let config):
                let event = try await pollRemote(config: config)
                hasCompleted = true
                return event

            case .local(let adapter, let category, let model, let params):
                hasCompleted = true
                return try await executeLocal(adapter: adapter, category: category, model: model, params: params)
            }
        }

        private func pollRemote(config: RemotePollingConfig) async throws -> GenerationEvent {
            let apiKey = ProviderConfig.apiKey(for: config.service)

            func authRequest(_ url: URL) -> URLRequest {
                var req = URLRequest(url: url)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 30
                return req
            }

            guard let baseURL = ProviderConfig.url(path: "", service: config.service)?.deletingLastPathComponent() else {
                return .failed("Provider not configured")
            }

            var jobId = config.jobId
            guard !jobId.isEmpty else { return .failed("No job ID") }

            while true {
                guard let pollURL = URL(string: "\(baseURL)/\(config.pollPath)/\(jobId)") else {
                    return .failed("Invalid poll URL")
                }

                let (data, response) = try await URLSession.shared.data(for: authRequest(pollURL))
                guard let http = response as? HTTPURLResponse else {
                    return .failed("Invalid poll response")
                }

                guard http.statusCode < 400 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    return .failed("Poll failed: \(body.prefix(200))")
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawStatus = json["status"] as? String else {
                    return .failed("Invalid poll response format")
                }

                switch rawStatus {
                case "completed", "succeeded":
                    guard let contentURL = URL(string: "\(baseURL)/\(config.contentPath)") else {
                        return .failed("Invalid content URL")
                    }
                    let (contentData, _) = try await URLSession.shared.data(for: authRequest(contentURL))
                    return .completed(contentData)

                case "failed", "cancelled":
                    let error: String
                    if let err = json["error"] as? [String: Any] {
                        error = err["message"] as? String ?? err["code"] as? String ?? "Generation failed"
                    } else {
                        error = json["error"] as? String ?? "Generation failed"
                    }
                    return .failed(error)

                default:
                    try await Task.sleep(nanoseconds: UInt64(config.interval * 1_000_000_000))
                    jobId = json["id"] as? String ?? jobId
                }
            }
        }

        private func executeLocal(
            adapter: LocalInferenceAdapter,
            category: ModelCategory,
            model: ModelID,
            params: [String: Any]
        ) async throws -> GenerationEvent {
            do {
                let data: Data
                switch category {
                case .tts:
                    data = try await adapter.speech(
                        model: model.displayString,
                        input: params["input"] as? String ?? "",
                        voice: params["voice"] as? String ?? "default",
                        responseFormat: params["response_format"] as? String ?? "mp3",
                        speed: params["speed"] as? Double ?? 1.0
                    )
                case .image:
                    let response = try await adapter.generateImage(
                        model: model.displayString,
                        prompt: params["prompt"] as? String ?? "",
                        size: params["size"] as? String ?? "1024x1024",
                        quality: params["quality"] as? String ?? "standard"
                    )
                    guard let b64 = response.images.first?.b64JSON,
                          let imgData = Data(base64Encoded: b64) else {
                        return .failed("No image data in response")
                    }
                    data = imgData
                case .music:
                    data = try await adapter.generateMusic(
                        model: model.displayString,
                        prompt: params["prompt"] as? String ?? "",
                        durationSeconds: params["duration_seconds"] as? Int ?? 30,
                        instrumental: params["instrumental"] as? Bool ?? false
                    )
                case .sfx:
                    data = try await adapter.generateSFX(
                        model: model.displayString,
                        prompt: params["prompt"] as? String ?? "",
                        durationSeconds: params["duration_seconds"] as? Double ?? 5.0
                    )
                case .video:
                    data = try await adapter.generateVideo(
                        model: model.displayString,
                        prompt: params["prompt"] as? String ?? "",
                        seconds: params["seconds"] as? Int ?? 4,
                        size: params["size"] as? String ?? "720x1280"
                    )
                case .upscale:
                    guard let b64 = params["image_base64"] as? String,
                          let mime = params["image_mime"] as? String else {
                        return .failed("Missing image data for upscale")
                    }
                    data = try await adapter.generateUpscale(
                        model: model.displayString,
                        imageBase64: b64,
                        imageMime: mime,
                        scale: params["scale"] as? Int ?? 2
                    )
                }
                return .completed(data)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}
