import Foundation

enum SleeperTeamSyncService {
    static func loadTeam(linked: LinkedFranchise, week: Int? = nil) async throws -> TeamSnapshot {
        let client = SleeperClient.shared
        let state = try await client.nflState()
        let currentWeek = week ?? state.week
        await SleeperPlayerCatalog.shared.ensureLoaded()

        async let rostersData = client.rosters(leagueId: linked.leagueId)
        async let usersData = client.users(leagueId: linked.leagueId)
        // Public MFL nflSchedule — no MFL login required; works for Sleeper-only users.
        async let teamGamesTask = NFLScheduleService.teamGames(season: state.season, week: currentWeek)
        async let projectionsData = try? await client.weeklyProjections(season: state.season, week: currentWeek)
        async let scoringKeyTask = client.leagueScoringKey(leagueId: linked.leagueId)

        let rostersRaw = try await rostersData
        let usersRaw = try await usersData
        let teamGames = await teamGamesTask
        let hasLiveGames = teamGames.values.contains { $0.lockState == "started" }
        let matchupsRaw = try? await client.matchups(
            leagueId: linked.leagueId,
            week: currentWeek,
            hasLiveGames: hasLiveGames
        )
        let projectionsRaw = await projectionsData
        let scoringKey = await scoringKeyTask
        let names = parseUserNames(usersRaw)
        let rosterId = Int(linked.franchiseId) ?? 0
        guard let myRoster = parseRosters(rostersRaw).first(where: { $0.rosterId == rosterId }) else {
            throw SleeperError.decode
        }

        let pointsMap = matchupPlayerPoints(matchupsRaw, rosterId: rosterId)
        let projMap = parseProjectionMap(projectionsRaw, scoringKey: scoringKey)
        let starterIds = myRoster.starters
        let reserveIds = Set(myRoster.reserve)
        let taxiIds = Set(myRoster.taxi)
        let allIds = myRoster.players

        var starters: [RosterPlayer] = []
        var bench: [RosterPlayer] = []
        var ir: [RosterPlayer] = []
        var taxi: [RosterPlayer] = []

        for pid in allIds {
            let record = await SleeperPlayerCatalog.shared.player(id: pid)
            let name = record?.fullName ?? "Player \(pid)"
            let position = record?.position ?? "?"
            let team = record?.team ?? ""
            let injury = record?.injuryStatus
            let pts = pointsMap[pid]
            let status: String
            if starterIds.contains(pid) {
                status = "starter"
            } else if reserveIds.contains(pid) {
                status = "ir"
            } else if taxiIds.contains(pid) {
                status = "taxi"
            } else {
                status = "bench"
            }
            let player = RosterPlayer(
                playerId: pid,
                name: name,
                position: position,
                team: team,
                status: status,
                projectedPoints: projMap[pid],
                actualPoints: pts,
                seasonPoints: nil,
                lastWeekPoints: nil,
                opponent: nil,
                injuryStatus: injury,
                gameLockState: nil
            )
            switch status {
            case "starter": starters.append(player)
            case "ir": ir.append(player)
            case "taxi": taxi.append(player)
            default: bench.append(player)
            }
        }

        // Preserve starter order from Sleeper.
        starters = starterIds.compactMap { id in starters.first { $0.playerId == id } }
        starters = NFLScheduleService.annotate(starters, games: teamGames)
        bench = NFLScheduleService.annotate(bench, games: teamGames)
        ir = NFLScheduleService.annotate(ir, games: teamGames)
        taxi = NFLScheduleService.annotate(taxi, games: teamGames)

        // Don't keep matchup zeros as "actual" for players who haven't kicked off.
        starters = clearActualIfNotLive(starters)
        bench = clearActualIfNotLive(bench)
        ir = clearActualIfNotLive(ir)
        taxi = clearActualIfNotLive(taxi)

        let myName = names[linked.sleeperUserId]
            ?? names.values.first { _ in true }
            ?? linked.franchiseName
        let franchiseDisplay = teamDisplayName(
            userId: linked.sleeperUserId,
            usersRaw: usersRaw,
            fallback: myName.isEmpty ? linked.franchiseName : myName
        )

        let matchup = buildMatchup(
            matchupsRaw: matchupsRaw,
            rosterId: rosterId,
            rosters: parseRosters(rostersRaw),
            names: names,
            usersRaw: usersRaw,
            week: currentWeek
        )

        let fpts = myRoster.settings["fpts"] as? Double
            ?? (myRoster.settings["fpts"] as? Int).map(Double.init)

        return TeamSnapshot(
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            leagueName: linked.leagueName,
            franchiseName: franchiseDisplay,
            week: currentWeek,
            seasonPointsFor: fpts,
            starters: starters,
            bench: bench,
            ir: ir,
            taxi: taxi,
            matchup: matchup,
            leagueRules: LeagueRules(
                rosterSize: allIds.count,
                injuredReserveSlots: reserveIds.isEmpty ? nil : reserveIds.count,
                taxiSquadSlots: taxiIds.isEmpty ? nil : taxiIds.count,
                totalStarters: starterIds.filter { $0 != "0" && !$0.isEmpty }.count,
                starterSlots: [],
                endWeek: 18
            ),
            syncedAt: .now
        )
    }

