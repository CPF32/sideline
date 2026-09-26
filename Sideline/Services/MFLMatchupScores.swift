import Foundation

/// Live / weekly matchup scores. Prefer `liveScoring` (in-progress), then `weeklyResults`, then `schedule`.
enum MFLMatchupScores {
    struct Side {
        let id: String
        let score: Double?
        let name: String?
    }

    struct Pair {
        let home: Side
        let away: Side
    }

    static func pairs(
        liveScoring: Data?,
        weeklyResults: Data?,
        schedule: Data?,
        week: Int,
        names: [String: String]
    ) -> [Pair] {
        let scoreMap = franchiseScores(liveScoring: liveScoring, weeklyResults: weeklyResults, schedule: nil)
        // Prefer schedule for who plays whom; scores overlay from live/weekly.
        let rawPairs =
            parsePairs(from: schedule, roots: ["schedule"], week: week)
            ?? parsePairs(from: liveScoring, roots: ["liveScoring"], week: week)
            ?? parsePairs(from: weeklyResults, roots: ["weeklyResults"], week: week)
            ?? []

        return rawPairs.map { pair in
            let homeScore = scoreMap[pair.home.id] ?? pair.home.score
            let awayScore = scoreMap[pair.away.id] ?? pair.away.score
            return Pair(
                home: Side(
                    id: pair.home.id,
                    score: homeScore,
                    name: MFLNameResolver.franchiseName(id: pair.home.id, names: names, fallback: pair.home.name)
                ),
                away: Side(
                    id: pair.away.id,
                    score: awayScore,
                    name: MFLNameResolver.franchiseName(id: pair.away.id, names: names, fallback: pair.away.name)
                )
            )
        }
    }

    static func snapshot(
        for franchiseId: String,
        liveScoring: Data?,
        weeklyResults: Data?,
        schedule: Data?,
        week: Int,
        names: [String: String]
    ) -> MatchupSnapshot {
        let myId = MFLNameResolver.normalizeFranchiseId(franchiseId)
        let all = pairs(
            liveScoring: liveScoring,
            weeklyResults: weeklyResults,
            schedule: schedule,
            week: week,
            names: names
        )
        for pair in all {
            if pair.home.id == myId {
                return MatchupSnapshot(
                    week: week,
                    myScore: pair.home.score,
                    oppScore: pair.away.score,
                    opponentName: pair.away.name,
                    opponentFranchiseId: pair.away.id,
                    lineupDeadline: nil,
                    oppLivePlayerLines: livePlayerLines(from: liveScoring, franchiseId: pair.away.id)
                )
            }
            if pair.away.id == myId {
                return MatchupSnapshot(
                    week: week,
                    myScore: pair.away.score,
                    oppScore: pair.home.score,
                    opponentName: pair.home.name,
                    opponentFranchiseId: pair.home.id,
                    lineupDeadline: nil,
                    oppLivePlayerLines: livePlayerLines(from: liveScoring, franchiseId: pair.home.id)
                )
            }
        }
        // Opponent unknown, but we may still have our live score.
        let scores = franchiseScores(liveScoring: liveScoring, weeklyResults: weeklyResults, schedule: schedule)
        return MatchupSnapshot(week: week, myScore: scores[myId], oppScore: nil, opponentName: nil)
    }

    // MARK: - Score map

    private static func franchiseScores(
        liveScoring: Data?,
        weeklyResults: Data?,
        schedule: Data?
    ) -> [String: Double] {
        var map: [String: Double] = [:]
        // Lowest priority first so live overwrites.
        for data in [schedule, weeklyResults, liveScoring].compactMap({ $0 }) {
            for (id, score) in collectScores(from: data) {
                map[id] = score
            }
        }
        return map
    }

    private static func collectScores(from data: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        collectFranchiseScores(in: root, into: &out)
        return out
    }

    private static func collectFranchiseScores(in value: Any, into out: inout [String: Double]) {
        if let dict = value as? [String: Any] {
            let franchises = arrayOfDicts(dict["franchise"])
            for franchise in franchises {
                let raw = (franchise["id"] as? String) ?? (franchise["id"] as? Int).map(String.init) ?? ""
                guard !raw.isEmpty, let score = scoreValue(franchise) else { continue }
                out[MFLNameResolver.normalizeFranchiseId(raw)] = score
            }
            for (key, child) in dict where key != "player" {
                collectFranchiseScores(in: child, into: &out)
            }
        } else if let arr = value as? [Any] {
            for child in arr {
                collectFranchiseScores(in: child, into: &out)
            }
        }
    }

    // MARK: - Pairings

    private static func parsePairs(from data: Data?, roots: [String], week: Int) -> [Pair]? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var containers: [[String: Any]] = [root]
        for key in roots {
            if let nested = root[key] as? [String: Any] {
                containers.append(nested)
            }
        }

