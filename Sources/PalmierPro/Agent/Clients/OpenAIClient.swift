import Foundation

struct OpenAIClient: AgentClient {
    let baseURL: String
    let apiKey: String
    let model: String
    var maxTokens: Int = 8192

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentWireMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentWireMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty, !baseURL.isEmpty else {
            throw AgentStreamError.notConfigured
        }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let endpoint = URL(string: "\(trimmedBase)/chat/completions") else {
            throw AgentStreamError.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: OpenAIRequestBody.build(
                model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages
            ),
            options: [.sortedKeys]
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AgentStreamError.httpError(status: http.statusCode, body: body)
        }

        try await OpenAISSE.parse(bytes: bytes, continuation: continuation)
    }
}
