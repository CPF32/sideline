import Foundation

enum LeagueReviewService {
    static func load(linked: LinkedFranchise, week: Int) async throws -> LeagueReviewSnapshot {
        let client = MFLClient.shared
        async let standingsData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "leagueStandings",
            leagueId: linked.leagueId, cacheTTL: 180
        )
        async let transactionsData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "transactions",
            leagueId: linked.leagueId, extra: ["W": String(week), "COUNT": "40"], cacheTTL: 120
        )
        async let scheduleData = try? await TeamSyncService.leagueScheduleData(linked: linked)
        async let weeklyResultsData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "weeklyResults",
            leagueId: linked.leagueId, extra: ["W": String(week)], cacheTTL: 60
        )
        // YTD weekly results — used to compare standings through last week vs this week.
        async let weeklyYTDData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "weeklyResults",
            leagueId: linked.leagueId, extra: ["W": "YTD"], cacheTTL: 300
        )
        async let liveScoringData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "liveScoring",
            leagueId: linked.leagueId, extra: ["W": String(week)], cacheTTL: 30
        )
        async let leagueData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "league",
            leagueId: linked.leagueId, cacheTTL: 600
        )
        async let playersData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "players",
            leagueId: linked.leagueId, extra: ["DETAILS": "1"], cacheTTL: 86_400
        )

        let (standingsRaw, txRaw, scheduleRaw, weeklyRaw, weeklyYTD, liveRaw, leagueRaw, playersRaw) = await (
            standingsData, transactionsData, scheduleData, weeklyResultsData, weeklyYTDData, liveScoringData, leagueData, playersData
        )
        let franchiseNames = leagueRaw.map { MFLNameResolver.parseFranchiseNames(from: $0) } ?? [:]
        var playerNames = playersRaw.map { MFLNameResolver.parsePlayerNames(from: $0) } ?? [:]
        // Fallback: lighter players export if detailed list failed / empty.
        if playerNames.isEmpty {
            if let basic = try? await client.exportJSON(
                host: linked.host, season: linked.season, type: "players",
                leagueId: linked.leagueId, cacheTTL: 86_400
            ) {
                playerNames = MFLNameResolver.parsePlayerNames(from: basic)
            }
        }
        let matchupPairs = MFLMatchupScores.pairs(
            liveScoring: liveRaw,
            weeklyResults: weeklyRaw,
            schedule: scheduleRaw,
            week: week,
            names: franchiseNames
        )

        let weekDeltas = StandingsWeekMovement.deltas(fromYTD: weeklyYTD, currentWeek: week)

        return LeagueReviewSnapshot(
            week: week,
            standings: standingsRaw.map {
                parseStandings($0, names: franchiseNames, weekDeltas: weekDeltas)
            } ?? [],
            transactions: txRaw.map { parseTransactions($0, franchiseNames: franchiseNames, players: playerNames) } ?? [],
            matchups: matchupPairs.enumerated().map { idx, pair in
                LeagueMatchupRow(
                    id: "\(week)-\(idx)-\(pair.home.id)-\(pair.away.id)",
                    homeName: pair.home.name ?? pair.home.id,
                    awayName: pair.away.name ?? pair.away.id,
                    homeScore: pair.home.score,
                    awayScore: pair.away.score
                )
            },
            syncedAt: .now
        )
    }

    private static func parseStandings(
        _ data: Data,
        names: [String: String],
        weekDeltas: [String: Int]
    ) -> [LeagueStandingRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let any = (root["leagueStandings"] as? [String: Any])?["franchise"]
            ?? (root["standings"] as? [String: Any])?["franchise"]
            ?? root["franchise"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] { list = arr }
        else if let one = any as? [String: Any] { list = [one] }
        else { return [] }

        var rows: [LeagueStandingRow] = list.enumerated().compactMap { idx, row in
            let rawId = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init)
            guard let rawId else { return nil }
            let id = MFLNameResolver.normalizeFranchiseId(rawId)
            let rank = intValue(row["rank"]) ?? (idx + 1)
            // Spots moved between end-of-last-week order vs end-of-this-week order (same record ranking).
            let delta = weekDeltas[id]
            return LeagueStandingRow(
                franchiseId: id,
                name: MFLNameResolver.franchiseName(id: id, names: names, fallback: row["name"] as? String),
                wins: intValue(row["h2hw"] ?? row["wins"]) ?? 0,
                losses: intValue(row["h2hl"] ?? row["losses"]) ?? 0,
                ties: intValue(row["h2ht"] ?? row["ties"]) ?? 0,
                pointsFor: doubleValue(row["pf"] ?? row["pointsFor"]) ?? 0,
                pointsAgainst: doubleValue(row["pa"] ?? row["pointsAgainst"]) ?? 0,
                rank: rank,
                rankDelta: delta
            )
        }
        rows.sort { ($0.rank ?? 99) < ($1.rank ?? 99) }
        return rows
    }

    private static func parseTransactions(
        _ data: Data,
        franchiseNames: [String: String],
        players: [String: (name: String, pos: String, team: String)]
    ) -> [LeagueTransactionRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let any = (root["transactions"] as? [String: Any])?["transaction"] ?? root["transaction"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] { list = arr }
        else if let one = any as? [String: Any] { list = [one] }
        else { return [] }

        return list.prefix(40).enumerated().map { idx, row in
            let franchiseRaw = (row["franchise"] as? String) ?? (row["franchise"] as? Int).map(String.init) ?? ""
            let franchiseId = MFLNameResolver.normalizeFranchiseId(franchiseRaw)
            let type = (row["type"] as? String) ?? "TX"
            let summary = humanTransactionSummary(row, players: players)
            let ts = doubleValue(row["timestamp"]).map { Date(timeIntervalSince1970: $0) }
            return LeagueTransactionRow(
                id: "\(franchiseId)-\(idx)-\(summary.prefix(24))",
                timestamp: ts,
                franchiseId: franchiseId,
                franchiseName: MFLNameResolver.franchiseName(id: franchiseId, names: franchiseNames, fallback: franchiseRaw),
                summary: summary,
                type: type
            )
        }
    }

    private static func humanTransactionSummary(
        _ row: [String: Any],
        players: [String: (name: String, pos: String, team: String)]
    ) -> String {
        let type = ((row["type"] as? String) ?? "").uppercased()
        var parts: [String] = []

        // FREE_AGENT / waiver payloads use `transaction` as "addedIds|droppedIds".
        if let tx = row["transaction"] as? String, !tx.isEmpty, looksLikePlayerIdList(tx) {
            let sides = tx.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let added = sides.first ?? ""
            let dropped = sides.count > 1 ? sides[1] : ""
            if !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               added.rangeOfCharacter(from: .decimalDigits) != nil {
                let label = type.contains("WAIVER") ? "Claim" : "Add"
                parts.append("\(label) \(MFLNameResolver.resolvePlayerList(added, players: players))")
            }
            if !dropped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               dropped.rangeOfCharacter(from: .decimalDigits) != nil {
                parts.append("Drop \(MFLNameResolver.resolvePlayerList(dropped, players: players))")
            }
        }

        if let adds = stringValue(row["adds"]), !adds.isEmpty {
            parts.append("Add \(MFLNameResolver.resolvePlayerList(adds, players: players))")
        }
        if let drops = stringValue(row["drops"]), !drops.isEmpty {
            parts.append("Drop \(MFLNameResolver.resolvePlayerList(drops, players: players))")
        }
        if let activated = stringValue(row["activated"]), !activated.isEmpty {
            parts.append("Activate \(MFLNameResolver.resolvePlayerList(activated, players: players))")
        }
        if let deactivated = stringValue(row["deactivated"]), !deactivated.isEmpty {
            parts.append("IR \(MFLNameResolver.resolvePlayerList(deactivated, players: players))")
        }
        if let promoted = stringValue(row["promoted"]), !promoted.isEmpty {
            parts.append("Promote \(MFLNameResolver.resolvePlayerList(promoted, players: players))")
        }
        if let demoted = stringValue(row["demoted"]), !demoted.isEmpty {
            parts.append("Taxi \(MFLNameResolver.resolvePlayerList(demoted, players: players))")
        }
        if let gave1 = stringValue(row["franchise1_gave_up"]), !gave1.isEmpty {
            parts.append("Gave \(MFLNameResolver.resolvePlayerList(gave1, players: players))")
        }
        if let gave2 = stringValue(row["franchise2_gave_up"]), !gave2.isEmpty {
            parts.append("Got \(MFLNameResolver.resolvePlayerList(gave2, players: players))")
        }

        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }

        // Human comments only when they aren't a raw id dump.
        if let notes = stringValue(row["notes"]) ?? stringValue(row["comments"]),
           !notes.isEmpty,
           !looksLikePlayerIdList(notes) {
            return notes
        }

        return type.isEmpty ? "Transaction" : type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        return nil
    }

    /// True for strings like "12345,67890|11111," (MFL player-id lists).
    private static func looksLikePlayerIdList(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isLetter }) { return false }
        return trimmed.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func parseMatchups(_ data: Data, names: [String: String], week: Int) -> [LeagueMatchupRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let any = (root["schedule"] as? [String: Any])?["weeklySchedule"]
            ?? (root["schedule"] as? [String: Any])?["matchup"]
            ?? root["matchup"]
        let matchups: [[String: Any]]
        if let weekObj = any as? [String: Any], let m = weekObj["matchup"] {
            if let arr = m as? [[String: Any]] { matchups = arr }
            else if let one = m as? [String: Any] { matchups = [one] }
            else { matchups = [] }
        } else if let arr = any as? [[String: Any]] {
            matchups = arr
        } else {
            matchups = []
        }

        return matchups.enumerated().compactMap { idx, m in
            let sidesAny = m["franchise"]
            let sides: [[String: Any]]
            if let arr = sidesAny as? [[String: Any]] { sides = arr }
            else if let one = sidesAny as? [String: Any] { sides = [one] }
            else { return nil }
            guard sides.count >= 2 else { return nil }
            let a = sides[0]
            let b = sides[1]
            let aId = (a["id"] as? String) ?? (a["id"] as? Int).map(String.init) ?? "a"
            let bId = (b["id"] as? String) ?? (b["id"] as? Int).map(String.init) ?? "b"
            return LeagueMatchupRow(
                id: "\(week)-\(idx)-\(aId)-\(bId)",
                homeName: MFLNameResolver.franchiseName(id: aId, names: names, fallback: a["name"] as? String),
                awayName: MFLNameResolver.franchiseName(id: bId, names: names, fallback: b["name"] as? String),
                homeScore: doubleValue(a["score"]),
                awayScore: doubleValue(b["score"])
            )
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
