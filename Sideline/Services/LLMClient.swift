import Foundation

enum LLMClientError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case decode
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an API key for the selected LLM provider in Settings."
        case .http(let c, let b): return "LLM error \(c): \(b.prefix(200))"
        case .decode: return "Could not parse LLM response."
        case .empty: return "LLM returned an empty response."
        }
    }
}

struct LLMClient {
    let provider: LLMProvider
    let model: String
    let apiKey: String

    func completeJSON(system: String, user: String) async throws -> String {
        switch provider {
        case .openAI, .openRouter:
            return try await openAICompatible(system: system, user: user, jsonMode: true)
        case .anthropic:
            return try await anthropic(system: system, messages: [("user", user)], jsonMode: true)
        case .google:
            return try await google(system: system, messages: [("user", user)], jsonMode: true)
        }
    }

    /// Multi-turn plain-text chat for follow-up threads.
    func completeChat(system: String, messages: [(role: String, content: String)]) async throws -> String {
        switch provider {
        case .openAI, .openRouter:
            let apiMessages: [[String: Any]] = messages.map {
                ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content]
            }
            let turn = try await openAIToolTurn(system: system, messages: apiMessages, tools: nil)
            let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { throw LLMClientError.empty }
            return text
        case .anthropic:
            return try await anthropic(system: system, messages: messages, jsonMode: false)
        case .google:
            return try await google(system: system, messages: messages, jsonMode: false)
        }
    }

    /// Tool-calling chat turn (OpenAI / OpenRouter). Returns text and/or tool calls.
    func completeChatTurn(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?
    ) async throws -> AgentChatToolkit.TurnResult {
        switch provider {
        case .openAI, .openRouter:
            return try await openAIToolTurn(system: system, messages: messages, tools: tools)
        case .anthropic, .google:
            let plain: [(String, String)] = messages.compactMap { m in
                guard let role = m["role"] as? String,
                      let content = m["content"] as? String
                else { return nil }
                return (role, content)
            }
            let text = try await completeChat(system: system, messages: plain)
            return AgentChatToolkit.TurnResult(assistantText: text, toolCalls: [])
        }
    }

    /// Runs a tool loop until the model returns a final text answer (max rounds).
    func runToolLoop(
        system: String,
        history: [(role: String, content: String)],
        tools: [[String: Any]],
        maxRounds: Int = 6,
        executeTool: @escaping @MainActor (String, String) async -> String,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> String {
        var messages: [[String: Any]] = history.map {
            ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content]
        }
        for round in 0..<maxRounds {
            onProgress?("Thinking\(round == 0 ? "" : " (round \(round + 1))")…")
            let turn = try await completeChatTurn(system: system, messages: messages, tools: tools)
            if turn.toolCalls.isEmpty {
                let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty { throw LLMClientError.empty }
                return text
            }

            var assistantMsg: [String: Any] = ["role": "assistant"]
            if let content = turn.assistantText {
                assistantMsg["content"] = content
            } else {
                assistantMsg["content"] = NSNull()
            }
            assistantMsg["tool_calls"] = turn.toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ]
                ]
            }
            messages.append(assistantMsg)

            for call in turn.toolCalls {
                let label = call.name.replacingOccurrences(of: "_", with: " ")
                onProgress?("Tool: \(label)…")
                let result = await executeTool(call.name, call.argumentsJSON)
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result
                ])
            }
        }
        onProgress?("Wrapping up…")
        let final = try await completeChatTurn(system: system, messages: messages, tools: nil)
        let text = final.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { throw LLMClientError.empty }
        return text
    }

    private var openAIBaseURL: URL {
        switch provider {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        default:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    private func openAICompatible(system: String, user: String, jsonMode: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        applyTemperature(0.2, to: &body)
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        return try await openAIRequest(body: body)
    }

    private func openAIToolTurn(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?
    ) async throws -> AgentChatToolkit.TurnResult {
        var apiMessages: [[String: Any]] = [["role": "system", "content": system]]
        apiMessages.append(contentsOf: messages)
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]
        applyTemperature(0.3, to: &body)
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        let data = try await openAIRequestData(body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw LLMClientError.decode }

        let content = message["content"] as? String
        var calls: [AgentChatToolkit.ToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let id = (tc["id"] as? String) ?? UUID().uuidString
                let fn = tc["function"] as? [String: Any]
                let name = (fn?["name"] as? String) ?? ""
                let args: String
                if let s = fn?["arguments"] as? String {
                    args = s
                } else if let obj = fn?["arguments"],
                          JSONSerialization.isValidJSONObject(obj),
                          let d = try? JSONSerialization.data(withJSONObject: obj),
                          let s = String(data: d, encoding: .utf8) {
                    args = s
                } else {
                    args = "{}"
                }
                if !name.isEmpty {
                    calls.append(.init(id: id, name: name, argumentsJSON: args))
                }
            }
        }
        return AgentChatToolkit.TurnResult(assistantText: content, toolCalls: calls)
    }

    /// Reasoning models (o1/o3/o4/gpt-5) only accept the default temperature (1).
    /// Sending 0.2/0.3 returns 400 unsupported_value — omit the field instead.
    private func applyTemperature(_ value: Double, to body: inout [String: Any]) {
        guard supportsCustomTemperature else { return }
        body["temperature"] = value
    }

    private var supportsCustomTemperature: Bool {
        let id = model.lowercased()
        // OpenRouter ids look like "openai/gpt-5-mini" — strip the provider prefix.
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        if bare.hasPrefix("o1") || bare.hasPrefix("o3") || bare.hasPrefix("o4") { return false }
        if bare.hasPrefix("gpt-5") { return false }
        return true
    }

    private func openAIRequest(body: [String: Any]) async throws -> String {
        let data = try await openAIRequestData(body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else { throw LLMClientError.empty }
        return content
    }

    private func openAIRequestData(body: [String: Any]) async throws -> Data {
        do {
            return try await openAIRequestDataOnce(body: body)
        } catch LLMClientError.http(_, let message) where Self.isTemperatureRejection(message) {
            // Reasoning models only accept temperature 1 — retry silently instead of surfacing the error.
            var retry = body
            retry["temperature"] = 1
            return try await openAIRequestDataOnce(body: retry)
        }
    }

    private func openAIRequestDataOnce(body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: openAIBaseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .openRouter {
            request.setValue("sideline.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Sideline", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response, data: data)
        return data
    }

    private static func isTemperatureRejection(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("temperature")
            && (lower.contains("unsupported") || lower.contains("does not support") || lower.contains("only the default"))
    }

    private func anthropic(
        system: String,
        messages: [(role: String, content: String)],
        jsonMode: Bool
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let systemText = jsonMode ? system + "\nRespond with a single JSON object only." : system
        let apiMessages: [[String: String]] = messages.map {
            ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content]
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": systemText,
            "messages": apiMessages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              !text.isEmpty
        else { throw LLMClientError.empty }
        return text
    }

    private func google(
        system: String,
        messages: [(role: String, content: String)],
        jsonMode: Bool
    ) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var generationConfig: [String: Any] = ["temperature": jsonMode ? 0.2 : 0.4]
        if jsonMode {
            generationConfig["responseMimeType"] = "application/json"
        }
        let systemText = jsonMode ? system + "\nRespond with JSON only." : system
        let contents: [[String: Any]] = messages.map { m in
            [
                "role": m.role == "assistant" ? "model" : "user",
                "parts": [["text": m.content]]
            ]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemText]]],
            "contents": contents,
            "generationConfig": generationConfig
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              !text.isEmpty
        else { throw LLMClientError.empty }
        return text
    }

    private func throwIfNeeded(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw LLMClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
