import Foundation

/// Fetches live model catalogs from each provider. Falls back to curated lists on failure.
enum LLMModelCatalog {
    static func fetch(provider: LLMProvider, apiKey: String?) async -> [LLMModelOption] {
        do {
            switch provider {
            case .openRouter:
                return try await fetchOpenRouter()
            case .openAI:
                guard let apiKey, !apiKey.isEmpty else { return provider.fallbackModels }
                return try await fetchOpenAI(apiKey: apiKey)
            case .anthropic:
                guard let apiKey, !apiKey.isEmpty else { return provider.fallbackModels }
                return try await fetchAnthropic(apiKey: apiKey)
            case .google:
                guard let apiKey, !apiKey.isEmpty else { return provider.fallbackModels }
                return try await fetchGoogle(apiKey: apiKey)
            }
        } catch {
            return provider.fallbackModels
        }
    }

    // MARK: - OpenRouter (public list + live pricing)

    private static func fetchOpenRouter() async throws -> [LLMModelOption] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Sideline/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        var options: [(option: LLMModelOption, price: Double)] = []
        for row in list {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            // Batch endpoints aren't for interactive agent chat.
            if id.contains(":batch") { continue }
            let arch = row["architecture"] as? [String: Any]
            let outputs = arch?["output_modalities"] as? [String] ?? []
            if !outputs.isEmpty, !outputs.contains("text") { continue }
            let lower = id.lowercased()
            if lower.contains("embed") || lower.contains("moderation") || lower.contains("whisper") {
                continue
            }

            let pricing = row["pricing"] as? [String: Any]
            let prompt = Double(pricing?["prompt"] as? String ?? "") ?? .greatestFiniteMagnitude
            let completion = Double(pricing?["completion"] as? String ?? "") ?? 0
            let score = prompt + completion * 0.5
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (name?.isEmpty == false ? name! : id)
            let label: String
            if id.contains(":free") || prompt == 0 {
                label = "Free"
            } else {
                label = costLabel(promptPerToken: prompt)
            }
            options.append((
                LLMModelOption(
                    id: id,
                    title: shortTitle(title, id: id),
                    costLabel: label,
                    sortPrice: score
                ),
                score
            ))
        }

        // Full catalog, cheapest first — UI search filters this list.
        return options.sorted { $0.price < $1.price }.map(\.option)
    }

    // MARK: - OpenAI

    private static func fetchOpenAI(apiKey: String) async throws -> [LLMModelOption] {
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        let preferredOrder = ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4o", "gpt-4.1", "o4-mini", "o3-mini"]
        let ids = Set(list.compactMap { $0["id"] as? String }.filter { id in
            let lower = id.lowercased()
            return lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4")
        })
        var options: [LLMModelOption] = []
        for (idx, id) in preferredOrder.enumerated() where ids.contains(id) {
            options.append(.init(
                id: id,
                title: prettyOpenAI(id),
                costLabel: idx == 0 ? "Lowest $" : (idx < 2 ? "Low $" : "Higher $"),
                sortPrice: Double(idx)
            ))
        }
        // Include other chat-ish gpt models not in preferred list.
        for id in ids.sorted() where !preferredOrder.contains(id) {
            if id.contains("realtime") || id.contains("audio") || id.contains("transcribe") { continue }
            if id.contains("instruct") || id.contains("image") { continue }
            options.append(.init(id: id, title: prettyOpenAI(id), costLabel: "—", sortPrice: 100))
        }
        return options.isEmpty ? LLMProvider.openAI.fallbackModels : options
    }

    // MARK: - Anthropic

    private static func fetchAnthropic(apiKey: String) async throws -> [LLMModelOption] {
        let url = URL(string: "https://api.anthropic.com/v1/models")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        func rank(_ id: String) -> Double {
            let lower = id.lowercased()
            if lower.contains("haiku") { return 0 }
            if lower.contains("sonnet") { return 1 }
            if lower.contains("opus") { return 2 }
            return 3
        }

        let options = list.compactMap { row -> LLMModelOption? in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["display_name"] as? String) ?? id
            let r = rank(id)
            return LLMModelOption(
                id: id,
                title: name,
                costLabel: r == 0 ? "Lowest $" : (r == 1 ? "Mid $" : "Higher $"),
                sortPrice: r
            )
        }
        .sorted { $0.sortPrice < $1.sortPrice }

        return options.isEmpty ? LLMProvider.anthropic.fallbackModels : options
    }

    // MARK: - Google

    private static func fetchGoogle(apiKey: String) async throws -> [LLMModelOption] {
        let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? apiKey
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(encoded)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        func rank(_ id: String) -> Double {
            let lower = id.lowercased()
            if lower.contains("flash-lite") { return 0 }
            if lower.contains("flash") { return 1 }
            if lower.contains("pro") { return 2 }
            return 3
        }

        let options = list.compactMap { row -> LLMModelOption? in
            guard var name = row["name"] as? String else { return nil }
            // "models/gemini-2.5-flash" → "gemini-2.5-flash"
            if name.hasPrefix("models/") { name = String(name.dropFirst("models/".count)) }
            let methods = row["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            if name.contains("embedding") || name.contains("aqa") || name.contains("tts") { return nil }
            let display = (row["displayName"] as? String) ?? name
            let r = rank(name)
            return LLMModelOption(
                id: name,
                title: display,
                costLabel: r == 0 ? "Lowest $" : (r == 1 ? "Low $" : "Higher $"),
                sortPrice: r
            )
        }
        .sorted { $0.sortPrice < $1.sortPrice }

        return options.isEmpty ? LLMProvider.google.fallbackModels : options
    }

    // MARK: - Helpers

    private static func costLabel(promptPerToken: Double) -> String {
        guard promptPerToken.isFinite, promptPerToken < .greatestFiniteMagnitude / 2 else { return "—" }
        let perMillion = promptPerToken * 1_000_000
        if perMillion < 0.05 { return String(format: "$%.3f/M in", perMillion) }
        if perMillion < 10 { return String(format: "$%.2f/M in", perMillion) }
        return String(format: "$%.0f/M in", perMillion)
    }

    private static func shortTitle(_ name: String, id: String) -> String {
        // Prefer human name; strip redundant provider prefixes when noisy.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 42 {
            if let last = id.split(separator: "/").last {
                return String(last)
            }
            return String(trimmed.prefix(42))
        }
        return trimmed.isEmpty ? id : trimmed
    }

    private static func prettyOpenAI(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ").uppercased()
    }
}