    static func upcomingMatchups(
        linked: LinkedFranchise,
        afterWeek: Int,
        throughWeek: Int
    ) async throws -> [UpcomingMatchupPreview] {
        let client = SleeperClient.shared
        let rosterId = Int(linked.franchiseId) ?? 0
        async let rostersData = client.rosters(leagueId: linked.leagueId)
        async let usersData = client.users(leagueId: linked.leagueId)
        let (rostersRaw, usersRaw) = try await (rostersData, usersData)
        let names = parseUserNames(usersRaw)
        let rosters = parseRosters(rostersRaw)

        var out: [UpcomingMatchupPreview] = []
        let end = min(throughWeek, afterWeek + 4)
        for week in (afterWeek + 1)...max(afterWeek + 1, end) {
            guard let data = try? await client.matchups(leagueId: linked.leagueId, week: week) else { continue }
            guard let mine = parseMatchups(data).first(where: { $0.rosterId == rosterId }),
                  let matchupId = mine.matchupId
            else { continue }
            guard let opp = parseMatchups(data).first(where: {
                $0.matchupId == matchupId && $0.rosterId != rosterId
            }) else { continue }
            let oppRoster = rosters.first { $0.rosterId == opp.rosterId }
            let oppOwner = oppRoster?.ownerId ?? ""
            let oppName = teamDisplayName(
                userId: oppOwner,
                usersRaw: usersRaw,
                fallback: names[oppOwner] ?? "Opponent"
            )
            out.append(UpcomingMatchupPreview(week: week, opponentName: oppName, isHome: nil))
        }
        return out
    }

    static func loadLeagueReview(linked: LinkedFranchise, week: Int) async throws -> LeagueReviewSnapshot {
        let client = SleeperClient.shared
        async let rostersData = client.rosters(leagueId: linked.leagueId)
        async let usersData = client.users(leagueId: linked.leagueId)
        async let matchupsData = try? await client.matchups(leagueId: linked.leagueId, week: week)
        async let txData = try? await client.transactions(leagueId: linked.leagueId, week: week)

        let (rostersRaw, usersRaw, matchupsRaw, transactionsRaw) = try await (
            rostersData, usersData, matchupsData, txData
        )
        let names = parseUserNames(usersRaw)
        let rosters = parseRosters(rostersRaw)

        var standings: [LeagueStandingRow] = rosters.map { roster in
            let wins = intSetting(roster.settings, "wins")
            let losses = intSetting(roster.settings, "losses")
            let ties = intSetting(roster.settings, "ties")
            let pf = doubleSetting(roster.settings, "fpts")
            let pa = doubleSetting(roster.settings, "fpts_against")
            let name = teamDisplayName(
                userId: roster.ownerId,
                usersRaw: usersRaw,
                fallback: names[roster.ownerId] ?? "Team \(roster.rosterId)"
            )
            return LeagueStandingRow(
                franchiseId: String(roster.rosterId),
                name: name,
                wins: wins,
                losses: losses,
                ties: ties,
                pointsFor: pf,
                pointsAgainst: pa,
                rank: nil
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
                rank: idx + 1,
                rankDelta: nil
            )
        }

        var matchups: [LeagueMatchupRow] = []
        if let matchupsRaw {
            let rows = parseMatchups(matchupsRaw)
            let byMatchup = Dictionary(grouping: rows, by: { $0.matchupId ?? -1 })
            for (mid, pair) in byMatchup where mid >= 0 && pair.count >= 2 {
                let a = pair[0]
                let b = pair[1]
                let aName = standings.first { $0.franchiseId == String(a.rosterId) }?.name ?? "Team"
                let bName = standings.first { $0.franchiseId == String(b.rosterId) }?.name ?? "Team"
                matchups.append(
                    LeagueMatchupRow(
                        id: "\(week)-\(mid)",
                        homeName: aName,
                        awayName: bName,
                        homeScore: a.points,
                        awayScore: b.points
                    )
                )
            }
        }

        let transactions = parseTransactions(transactionsRaw, names: names, usersRaw: usersRaw)

        return LeagueReviewSnapshot(
            week: week,
            standings: standings,
            transactions: transactions,
            matchups: matchups,
            syncedAt: .now
        )
    }

