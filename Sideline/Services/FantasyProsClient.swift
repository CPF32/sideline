import Foundation

enum FantasyProsScoring: String, CaseIterable, Identifiable {
    case std = "STD"
    case half = "HALF"
    case ppr = "PPR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .std: return "Standard"
        case .half: return "Half PPR"
        case .ppr: return "PPR"
        }
    }
}

enum FantasyProsError: LocalizedError {
    case missingAPIKey
    case http(Int, String?)
    case rateLimited(String?)
    case decode
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a FantasyPros API key in Settings."
        case .rateLimited(let body):
            if let body, !body.isEmpty {
                return "FantasyPros rate limit / quota exceeded — \(body)"
            }
            return "FantasyPros rate limit or quota exceeded. Try again later or check your plan at fantasypros.com/api-data."
        case .http(let code, let body):
            if let body, !body.isEmpty { return "FantasyPros \(code): \(body)" }
            return "FantasyPros error \(code)."
        case .decode:
            return "Could not parse FantasyPros data."
        case .empty:
            return "No FantasyPros data returned."
        }
    }

    var isQuotaIssue: Bool {
        if case .rateLimited = self { return true }
        if case .http(429, _) = self { return true }
        if case .http(403, let body) = self {
            let lower = (body ?? "").lowercased()
            return lower.contains("quota") || lower.contains("limit") || lower.contains("exceed")
                || lower.contains("rate") || lower.contains("credit")
        }
        return false
    }
}

/// Thin FantasyPros public v2 HTTP client (`x-api-key`).
actor FantasyProsClient {
    static let shared = FantasyProsClient()

    private let session: URLSession
    private let base = "https://api.fantasypros.com/public/v2/json"

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func apiKey() -> String? {
        let key = KeychainStore.get(.fantasyProsAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, key.count >= 8 else { return nil }
        return key
    }

    static var hasAPIKey: Bool { apiKey() != nil }

    static var scoring: FantasyProsScoring {
        get {
            let raw = UserDefaults.standard.string(forKey: "sideline.fantasypros.scoring")
                ?? FantasyProsScoring.half.rawValue
            return FantasyProsScoring(rawValue: raw) ?? .half
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sideline.fantasypros.scoring")
        }
    }

    func consensusRankings(
        season: Int,
        position: String = "ALL",
        type: String? = nil,
        week: Int? = nil,
        scoring: FantasyProsScoring = FantasyProsClient.scoring
    ) async throws -> Data {
        var query: [String: String] = [
            "position": position,
            "scoring": scoring.rawValue
        ]
        if let type, !type.isEmpty {
            query["type"] = type
        }
        if let week {
            query["week"] = String(week)
        }
        return try await get("nfl/\(season)/consensus-rankings", query: query, policy: .standard)
    }

    func projections(
        season: Int,
        week: Int,
        position: String? = nil,
        positions: String? = nil,
        scoring: FantasyProsScoring = FantasyProsClient.scoring
    ) async throws -> Data {
        // Docs: single `position` (default RB). `ALL` is invalid — fetch per-pos or use `positions`.
        var query: [String: String] = [
            "week": String(week),
            "scoring": scoring.rawValue
        ]
        if let positions, !positions.isEmpty {
            query["positions"] = positions
        } else if let position, !position.isEmpty {
            query["position"] = position
        } else {
            query["position"] = "RB"
        }
        return try await get(
            "nfl/\(season)/projections",
            query: query,
            policy: .standard
        )
    }

    /// Drop FantasyPros HTTP cache (e.g. after saving a new key).
    func clearCache() async {
        await DataCache.shared.removeAll(matchingPrefix: "fp:")
    }

    func news(limit: Int = 50) async throws -> Data {
        try await get("nfl/news", query: ["limit": String(limit)], policy: .standard)
    }

    func players(ecr: Bool = true) async throws -> Data {
        var query: [String: String] = ["show": "pos_rank"]
        if ecr { query["ecr"] = "included" }
        return try await get("nfl/players", query: query, policy: .day)
    }

    private func get(_ path: String, query: [String: String], policy: DataCache.Policy) async throws -> Data {
        guard let apiKey = Self.apiKey() else { throw FantasyProsError.missingAPIKey }

        let sortedQuery = query.sorted { $0.key < $1.key }
        let queryString = sortedQuery
            .map { "\($0.key.urlQueryEncoded)=\($0.value.urlQueryEncoded)" }
            .joined(separator: "&")
        let urlString = queryString.isEmpty
            ? "\(base)/\(path)"
            : "\(base)/\(path)?\(queryString)"

        return try await DataCache.shared.data(key: "fp:\(urlString)", policy: policy) {
            try await self.fetch(urlString: urlString, apiKey: apiKey)
        }
    }

    private func fetch(urlString: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw FantasyProsError.decode }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sideline/1.0 (com.cpf32.sideline; iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FantasyProsError.decode }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let short = body.flatMap { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }
            let lower = (short ?? "").lowercased()
            if http.statusCode == 429
                || (http.statusCode == 403 && (lower.contains("quota") || lower.contains("limit")
                    || lower.contains("exceed") || lower.contains("rate") || lower.contains("credit"))) {
                throw FantasyProsError.rateLimited(short)
            }
            throw FantasyProsError.http(http.statusCode, short)
        }
        if data.isEmpty || data == Data("null".utf8) { throw FantasyProsError.empty }
        return data
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
