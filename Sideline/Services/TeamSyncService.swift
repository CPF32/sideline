import Foundation

enum TeamSyncService {
    static func loadTeam(
        linked: LinkedFranchise,
        week: Int? = nil
    ) async throws -> TeamSnapshot {
        let client = MFLClient.shared
        let season = linked.season
        let host = linked.host
        let leagueId = linked.leagueId
        let franchiseId = linked.franchiseId

        let leagueData = try await client.exportJSON(
            host: host, season: season, type: "league", leagueId: leagueId, cacheTTL: 600
        )
        // Prefer MFL nflSchedule live week (not league "next lineup" week).
        let currentWeek: Int
        if let week {
            currentWeek = week
        } else if let live = try? await resolveLiveNFLWeek(season: season) {
            currentWeek = live
        } else if let parsed = parseCurrentWeek(from: leagueData) {
            currentWeek = parsed
        } else {
            currentWeek = estimatedNFLWeek()
        }

        async let rostersData = client.exportJSON(
            host: host, season: season, type: "rosters", leagueId: leagueId,
            extra: ["FRANCHISE": franchiseId], cacheTTL: 60
        )
        async let playersData = client.exportJSON(
            host: host, season: season, type: "players", leagueId: leagueId,
            extra: ["DETAILS": "1"], cacheTTL: 86_400
        )
        async let projectionsData = try? await client.exportJSON(
            host: host, season: season, type: "projectedScores", leagueId: leagueId,
            extra: ["W": String(currentWeek)], cacheTTL: 300
        )
        async let scheduleData = try? await client.exportJSON(
            host: host, season: season, type: "schedule", leagueId: leagueId,
            extra: ["W": String(currentWeek)], cacheTTL: 300
        )
        async let standingsData = try? await client.exportJSON(
            host: host, season: season, type: "leagueStandings", leagueId: leagueId,
            cacheTTL: 300
        )
        // Week-specific starters/bench — `rosters` alone is last-submitted lineup (often prior week).
        async let weeklyResultsData = try? await client.exportJSON(
            host: host, season: season, type: "weeklyResults", leagueId: leagueId,
            extra: ["W": String(currentWeek)], cacheTTL: 60
        )
        // Live totals + per-player scores (DETAILS=1 includes bench).
        async let liveScoringData = try? await client.exportJSON(
            host: host, season: season, type: "liveScoring", leagueId: leagueId,
            extra: ["W": String(currentWeek), "DETAILS": "1"], cacheTTL: 30
        )
        // Final / prelim week scores — fills gaps once games post.
        async let playerScoresData = try? await client.exportJSON(
            host: host, season: season, type: "playerScores", leagueId: leagueId,
            extra: ["W": String(currentWeek)], cacheTTL: 120
        )
        async let nflScheduleData = try? await NFLScheduleService.fetchData(season: season, week: currentWeek)
        async let salariesData = try? await client.exportJSON(
            host: host, season: season, type: "salaries", leagueId: leagueId, cacheTTL: 300
        )

        let (rosters, players, projections, schedule, standings, weeklyResults, liveScoring, playerScores, nflSchedule, salaries) = try await (
            rostersData, playersData, projectionsData, scheduleData, standingsData, weeklyResultsData, liveScoringData, playerScoresData, nflScheduleData, salariesData
        )
        let playerMap = parsePlayers(players)
        let injuryMap = parseInjuries(players)
        let franchiseNames = MFLNameResolver.parseFranchiseNames(from: leagueData)
        let resolvedFranchiseName = MFLNameResolver.franchiseName(
            id: franchiseId,
            names: franchiseNames,
            fallback: Self.nonPlaceholderName(linked.franchiseName)
        )
        let projMap = projections.map { parseProjections($0) } ?? [:]
        let salaryMap = salaries.map { parseSalaries($0) } ?? [:]
        let leagueRules = LeagueRules.parse(from: leagueData)
        let teamGames = nflSchedule.map { NFLScheduleService.parse($0) } ?? [:]
        let rosterBuckets = parseRoster(
            rosters,
            franchiseId: franchiseId,
            players: playerMap,
            projections: projMap,
            injuries: injuryMap,
            salaries: salaryMap
        )
        var (starters, bench, ir, taxi) = applyWeekLineup(
            roster: rosterBuckets,
            weeklyResults: weeklyResults,
            franchiseId: franchiseId,
            players: playerMap,
            projections: projMap
        )
        starters = NFLScheduleService.annotate(starters, games: teamGames)
        bench = NFLScheduleService.annotate(bench, games: teamGames)
        ir = NFLScheduleService.annotate(ir, games: teamGames)
        taxi = NFLScheduleService.annotate(taxi, games: teamGames)

        var actualMap: [String: Double] = [:]
        if let playerScores {
            for (id, score) in parseProjections(playerScores) {
                actualMap[id] = score
                actualMap[MFLNameResolver.normalizePlayerId(id)] = score
            }
        }
        if let liveScoring {
            for (id, score) in parseLivePlayerScores(liveScoring) {
                actualMap[id] = score
                actualMap[MFLNameResolver.normalizePlayerId(id)] = score
            }
        }
        starters = applyActualPoints(starters, actuals: actualMap)
        bench = applyActualPoints(bench, actuals: actualMap)
        ir = applyActualPoints(ir, actuals: actualMap)
        taxi = applyActualPoints(taxi, actuals: actualMap)

        let matchup = MFLMatchupScores.snapshot(
            for: franchiseId,
            liveScoring: liveScoring,
            weeklyResults: weeklyResults,
            schedule: schedule,
            week: currentWeek,
            names: franchiseNames
        )
        let seasonPF = standings.flatMap { parseSeasonPointsFor($0, franchiseId: franchiseId) }
        let all = starters + bench + ir + taxi
        let salaryValues = all.compactMap(\.salary)
        let totalSalary: Double? = salaryValues.isEmpty ? nil : salaryValues.reduce(0, +)

        return TeamSnapshot(
            leagueId: leagueId,
            franchiseId: franchiseId,
            leagueName: linked.leagueName,
            franchiseName: resolvedFranchiseName,
            week: currentWeek,
            seasonPointsFor: seasonPF,
            starters: starters,
            bench: bench,
            ir: ir,
            taxi: taxi,
            matchup: matchup,
            leagueRules: leagueRules,
            totalSalary: totalSalary,
            syncedAt: .now
        )
    }