    static func trendingFreeAgents(limit: Int = 20) async throws -> [RosterPlayer] {
        await SleeperPlayerCatalog.shared.ensureLoaded()
        let data = try await SleeperClient.shared.trendingAdds(limit: limit)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [RosterPlayer] = []
        for row in arr {
            guard let pid = row["player_id"] as? String else { continue }
            let record = await SleeperPlayerCatalog.shared.player(id: pid)
            out.append(
                RosterPlayer(
                    playerId: pid,
                    name: record?.fullName ?? "Player \(pid)",
                    position: record?.position ?? "?",
                    team: record?.team ?? "",
                    status: "fa",
                    injuryStatus: record?.injuryStatus
                )
            )
        }
        return out
    }

    // MARK: - Parsing

    private struct SleeperRoster {
        let rosterId: Int
        let ownerId: String
        let players: [String]
        let starters: [String]
        let reserve: [String]
        let taxi: [String]
        let settings: [String: Any]
    }

    private struct SleeperMatchup {
        let rosterId: Int
        let matchupId: Int?
        let points: Double?
        let playersPoints: [String: Double]
    }

    private static func parseRosters(_ data: Data) -> [SleeperRoster] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { row in
            let rosterId = (row["roster_id"] as? Int)
                ?? Int(row["roster_id"] as? String ?? "")
            guard let rosterId else { return nil }
            let owner = (row["owner_id"] as? String)
                ?? (row["owner_id"] as? Int).map(String.init)
                ?? ""
            let players = stringIds(row["players"])
            let starters = stringIds(row["starters"])
            let reserve = stringIds(row["reserve"])
            let taxi = stringIds(row["taxi"])
            let settings = (row["settings"] as? [String: Any]) ?? [:]
            return SleeperRoster(
                rosterId: rosterId,
                ownerId: owner,
                players: players,
                starters: starters,
                reserve: reserve,
                taxi: taxi,
                settings: settings
            )
        }
    }

    private static func stringIds(_ any: Any?) -> [String] {
        if let arr = any as? [String] {
            return arr.filter { !$0.isEmpty && $0 != "0" }
        }
        if let arr = any as? [Int] {
            return arr.map(String.init).filter { $0 != "0" }
        }
        if let arr = any as? [Any] {
            return arr.compactMap { value -> String? in
                if let s = value as? String {
                    let t = s.trimmingCharacters(in: .whitespaces)
                    return (t.isEmpty || t == "0") ? nil : t
                }
                if let i = value as? Int {
                    return i == 0 ? nil : String(i)
                }
                if let n = value as? NSNumber {
                    let i = n.intValue
                    return i == 0 ? nil : String(i)
                }
                return nil
            }
        }
        return []
    }

    private static func parseMatchups(_ data: Data) -> [SleeperMatchup] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { row in
            let rosterId = (row["roster_id"] as? Int)
                ?? Int(row["roster_id"] as? String ?? "")
            guard let rosterId else { return nil }
            let mid = (row["matchup_id"] as? Int) ?? Int(row["matchup_id"] as? String ?? "")
            let points = (row["points"] as? Double) ?? (row["points"] as? Int).map(Double.init)
            var pp: [String: Double] = [:]
            if let map = row["players_points"] as? [String: Any] {
                for (k, v) in map {
                    if let d = v as? Double { pp[k] = d }
                    else if let i = v as? Int { pp[k] = Double(i) }
                    else if let s = v as? String, let d = Double(s) { pp[k] = d }
                }
            }
            return SleeperMatchup(
                rosterId: rosterId,
                matchupId: mid,
                points: points,
                playersPoints: pp
            )
        }
    }

    private static func matchupPlayerPoints(_ data: Data?, rosterId: Int) -> [String: Double] {
        guard let data else { return [:] }
        return parseMatchups(data).first(where: { $0.rosterId == rosterId })?.playersPoints ?? [:]
    }

    /// Drop matchup point stubs for players whose NFL game hasn't started (Sleeper often sends 0).
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

    private static func parseProjectionMap(_ data: Data?, scoringKey: String) -> [String: Double] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }

        let rows: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            rows = arr
        } else if let dict = root as? [String: Any] {
            // Some responses are { playerId: { stats: ... } }
            rows = dict.compactMap { key, value -> [String: Any]? in
                guard var row = value as? [String: Any] else { return nil }
                if row["player_id"] == nil { row["player_id"] = key }
                return row
            }
        } else {
            return [:]
        }

        var map: [String: Double] = [:]
        for row in rows {
            let pid = (row["player_id"] as? String)
                ?? (row["player"] as? [String: Any]).flatMap { $0["player_id"] as? String }
                ?? (row["player_id"] as? Int).map(String.init)
            guard let pid, !pid.isEmpty else { continue }
            let stats = (row["stats"] as? [String: Any]) ?? row
            let pts = doubleValue(stats[scoringKey])
                ?? doubleValue(stats["pts_ppr"])
                ?? doubleValue(stats["pts_half_ppr"])
                ?? doubleValue(stats["pts_std"])
            guard let pts else { continue }
            map[pid] = pts
        }
        return map
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseUserNames(_ data: Data) -> [String: String] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var map: [String: String] = [:]
        for row in arr {
            guard let uid = row["user_id"] as? String else { continue }
            let display = (row["display_name"] as? String)
                ?? (row["username"] as? String)
                ?? uid
            map[uid] = display
        }
        return map
    }

    private static func teamDisplayName(userId: String, usersRaw: Data, fallback: String) -> String {
        guard let arr = try? JSONSerialization.jsonObject(with: usersRaw) as? [[String: Any]] else {
            return fallback
        }
        guard let row = arr.first(where: { ($0["user_id"] as? String) == userId }) else {
            return fallback
        }
        if let meta = row["metadata"] as? [String: Any],
           let team = meta["team_name"] as? String,
           !team.trimmingCharacters(in: .whitespaces).isEmpty {
            return team
        }
        return (row["display_name"] as? String) ?? (row["username"] as? String) ?? fallback
    }

    private static func buildMatchup(
        matchupsRaw: Data?,
        rosterId: Int,
        rosters: [SleeperRoster],
        names: [String: String],
        usersRaw: Data,
        week: Int
    ) -> MatchupSnapshot? {
        guard let matchupsRaw else { return nil }
        let rows = parseMatchups(matchupsRaw)
        guard let mine = rows.first(where: { $0.rosterId == rosterId }),
              let mid = mine.matchupId
        else {
            return MatchupSnapshot(week: week, myScore: nil, oppScore: nil, opponentName: nil)
        }
        let opp = rows.first { $0.matchupId == mid && $0.rosterId != rosterId }
        let oppOwner = rosters.first { $0.rosterId == opp?.rosterId }?.ownerId ?? ""
        let oppName = teamDisplayName(
            userId: oppOwner,
            usersRaw: usersRaw,
            fallback: names[oppOwner] ?? "Opponent"
        )
        return MatchupSnapshot(
            week: week,
            myScore: mine.points,
            oppScore: opp?.points,
            opponentName: oppName
        )
    }

    private static func parseTransactions(
        _ data: Data?,
        names: [String: String],
        usersRaw: Data
    ) -> [LeagueTransactionRow] {
        guard let data,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.prefix(40).enumerated().compactMap { idx, row in
            let type = (row["type"] as? String) ?? "tx"
            let status = (row["status"] as? String) ?? ""
            guard status == "complete" || status.isEmpty else { return nil }
            let rosterIds = (row["roster_ids"] as? [Int]) ?? []
            let franchiseId = rosterIds.first.map(String.init) ?? ""
            let ownerLookup: String = {
                // Best-effort: use first creator
                if let creator = row["creator"] as? String { return creator }
                return ""
            }()
            let franchiseName = teamDisplayName(
                userId: ownerLookup,
                usersRaw: usersRaw,
                fallback: names[ownerLookup] ?? (franchiseId.isEmpty ? "League" : "Roster \(franchiseId)")
            )
            let adds = (row["adds"] as? [String: Any])?.keys.joined(separator: ",") ?? ""
            let drops = (row["drops"] as? [String: Any])?.keys.joined(separator: ",") ?? ""
            var bits: [String] = [type]
            if !adds.isEmpty { bits.append("add \(adds)") }
            if !drops.isEmpty { bits.append("drop \(drops)") }
            let ts = (row["status_updated"] as? Double)
                ?? (row["created"] as? Double)
                ?? (row["status_updated"] as? Int).map(Double.init)
            let date = ts.map { Date(timeIntervalSince1970: $0 / ($0 > 1_000_000_000_000 ? 1000 : 1)) }
            return LeagueTransactionRow(
                id: (row["transaction_id"] as? String) ?? "tx-\(idx)",
                timestamp: date,
                franchiseId: franchiseId,
                franchiseName: franchiseName,
                summary: bits.joined(separator: " · "),
                type: type
            )
        }
    }

    private static func intSetting(_ settings: [String: Any], _ key: String) -> Int {
        if let i = settings[key] as? Int { return i }
        if let d = settings[key] as? Double { return Int(d) }
        if let s = settings[key] as? String, let i = Int(s) { return i }
        return 0
    }

    private static func doubleSetting(_ settings: [String: Any], _ key: String) -> Double {
        if let d = settings[key] as? Double { return d }
        if let i = settings[key] as? Int { return Double(i) }
        if let s = settings[key] as? String, let d = Double(s) { return d }
        return 0
    }
}
