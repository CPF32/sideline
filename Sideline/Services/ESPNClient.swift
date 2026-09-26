import Foundation

enum ESPNError: LocalizedError {
    case http(Int)
    case unauthorized
    case notFound
    case decode
    case empty
    case missingLeagueId

    var errorDescription: String? {
        switch self {
        case .http(let c): return "ESPN error \(c)."
        case .unauthorized:
            return "This ESPN league is private. Paste espn_s2 and SWID cookies from fantasy.espn.com."
        case .notFound:
            return "ESPN league not found. Check league ID and season year."
        case .decode: return "Could not parse ESPN data."
        case .empty: return "No data from ESPN."
        case .missingLeagueId: return "Enter an ESPN league ID."
        }
    }
}

struct ESPNCookies: Hashable, Sendable {
    var espnS2: String
    var swid: String

    var isEmpty: Bool {
        espnS2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || swid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func fromKeychain() -> ESPNCookies? {
        let s2 = KeychainStore.get(.espnS2)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let swid = KeychainStore.get(.espnSWID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !s2.isEmpty, !swid.isEmpty else { return nil }
        return ESPNCookies(espnS2: s2, swid: swid)
    }

    func saveToKeychain() {
        KeychainStore.set(espnS2, for: .espnS2)
        KeychainStore.set(swid, for: .espnSWID)
    }

    var headerValue: String {
        var swidValue = swid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !swidValue.hasPrefix("{") { swidValue = "{\(swidValue)}" }
        if !swidValue.hasSuffix("}") { swidValue = "\(swidValue)}" }
        let s2 = espnS2.trimmingCharacters(in: .whitespacesAndNewlines)
        return "espn_s2=\(s2); SWID=\(swidValue)"
    }
}

struct ESPNTeamSummary: Identifiable, Hashable {
    var id: String { String(teamId) }
    let teamId: Int
    let name: String
    let abbrev: String?
    let primaryOwner: String?
    let owners: [String]
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let playoffSeed: Int?
}

struct ESPNLeagueProbe: Hashable {
    let leagueId: String
    let season: Int
    let name: String
    let scoringPeriodId: Int
    let currentMatchupPeriod: Int
    let finalScoringPeriod: Int
    let teams: [ESPNTeamSummary]
}

/// Read-only ESPN Fantasy Football API (unofficial lm-api-reads).
actor ESPNClient {
    static let shared = ESPNClient()
    static let host = "lm-api-reads.fantasy.espn.com"
    private static let readsBase = "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    func probeLeague(
        leagueId: String,
        season: Int,
        cookies: ESPNCookies? = nil
    ) async throws -> ESPNLeagueProbe {
        let data = try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mTeam", "mSettings", "mStatus"],
            cookies: cookies,
            policy: .standard
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ESPNError.decode
        }
        let settings = root["settings"] as? [String: Any]
        let status = root["status"] as? [String: Any]
        let name = (settings?["name"] as? String)
            ?? (root["settings"] as? [String: Any])?["name"] as? String
            ?? "ESPN League"
        let scoringPeriodId = Self.intValue(root["scoringPeriodId"])
            ?? Self.intValue(status?["latestScoringPeriod"])
            ?? 1
        let matchupPeriod = Self.intValue(status?["currentMatchupPeriod"]) ?? scoringPeriodId
        let finalPeriod = Self.intValue(status?["finalScoringPeriod"]) ?? 18
        let teams = parseTeams(root["teams"])
        return ESPNLeagueProbe(
            leagueId: leagueId,
            season: season,
            name: name,
            scoringPeriodId: max(1, scoringPeriodId),
            currentMatchupPeriod: max(1, matchupPeriod),
            finalScoringPeriod: max(1, finalPeriod),
            teams: teams
        )
    }

