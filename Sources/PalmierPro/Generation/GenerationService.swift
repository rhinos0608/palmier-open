import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        preUploadedURLs: [String]? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> GenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for _ in 0..<count {
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: genInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        let refURLs = references.map(\.url)

        Task { @MainActor in
            var tempToCleanup: [URL] = []
            defer { Self.cleanupTempFiles(tempToCleanup) }
            do {
                let uploaded: [String]
                if let preUploadedURLs, !preUploadedURLs.isEmpty {
                    uploaded = preUploadedURLs
                } else {
                    var urlsToUpload = refURLs
                    let refTypes = references.map(\.type)
                    if let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                        Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                        let extracted = try await VideoTrimExtractor.extract(trim)
                        urlsToUpload[0] = extracted
                        tempToCleanup.append(extracted)
                    }
                    if let preprocessRef, !references.isEmpty {
                        let snapshot = references
                        let rewrites: [(Int, URL?)] = try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
                            for (i, asset) in snapshot.enumerated() {
                                group.addTask { (i, try await preprocessRef(i, asset)) }
                            }
                            var results: [(Int, URL?)] = []
                            for try await r in group { results.append(r) }
                            return results
                        }
                        for (i, rewritten) in rewrites {
                            if let rewritten {
                                urlsToUpload[i] = rewritten
                                tempToCleanup.append(rewritten)
                            }
                        }
                    }
                    // Encode reference images as base64 data URIs; skip video/audio refs.
                    uploaded = await encodeReferences(
                        at: urlsToUpload,
                        types: refTypes,
                    )
                }

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for placeholder in placeholders {
                    placeholder.generationInput = finalGenInput
                }

                let params = buildParams(uploaded)

                await self.runJob(
                    placeholders: placeholders,
                    params: params,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed("Upload failed: \(message)")
                }
                onFailure?()
            }
        }

        return primaryId
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .generating
        placeholder.folderId = folderId
        editor.mediaAssets.append(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            let dir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default.temporaryDirectory
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        asset.generationStatus = .downloading
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            try? FileManager.default.removeItem(at: asset.url)
            try FileManager.default.moveItem(at: tempURL, to: asset.url)

            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            editor.appendGenerationLog(for: asset)
            await editor.finalizeImportedAsset(asset)
            return true
        } catch {
            let message = error.localizedDescription
            Log.generation.error("download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.pendingDownloadURL = remoteURL
            asset.generationStatus = .failed(message)
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    /// Encodes reference images as base64 data URIs. The first reference is always encoded
    /// (needed for upscale source). Additional video/audio references are skipped.
    private func encodeReferences(
        at urls: [URL],
        types: [ClipType],
    ) async -> [String] {
        var out: [String] = []
        for (i, url) in urls.enumerated() {
            let type = types.indices.contains(i) ? types[i] : .image
            let isFirst = i == 0
            guard isFirst || type == .image else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = Self.contentType(for: url, fallback: type)
            let b64 = data.base64EncodedString()
            out.append("data:\(mime);base64,\(b64)")
        }
        return out
    }

// MARK: - Content type helpers

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text: return "application/octet-stream"
            case .lottie: return "application/json"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        params: GenerationParams,
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let hasRemote = ProviderConfig.isConfigured
        let hasLocal = ProviderConfig.isLocalAIEnabled
        guard hasRemote || hasLocal else {
            for placeholder in placeholders {
                placeholder.generationStatus = .failed("No AI provider configured. Enable Local AI or set a base URL in Settings.")
            }
            onFailure?()
            return
        }

        do {
            switch params {
            case .video(let p):
                try await runVideoJob(params: p, genInput: genInput, placeholders: placeholders,
                                      editor: editor, onComplete: onComplete, onFailure: onFailure)
            case .image(let p):
                try await runImageJob(params: p, genInput: genInput, placeholders: placeholders,
                                      editor: editor, onComplete: onComplete, onFailure: onFailure)
            case .audio(let p):
                try await runAudioJob(params: p, genInput: genInput, placeholders: placeholders,
                                      editor: editor, onComplete: onComplete, onFailure: onFailure)
            case .upscale(let p):
                try await runUpscaleJob(params: p, genInput: genInput, placeholders: placeholders,
                                        editor: editor, onComplete: onComplete, onFailure: onFailure)
            }
        } catch {
            let message = error.localizedDescription
            Log.generation.error("job failed model=\(genInput.model) error=\(message)")
            for placeholder in placeholders {
                placeholder.generationStatus = .failed(message)
            }
            onFailure?()
        }
    }

    // MARK: - Per-type job runners

    private func runVideoJob(
        params: VideoGenerationParams, genInput: GenerationInput,
        placeholders: [MediaAsset], editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) async throws {
        let imageRef = genInput.imageURLs?.first
        let (b64, mime): (String?, String?) = parseDataURI(imageRef)
        let resolution = params.resolution ?? GenerationCapabilities.videoDefaultSize

        // Local sync path: adapter returns data directly.
        if ProviderConfig.isLocalMode(for: .video),
           let localModel = ProviderConfig.selectedLocalModel(for: .video),
           let adapter = GenerationProvider.localAdapter,
           adapter.serverManager.isRunningValue {
            let data = try await adapter.generateVideo(
                model: localModel, prompt: params.prompt,
                seconds: params.duration, size: resolution
            )
            for placeholder in placeholders {
                try data.write(to: placeholder.url)
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
            }
            return
        }

        let job = try await GenerationProvider.createVideo(
            model: genInput.model, prompt: params.prompt,
            seconds: params.duration, size: resolution,
            imageRefBase64: b64, imageRefMime: mime
        )
        try await pollAndFinalize(job: job, placeholders: placeholders, editor: editor,
                                  poll: { try await GenerationProvider.getVideo(jobId: $0) },
                                  download: { try await GenerationProvider.downloadVideoContent(jobId: $0) },
                                  onComplete: onComplete, onFailure: onFailure)
    }

    private func runImageJob(
        params: ImageGenerationParams, genInput: GenerationInput,
        placeholders: [MediaAsset], editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) async throws {
        let response = try await GenerationProvider.generateImage(
            model: genInput.model, prompt: params.prompt,
            size: params.resolution ?? "1024x1024",
            n: min(params.numImages, placeholders.count),
            quality: params.quality ?? "standard",
            imageURLs: params.imageURLs
        )
        var allSucceeded = true
        for (i, img) in response.images.enumerated() {
            guard i < placeholders.count else { break }
            let placeholder = placeholders[i]
            if let b64 = img.b64JSON, let data = Data(base64Encoded: b64) {
                try data.write(to: placeholder.url)
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
            } else if let urlStr = img.url, let remote = URL(string: urlStr) {
                let ok = await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor)
                if ok {
                    onComplete?(placeholder)
                } else {
                    allSucceeded = false
                }
            } else {
                placeholder.generationStatus = .failed("No image data in response")
                allSucceeded = false
            }
        }
        if response.images.count < placeholders.count {
            for i in response.images.count..<placeholders.count {
                placeholders[i].generationStatus = .failed("Provider returned fewer images than requested")
            }
            allSucceeded = false
        }
        if !allSucceeded {
            onFailure?()
        }
    }

    private func runAudioJob(
        params: AudioGenerationParams, genInput: GenerationInput,
        placeholders: [MediaAsset], editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) async throws {
        let category: AudioModelConfig.Category = {
            let modelId = ModelID(string: genInput.model)
            if modelId.isLocal {
                switch modelId.localCategory {
                case .music: return .music
                case .sfx:   return .sfx
                default:     return .tts
                }
            }
            if let kind = ModelCatalog.shared.byId[genInput.model] {
                if case let .audio(config) = kind { return config.category }
            }
            return params.instrumental ? .music : .tts
        }()

        switch category {
        case .tts:
            let voice = params.voice ?? GenerationCapabilities.ttsDefaultVoice
            let data = try await GenerationProvider.speech(
                model: genInput.model, input: params.prompt, voice: voice
            )
            for placeholder in placeholders {
                try data.write(to: placeholder.url)
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
            }
        case .sfx:
            let data = try await GenerationProvider.generateSFX(
                model: genInput.model, prompt: params.prompt,
                durationSeconds: Double(params.durationSeconds ?? GenerationCapabilities.sfxDefaultDuration)
            )
            for placeholder in placeholders {
                try data.write(to: placeholder.url)
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
            }
        case .music:
            // Local sync path: adapter returns data directly.
            if ProviderConfig.isLocalMode(for: .music),
               let localModel = ProviderConfig.selectedLocalModel(for: .music),
               let adapter = GenerationProvider.localAdapter,
               adapter.serverManager.isRunningValue {
                let data = try await adapter.generateMusic(
                    model: localModel, prompt: params.prompt,
                    durationSeconds: params.durationSeconds ?? 30,
                    instrumental: params.instrumental
                )
                for placeholder in placeholders {
                    try data.write(to: placeholder.url)
                    placeholder.generationStatus = .none
                    editor.importMediaAsset(placeholder, skipAppend: true)
                    editor.appendGenerationLog(for: placeholder)
                    await editor.finalizeImportedAsset(placeholder)
                    onComplete?(placeholder)
                }
                return
            }

            let job = try await GenerationProvider.createMusic(
                model: genInput.model, prompt: params.prompt,
                durationSeconds: params.durationSeconds ?? 30,
                instrumental: params.instrumental, style: params.styleInstructions
            )
            try await pollAndFinalize(job: job, placeholders: placeholders, editor: editor,
                                      poll: { try await GenerationProvider.getMusicJob(jobId: $0) },
                                      download: { try await GenerationProvider.downloadMusicContent(jobId: $0) },
                                      onComplete: onComplete, onFailure: onFailure)
        }
    }

    private func runUpscaleJob(
        params: UpscaleGenerationParams, genInput: GenerationInput,
        placeholders: [MediaAsset], editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?
    ) async throws {
        let (b64, mime) = parseDataURI(params.sourceURL)
        guard let b64, let mime else {
            throw ProviderError.unexpectedResponse("upscale — no valid source image")
        }

        // Local sync path: adapter returns data directly.
        if ProviderConfig.isLocalMode(for: .upscale),
           let localModel = ProviderConfig.selectedLocalModel(for: .image),
           let adapter = GenerationProvider.localAdapter,
           adapter.serverManager.isRunningValue {
            let data = try await adapter.generateUpscale(
                model: localModel, imageBase64: b64, imageMime: mime, scale: 2
            )
            for placeholder in placeholders {
                try data.write(to: placeholder.url)
                placeholder.generationStatus = .none
                editor.importMediaAsset(placeholder, skipAppend: true)
                editor.appendGenerationLog(for: placeholder)
                await editor.finalizeImportedAsset(placeholder)
                onComplete?(placeholder)
            }
            return
        }

        let job = try await GenerationProvider.createUpscale(
            model: genInput.model, imageBase64: b64, imageMime: mime
        )
        try await pollAndFinalize(job: job, placeholders: placeholders, editor: editor,
                                  poll: { try await GenerationProvider.getUpscaleJob(jobId: $0) },
                                  download: { try await GenerationProvider.downloadUpscaleContent(jobId: $0) },
                                  onComplete: onComplete, onFailure: onFailure)
    }

    // MARK: - Shared async job poller

    private func pollAndFinalize(
        job: AsyncJob,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        poll: @escaping (String) async throws -> AsyncJob,
        download: @escaping (String) async throws -> Data,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async throws {
        var current = job
        while true {
            try Task.checkCancellation()
            switch current.status {
            case .completed:
                if let urlStr = current.resultURL, let remote = URL(string: urlStr) {
                    var allSucceeded = true
                    for placeholder in placeholders {
                        let ok = await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor)
                        if ok {
                            onComplete?(placeholder)
                        } else {
                            allSucceeded = false
                        }
                    }
                    if !allSucceeded {
                        onFailure?()
                    }
                } else {
                    let data = try await download(current.id)
                    for placeholder in placeholders {
                        try data.write(to: placeholder.url)
                        placeholder.generationStatus = .none
                        editor.importMediaAsset(placeholder, skipAppend: true)
                        editor.appendGenerationLog(for: placeholder)
                        await editor.finalizeImportedAsset(placeholder)
                        onComplete?(placeholder)
                    }
                }
                return
            case .failed:
                let msg = current.error ?? "Generation failed"
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed(msg)
                }
                onFailure?()
                return
            case .queued, .inProgress:
                try await Task.sleep(nanoseconds: 2_000_000_000)
                current = try await poll(current.id)
            }
        }
    }

    private func parseDataURI(_ s: String?) -> (base64: String?, mime: String?) {
        guard let s, s.hasPrefix("data:") else { return (nil, nil) }
        let stripped = String(s.dropFirst("data:".count))
        guard let commaIdx = stripped.firstIndex(of: ",") else { return (nil, nil) }
        let mediaType = String(stripped[..<commaIdx])
        let mime = mediaType.components(separatedBy: ";").first ?? mediaType
        let b64 = String(stripped[stripped.index(after: commaIdx)...])
        return (b64, mime)
    }

}
