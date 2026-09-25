import Foundation

enum ESPNTeamSyncService {
    static func loadTeam(linked: LinkedFranchise, week: Int? = nil) async throws -> TeamSnapshot {
        let client = ESPNClient.shared
        let cookies = ESPNCookies.fromKeychain()
        let probe = try await client.probeLeague(
            leagueId: linked.leagueId,
            season: linked.season,
            cookies: cookies
        )
        let currentWeek = week ?? probe.scoringPeriodId
        let teamId = Int(linked.franchiseId) ?? 0

        async let teamGamesTask = NFLScheduleService.teamGames(season: linked.season, week: currentWeek)
        let teamGames = await teamGamesTask
        let hasLiveGames = teamGames.values.contains { $0.lockState == "started" }

        async let rosterDataTask = client.roster(
            leagueId: linked.leagueId,
            season: linked.season,
            week: currentWeek,
            cookies: cookies,
            hasLiveGames: hasLiveGames
        )
        async let matchupDataTask = try? await client.matchupScore(
            leagueId: linked.leagueId,
            season: linked.season,
            week: currentWeek,
            cookies: cookies,
            hasLiveGames: hasLiveGames
        )
        async let bootstrapTask = try? await client.bootstrap(
            leagueId: linked.leagueId,
            season: linked.season,
            cookies: cookies,
            hasLiveGames: hasLiveGames
        )

        let rosterRaw = try await rosterDataTask
        let matchupRaw = await matchupDataTask
        let bootstrapRaw = await bootstrapTask

        guard let rosterRoot = try JSONSerialization.jsonObject(with: rosterRaw) as? [String: Any] else {
            throw ESPNError.decode
        }
        let teams = parseTeamDicts(rosterRoot["teams"])
        guard let myTeam = teams.first(where: { ESPNClient.intValue($0["id"]) == teamId }) else {
            throw ESPNError.decode
        }

        let settingsRoot: [String: Any]? = {
            if let bootstrapRaw,
               let root = try? JSONSerialization.jsonObject(with: bootstrapRaw) as? [String: Any] {
                return root
            }
            return rosterRoot
        }()
        let rules = parseLeagueRules(from: settingsRoot, endWeekFallback: probe.finalScoringPeriod)
        let scoringRules = ScoringRules.parseESPN(from: settingsRoot)

        let entries = rosterEntries(from: myTeam)
        let pointsByPlayer = matchupPlayerPoints(
            matchupRaw: matchupRaw,
            teamId: teamId,
            week: currentWeek
        )
        let projByPlayer = matchupProjectedPoints(
            matchupRaw: matchupRaw,
            teamId: teamId,
            week: currentWeek
        )

        var starters: [RosterPlayer] = []
        var bench: [RosterPlayer] = []
        var ir: [RosterPlayer] = []

        for entry in entries {
            let status = ESPNClient.rosterStatus(lineupSlotId: entry.lineupSlotId)
            let player = RosterPlayer(
                playerId: entry.playerId,
                name: entry.name,
                position: entry.position,
                team: entry.nflTeam,
                status: status,
                projectedPoints: projByPlayer[entry.playerId] ?? entry.projectedPoints,
                actualPoints: pointsByPlayer[entry.playerId] ?? entry.actualPoints,
                seasonPoints: nil,
                lastWeekPoints: nil,
                opponent: nil,
                injuryStatus: entry.injuryStatus,
                gameLockState: nil
            )
            switch status {
            case "starter": starters.append(player)
            case "ir": ir.append(player)
            default: bench.append(player)
            }
        }

        // Preserve ESPN starter order (lineup slot ascending, then entry index).
        starters.sort { a, b in
            let sa = entries.first { $0.playerId == a.playerId }?.lineupSlotId ?? 99
            let sb = entries.first { $0.playerId == b.playerId }?.lineupSlotId ?? 99
            if sa != sb { return sa < sb }
            return a.name < b.name
        }

        starters = NFLScheduleService.annotate(starters, games: teamGames)
        bench = NFLScheduleService.annotate(bench, games: teamGames)
        ir = NFLScheduleService.annotate(ir, games: teamGames)

        starters = clearActualIfNotLive(starters)
        bench = clearActualIfNotLive(bench)
        ir = clearActualIfNotLive(ir)

        let franchiseDisplay = ESPNClient.teamDisplayName(from: myTeam)
        let seasonPF = ESPNClient.doubleValue(
            ((myTeam["record"] as? [String: Any])?["overall"] as? [String: Any])?["pointsFor"]
        )

        let matchup = buildMatchup(
            matchupRaw: matchupRaw,
            teamId: teamId,
            week: currentWeek,
            teams: teams,
            teamGames: teamGames
        )

        return TeamSnapshot(
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            leagueName: linked.leagueName.isEmpty ? probe.name : linked.leagueName,
            franchiseName: franchiseDisplay,
            week: currentWeek,
            seasonPointsFor: seasonPF,
            starters: starters,
            bench: bench,
            ir: ir,
            taxi: [],
            matchup: matchup,
            leagueRules: rules,
            scoringRules: scoringRules,
            syncedAt: .now
        )
    }