        for container in containers {
            if let pairs = matchups(from: container, week: week), !pairs.isEmpty {
                return pairs
            }
        }
        return nil
    }

    private static func matchups(from container: [String: Any], week: Int) -> [Pair]? {
        // Full-season shape: weeklySchedule = [ { week, matchup }, ... ]
        let weekly = arrayOfDicts(container["weeklySchedule"])
        if !weekly.isEmpty {
            for node in weekly {
                let w = intValue(node["week"]) ?? intValue(node["id"]) ?? 0
                guard w == week else { continue }
                if let pairs = pairsFromMatchupRows(arrayOfDicts(node["matchup"])) {
                    return pairs
                }
            }
        }

        let matchupAny = (container["weeklySchedule"] as? [String: Any])?["matchup"]
            ?? container["matchup"]
            ?? (container["schedule"] as? [String: Any])?["matchup"]
            ?? (container["schedule"] as? [String: Any]).flatMap { ($0["weeklySchedule"] as? [String: Any])?["matchup"] }

        let matchupRows = arrayOfDicts(matchupAny)
        // Flat matchups may carry a week attribute — keep only the selected week when present.
        let filtered: [[String: Any]]
        if matchupRows.contains(where: { intValue($0["week"]) != nil }) {
            filtered = matchupRows.filter { intValue($0["week"]) == week }
        } else {
            filtered = matchupRows
        }
        return pairsFromMatchupRows(filtered)
    }

    private static func pairsFromMatchupRows(_ matchupRows: [[String: Any]]) -> [Pair]? {
        guard !matchupRows.isEmpty else { return nil }
        let pairs = matchupRows.compactMap { row -> Pair? in
            let sides = arrayOfDicts(row["franchise"]).map(parseSide)
            guard sides.count >= 2 else { return nil }
            return Pair(home: sides[0], away: sides[1])
        }
        return pairs.isEmpty ? nil : pairs
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func parseSide(_ row: [String: Any]) -> Side {
        let raw = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init) ?? ""
        let id = MFLNameResolver.normalizeFranchiseId(raw)
        return Side(id: id, score: scoreValue(row), name: row["name"] as? String)
    }

    private static func scoreValue(_ row: [String: Any]) -> Double? {
        // Never use `pf` here — on schedule/standings payloads that is season points-for,
        // not this week's live/final matchup total.
        if let direct = doubleValue(row["score"] ?? row["pts"] ?? row["points"]) {
            return direct
        }
        let players = arrayOfDicts(row["player"])
        guard !players.isEmpty else { return nil }
        var total = 0.0
        var any = false
        for player in players {
            let status = ((player["status"] as? String) ?? "").lowercased()
            let isStarter = (status.contains("starter") && !status.contains("non"))
                || status == "s"
                || status.isEmpty
            guard isStarter else { continue }
            if let s = doubleValue(player["score"]) {
                total += s
                any = true
            }
        }
        return any ? total : nil
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "-" { return nil }
            return Double(trimmed)
        }
        return nil
    }

    /// Live fantasy lines for a franchise from `liveScoring` DETAILS (`Name  12.3`).
    private static func livePlayerLines(from data: Data?, franchiseId: String) -> [String] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let live = (root["liveScoring"] as? [String: Any]) ?? root
        let want = MFLNameResolver.normalizeFranchiseId(franchiseId)

        func playerRows(in franchise: [String: Any]) -> [[String: Any]] {
            let playersNode = franchise["players"] as? [String: Any]
            return arrayOfDicts(playersNode?["player"] ?? franchise["player"])
        }

        func lines(from franchise: [String: Any]) -> [String] {
            playerRows(in: franchise)
                .compactMap { row -> (String, Double)? in
                    let status = String(row["status"] as? String ?? "")
                        .uppercased()
                        .replacingOccurrences(of: " ", with: "")
                    let inProgress =
                        status.contains("LIVE")
                        || status.contains("INPLAY")
                        || status.contains("IN_PROGRESS")
                    guard inProgress else { return nil }
                    let name = (row["name"] as? String)
                        ?? (row["id"] as? String)
                        ?? (row["id"] as? Int).map(String.init)
                        ?? "Player"
                    let score = doubleValue(row["score"]) ?? doubleValue(row["pts"]) ?? 0
                    return (name, score)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
                .map { String(format: "%@  %.1f", $0.0, $0.1) }
        }

        for matchup in arrayOfDicts(live["matchup"]) {
            for franchise in arrayOfDicts(matchup["franchise"]) {
                let id = MFLNameResolver.normalizeFranchiseId((franchise["id"] as? String) ?? "")
                if id == want { return lines(from: franchise) }
            }
        }
        for franchise in arrayOfDicts(live["franchise"]) {
            let id = MFLNameResolver.normalizeFranchiseId((franchise["id"] as? String) ?? "")
            if id == want { return lines(from: franchise) }
        }
        return []
    }
}
