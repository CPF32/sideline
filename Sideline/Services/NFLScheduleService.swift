import Foundation

/// Per-NFL-team kickoff info for the selected fantasy week.
struct NFLGameInfo: Hashable {
    var opponent: String
    var kickoff: Date
    /// upcoming | started | final
    var lockState: String
    var gameSecondsRemaining: Int
}

enum NFLScheduleService {
    static func fetchData(season: Int, week: Int) async throws -> Data {
        let url = URL(string: "https://api.myfantasyleague.com/\(season)/export?TYPE=nflSchedule&W=\(week)&JSON=1")!
        var request = URLRequest(url: url)
        request.setValue(MFLClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Fetches MFL `TYPE=nflSchedule` for a week and maps each NFL team → game info.
    static func teamGames(season: Int, week: Int, now: Date = .now) async -> [String: NFLGameInfo] {
        guard let data = try? await fetchData(season: season, week: week) else { return [:] }
        return parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = .now) -> [String: NFLGameInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let schedule = (root["nflSchedule"] as? [String: Any]) ?? root
        let matchups = arrayOfDicts(schedule["matchup"])
        var map: [String: NFLGameInfo] = [:]

        for matchup in matchups {
            let kickoff = dateFromKickoff(matchup["kickoff"]) ?? now
            let seconds = intValue(matchup["gameSecondsRemaining"]) ?? 3600
            let lockState: String
            if seconds == 0 {
                lockState = "final"
            } else if kickoff <= now || seconds < 3600 {
                lockState = "started"
            } else {
                lockState = "upcoming"
            }

            let teams = arrayOfDicts(matchup["team"])
            guard teams.count >= 2 else { continue }
            let ids = teams.compactMap { ($0["id"] as? String)?.uppercased() }
            guard ids.count >= 2 else { continue }

            for (idx, team) in teams.enumerated() {
                guard let id = (team["id"] as? String)?.uppercased() else { continue }
                let isHome = (team["isHome"] as? String) == "1" || (team["isHome"] as? Int) == 1
                let opp = ids.first { $0 != id } ?? (idx == 0 ? ids[1] : ids[0])
                let oppLabel = isHome ? "vs \(opp)" : "@ \(opp)"
                map[normalizeTeam(id)] = NFLGameInfo(
                    opponent: oppLabel,
                    kickoff: kickoff,
                    lockState: lockState,
                    gameSecondsRemaining: seconds
                )
                // Also store raw id if different after normalize
                map[id] = map[normalizeTeam(id)]!
            }
        }
        return map
    }

    static func annotate(
        _ players: [RosterPlayer],
        games: [String: NFLGameInfo]
    ) -> [RosterPlayer] {
        // Empty map means schedule fetch/parse failed — never invent BYEs for everyone.
        let scheduleLoaded = !games.isEmpty
        return players.map { player in
            var p = player
            if player.team.isEmpty {
                p.gameLockState = "unknown"
                return p
            }
            let key = normalizeTeam(player.team)
            if let info = games[key] ?? games[player.team.uppercased()] {
                p.opponent = info.opponent
                p.gameKickoff = info.kickoff
                p.gameLockState = info.lockState
            } else if scheduleLoaded {
                // Team absent from a loaded slate → genuine bye week.
                p.opponent = "BYE"
                p.gameLockState = "bye"
                p.gameKickoff = nil
            } else {
                p.opponent = nil
                p.gameLockState = "unknown"
                p.gameKickoff = nil
            }
            return p
        }
    }

    /// MFL uses codes like GBP, KCC, NEP, TBB, JAC — normalize common aliases from player feeds.
    static func normalizeTeam(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch t {
        case "GB": return "GBP"
        case "KC": return "KCC"
        case "NE": return "NEP"
        case "TB": return "TBB"
        case "SF": return "SFO"
        case "NO": return "NOS"
        case "LV", "OAK": return "LVR"
        case "LA", "STL": return "LAR"
        case "WSH", "WAS": return "WAS"
        case "JAX": return "JAC"
        default: return t
        }
    }

    private static func dateFromKickoff(_ any: Any?) -> Date? {
        if let s = any as? String, let t = TimeInterval(s) { return Date(timeIntervalSince1970: t) }
        if let i = any as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = any as? Double { return Date(timeIntervalSince1970: d) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }
}
