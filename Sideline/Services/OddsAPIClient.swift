import Foundation

enum OddsAPIError: LocalizedError {
    case missingAPIKey
    case http(Int, String?)
    case decode
    case empty
    case quota
    case historicUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an Odds API key in Settings → APIs."
        case .http(let code, let body):
            if let body, !body.isEmpty { return "Odds API \(code): \(body)" }
            return "Odds API error \(code)."
        case .decode:
            return "Could not parse Odds API data."
        case .empty:
            return "No Odds API data returned."
        case .quota:
            return "Odds API quota exceeded — check remaining requests at the-odds-api.com."
        case .historicUnavailable:
            return "Historic player props need a paid Odds API plan (historical endpoints)."
        }
    }
}

/// Thin client for The Odds API v4 — NFL events + per-event player props.
actor OddsAPIClient {
    static let shared = OddsAPIClient()

    private let session: URLSession
    private let base = "https://api.the-odds-api.com/v4"
    private let sport = "americanfootball_nfl"

    /// Live / upcoming (cost = market count × regions per event).
    static let defaultPlayerMarkets = [
        "player_pass_yds",
        "player_pass_tds",
        "player_rush_yds",
        "player_receptions",
        "player_reception_yds",
        "player_anytime_td",
    ].joined(separator: ",")

    /// Smaller set for historic (×10 credits per market on historical event-odds).
    static let historicPlayerMarkets = [
        "player_pass_yds",
        "player_rush_yds",
        "player_receptions",
        "player_anytime_td",
    ].joined(separator: ",")

    private(set) var lastRemaining: Int?
    private(set) var lastUsed: Int?
    private(set) var lastCost: Int?

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func apiKey() -> String? {
        let key = KeychainStore.get(.oddsAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, key.count >= 8 else { return nil }
        return key
    }

    static var hasAPIKey: Bool { apiKey() != nil }

    /// Upcoming / live NFL events. Does **not** count against quota.
    func nflEvents() async throws -> Data {
        guard let apiKey = Self.apiKey() else { throw OddsAPIError.missingAPIKey }
        let cacheKey = "odds:events:\(sport)"
        if let hit = await DataCache.shared.get(cacheKey, policy: .standard) {
            return hit
        }
        var components = URLComponents(string: "\(base)/sports/\(sport)/events")!
        components.queryItems = [URLQueryItem(name: "apiKey", value: apiKey)]
        let data = try await fetch(url: components.url!)
        await DataCache.shared.set(data, for: cacheKey, persistToDisk: true)
        return data
    }

    /// Player props for one live/upcoming event.
    func eventPlayerProps(
        eventId: String,
        markets: String = OddsAPIClient.defaultPlayerMarkets,
        hasLiveGames: Bool = false
    ) async throws -> Data {
        guard let apiKey = Self.apiKey() else { throw OddsAPIError.missingAPIKey }
        let cacheKey = "odds:props:\(eventId):\(markets):us:american"
        let policy: DataCache.Policy = .liveAware(hasLiveGames: hasLiveGames)
        if let hit = await DataCache.shared.get(cacheKey, policy: policy) {
            return hit
        }
        var components = URLComponents(
            string: "\(base)/sports/\(sport)/events/\(eventId)/odds"
        )!
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: markets),
            URLQueryItem(name: "oddsFormat", value: "american"),
        ]
        let data = try await fetch(url: components.url!)
        await DataCache.shared.set(data, for: cacheKey, persistToDisk: true)
        return data
    }

    /// Historical event list at a snapshot (paid plans). Costs 1 credit when events exist.
    func historicalEvents(
        snapshot: Date,
        commenceFrom: Date?,
        commenceTo: Date?
    ) async throws -> Data {
        guard let apiKey = Self.apiKey() else { throw OddsAPIError.missingAPIKey }
        let dateKey = Self.isoUTC(snapshot)
        let fromKey = commenceFrom.map(Self.isoUTC) ?? "-"
        let toKey = commenceTo.map(Self.isoUTC) ?? "-"
        let cacheKey = "odds:hist-events:\(sport):\(dateKey):\(fromKey):\(toKey)"
        if let hit = await DataCache.shared.get(cacheKey, policy: .day) {
            return hit
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "date", value: dateKey),
        ]
        if let commenceFrom {
            items.append(URLQueryItem(name: "commenceTimeFrom", value: Self.isoUTC(commenceFrom)))
        }
        if let commenceTo {
            items.append(URLQueryItem(name: "commenceTimeTo", value: Self.isoUTC(commenceTo)))
        }
        var components = URLComponents(string: "\(base)/historical/sports/\(sport)/events")!
        components.queryItems = items
        do {
            let data = try await fetch(url: components.url!, historic: true)
            await DataCache.shared.set(data, for: cacheKey, persistToDisk: true)
            return data
        } catch OddsAPIError.historicUnavailable {
            throw OddsAPIError.historicUnavailable
        }
    }

    /// Historical player props for one event (paid; ~10 credits × markets).
    func historicalEventPlayerProps(
        eventId: String,
        snapshot: Date,
        markets: String = OddsAPIClient.historicPlayerMarkets
    ) async throws -> Data {
        guard let apiKey = Self.apiKey() else { throw OddsAPIError.missingAPIKey }
        let dateKey = Self.isoUTC(snapshot)
        let cacheKey = "odds:hist-props:\(eventId):\(dateKey):\(markets):us"
        if let hit = await DataCache.shared.get(cacheKey, policy: .day) {
            return hit
        }
        var components = URLComponents(
            string: "\(base)/historical/sports/\(sport)/events/\(eventId)/odds"
        )!
        components.queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "regions", value: "us"),
            URLQueryItem(name: "markets", value: markets),
            URLQueryItem(name: "oddsFormat", value: "american"),
            URLQueryItem(name: "date", value: dateKey),
        ]
        let data = try await fetch(url: components.url!, historic: true)
        await DataCache.shared.set(data, for: cacheKey, persistToDisk: true)
        return data
    }

    func clearCache() async {
        await DataCache.shared.removeAll(matchingPrefix: "odds:")
    }

    private func fetch(url: URL, historic: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Sideline/1.0 (com.cpf32.sideline; iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OddsAPIError.decode }
        lastRemaining = http.value(forHTTPHeaderField: "x-requests-remaining").flatMap(Int.init)
        lastUsed = http.value(forHTTPHeaderField: "x-requests-used").flatMap(Int.init)
        lastCost = http.value(forHTTPHeaderField: "x-requests-last").flatMap(Int.init)
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let short = body.flatMap { $0.count > 160 ? String($0.prefix(160)) + "…" : $0 }
            let lower = (short ?? "").lowercased()
            if historic, http.statusCode == 401 || http.statusCode == 403
                || lower.contains("paid") || lower.contains("plan") || lower.contains("upgrade") {
                throw OddsAPIError.historicUnavailable
            }
            if http.statusCode == 401 || http.statusCode == 429 {
                throw OddsAPIError.quota
            }
            throw OddsAPIError.http(http.statusCode, short)
        }
        if data.isEmpty { throw OddsAPIError.empty }
        return data
    }

    static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
