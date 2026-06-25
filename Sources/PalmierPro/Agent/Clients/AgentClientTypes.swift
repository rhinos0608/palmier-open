import Foundation

// MARK: - Shared value types

enum AgentStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case other

    static func from(finishReason: String) -> AgentStopReason {
        switch finishReason {
        case "stop": return .endTurn
        case "tool_calls", "function_call": return .toolUse
        case "length": return .maxTokens
        default: return .other
        }
    }
}

/// A fully-formed OpenAI chat message object (role + content + optional
/// tool_calls / tool_call_id). Built by `AgentService` so each client stays thin.
struct AgentWireMessage: @unchecked Sendable {
    let json: [String: Any]
}

struct AgentToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AgentStreamEvent: Sendable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AgentStopReason)
}

enum AgentStreamError: LocalizedError {
    case notConfigured
    case httpError(status: Int, body: String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add an API base URL and key in Settings to start."
        case .httpError(let status, let body): "Provider error (\(status)): \(body.prefix(500))"
        case .streamError(let msg): "Stream error: \(msg)"
        }
    }
}

// MARK: - Client protocol

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentWireMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Usage logging

enum AgentUsageLog {
    static func record(_ usage: [String: Any]) {
        #if DEBUG
        let prompt = usage["prompt_tokens"] as? Int ?? 0
        let completion = usage["completion_tokens"] as? Int ?? 0
        print("[agent usage] prompt=\(prompt) completion=\(completion)")
        #endif
    }
}

// MARK: - OpenAI request body builder

enum OpenAIRequestBody {
    static func build(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentWireMessage]
    ) -> [String: Any] {
        var wire: [[String: Any]] = []
        if !system.isEmpty {
            wire.append(["role": "system", "content": system])
        }
        wire.append(contentsOf: messages.map(\.json))

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": maxTokens,
            "messages": wire,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ],
                ]
            }
        }
        return body
    }
}

// MARK: - Shared OpenAI SSE parser

enum OpenAISSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        var pendingTools: [Int: (id: String, name: String, json: String)] = [:]

        func flushTools() {
            for (_, acc) in pendingTools.sorted(by: { $0.key < $1.key }) {
                let json = acc.json.isEmpty ? "{}" : acc.json
                continuation.yield(.toolUseComplete(id: acc.id, name: acc.name, inputJSON: json))
            }
            pendingTools.removeAll()
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = event["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "unknown error"
                continuation.finish(throwing: AgentStreamError.streamError(msg))
                return
            }

            if let usage = event["usage"] as? [String: Any] {
                AgentUsageLog.record(usage)
            }

            guard let choices = event["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let index = call["index"] as? Int ?? 0
                        var acc = pendingTools[index] ?? (id: "", name: "", json: "")
                        if let id = call["id"] as? String, !id.isEmpty { acc.id = id }
                        if let function = call["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty { acc.name = name }
                            if let args = function["arguments"] as? String { acc.json += args }
                        }
                        pendingTools[index] = acc
                    }
                }
            }

            if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
                flushTools()
                continuation.yield(.messageStop(stopReason: AgentStopReason.from(finishReason: finish)))
            }
        }
        flushTools()
    }
}