    func bootstrap(
        leagueId: String,
        season: Int,
        cookies: ESPNCookies? = nil,
        hasLiveGames: Bool = false
    ) async throws -> Data {
        try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mTeam", "mRoster", "mMatchup", "mSettings", "mStandings"],
            cookies: cookies,
            policy: .liveAware(hasLiveGames: hasLiveGames)
        )
    }

    func roster(
        leagueId: String,
        season: Int,
        week: Int? = nil,
        cookies: ESPNCookies? = nil,
        hasLiveGames: Bool = false
    ) async throws -> Data {
        var extra: [String: String] = [:]
        if let week { extra["scoringPeriodId"] = String(week) }
        return try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mTeam", "mRoster"],
            extraQuery: extra,
            cookies: cookies,
            policy: .liveAware(hasLiveGames: hasLiveGames)
        )
    }

    func matchupScore(
        leagueId: String,
        season: Int,
        week: Int,
        cookies: ESPNCookies? = nil,
        hasLiveGames: Bool = false
    ) async throws -> Data {
        let filter: [String: Any] = [
            "schedule": [
                "filterMatchupPeriodIds": ["value": [week]]
            ]
        ]
        return try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mMatchupScore", "mScoreboard", "mTeam"],
            extraQuery: ["scoringPeriodId": String(week)],
            fantasyFilter: filter,
            cookies: cookies,
            policy: .liveAware(hasLiveGames: hasLiveGames)
        )
    }

    func standings(
        leagueId: String,
        season: Int,
        cookies: ESPNCookies? = nil
    ) async throws -> Data {
        try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mStandings", "mTeam"],
            cookies: cookies,
            policy: .standard
        )
    }

    func transactions(
        leagueId: String,
        season: Int,
        week: Int,
        cookies: ESPNCookies? = nil
    ) async throws -> Data {
        let filter: [String: Any] = [
            "transactions": [
                "filterType": [
                    "value": [
                        "FREEAGENT", "WAIVER", "WAIVER_ERROR",
                        "TRADE_ACCEPT", "TRADE_PENDING", "ROSTER"
                    ]
                ]
            ]
        ]
        return try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["mTransactions2"],
            extraQuery: ["scoringPeriodId": String(week)],
            fantasyFilter: filter,
            cookies: cookies,
            policy: .standard
        )
    }

    func freeAgents(
        leagueId: String,
        season: Int,
        week: Int,
        limit: Int = 40,
        slotIds: [Int] = [0, 2, 4, 6, 16, 17, 23],
        cookies: ESPNCookies? = nil
    ) async throws -> Data {
        let filter: [String: Any] = [
            "players": [
                "filterStatus": ["value": ["FREEAGENT", "WAIVERS"]],
                "filterSlotIds": ["value": slotIds],
                "limit": limit,
                "sortPercOwned": ["sortPriority": 1, "sortAsc": false],
                "sortDraftRanks": [
                    "sortPriority": 100,
                    "sortAsc": true,
                    "value": "STANDARD"
                ]
            ]
        ]
        return try await leagueJSON(
            leagueId: leagueId,
            season: season,
            views: ["kona_player_info"],
            extraQuery: ["scoringPeriodId": String(week)],
            fantasyFilter: filter,
            cookies: cookies,
            policy: .standard
        )
    }

    /// Match SWID to a team; returns nil when cookies missing or no owner match.
    func resolveMyTeam(teams: [ESPNTeamSummary], swid: String?) -> ESPNTeamSummary? {
        guard let raw = swid?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let normalized = Self.normalizeSWID(raw)
        return teams.first { team in
            if let primary = team.primaryOwner, Self.normalizeSWID(primary) == normalized {
                return true
            }
            return team.owners.contains { Self.normalizeSWID($0) == normalized }
        }
    }

    // MARK: - Slot / position helpers

    /// Bench = 20, IR = 21; everything else with a roster count is a starter slot.
    static func rosterStatus(lineupSlotId: Int) -> String {
        switch lineupSlotId {
        case 20: return "bench"
        case 21: return "ir"
        default: return "starter"
        }
    }

    static func positionName(defaultPositionId: Int?) -> String {
        switch defaultPositionId {
        case 1: return "TQB"
        case 2: return "RB"
        case 3: return "RB/WR"
        case 4: return "WR"
        case 5: return "WR/TE"
        case 6: return "TE"
        case 7: return "OP"
        case 8: return "DT"
        case 9: return "DE"
        case 10: return "LB"
        case 11: return "DL"
        case 12: return "CB"
        case 13: return "S"
        case 14: return "DB"
        case 15: return "DP"
        case 16: return "D/ST"
        case 17: return "K"
        case 18: return "P"
        case 19: return "HC"
        case 0: return "QB"
        default: return "?"
        }
    }

    static func slotName(lineupSlotId: Int) -> String {
        switch lineupSlotId {
        case 0: return "QB"
        case 1: return "TQB"
        case 2: return "RB"
        case 3: return "RB/WR"
        case 4: return "WR"
        case 5: return "WR/TE"
        case 6: return "TE"
        case 7: return "OP"
        case 8: return "DT"
        case 9: return "DE"
        case 10: return "LB"
        case 11: return "DL"
        case 12: return "CB"
        case 13: return "S"
        case 14: return "DB"
        case 15: return "DP"
        case 16: return "D/ST"
        case 17: return "K"
        case 20: return "BE"
        case 21: return "IR"
        // ESPN FLEX is RB/WR/TE — keep eligibility explicit (not a bare "FLEX" label).
        case 23: return "RB/WR/TE"
        case 24: return "ER"
        default: return "SLOT\(lineupSlotId)"
        }
    }

    /// ESPN numeric proTeamId → NFL abbrev used by NFLScheduleService.
    static func nflTeamAbbrev(proTeamId: Int?) -> String {
        guard let proTeamId, proTeamId > 0 else { return "" }
        let map: [Int: String] = [
            1: "ATL", 2: "BUF", 3: "CHI", 4: "CIN", 5: "CLE",
            6: "DAL", 7: "DEN", 8: "DET", 9: "GB", 10: "TEN",
            11: "IND", 12: "KC", 13: "LV", 14: "LAR", 15: "MIA",
            16: "MIN", 17: "NE", 18: "NO", 19: "NYG", 20: "NYJ",
            21: "PHI", 22: "ARI", 23: "PIT", 24: "LAC", 25: "SF",
            26: "SEA", 27: "TB", 28: "WSH", 29: "CAR", 30: "JAX",
            33: "BAL", 34: "HOU"
        ]
        return map[proTeamId] ?? ""
    }

    static func teamDisplayName(from team: [String: Any]) -> String {
        if let name = team["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        let location = (team["location"] as? String) ?? ""
        let nickname = (team["nickname"] as? String) ?? ""
        let joined = "\(location) \(nickname)".trimmingCharacters(in: .whitespaces)
        if !joined.isEmpty { return joined }
        if let abbrev = team["abbrev"] as? String, !abbrev.isEmpty { return abbrev }
        let id = intValue(team["id"]).map(String.init) ?? "?"
        return "Team \(id)"
    }

    static func normalizeSWID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .uppercased()
    }

    // MARK: - HTTP

    private func leagueJSON(
        leagueId: String,
        season: Int,
        views: [String],
        extraQuery: [String: String] = [:],
        fantasyFilter: [String: Any]? = nil,
        cookies: ESPNCookies?,
        policy: DataCache.Policy
    ) async throws -> Data {
        let trimmed = leagueId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ESPNError.missingLeagueId }

        var components = URLComponents(
            string: "\(Self.readsBase)/seasons/\(season)/segments/0/leagues/\(trimmed)"
        )!
        var items: [URLQueryItem] = views.map { URLQueryItem(name: "view", value: $0) }
        for (k, v) in extraQuery.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: k, value: v))
        }
        components.queryItems = items
        guard let url = components.url else { throw ESPNError.decode }

        let cookie = cookies ?? ESPNCookies.fromKeychain()
        let filterKey = fantasyFilter.flatMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap {
                String(data: $0, encoding: .utf8)
            }
        } ?? ""
        let cacheKey = "espn:\(url.absoluteString)|c:\(cookie?.swid ?? "")|f:\(filterKey.hashValue)"

        return try await DataCache.shared.data(key: cacheKey, policy: policy) {
            try await self.fetch(url: url, cookies: cookie, fantasyFilter: fantasyFilter)
        }
    }

    private func fetch(
        url: URL,
        cookies: ESPNCookies?,
        fantasyFilter: [String: Any]?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Sideline/1.0 (com.cpf32.sideline; iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookies, !cookies.isEmpty {
            request.setValue(cookies.headerValue, forHTTPHeaderField: "Cookie")
        }
        if let fantasyFilter,
           let filterData = try? JSONSerialization.data(withJSONObject: fantasyFilter),
           let filterString = String(data: filterData, encoding: .utf8) {
            request.setValue(filterString, forHTTPHeaderField: "X-Fantasy-Filter")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ESPNError.decode }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ESPNError.unauthorized
        }
        if http.statusCode == 404 {
            throw ESPNError.notFound
        }
        guard (200...299).contains(http.statusCode) else {
            throw ESPNError.http(http.statusCode)
        }
        if data.isEmpty || data == Data("null".utf8) {
            throw ESPNError.empty
        }
        return data
    }

    // MARK: - Parsing

    private func parseTeams(_ any: Any?) -> [ESPNTeamSummary] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            guard let teamId = Self.intValue(row["id"]) else { return nil }
            let record = (row["record"] as? [String: Any])?["overall"] as? [String: Any]
            let ownersRaw = row["owners"] as? [Any] ?? []
            let owners = ownersRaw.compactMap { value -> String? in
                if let s = value as? String { return s }
                if let i = value as? Int { return String(i) }
                return nil
            }
            return ESPNTeamSummary(
                teamId: teamId,
                name: Self.teamDisplayName(from: row),
                abbrev: row["abbrev"] as? String,
                primaryOwner: row["primaryOwner"] as? String,
                owners: owners,
                wins: Self.intValue(record?["wins"]) ?? 0,
                losses: Self.intValue(record?["losses"]) ?? 0,
                ties: Self.intValue(record?["ties"]) ?? 0,
                pointsFor: Self.doubleValue(record?["pointsFor"]) ?? 0,
                pointsAgainst: Self.doubleValue(record?["pointsAgainst"]) ?? 0,
                playoffSeed: Self.intValue(row["playoffSeed"])
            )
        }
    }

    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