    /// Franchise opponents for weeks after `afterWeek` through `throughWeek` (from full league schedule).
    static func upcomingMatchups(
        linked: LinkedFranchise,
        franchiseId: String,
        afterWeek: Int,
        throughWeek: Int
    ) async throws -> [UpcomingMatchupPreview] {
        let data = try await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "schedule",
            leagueId: linked.leagueId,
            cacheTTL: 600
        )
        let leagueData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "league",
            leagueId: linked.leagueId,
            cacheTTL: 600
        )
        let names = leagueData.map { MFLNameResolver.parseFranchiseNames(from: $0) } ?? [:]
        return parseFranchiseSchedule(
            data,
            franchiseId: franchiseId,
            names: names,
            afterWeek: afterWeek,
            throughWeek: throughWeek
        )
    }

    private static func parseFranchiseSchedule(
        _ data: Data,
        franchiseId: String,
        names: [String: String],
        afterWeek: Int,
        throughWeek: Int
    ) -> [UpcomingMatchupPreview] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let schedule = (root["schedule"] as? [String: Any]) ?? root
        let myId = MFLNameResolver.normalizeFranchiseId(franchiseId)
        var byWeek: [Int: UpcomingMatchupPreview] = [:]

        func ingest(week: Int, matchupRows: [[String: Any]]) {
            guard week > afterWeek, week <= throughWeek else { return }
            for m in matchupRows {
                let sides = arrayOfDicts(m["franchise"])
                let ids = sides.compactMap { side -> String? in
                    let raw = (side["id"] as? String) ?? (side["id"] as? Int).map(String.init)
                    return raw.map { MFLNameResolver.normalizeFranchiseId($0) }
                }
                guard ids.contains(myId), ids.count >= 2 else { continue }
                let oppId = ids.first { $0 != myId } ?? ""
                let oppSide = sides.first { side in
                    let raw = (side["id"] as? String) ?? (side["id"] as? Int).map(String.init) ?? ""
                    return MFLNameResolver.normalizeFranchiseId(raw) == oppId
                }
                let isHome: Bool? = {
                    if let h = oppSide?["isHome"] as? String { return h == "0" } // opp away ⇒ we home
                    if let h = oppSide?["isHome"] as? Int { return h == 0 }
                    // Some feeds mark our side
                    if let mine = sides.first(where: {
                        let raw = ($0["id"] as? String) ?? ($0["id"] as? Int).map(String.init) ?? ""
                        return MFLNameResolver.normalizeFranchiseId(raw) == myId
                    }) {
                        if let h = mine["isHome"] as? String { return h == "1" }
                        if let h = mine["isHome"] as? Int { return h == 1 }
                    }
                    return nil
                }()
                let oppName = MFLNameResolver.franchiseName(
                    id: oppId,
                    names: names,
                    fallback: oppSide?["name"] as? String
                ) ?? "Opponent"
                byWeek[week] = UpcomingMatchupPreview(week: week, opponentName: oppName, isHome: isHome)
            }
        }

        // Shape A: weeklySchedule = [ { week, matchup }, ... ]
        let weekly = arrayOfDicts(schedule["weeklySchedule"])
        if !weekly.isEmpty {
            for node in weekly {
                let w = intValue(node["week"]) ?? intValue(node["id"]) ?? 0
                ingest(week: w, matchupRows: arrayOfDicts(node["matchup"]))
            }
        }

        // Shape B: matchup array with week attribute on each
        let flat = arrayOfDicts(schedule["matchup"])
        for m in flat {
            let w = intValue(m["week"]) ?? 0
            if w > 0 {
                ingest(week: w, matchupRows: [m])
            }
        }

        return byWeek.keys.sorted().compactMap { byWeek[$0] }
    }

    private static func nonPlaceholderName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.caseInsensitiveCompare("Franchise") == .orderedSame { return nil }
        return trimmed
    }

    /// MFL nflSchedule without W returns the live/current NFL week (not next week's lineup week).
    private static func resolveLiveNFLWeek(season: Int) async throws -> Int? {
        let url = URL(string: "https://api.myfantasyleague.com/\(season)/export?TYPE=nflSchedule&JSON=1")!
        var request = URLRequest(url: url)
        request.setValue(MFLClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let schedule = root["nflSchedule"] as? [String: Any] {
            if let w = schedule["week"] as? String, let i = Int(w), i >= 1, i <= 22 { return i }
            if let w = schedule["week"] as? Int, w >= 1, w <= 22 { return w }
        }
        // Some payloads nest under fullNflSchedule
        if let full = root["fullNflSchedule"] as? [String: Any],
           let schedule = full["nflSchedule"] as? [String: Any] {
            if let w = schedule["week"] as? String, let i = Int(w), i >= 1 { return i }
            if let w = schedule["week"] as? Int, w >= 1 { return w }
        }
        return nil
    }

    private static func estimatedNFLWeek() -> Int {
        // Conservative fallback when MFL schedule is unavailable.
        let cal = Calendar.current
        let month = cal.component(.month, from: Date())
        let day = cal.component(.day, from: Date())
        if month < 9 { return 1 }
        if month == 9 {
            // Week 1 ≈ first Thu of Sep; rough buckets without overshooting
            if day < 9 { return 1 }
            if day < 16 { return 2 }
            if day < 23 { return 2 } // prefer current completed/in-progress week over next
            return 3
        }
        if month == 10 { return min(8, 4 + (day / 7)) }
        if month == 11 { return min(13, 8 + (day / 7)) }
        if month == 12 { return min(18, 13 + (day / 7)) }
        return 1
    }

    private static func parseCurrentWeek(from data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let league = (root["league"] as? [String: Any]) ?? root
        // Prefer explicit current scoring week fields when present.
        let keys = ["baseWeek", "scoreWeek", "currentScoringWeek", "currentWeek", "week"]
        for key in keys {
            if let w = league[key] as? String, let i = Int(w), i >= 1 { return i }
            if let w = league[key] as? Int, w >= 1 { return w }
        }
        return nil
    }

    private static func parsePlayers(_ data: Data) -> [String: (name: String, pos: String, team: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let playersAny = (root["players"] as? [String: Any])?["player"] ?? root["player"]
        let list: [[String: Any]]
        if let arr = playersAny as? [[String: Any]] { list = arr }
        else if let one = playersAny as? [String: Any] { list = [one] }
        else { return [:] }
        var map: [String: (String, String, String)] = [:]
        for p in list {
            guard let id = p["id"] as? String ?? (p["id"] as? Int).map(String.init) else { continue }
            let name = (p["name"] as? String) ?? id
            let pos = (p["position"] as? String) ?? ""
            let team = (p["team"] as? String) ?? ""
            map[id] = (name, pos, team)
        }
        return map
    }

    private static func parseInjuries(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let playersAny = (root["players"] as? [String: Any])?["player"] ?? root["player"]
        let list: [[String: Any]]
        if let arr = playersAny as? [[String: Any]] { list = arr }
        else if let one = playersAny as? [String: Any] { list = [one] }
        else { return [:] }
        var map: [String: String] = [:]
        for p in list {
            guard let id = p["id"] as? String ?? (p["id"] as? Int).map(String.init) else { continue }
            let status = (p["status"] as? String)
                ?? (p["injury"] as? String)
                ?? (p["injury_status"] as? String)
            if let status, !status.isEmpty, status.lowercased() != "healthy" {
                map[id] = status
            }
        }
        return map
    }

    private static func parseProjections(_ data: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["projectedScores"] as? [String: Any])?["playerScore"]
            ?? (root["playerScores"] as? [String: Any])?["playerScore"]
            ?? root["playerScore"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] { list = arr }
        else if let one = any as? [String: Any] { list = [one] }
        else { return [:] }
        var map: [String: Double] = [:]
        for row in list {
            guard let id = row["id"] as? String ?? row["player_id"] as? String else { continue }
            if let s = row["score"] as? String, let v = Double(s) { map[id] = v }
            else if let v = row["score"] as? Double { map[id] = v }
        }
        return map
    }

    /// Per-player live/final fantasy points from `liveScoring` (DETAILS=1).
    private static func parseLivePlayerScores(_ data: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let live = (root["liveScoring"] as? [String: Any]) ?? root
        var map: [String: Double] = [:]

        func ingestPlayerRows(_ any: Any?) {
            for row in arrayOfDicts(any) {
                // Franchise nodes nest players — skip those containers.
                if row["players"] != nil { continue }
                if row["player"] is [[String: Any]] || row["player"] is [String: Any] { continue }
                guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init),
                      let score = doubleValue(row["score"]) else { continue }
                let nid = MFLNameResolver.normalizePlayerId(id)
                map[nid] = score
                map[id] = score
            }
        }

        func walkFranchise(_ franchise: [String: Any]) {
            let playersNode = franchise["players"] as? [String: Any]
            ingestPlayerRows(playersNode?["player"] ?? franchise["player"])
        }

        for matchup in arrayOfDicts(live["matchup"]) {
            for franchise in arrayOfDicts(matchup["franchise"]) {
                walkFranchise(franchise)
            }
        }
        for franchise in arrayOfDicts(live["franchise"]) {
            walkFranchise(franchise)
        }
        return map
    }

    private static func applyActualPoints(
        _ players: [RosterPlayer],
        actuals: [String: Double]
    ) -> [RosterPlayer] {
        players.map { player in
            let nid = MFLNameResolver.normalizePlayerId(player.playerId)
            guard let score = actuals[nid] ?? actuals[player.playerId] else { return player }
            return player.replacing(actualPoints: score)
        }
    }

    private static func parseRoster(
        _ data: Data,
        franchiseId: String,
        players: [String: (name: String, pos: String, team: String)],
        projections: [String: Double],
        injuries: [String: String],
        salaries: [String: (salary: Double?, contractYear: Int?)]
    ) -> (starters: [RosterPlayer], bench: [RosterPlayer], ir: [RosterPlayer], taxi: [RosterPlayer]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [], [], [])
        }
        let franchisesAny = (root["rosters"] as? [String: Any])?["franchise"] ?? root["franchise"]
        let franchises: [[String: Any]]
        if let arr = franchisesAny as? [[String: Any]] { franchises = arr }
        else if let one = franchisesAny as? [String: Any] { franchises = [one] }
        else { return ([], [], [], []) }

        guard let franchise = franchises.first(where: {
            MFLNameResolver.normalizeFranchiseId(($0["id"] as? String) ?? "")
                == MFLNameResolver.normalizeFranchiseId(franchiseId)
        }) ?? franchises.first else {
            return ([], [], [], [])
        }

        let playerAny = franchise["player"]
        let playerRows: [[String: Any]]
        if let arr = playerAny as? [[String: Any]] { playerRows = arr }
        else if let one = playerAny as? [String: Any] { playerRows = [one] }
        else if let csv = franchise["player"] as? String {
            return parseCSVRoster(csv, players: players, projections: projections, injuries: injuries, salaries: salaries)
        } else {
            return ([], [], [], [])
        }

        var starters: [RosterPlayer] = []
        var bench: [RosterPlayer] = []
        var ir: [RosterPlayer] = []
        var taxi: [RosterPlayer] = []
        for row in playerRows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let statusCode = (row["status"] as? String)?.uppercased() ?? ""
            let meta = players[id]
            let nid = MFLNameResolver.normalizePlayerId(id)
            let fromSalaries = salaries[nid] ?? salaries[id]
            let salary = doubleValue(row["salary"]) ?? fromSalaries?.salary
            let contractYear = intValue(row["contractYear"]) ?? fromSalaries?.contractYear
            let player = RosterPlayer(
                playerId: id,
                name: meta?.name ?? id,
                position: meta?.pos ?? (row["position"] as? String ?? ""),
                team: meta?.team ?? "",
                status: statusFromCode(statusCode),
                projectedPoints: projections[id],
                opponent: nil,
                injuryStatus: injuries[id],
                salary: salary,
                contractYear: contractYear
            )
            switch player.status {
            case "starter": starters.append(player)
            case "ir": ir.append(player)
            case "taxi": taxi.append(player)
            default: bench.append(player)
            }
        }
        return (starters, bench, ir, taxi)
    }

    /// Prefer week-specific starter flags from `weeklyResults`.
    /// If that week has no lineup recorded yet, do not fall back to last-submitted `rosters` starters.
    private static func applyWeekLineup(
        roster: (starters: [RosterPlayer], bench: [RosterPlayer], ir: [RosterPlayer], taxi: [RosterPlayer]),
        weeklyResults: Data?,
        franchiseId: String,
        players: [String: (name: String, pos: String, team: String)],
        projections: [String: Double]
    ) -> (starters: [RosterPlayer], bench: [RosterPlayer], ir: [RosterPlayer], taxi: [RosterPlayer]) {
        let ir = roster.ir
        let taxi = roster.taxi
        let reservedIds = Set(ir.map(\.playerId) + taxi.map(\.playerId))
        let rosterPool = roster.starters + roster.bench + roster.ir + roster.taxi
        let byId = Dictionary(uniqueKeysWithValues: rosterPool.map { ($0.playerId, $0) })

        guard let weeklyResults,
              let weekStatuses = parseWeeklyPlayerStatuses(weeklyResults, franchiseId: franchiseId),
              !weekStatuses.isEmpty
        else {
            // No week lineup yet — show full active roster on the bench.
            let bench = (roster.starters + roster.bench).map {
                $0.replacing(
                    status: "bench",
                    projectedPoints: projections[$0.playerId] ?? $0.projectedPoints
                )
            }
            return ([], bench, ir, taxi)
        }

        var starters: [RosterPlayer] = []
        var bench: [RosterPlayer] = []
        var seen = Set<String>()

        for (id, status) in weekStatuses {
            seen.insert(id)
            if reservedIds.contains(id) { continue }
            let base = byId[id]
            let meta = players[id]
            let player = (base ?? RosterPlayer(
                playerId: id,
                name: meta?.name ?? id,
                position: meta?.pos ?? "",
                team: meta?.team ?? "",
                status: status,
                projectedPoints: projections[id]
            )).replacing(
                status: status,
                name: base?.name ?? meta?.name,
                position: base?.position ?? meta?.pos,
                team: base?.team ?? meta?.team,
                projectedPoints: projections[id] ?? base?.projectedPoints
            )
            if status == "starter" {
                starters.append(player)
            } else {
                bench.append(player)
            }
        }

        // Anyone still on the current roster but missing from weeklyResults stays on the bench.
        for player in roster.starters + roster.bench where !seen.contains(player.playerId) && !reservedIds.contains(player.playerId) {
            bench.append(
                player.replacing(
                    status: "bench",
                    projectedPoints: projections[player.playerId] ?? player.projectedPoints
                )
            )
        }

        return (starters, bench, ir, taxi)
    }

    /// Returns playerId → "starter" | "bench" for the franchise in this week's results.
    private static func parseWeeklyPlayerStatuses(
        _ data: Data,
        franchiseId: String
    ) -> [String: String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let weekly = (root["weeklyResults"] as? [String: Any]) ?? root
        let want = MFLNameResolver.normalizeFranchiseId(franchiseId)

        var franchiseRows: [[String: Any]] = []

        let matchupAny = weekly["matchup"]
        let matchups: [[String: Any]]
        if let arr = matchupAny as? [[String: Any]] {
            matchups = arr
        } else if let one = matchupAny as? [String: Any] {
            matchups = [one]
        } else {
            matchups = []
        }
        for matchup in matchups {
            franchiseRows.append(contentsOf: arrayOfDicts(matchup["franchise"]))
        }
        // Bye / unmatched franchises sometimes sit at the weeklyResults root.
        franchiseRows.append(contentsOf: arrayOfDicts(weekly["franchise"]))

        var statuses: [String: String] = [:]
        var sawFranchise = false

        for franchise in franchiseRows {
            let id = MFLNameResolver.normalizeFranchiseId(
                (franchise["id"] as? String) ?? String(describing: franchise["id"] ?? "")
            )
            guard id == want else { continue }
            sawFranchise = true

            let rows = arrayOfDicts(franchise["player"])
            // Explicit empty player list means this week has no lineup recorded yet.
            if rows.isEmpty { return [:] }

            for row in rows {
                guard let pid = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
                let raw = ((row["status"] as? String) ?? "").lowercased()
                let isStarter = (raw.contains("starter") && !raw.contains("non"))
                    || raw == "s"
                    || raw == "1"
                statuses[pid] = isStarter ? "starter" : "bench"
            }
        }

        if !sawFranchise { return nil }
        return statuses
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }

    private static func parseCSVRoster(
        _ csv: String,
        players: [String: (name: String, pos: String, team: String)],
        projections: [String: Double],
        injuries: [String: String],
        salaries: [String: (salary: Double?, contractYear: Int?)]
    ) -> ([RosterPlayer], [RosterPlayer], [RosterPlayer], [RosterPlayer]) {
        // MFL often uses: id, id|status, ...
        var starters: [RosterPlayer] = []
        var bench: [RosterPlayer] = []
        var ir: [RosterPlayer] = []
        var taxi: [RosterPlayer] = []
        let parts = csv.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        for part in parts where !part.isEmpty {
            let bits = part.split(separator: "|").map(String.init)
            let id = bits[0]
            let code = bits.count > 1 ? bits[1].uppercased() : ""
            let meta = players[id]
            let nid = MFLNameResolver.normalizePlayerId(id)
            let fromSalaries = salaries[nid] ?? salaries[id]
            let player = RosterPlayer(
                playerId: id,
                name: meta?.name ?? id,
                position: meta?.pos ?? "",
                team: meta?.team ?? "",
                status: statusFromCode(code),
                projectedPoints: projections[id],
                opponent: nil,
                injuryStatus: injuries[id],
                salary: fromSalaries?.salary,
                contractYear: fromSalaries?.contractYear
            )
            switch player.status {
            case "starter": starters.append(player)
            case "ir": ir.append(player)
            case "taxi": taxi.append(player)
            default: bench.append(player)
            }
        }
        return (starters, bench, ir, taxi)
    }

    private static func parseSalaries(_ data: Data) -> [String: (salary: Double?, contractYear: Int?)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["salaries"] as? [String: Any])?["player"]
            ?? root["player"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }

        var map: [String: (salary: Double?, contractYear: Int?)] = [:]
        var defaults: (salary: Double?, contractYear: Int?) = (nil, nil)
        for row in rows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let salary = doubleValue(row["salary"])
            let year = intValue(row["contractYear"])
            if id == "0000" {
                defaults = (salary, year)
                continue
            }
            let nid = MFLNameResolver.normalizePlayerId(id)
            map[nid] = (salary ?? defaults.salary, year ?? defaults.contractYear)
            map[id] = map[nid]
        }
        return map
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String {
            let cleaned = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func statusFromCode(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch c {
        case "S", "STARTER", "ROSTER": return "starter"
        case "IR", "INJURED_RESERVE", "INJUREDRESERVE": return "ir"
        case "TAXI", "TS", "TAXI_SQUAD", "TAXISQUAD", "TAXI-SQUAD": return "taxi"
        case "NS", "BENCH", "": return "bench"
        default:
            if c.contains("TAXI") { return "taxi" }
            if c.contains("INJUR") || c == "IR" { return "ir" }
            if c == "S" || c.contains("STARTER") { return "starter" }
            return "bench"
        }
    }

    private static func parseMatchup(
        _ data: Data,
        franchiseId: String,
        week: Int,
        franchiseNames: [String: String]
    ) -> MatchupSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MatchupSnapshot(week: week)
        }
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

        let myId = MFLNameResolver.normalizeFranchiseId(franchiseId)
        for m in matchups {
            let franchisesAny = m["franchise"]
            let sides: [[String: Any]]
            if let arr = franchisesAny as? [[String: Any]] { sides = arr }
            else if let one = franchisesAny as? [String: Any] { sides = [one] }
            else { continue }

            let normalized = sides.map { side -> (id: String, score: Double?, name: String?) in
                let raw = (side["id"] as? String) ?? (side["id"] as? Int).map(String.init) ?? ""
                let id = MFLNameResolver.normalizeFranchiseId(raw)
                return (id, doubleValue(side["score"]), side["name"] as? String)
            }
            guard normalized.contains(where: { $0.id == myId }) else { continue }
            let mine = normalized.first { $0.id == myId }
            let opp = normalized.first { $0.id != myId }
            let oppName = MFLNameResolver.franchiseName(
                id: opp?.id,
                names: franchiseNames,
                fallback: opp?.name
            )
            return MatchupSnapshot(
                week: week,
                myScore: mine?.score,
                oppScore: opp?.score,
                opponentName: oppName,
                lineupDeadline: nil
            )
        }
        return MatchupSnapshot(week: week, opponentName: nil)
    }

    private static func parseSeasonPointsFor(_ data: Data, franchiseId: String) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let any = (root["leagueStandings"] as? [String: Any])?["franchise"]
            ?? (root["standings"] as? [String: Any])?["franchise"]
            ?? root["franchise"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] {
            list = arr
        } else if let one = any as? [String: Any] {
            list = [one]
        } else {
            return nil
        }
        let want = MFLNameResolver.normalizeFranchiseId(franchiseId)
        for row in list {
            let id = MFLNameResolver.normalizeFranchiseId(
                (row["id"] as? String) ?? String(describing: row["id"] ?? "")
            )
            guard id == want || id == franchiseId else { continue }
            return doubleValue(row["pf"] ?? row["pointsFor"] ?? row["score"])
        }
        return nil
    }

    /// League-wide salary map for FA enrichment / tools.
    static func fetchSalaryMap(linked: LinkedFranchise) async -> [String: (salary: Double?, contractYear: Int?)] {
        guard let data = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "salaries",
            leagueId: linked.leagueId,
            cacheTTL: 300
        ) else { return [:] }
        return parseSalaries(data)
    }
}