    static func upcomingMatchups(
        linked: LinkedFranchise,
        afterWeek: Int,
        throughWeek: Int
    ) async throws -> [UpcomingMatchupPreview] {
        let cookies = ESPNCookies.fromKeychain()
        let data = try await ESPNClient.shared.bootstrap(
            leagueId: linked.leagueId,
            season: linked.season,
            cookies: cookies
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let teams = parseTeamDicts(root["teams"])
        let teamNames = Dictionary(
            uniqueKeysWithValues: teams.compactMap { row -> (Int, String)? in
                guard let id = ESPNClient.intValue(row["id"]) else { return nil }
                return (id, ESPNClient.teamDisplayName(from: row))
            }
        )
        let teamId = Int(linked.franchiseId) ?? 0
        let schedule = root["schedule"] as? [[String: Any]] ?? []
        let end = min(throughWeek, afterWeek + 4)
        var out: [UpcomingMatchupPreview] = []
        for week in (afterWeek + 1)...max(afterWeek + 1, end) {
            guard let row = schedule.first(where: {
                ESPNClient.intValue($0["matchupPeriodId"]) == week
                    && sideContains(teamId: teamId, matchup: $0)
            }) else { continue }
            let homeId = sideTeamId(row["home"])
            let awayId = sideTeamId(row["away"])
            let oppId = homeId == teamId ? awayId : homeId
            let oppName = oppId.flatMap { teamNames[$0] } ?? "Opponent"
            out.append(
                UpcomingMatchupPreview(
                    week: week,
                    opponentName: oppName,
                    isHome: homeId == teamId
                )
            )
        }
        return out
    }

    static func loadLeagueReview(linked: LinkedFranchise, week: Int) async throws -> LeagueReviewSnapshot {
        let cookies = ESPNCookies.fromKeychain()
        let client = ESPNClient.shared

        async let standingsData = try? await client.standings(
            leagueId: linked.leagueId,
            season: linked.season,
            cookies: cookies
        )
        async let matchupData = try? await client.matchupScore(
            leagueId: linked.leagueId,
            season: linked.season,
            week: week,
            cookies: cookies
        )
        async let txData = try? await client.transactions(
            leagueId: linked.leagueId,
            season: linked.season,
            week: week,
            cookies: cookies
        )

        let (standingsRaw, matchupRaw, transactionsRaw) = await (standingsData, matchupData, txData)

        let standingsRoot: [String: Any] = {
            if let standingsRaw,
               let root = try? JSONSerialization.jsonObject(with: standingsRaw) as? [String: Any] {
                return root
            }
            return [:]
        }()
        let teams = parseTeamDicts(standingsRoot["teams"])
        var standings: [LeagueStandingRow] = teams.compactMap { row in
            guard let id = ESPNClient.intValue(row["id"]) else { return nil }
            let record = (row["record"] as? [String: Any])?["overall"] as? [String: Any]
            return LeagueStandingRow(
                franchiseId: String(id),
                name: ESPNClient.teamDisplayName(from: row),
                wins: ESPNClient.intValue(record?["wins"]) ?? 0,
                losses: ESPNClient.intValue(record?["losses"]) ?? 0,
                ties: ESPNClient.intValue(record?["ties"]) ?? 0,
                pointsFor: ESPNClient.doubleValue(record?["pointsFor"]) ?? 0,
                pointsAgainst: ESPNClient.doubleValue(record?["pointsAgainst"]) ?? 0,
                rank: ESPNClient.intValue(row["playoffSeed"])
                    ?? ESPNClient.intValue(row["rankCalculatedFinal"])
            )
        }
        standings.sort {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            return $0.pointsFor > $1.pointsFor
        }
        standings = standings.enumerated().map { idx, row in
            LeagueStandingRow(
                franchiseId: row.franchiseId,
                name: row.name,
                wins: row.wins,
                losses: row.losses,
                ties: row.ties,
                pointsFor: row.pointsFor,
                pointsAgainst: row.pointsAgainst,
                rank: row.rank ?? (idx + 1),
                rankDelta: nil
            )
        }

        let nameById = Dictionary(uniqueKeysWithValues: standings.map { ($0.franchiseId, $0.name) })
        var matchups: [LeagueMatchupRow] = []
        if let matchupRaw,
           let root = try? JSONSerialization.jsonObject(with: matchupRaw) as? [String: Any] {
            let schedule = root["schedule"] as? [[String: Any]] ?? []
            for (idx, row) in schedule.enumerated() where ESPNClient.intValue(row["matchupPeriodId"]) == week {
                let homeId = sideTeamId(row["home"]).map(String.init) ?? ""
                let awayId = sideTeamId(row["away"]).map(String.init) ?? ""
                guard !homeId.isEmpty || !awayId.isEmpty else { continue }
                matchups.append(
                    LeagueMatchupRow(
                        id: "\(week)-\(idx)",
                        homeName: nameById[homeId] ?? "Team \(homeId)",
                        awayName: nameById[awayId] ?? "Team \(awayId)",
                        homeScore: sideScore(row["home"]),
                        awayScore: sideScore(row["away"])
                    )
                )
            }
        }

        let transactions = parseTransactions(transactionsRaw, nameById: nameById)

        return LeagueReviewSnapshot(
            week: week,
            standings: standings,
            transactions: transactions,
            matchups: matchups,
            syncedAt: .now
        )
    }

    static func freeAgents(
        linked: LinkedFranchise,
        week: Int,
        limit: Int = 25,
        position: String? = nil
    ) async throws -> [RosterPlayer] {
        let cookies = ESPNCookies.fromKeychain()
        let data = try await ESPNClient.shared.freeAgents(
            leagueId: linked.leagueId,
            season: linked.season,
            week: week,
            limit: max(limit, 15),
            cookies: cookies
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let players = root["players"] as? [[String: Any]] ?? []
        var out: [RosterPlayer] = []
        for row in players {
            let pool = (row["playerPoolEntry"] as? [String: Any]) ?? row
            let player = (pool["player"] as? [String: Any]) ?? [:]
            let pid = ESPNClient.intValue(row["id"])
                ?? ESPNClient.intValue(pool["id"])
                ?? ESPNClient.intValue(player["id"])
            guard let pid else { continue }
            let pos = ESPNClient.positionName(
                defaultPositionId: ESPNClient.intValue(player["defaultPositionId"])
            )
            if let position, !position.isEmpty,
               pos.uppercased() != position.uppercased() {
                continue
            }
            let name = (player["fullName"] as? String)
                ?? [player["firstName"] as? String, player["lastName"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
            let team = ESPNClient.nflTeamAbbrev(
                proTeamId: ESPNClient.intValue(player["proTeamId"])
            )
            let injured = (player["injured"] as? Bool) == true
            out.append(
                RosterPlayer(
                    playerId: String(pid),
                    name: name.isEmpty ? "Player \(pid)" : name,
                    position: pos,
                    team: team,
                    status: "fa",
                    injuryStatus: injured ? "Injured" : (player["injuryStatus"] as? String)
                )
            )
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: - Parsing helpers

    private struct ESPNRosterEntry {
        let playerId: String
        let name: String
        let position: String
        let nflTeam: String
        let lineupSlotId: Int
        let injuryStatus: String?
        let actualPoints: Double?
        let projectedPoints: Double?
    }

    private static func parseTeamDicts(_ any: Any?) -> [[String: Any]] {
        (any as? [[String: Any]]) ?? []
    }

    private static func rosterEntries(from team: [String: Any]) -> [ESPNRosterEntry] {
        let roster = team["roster"] as? [String: Any]
        let entries = roster?["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            let lineupSlotId = ESPNClient.intValue(entry["lineupSlotId"]) ?? 20
            let pool = entry["playerPoolEntry"] as? [String: Any]
            let player = pool?["player"] as? [String: Any] ?? [:]
            let pid = ESPNClient.intValue(entry["playerId"])
                ?? ESPNClient.intValue(pool?["id"])
                ?? ESPNClient.intValue(player["id"])
            guard let pid else { return nil }
            let name = (player["fullName"] as? String)
                ?? [player["firstName"] as? String, player["lastName"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
            let pos = ESPNClient.positionName(
                defaultPositionId: ESPNClient.intValue(player["defaultPositionId"])
            )
            let teamAbbrev = ESPNClient.nflTeamAbbrev(
                proTeamId: ESPNClient.intValue(player["proTeamId"])
            )
            let injured = (player["injured"] as? Bool) == true
            let applied = ESPNClient.doubleValue(pool?["appliedStatTotal"])
            return ESPNRosterEntry(
                playerId: String(pid),
                name: name.isEmpty ? "Player \(pid)" : name,
                position: pos,
                nflTeam: teamAbbrev,
                lineupSlotId: lineupSlotId,
                injuryStatus: injured ? "Injured" : (player["injuryStatus"] as? String),
                actualPoints: applied,
                projectedPoints: nil
            )
        }
    }

    private static func parseLeagueRules(from root: [String: Any]?, endWeekFallback: Int) -> LeagueRules {
        guard let root else {
            return LeagueRules(starterSlots: [], endWeek: endWeekFallback)
        }
        let settings = root["settings"] as? [String: Any]
        let rosterSettings = settings?["rosterSettings"] as? [String: Any]
        let counts = rosterSettings?["lineupSlotCounts"] as? [String: Any] ?? [:]
        var slots: [LeagueRules.StarterSlot] = []
        var totalStarters = 0
        var irSlots: Int?
        for (key, value) in counts {
            guard let slotId = Int(key), let count = ESPNClient.intValue(value), count > 0 else { continue }
            if slotId == 20 { continue } // bench
            if slotId == 21 {
                irSlots = count
                continue
            }
            let name = ESPNClient.slotName(lineupSlotId: slotId)
            slots.append(.init(name: name, min: count, max: count))
            totalStarters += count
        }
        slots.sort { $0.name < $1.name }
        let status = root["status"] as? [String: Any]
        let endWeek = ESPNClient.intValue(status?["finalScoringPeriod"]) ?? endWeekFallback
        let startWeek = ESPNClient.intValue(status?["firstScoringPeriod"])
        return LeagueRules(
            rosterSize: ESPNClient.intValue(rosterSettings?["rosterSize"]),
            injuredReserveSlots: irSlots,
            taxiSquadSlots: nil,
            totalStarters: totalStarters > 0 ? totalStarters : nil,
            starterSlots: slots,
            usesSalaries: false,
            salaryCapAmount: nil,
            startWeek: startWeek,
            endWeek: endWeek,
            rawNotes: "ESPN lineupSlotCounts"
        )
    }

    private static func sideTeamId(_ any: Any?) -> Int? {
        guard let side = any as? [String: Any] else { return nil }
        return ESPNClient.intValue(side["teamId"])
    }

    private static func sideScore(_ any: Any?) -> Double? {
        guard let side = any as? [String: Any] else { return nil }
        if let live = ESPNClient.doubleValue(side["totalPointsLive"]) { return live }
        if let total = ESPNClient.doubleValue(side["totalPoints"]) { return total }
        if let roster = side["rosterForCurrentScoringPeriod"] as? [String: Any],
           let applied = ESPNClient.doubleValue(roster["appliedStatTotal"]) {
            return applied
        }
        return nil
    }

    private static func sideContains(teamId: Int, matchup: [String: Any]) -> Bool {
        sideTeamId(matchup["home"]) == teamId || sideTeamId(matchup["away"]) == teamId
    }

    private static func sideForTeam(matchupRaw: Data?, teamId: Int, week: Int) -> [String: Any]? {
        guard let matchupRaw,
              let root = try? JSONSerialization.jsonObject(with: matchupRaw) as? [String: Any]
        else { return nil }
        let schedule = root["schedule"] as? [[String: Any]] ?? []
        guard let row = schedule.first(where: {
            ESPNClient.intValue($0["matchupPeriodId"]) == week && sideContains(teamId: teamId, matchup: $0)
        }) else { return nil }
        if sideTeamId(row["home"]) == teamId { return row["home"] as? [String: Any] }
        if sideTeamId(row["away"]) == teamId { return row["away"] as? [String: Any] }
        return nil
    }

    private static func matchupPlayerPoints(
        matchupRaw: Data?,
        teamId: Int,
        week: Int
    ) -> [String: Double] {
        pointsFromSide(sideForTeam(matchupRaw: matchupRaw, teamId: teamId, week: week), projected: false)
    }

    private static func matchupProjectedPoints(
        matchupRaw: Data?,
        teamId: Int,
        week: Int
    ) -> [String: Double] {
        pointsFromSide(sideForTeam(matchupRaw: matchupRaw, teamId: teamId, week: week), projected: true)
    }

    private static func pointsFromSide(_ side: [String: Any]?, projected: Bool) -> [String: Double] {
        guard let side else { return [:] }
        let roster = (side["rosterForCurrentScoringPeriod"] as? [String: Any])
            ?? (side["roster"] as? [String: Any])
        let entries = roster?["entries"] as? [[String: Any]] ?? []
        var map: [String: Double] = [:]
        for entry in entries {
            let pid = ESPNClient.intValue(entry["playerId"]).map(String.init)
            guard let pid else { continue }
            let pool = entry["playerPoolEntry"] as? [String: Any]
            if projected {
                // Prefer live projected total when present on the side; else per-player applied projected.
                if let pts = ESPNClient.doubleValue(pool?["appliedProjectedStatTotal"])
                    ?? projectedFromPlayerStats(pool) {
                    map[pid] = pts
                }
            } else if let pts = ESPNClient.doubleValue(pool?["appliedStatTotal"]) {
                map[pid] = pts
            }
        }
        return map
    }

    private static func projectedFromPlayerStats(_ pool: [String: Any]?) -> Double? {
        guard let player = pool?["player"] as? [String: Any],
              let stats = player["stats"] as? [[String: Any]]
        else { return nil }
        // statSourceId 1 = projected in many ESPN payloads
        for row in stats {
            let source = ESPNClient.intValue(row["statSourceId"])
            if source == 1, let pts = ESPNClient.doubleValue(row["appliedTotal"]) {
                return pts
            }
        }
        return nil
    }

    private static func buildMatchup(
        matchupRaw: Data?,
        teamId: Int,
        week: Int,
        teams: [[String: Any]],
        teamGames: [String: NFLGameInfo]
    ) -> MatchupSnapshot? {
        guard let matchupRaw,
              let root = try? JSONSerialization.jsonObject(with: matchupRaw) as? [String: Any]
        else {
            return MatchupSnapshot(week: week, myScore: nil, oppScore: nil, opponentName: nil)
        }
        let schedule = root["schedule"] as? [[String: Any]] ?? []
        guard let row = schedule.first(where: {
            ESPNClient.intValue($0["matchupPeriodId"]) == week && sideContains(teamId: teamId, matchup: $0)
        }) else {
            return MatchupSnapshot(week: week, myScore: nil, oppScore: nil, opponentName: nil)
        }

        let homeId = sideTeamId(row["home"])
        let awayId = sideTeamId(row["away"])
        let mineIsHome = homeId == teamId
        let mySide = (mineIsHome ? row["home"] : row["away"]) as? [String: Any]
        let oppSide = (mineIsHome ? row["away"] : row["home"]) as? [String: Any]
        let oppId = mineIsHome ? awayId : homeId
        let oppName: String = {
            if let oppId,
               let team = teams.first(where: { ESPNClient.intValue($0["id"]) == oppId }) {
                return ESPNClient.teamDisplayName(from: team)
            }
            return "Opponent"
        }()

        let oppLines = oppLiveFantasyLines(oppSide: oppSide, teamGames: teamGames)

        return MatchupSnapshot(
            week: week,
            myScore: sideScore(mySide),
            oppScore: sideScore(oppSide),
            opponentName: oppName,
            oppLivePlayerLines: oppLines
        )
    }

    private static func oppLiveFantasyLines(
        oppSide: [String: Any]?,
        teamGames: [String: NFLGameInfo]
    ) -> [String] {
        guard let oppSide else { return [] }
        let roster = (oppSide["rosterForCurrentScoringPeriod"] as? [String: Any])
            ?? (oppSide["roster"] as? [String: Any])
        let entries = roster?["entries"] as? [[String: Any]] ?? []
        var scored: [(name: String, pts: Double)] = []
        for entry in entries {
            let slot = ESPNClient.intValue(entry["lineupSlotId"]) ?? 20
            guard ESPNClient.rosterStatus(lineupSlotId: slot) == "starter" else { continue }
            let pool = entry["playerPoolEntry"] as? [String: Any]
            let player = pool?["player"] as? [String: Any] ?? [:]
            let team = ESPNClient.nflTeamAbbrev(proTeamId: ESPNClient.intValue(player["proTeamId"]))
            let key = NFLScheduleService.normalizeTeam(team)
            let lock = teamGames[key]?.lockState ?? teamGames[team]?.lockState
            guard lock == "started" else { continue }
            let name = (player["fullName"] as? String) ?? "Player"
            let pts = ESPNClient.doubleValue(pool?["appliedStatTotal"]) ?? 0
            scored.append((name, pts))
        }
        return scored
            .sorted { $0.pts > $1.pts }
            .prefix(10)
            .map { String(format: "%@  %.1f", $0.name, $0.pts) }
    }

    private static func clearActualIfNotLive(_ players: [RosterPlayer]) -> [RosterPlayer] {
        players.map { player in
            let lock = player.gameLockState ?? "upcoming"
            guard lock == "started" || lock == "final" else {
                var p = player
                p.actualPoints = nil
                return p
            }
            return player
        }
    }

    private static func parseTransactions(
        _ data: Data?,
        nameById: [String: String]
    ) -> [LeagueTransactionRow] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let txs = root["transactions"] as? [[String: Any]] ?? []
        return txs.prefix(40).enumerated().compactMap { idx, row in
            let type = (row["type"] as? String) ?? "tx"
            let status = (row["status"] as? String) ?? ""
            // Keep executed / completed; skip failed when status is present.
            if !status.isEmpty,
               status.uppercased().contains("FAILED")
                || status.uppercased().contains("CANCELED")
                || status.uppercased().contains("CANCELLED") {
                return nil
            }
            let teamId = ESPNClient.intValue(row["teamId"]).map(String.init) ?? ""
            let franchiseName = nameById[teamId] ?? (teamId.isEmpty ? "League" : "Team \(teamId)")
            let items = row["items"] as? [[String: Any]] ?? []
            var bits: [String] = [type]
            for item in items.prefix(4) {
                let itemType = (item["type"] as? String) ?? ""
                let pid = ESPNClient.intValue(item["playerId"]).map(String.init) ?? "?"
                bits.append("\(itemType) \(pid)")
            }
            let ts = ESPNClient.doubleValue(row["proposedDate"])
                ?? ESPNClient.doubleValue(row["processDate"])
                ?? ESPNClient.doubleValue(row["executionDate"])
            let date = ts.map { Date(timeIntervalSince1970: $0 / ($0 > 1_000_000_000_000 ? 1000 : 1)) }
            return LeagueTransactionRow(
                id: ESPNClient.intValue(row["id"]).map(String.init) ?? "espn-tx-\(idx)",
                timestamp: date,
                franchiseId: teamId,
                franchiseName: franchiseName,
                summary: bits.joined(separator: " · "),
                type: type
            )
        }
    }
}
