import Foundation

enum LeagueProvider: String, Codable, CaseIterable, Identifiable {
    case mfl
    case sleeper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mfl: return "MyFantasyLeague"
        case .sleeper: return "Sleeper"
        }
    }

    var shortName: String {
        switch self {
        case .mfl: return "MFL"
        case .sleeper: return "Sleeper"
        }
    }
}

enum SleeperError: LocalizedError {
    case userNotFound
    case http(Int)
    case decode
    case empty

    var errorDescription: String? {
        switch self {
        case .userNotFound: return "Sleeper username not found."
        case .http(let c): return "Sleeper error \(c)."
        case .decode: return "Could not parse Sleeper data."
        case .empty: return "No data from Sleeper."
        }
    }
}

/// Read-only Sleeper HTTP API (no auth token required).
actor SleeperClient {
    static let shared = SleeperClient()

    private let session: URLSession
    private var cache: [String: (date: Date, data: Data)] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func user(usernameOrId: String) async throws -> SleeperUser {
        let trimmed = usernameOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SleeperError.userNotFound }
        let data = try await get("https://api.sleeper.app/v1/user/\(trimmed.urlPathEncoded)", cacheTTL: 300)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = root["user_id"] as? String ?? (root["user_id"] as? Int).map(String.init)
        else { throw SleeperError.userNotFound }
        return SleeperUser(
            userId: userId,
            username: (root["username"] as? String) ?? trimmed,
            displayName: (root["display_name"] as? String) ?? (root["username"] as? String) ?? trimmed,
            avatar: root["avatar"] as? String
        )
    }

    func leagues(userId: String, season: Int) async throws -> [SleeperLeagueSummary] {
        let data = try await get(
            "https://api.sleeper.app/v1/user/\(userId.urlPathEncoded)/leagues/nfl/\(season)",
            cacheTTL: 120
        )
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SleeperError.decode
        }
        return arr.compactMap { row in
            guard let leagueId = row["league_id"] as? String else { return nil }
            return SleeperLeagueSummary(
                leagueId: leagueId,
                name: (row["name"] as? String) ?? "Sleeper League",
                season: Int(row["season"] as? String ?? "") ?? season,
                status: row["status"] as? String,
                totalRosters: row["total_rosters"] as? Int,
                avatar: row["avatar"] as? String
            )
        }
    }

    func rosters(leagueId: String) async throws -> Data {
        try await get("https://api.sleeper.app/v1/league/\(leagueId.urlPathEncoded)/rosters", cacheTTL: 60)
    }

    func users(leagueId: String) async throws -> Data {
        try await get("https://api.sleeper.app/v1/league/\(leagueId.urlPathEncoded)/users", cacheTTL: 300)
    }

    func matchups(leagueId: String, week: Int) async throws -> Data {
        try await get(
            "https://api.sleeper.app/v1/league/\(leagueId.urlPathEncoded)/matchups/\(week)",
            cacheTTL: 30
        )
    }

    func transactions(leagueId: String, week: Int) async throws -> Data {
        try await get(
            "https://api.sleeper.app/v1/league/\(leagueId.urlPathEncoded)/transactions/\(week)",
            cacheTTL: 120
        )
    }

    func nflState() async throws -> (week: Int, season: Int) {
        let data = try await get("https://api.sleeper.app/v1/state/nfl", cacheTTL: 300)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SleeperError.decode
        }
        let week = (root["week"] as? Int)
            ?? Int(root["week"] as? String ?? "")
            ?? 1
        let season = Int(root["league_season"] as? String ?? "")
            ?? Int(root["season"] as? String ?? "")
            ?? Calendar.current.mflSeason
        return (week, season)
    }

    func allPlayers() async throws -> Data {
        // Huge payload — cache a day.
        try await get("https://api.sleeper.app/v1/players/nfl", cacheTTL: 86_400)
    }

    func trendingAdds(limit: Int = 25) async throws -> Data {
        try await get(
            "https://api.sleeper.app/v1/players/nfl/trending/add?lookback_hours=48&limit=\(limit)",
            cacheTTL: 300
        )
    }

    /// Resolve the caller's roster in a league (owner_id match).
    func resolveRoster(leagueId: String, userId: String) async throws -> (rosterId: String, teamName: String) {
        async let rostersData = rosters(leagueId: leagueId)
        async let usersData = users(leagueId: leagueId)
        let (rostersRaw, usersRaw) = try await (rostersData, usersData)
        guard let arr = try JSONSerialization.jsonObject(with: rostersRaw) as? [[String: Any]],
              let mine = arr.first(where: { ($0["owner_id"] as? String) == userId })
        else { throw SleeperError.decode }
        let rosterId = (mine["roster_id"] as? Int).map(String.init)
            ?? (mine["roster_id"] as? String)
            ?? ""
        guard !rosterId.isEmpty else { throw SleeperError.decode }

        var teamName = "Roster \(rosterId)"
        if let users = try JSONSerialization.jsonObject(with: usersRaw) as? [[String: Any]],
           let user = users.first(where: { ($0["user_id"] as? String) == userId }) {
            if let meta = user["metadata"] as? [String: Any],
               let name = meta["team_name"] as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                teamName = name
            } else if let display = user["display_name"] as? String {
                teamName = display
            }
        }
        return (rosterId, teamName)
    }

    private func get(_ urlString: String, cacheTTL: TimeInterval) async throws -> Data {
        if cacheTTL > 0, let hit = cache[urlString], Date().timeIntervalSince(hit.date) < cacheTTL {
            return hit.data
        }
        guard let url = URL(string: urlString) else { throw SleeperError.decode }
        var request = URLRequest(url: url)
        request.setValue("Sideline/1.0 (com.cpf32.sideline; iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SleeperError.decode }
        if http.statusCode == 404 { throw SleeperError.userNotFound }
        guard (200...299).contains(http.statusCode) else { throw SleeperError.http(http.statusCode) }
        if data.isEmpty || data == Data("null".utf8) { throw SleeperError.empty }
        if cacheTTL > 0 {
            cache[urlString] = (Date(), data)
        }
        return data
    }
}

struct SleeperUser: Hashable {
    let userId: String
    let username: String
    let displayName: String
    let avatar: String?
}

struct SleeperLeagueSummary: Identifiable, Hashable {
    var id: String { leagueId }
    let leagueId: String
    let name: String
    let season: Int
    let status: String?
    let totalRosters: Int?
    let avatar: String?
    /// Filled when user picks a league (their roster).
    var rosterId: String = ""
    var franchiseName: String = ""
}

struct SleeperPlayerRecord: Hashable {
    let playerId: String
    let firstName: String
    let lastName: String
    let fullName: String
    let position: String
    let team: String
    let number: String?
    let height: String?
    let weight: String?
    let age: Int?
    let college: String?
    let status: String?
    let injuryStatus: String?
    let yearsExp: Int?
    let depthChartPosition: Int?
    let depthChartOrder: Int?

    var searchKey: String {
        "\(lastName.lowercased())|\(firstName.lowercased())|\(position.uppercased())|\(NFLScheduleService.normalizeTeam(team))"
    }
}

private extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
