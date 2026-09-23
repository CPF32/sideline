import Foundation

struct FantasyProsRanking: Hashable {
    let fpId: String
    let name: String
    let team: String
    let position: String
    let rankECR: Int?
    let posRank: String?
    let tier: Int?
    let rankMin: Int?
    let rankMax: Int?
    let rankAve: Double?
}

struct FantasyProsProjection: Hashable {
    let fpId: String
    let mflId: String?
    let sleeperId: String?
    let name: String
    let team: String
    let position: String
    let points: Double?
    let pointsPPR: Double?
    let pointsHalf: Double?

    func points(for scoring: FantasyProsScoring) -> Double? {
        switch scoring {
        case .ppr: return pointsPPR ?? points
        case .half: return pointsHalf ?? pointsPPR ?? points
        case .std: return points
        }
    }
}

struct FantasyProsNewsItem: Hashable, Identifiable {
    var id: String { link ?? "\(title)-\(summary.prefix(40))" }
    let playerName: String?
    let title: String
    let summary: String
    let link: String?
}

/// Caches FantasyPros rankings / projections / news and matches onto MFL + Sleeper players.
actor FantasyProsIntelService {
    static let shared = FantasyProsIntelService()

    private var weeklyRankings: [FantasyProsRanking] = []
    private var rosRankings: [FantasyProsRanking] = []
    private var projections: [FantasyProsProjection] = []
    private var news: [FantasyProsNewsItem] = []
    private var byMFLId: [String: FantasyProsProjection] = [:]
    private var bySleeperId: [String: FantasyProsProjection] = [:]
    private var bySearchKey: [String: FantasyProsProjection] = [:]
    private var byLastNamePos: [String: FantasyProsProjection] = [:]
    private var rankBySearchKey: [String: FantasyProsRanking] = [:]
    private var rosBySearchKey: [String: FantasyProsRanking] = [:]
    private var rankBySleeperId: [String: FantasyProsRanking] = [:]
    private var rosBySleeperId: [String: FantasyProsRanking] = [:]
    private var loadedWeek: Int?
    private var loadedSeason: Int?
    private var loadedAt: Date?

    /// Surfaced on player sheet / settings when a load fails.
    private(set) var lastStatus: String?
    /// True when the last failure looked like quota / rate limit.
    private(set) var lastWasQuotaError = false

    var isConfigured: Bool { FantasyProsClient.hasAPIKey }

    var hasData: Bool {
        !projections.isEmpty || !weeklyRankings.isEmpty || !rosRankings.isEmpty
    }

    /// Ready to annotate Sleeper (and fill gaps) with weekly projections.
    var hasProjections: Bool { !projections.isEmpty }

    func ensureLoaded(season: Int, week: Int, hasLiveGames: Bool = false) async {
        let maxAge: TimeInterval = hasLiveGames ? 60 : 3_600
        if let loadedAt,
           loadedWeek == week,
           loadedSeason == season,
           Date().timeIntervalSince(loadedAt) < maxAge,
           hasProjections {
            return
        }
        guard FantasyProsClient.hasAPIKey else {
            lastStatus = "No FantasyPros API key"
            lastWasQuotaError = false
            return
        }

        lastWasQuotaError = false
        let scoring = FantasyProsClient.scoring
        let seasonsToTry = Array(Set([season, Calendar.current.mflSeason]))
            .filter { $0 >= 2020 }
            .sorted(by: >)

        var bestWeekly: [FantasyProsRanking] = []
        var bestRos: [FantasyProsRanking] = []
        var bestProj: [FantasyProsProjection] = []
        var bestNews: [FantasyProsNewsItem] = []
        var errors: [String] = []
        var usedSeason = season
        var hitQuota = false

        seasonLoop: for trySeason in seasonsToTry {
            // Probe once — if quota is dead, don’t burn dozens more calls.
            do {
                let probe = try await FantasyProsClient.shared.consensusRankings(
                    season: trySeason, position: "RB", type: "ROS", week: nil, scoring: scoring
                )
                bestRos = parseRankings(probe)
            } catch let error as FantasyProsError where error.isQuotaIssue {
                hitQuota = true
                errors.append(error.localizedDescription)
                break
            } catch {
                errors.append(error.localizedDescription)
            }

            var weekly: [FantasyProsRanking] = []
            do {
                let data = try await FantasyProsClient.shared.consensusRankings(
                    season: trySeason, position: "ALL", type: nil, week: week, scoring: scoring
                )
                weekly = parseRankings(data)
            } catch let error as FantasyProsError where error.isQuotaIssue {
                hitQuota = true
                errors.append(error.localizedDescription)
                break
            } catch {
                // Soft
            }

            var newsItems: [FantasyProsNewsItem] = []
            if let data = try? await FantasyProsClient.shared.news() {
                newsItems = parseNews(data)
            }

            var ros = bestRos
            if ros.isEmpty {
                if let data = try? await FantasyProsClient.shared.consensusRankings(
                    season: trySeason, position: "ALL", type: "ROS", week: nil, scoring: scoring
                ) {
                    ros = parseRankings(data)
                }
            }

            var projs: [FantasyProsProjection] = []
            for pos in ["QB", "RB", "WR", "TE", "K", "DST"] {
                do {
                    let data = try await FantasyProsClient.shared.projections(
                        season: trySeason, week: week, position: pos, positions: nil, scoring: scoring
                    )
                    projs.append(contentsOf: parseProjections(data))
                } catch let error as FantasyProsError where error.isQuotaIssue {
                    hitQuota = true
                    errors.append(error.localizedDescription)
                    break seasonLoop
                } catch {
                    continue
                }
            }

            var resolvedWeekly = weekly
            if resolvedWeekly.isEmpty {
                for pos in ["QB", "RB", "WR", "TE"] {
                    do {
                        let data = try await FantasyProsClient.shared.consensusRankings(
                            season: trySeason, position: pos, type: nil, week: week, scoring: scoring
                        )
                        resolvedWeekly.append(contentsOf: parseRankings(data))
                    } catch let error as FantasyProsError where error.isQuotaIssue {
                        hitQuota = true
                        errors.append(error.localizedDescription)
                        break seasonLoop
                    } catch {
                        continue
                    }
                }
            }

            let newsItemsFinal = newsItems

            if !projs.isEmpty || !resolvedWeekly.isEmpty || !ros.isEmpty {
                bestWeekly = resolvedWeekly
                bestRos = ros
                bestProj = projs
                bestNews = newsItemsFinal
                usedSeason = trySeason
                break
            }
        }

        lastWasQuotaError = hitQuota

        if bestProj.isEmpty && bestWeekly.isEmpty && bestRos.isEmpty {
            if hitQuota {
                lastStatus = errors.last
                    ?? "FantasyPros rate limit / quota exceeded. Check your plan at fantasypros.com/api-data."
            } else if !errors.isEmpty {
                lastStatus = errors.joined(separator: " · ")
            } else {
                lastStatus = "Rankings returned empty for season \(season)"
            }
            return
        }

        self.weeklyRankings = bestWeekly
        self.rosRankings = bestRos
        self.projections = bestProj
        self.news = bestNews

        var byMFL: [String: FantasyProsProjection] = [:]
        var bySleeper: [String: FantasyProsProjection] = [:]
        var byKey: [String: FantasyProsProjection] = [:]
        var byLast: [String: FantasyProsProjection] = [:]

        await PlayerIDCrosswalk.shared.ensureLoaded()

        for p in bestProj {
            if let mfl = p.mflId, !mfl.isEmpty {
                byMFL[mfl] = p
                byMFL[MFLNameResolver.normalizePlayerId(mfl)] = p
            }
            if let sid = p.sleeperId, !sid.isEmpty {
                bySleeper[sid] = p
            }
            // DynastyProcess: FantasyPros id → Sleeper / MFL ids
            if !p.fpId.isEmpty, let link = await PlayerIDCrosswalk.shared.record(fantasyProsId: p.fpId) {
                if let sid = link.sleeperId { bySleeper[sid] = p }
                if let mfl = link.mflId {
                    byMFL[mfl] = p
                    byMFL[MFLNameResolver.normalizePlayerId(mfl)] = p
                }
            }
            byKey[searchKey(name: p.name, team: p.team, position: p.position)] = p
            let last = foldToken(splitName(p.name).1)
            byLast["\(last)|\(normalizePos(p.position))"] = p
        }

        // Fallback name map for any FP rows missing fantasypros_id in the crosswalk.
        await SleeperPlayerCatalog.shared.ensureLoaded()
        for p in bestProj {
            if let existing = p.sleeperId, bySleeper[existing] != nil { continue }
            if let s = await SleeperPlayerCatalog.shared.match(
                name: p.name, team: p.team, position: p.position
            ), bySleeper[s.playerId] == nil {
                bySleeper[s.playerId] = p
            }
        }
        self.byMFLId = byMFL
        self.bySleeperId = bySleeper
        self.bySearchKey = byKey
        self.byLastNamePos = byLast

        var weeklyKeys: [String: FantasyProsRanking] = [:]
        var weeklyBySleeper: [String: FantasyProsRanking] = [:]
        for r in bestWeekly {
            weeklyKeys[searchKey(name: r.name, team: r.team, position: r.position)] = r
            if !r.fpId.isEmpty, let link = await PlayerIDCrosswalk.shared.record(fantasyProsId: r.fpId),
               let sid = link.sleeperId {
                weeklyBySleeper[sid] = r
            } else if let s = await SleeperPlayerCatalog.shared.match(
                name: r.name, team: r.team, position: r.position
            ) {
                weeklyBySleeper[s.playerId] = r
            }
        }
        self.rankBySearchKey = weeklyKeys
        self.rankBySleeperId = weeklyBySleeper

        var rosKeys: [String: FantasyProsRanking] = [:]
        var rosBySleeper: [String: FantasyProsRanking] = [:]
        for r in bestRos {
            rosKeys[searchKey(name: r.name, team: r.team, position: r.position)] = r
            if !r.fpId.isEmpty, let link = await PlayerIDCrosswalk.shared.record(fantasyProsId: r.fpId),
               let sid = link.sleeperId {
                rosBySleeper[sid] = r
            } else if let s = await SleeperPlayerCatalog.shared.match(
                name: r.name, team: r.team, position: r.position
            ) {
                rosBySleeper[s.playerId] = r
            }
        }
        self.rosBySearchKey = rosKeys
        self.rosBySleeperId = rosBySleeper

        let crossStatus = await PlayerIDCrosswalk.shared.lastStatus ?? "crosswalk n/a"
        self.loadedWeek = week
        self.loadedSeason = usedSeason
        self.loadedAt = .now
        lastStatus = "Loaded \(bestProj.count) proj · \(bestWeekly.count) weekly · \(bestRos.count) ROS · \(bySleeper.count) Sleeper links (season \(usedSeason)) · \(crossStatus)"
        if hitQuota {
            lastStatus = (lastStatus ?? "") + " · partial (hit rate limit mid-load)"
            lastWasQuotaError = true
        }
    }

    /// Clear cache so the next ensureLoaded hits the network (e.g. after saving a new key).
    func reset() async {
        weeklyRankings = []
        rosRankings = []
        projections = []
        news = []
        byMFLId = [:]
        bySleeperId = [:]
        bySearchKey = [:]
        byLastNamePos = [:]
        rankBySearchKey = [:]
        rosBySearchKey = [:]
        rankBySleeperId = [:]
        rosBySleeperId = [:]
        loadedWeek = nil
        loadedSeason = nil
        loadedAt = nil
        lastStatus = nil
        lastWasQuotaError = false
        await FantasyProsClient.shared.clearCache()
    }

    func projection(for player: RosterPlayer) async -> FantasyProsProjection? {
        lookupProjection(player)
    }

    func weeklyRank(for player: RosterPlayer) async -> FantasyProsRanking? {
        if let hit = rankBySleeperId[player.playerId] { return hit }
        let key = searchKey(name: player.name, team: player.team, position: player.position)
        if let hit = rankBySearchKey[key] { return hit }
        return matchRanking(weeklyRankings, name: player.name, team: player.team, position: player.position)
    }

    func rosRank(for player: RosterPlayer) async -> FantasyProsRanking? {
        if let hit = rosBySleeperId[player.playerId] { return hit }
        let key = searchKey(name: player.name, team: player.team, position: player.position)
        if let hit = rosBySearchKey[key] { return hit }
        return matchRanking(rosRankings, name: player.name, team: player.team, position: player.position)
    }

    func newsItems(for playerName: String, limit: Int = 4) async -> [FantasyProsNewsItem] {
        let needle = playerName.lowercased()
        let (first, last) = splitName(playerName)
        let hits = news.filter { item in
            let blob = (item.playerName ?? "") + " " + item.title + " " + item.summary
            let lower = blob.lowercased()
            if lower.contains(needle) { return true }
            if !last.isEmpty, lower.contains(last.lowercased()) { return true }
            if !first.isEmpty, lower.contains(first.lowercased()), lower.contains(last.lowercased()) {
                return true
            }
            return false
        }
        return Array(hits.prefix(limit))
    }

    func news(for playerName: String, limit: Int = 3) async -> [String] {
        await newsItems(for: playerName, limit: limit).map { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = stripHTML(item.summary)
            if summary.isEmpty { return title }
            return "\(title) — \(summary)"
        }
    }

    private func stripHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func annotateProjections(_ players: [RosterPlayer], preferFantasyPros: Bool) async -> [RosterPlayer] {
        let scoring = FantasyProsClient.scoring
        return players.map { player in
            var p = player
            guard let proj = lookupProjection(player),
                  let pts = proj.points(for: scoring)
            else { return p }
            if preferFantasyPros || p.projectedPoints == nil {
                p.projectedPoints = pts
            }
            return p
        }
    }

    func enrichDetail(_ base: PlayerDetail, player: RosterPlayer) async -> PlayerDetail {
        var d = base
        if let weekly = await weeklyRank(for: player) {
            d.fpRankECR = weekly.rankECR.map(String.init)
            d.fpPosRank = weekly.posRank
            d.fpTier = weekly.tier.map(String.init)
        }
        if let ros = await rosRank(for: player) {
            d.fpRosRank = ros.rankECR.map(String.init)
            d.fpRosPosRank = ros.posRank
        }
        if let proj = await projection(for: player),
           let pts = proj.points(for: FantasyProsClient.scoring) {
            d.fpProjection = String(format: "%.1f", pts)
        }
        let fpNews = await newsItems(for: player.name, limit: 4)
        if !fpNews.isEmpty {
            let mapped: [PlayerNewsItem] = fpNews.map { item in
                PlayerNewsItem(
                    id: item.id,
                    title: item.title,
                    body: stripHTML(item.summary),
                    linkURL: item.link.flatMap { URL(string: $0) },
                    source: "FantasyPros"
                )
            }
            var byId = Dictionary(uniqueKeysWithValues: d.newsItems.map { ($0.id, $0) })
            for item in mapped { byId[item.id] = item }
            d.newsItems = Array(byId.values)
            d.newsHeadlines = d.newsItems.map { item in
                item.body.isEmpty ? item.title : "\(item.title) — \(item.body)"
            }
        }
        return d
    }

    func contextLines(for players: [RosterPlayer], limit: Int = 24) async -> String {
        guard isConfigured else {
            return "FANTASYPROS: (no API key — add one in Settings → FantasyPros)"
        }
        if let lastStatus, !hasData {
            return "FANTASYPROS: \(lastStatus)"
        }
        let scoring = FantasyProsClient.scoring
        var lines: [String] = [
            "FANTASYPROS INTEL (scoring=\(scoring.rawValue)):"
        ]
        var count = 0
        for p in players {
            guard count < limit else { break }
            let weekly = await weeklyRank(for: p)
            let ros = await rosRank(for: p)
            let proj = await projection(for: p)
            let pts = proj?.points(for: scoring)
            if weekly == nil, ros == nil, pts == nil { continue }
            var bits: [String] = ["\(p.name) \(p.position) \(p.team)"]
            if let ecr = weekly?.rankECR { bits.append("weeklyECR=#\(ecr)") }
            if let pos = weekly?.posRank { bits.append("pos=\(pos)") }
            if let tier = weekly?.tier { bits.append("tier=\(tier)") }
            if let rosECR = ros?.rankECR { bits.append("rosECR=#\(rosECR)") }
            if let pts {
                bits.append("proj=\(String(format: "%.1f", pts))")
            }
            lines.append("- " + bits.joined(separator: " · "))
            count += 1
        }
        if count == 0 {
            lines.append("(no FantasyPros matches for this roster)")
        }
        if !rosRankings.isEmpty {
            lines.append("FP ROS TOP 15:")
            for r in rosRankings.prefix(15) {
                let pos = r.posRank ?? r.position
                lines.append("- #\(r.rankECR ?? 0) \(r.name) \(pos) \(r.team)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Agent-chat tool: consensus rankings for a position (weekly or ROS).
    func rankingsToolText(
        position: String,
        scope: String,
        limit: Int
    ) async -> String {
        guard isConfigured else {
            return "FANTASYPROS: (no API key — add one in Settings → FantasyPros)"
        }
        if let lastStatus, !hasData {
            return "FANTASYPROS: \(lastStatus)"
        }
        let pos = position.uppercased()
        let lim = min(40, max(1, limit))
        let source: [FantasyProsRanking]
        let label: String
        if scope.lowercased() == "ros" {
            source = rosRankings
            label = "ROS"
        } else {
            source = weeklyRankings
            label = "WEEKLY"
        }
        let filtered: [FantasyProsRanking]
        if pos == "ALL" || pos.isEmpty {
            filtered = source
        } else {
            filtered = source.filter {
                $0.position.uppercased().contains(pos)
                    || ($0.posRank ?? "").uppercased().hasPrefix(pos)
            }
        }
        guard !filtered.isEmpty else {
            return "FANTASYPROS \(label) rankings: no rows for position=\(pos.isEmpty ? "ALL" : pos). status=\(lastStatus ?? "ok")"
        }
        var lines = [
            "FANTASYPROS \(label) RANKINGS position=\(pos.isEmpty ? "ALL" : pos) scoring=\(FantasyProsClient.scoring.rawValue) (top \(min(lim, filtered.count))):"
        ]
        for r in filtered.prefix(lim) {
            let ecr = r.rankECR.map(String.init) ?? "?"
            let posRank = r.posRank ?? r.position
            let tier = r.tier.map { " tier:\($0)" } ?? ""
            lines.append("#\(ecr) \(r.name) \(posRank) \(r.team)\(tier)")
        }
        return lines.joined(separator: "\n")
    }

    /// Agent-chat tool: weekly projections for a position.
    func projectionsToolText(position: String, limit: Int) async -> String {
        guard isConfigured else {
            return "FANTASYPROS: (no API key — add one in Settings → FantasyPros)"
        }
        if let lastStatus, !hasData {
            return "FANTASYPROS: \(lastStatus)"
        }
        let pos = position.uppercased()
        let lim = min(40, max(1, limit))
        let scoring = FantasyProsClient.scoring
        let filtered: [FantasyProsProjection]
        if pos == "ALL" || pos.isEmpty {
            filtered = projections
        } else {
            filtered = projections.filter { $0.position.uppercased().contains(pos) }
        }
        let ranked = filtered.sorted {
            ($0.points(for: scoring) ?? -1) > ($1.points(for: scoring) ?? -1)
        }
        guard !ranked.isEmpty else {
            return "FANTASYPROS projections: none for position=\(pos.isEmpty ? "ALL" : pos)."
        }
        var lines = [
            "FANTASYPROS WEEKLY PROJECTIONS position=\(pos.isEmpty ? "ALL" : pos) scoring=\(scoring.rawValue):"
        ]
        for p in ranked.prefix(lim) {
            let pts = p.points(for: scoring).map { String(format: "%.1f", $0) } ?? "-"
            lines.append("\(p.name) \(p.position) \(p.team) proj:\(pts)")
        }
        return lines.joined(separator: "\n")
    }

    /// Agent-chat tool: news wire, optionally filtered by player name.
    func newsToolText(playerName: String?, limit: Int) async -> String {
        guard isConfigured else {
            return "FANTASYPROS: (no API key — add one in Settings → FantasyPros)"
        }
        let lim = min(15, max(1, limit))
        let items: [FantasyProsNewsItem]
        if let playerName, !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = await newsItems(for: playerName, limit: lim)
        } else {
            items = Array(news.prefix(lim))
        }
        guard !items.isEmpty else {
            if let playerName, !playerName.isEmpty {
                return "FANTASYPROS news: no items matched \"\(playerName)\"."
            }
            return "FANTASYPROS news: empty (quota or no wire loaded). \(lastStatus ?? "")"
        }
        var lines = ["FANTASYPROS NEWS (up to \(items.count)):"]
        for item in items {
            let who = item.playerName.map { "[\($0)] " } ?? ""
            let body = stripHTML(item.summary)
            if body.isEmpty {
                lines.append("- \(who)\(item.title)")
            } else {
                lines.append("- \(who)\(item.title) — \(body)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Agent-chat tool: match FantasyPros intel by player display names (roster or FA).
    func researchByNames(_ names: [String], limitPerPlayer: Int = 3) async -> String {
        guard isConfigured else {
            return "FANTASYPROS: (no API key — add one in Settings → FantasyPros)"
        }
        if let lastStatus, !hasData {
            return "FANTASYPROS: \(lastStatus)"
        }
        let scoring = FantasyProsClient.scoring
        var lines = ["FANTASYPROS RESEARCH (by name, scoring=\(scoring.rawValue)):"]
        var hitCount = 0
        for raw in names.prefix(10) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let stub = RosterPlayer(
                playerId: "name:\(name)",
                name: name,
                position: "",
                team: "",
                status: "fa"
            )
            let weekly = await weeklyRank(for: stub)
            let ros = await rosRank(for: stub)
            let proj = await projection(for: stub)
            let newsHits = await news(for: name, limit: limitPerPlayer)
            if weekly == nil, ros == nil, proj == nil, newsHits.isEmpty {
                lines.append("- \(name): (no FantasyPros match)")
                continue
            }
            hitCount += 1
            var bits = [name]
            if let ecr = weekly?.rankECR { bits.append("weeklyECR=#\(ecr)") }
            if let pos = weekly?.posRank { bits.append("pos=\(pos)") }
            if let tier = weekly?.tier { bits.append("tier=\(tier)") }
            if let rosECR = ros?.rankECR { bits.append("rosECR=#\(rosECR)") }
            if let pts = proj?.points(for: scoring) {
                bits.append("proj=\(String(format: "%.1f", pts))")
            }
            lines.append("- " + bits.joined(separator: " · "))
            for n in newsHits {
                lines.append("  news: \(n)")
            }
        }
        if hitCount == 0 {
            lines.append("(no matches — check spelling or wait for FantasyPros reload)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    private func lookupProjection(_ player: RosterPlayer) -> FantasyProsProjection? {
        // Sleeper leagues use Sleeper ids — never treat them as MFL ids (collision risk).
        if let sleeperHit = bySleeperId[player.playerId] {
            return sleeperHit
        }
        // Exact MFL id only (no zero-pad normalize on the query id — that maps Sleeper "86" → MFL "0086").
        if let mflHit = byMFLId[player.playerId] {
            return mflHit
        }
        let key = searchKey(name: player.name, team: player.team, position: player.position)
        return bySearchKey[key] ?? matchProjection(name: player.name, team: player.team, position: player.position)
    }

    private func parseRankings(_ data: Data) -> [FantasyProsRanking] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["players"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { row in
            let name = (row["player_name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let fpId = stringValue(row["player_id"]) ?? ""
            return FantasyProsRanking(
                fpId: fpId,
                name: name,
                team: (row["player_team_id"] as? String) ?? "",
                position: (row["player_position_id"] as? String)
                    ?? (row["player_positions"] as? String)
                    ?? "",
                rankECR: intValue(row["rank_ecr"]),
                posRank: row["pos_rank"] as? String,
                tier: intValue(row["tier"]),
                rankMin: intValue(row["rank_min"]),
                rankMax: intValue(row["rank_max"]),
                rankAve: doubleValue(row["rank_ave"])
            )
        }
    }

    private func parseProjections(_ data: Data) -> [FantasyProsProjection] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["players"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { row in
            let name = (row["name"] as? String) ?? (row["player_name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let stats = statsMap(row["stats"])
            let mflRaw = stringValue(row["mflid"]) ?? stringValue(row["mfl_id"])
            let sleeperRaw = stringValue(row["sleeper_id"])
                ?? stringValue(row["sleeperid"])
                ?? stringValue(row["sleeperId"])
            return FantasyProsProjection(
                fpId: stringValue(row["fpid"]) ?? stringValue(row["player_id"]) ?? "",
                mflId: mflRaw,
                sleeperId: sleeperRaw,
                name: name,
                team: (row["team_id"] as? String) ?? (row["player_team_id"] as? String) ?? "",
                position: (row["position_id"] as? String) ?? (row["player_position_id"] as? String) ?? "",
                points: doubleValue(stats["points"]),
                pointsPPR: doubleValue(stats["points_ppr"]),
                pointsHalf: doubleValue(stats["points_half"])
            )
        }
    }

    /// API docs disagree (object vs array) — accept both.
    private func statsMap(_ any: Any?) -> [String: Any] {
        if let d = any as? [String: Any] { return d }
        if let arr = any as? [[String: Any]], let first = arr.first { return first }
        return [:]
    }

    private func parseNews(_ data: Data) -> [FantasyProsNewsItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let arr = (root["items"] as? [[String: Any]])
            ?? (root["news"] as? [[String: Any]])
            ?? []
        return arr.compactMap { row in
            let title = (row["title"] as? String) ?? ""
            let desc = (row["desc"] as? String)
                ?? (row["description"] as? String)
                ?? (row["summary"] as? String)
                ?? ""
            guard !title.isEmpty || !desc.isEmpty else { return nil }
            let playerName = (row["player"] as? [String: Any])?["name"] as? String
                ?? row["player_name"] as? String
            let link = Self.normalizedURLString(
                (row["link"] as? String)
                    ?? (row["url"] as? String)
                    ?? (row["player_page_url"] as? String)
            )
            return FantasyProsNewsItem(
                playerName: playerName,
                title: title.isEmpty ? String(desc.prefix(80)) : title,
                summary: desc,
                link: link
            )
        }
    }

    private static func normalizedURLString(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        }
        return s
    }

    private func matchProjection(name: String, team: String, position: String) -> FantasyProsProjection? {
        let (first, last) = splitName(name)
        let lastFold = foldToken(last)
        let firstFold = foldToken(first)
        let pos = normalizePos(position)
        let teamKey = NFLScheduleService.normalizeTeam(team)

        if let hit = byLastNamePos["\(lastFold)|\(pos)"] {
            let hitTeam = NFLScheduleService.normalizeTeam(hit.team)
            if teamKey.isEmpty || hitTeam == teamKey || teamAliasesMatch(teamKey, hitTeam) {
                return hit
            }
        }

        let byLastPos = projections.first {
            foldToken(lastName(of: $0.name)) == lastFold
                && (pos.isEmpty || normalizePos($0.position) == pos)
                && (teamKey.isEmpty
                    || NFLScheduleService.normalizeTeam($0.team) == teamKey
                    || teamAliasesMatch(teamKey, NFLScheduleService.normalizeTeam($0.team)))
        }
        if let byLastPos { return byLastPos }

        return projections.first {
            foldToken(lastName(of: $0.name)) == lastFold
                && (firstFold.isEmpty || foldToken($0.name).contains(firstFold))
        }
    }

    private func matchRanking(_ list: [FantasyProsRanking], name: String, team: String, position: String) -> FantasyProsRanking? {
        let (first, last) = splitName(name)
        let lastFold = foldToken(last)
        let firstFold = foldToken(first)
        let pos = normalizePos(position)
        let teamKey = NFLScheduleService.normalizeTeam(team)
        return list.first {
            foldToken(lastName(of: $0.name)) == lastFold
                && (pos.isEmpty || normalizePos($0.position) == pos)
                && (teamKey.isEmpty
                    || NFLScheduleService.normalizeTeam($0.team) == teamKey
                    || teamAliasesMatch(teamKey, NFLScheduleService.normalizeTeam($0.team)))
        } ?? list.first {
            foldToken(lastName(of: $0.name)) == lastFold
                && (firstFold.isEmpty || foldToken($0.name).contains(firstFold))
        }
    }

    private func lastName(of name: String) -> String {
        splitName(name).1
    }

    private func searchKey(name: String, team: String, position: String) -> String {
        let (first, last) = splitName(name)
        return "\(foldToken(last))|\(foldToken(first))|\(normalizePos(position))|\(NFLScheduleService.normalizeTeam(team))"
    }

    /// Sleeper uses DEF; FantasyPros uses DST.
    private func normalizePos(_ position: String) -> String {
        let p = position.uppercased()
        if p == "DEF" || p == "D/ST" || p == "D" { return "DST" }
        return p
    }

    /// Fold names for matching (Ja'Marr / Amon-Ra / Jr. suffixes).
    private func foldToken(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let stripped = folded
            .replacingOccurrences(of: #"\b(jr|sr|ii|iii|iv|v)\b\.?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        return stripped
    }

    private func splitName(_ raw: String) -> (String, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let last = parts.first ?? trimmed
            let first = parts.count > 1 ? parts[1] : ""
            return (first, last)
        }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let last = parts.last else { return ("", trimmed) }
        let first = parts.dropLast().joined(separator: " ")
        return (first, last)
    }

    private func teamAliasesMatch(_ a: String, _ b: String) -> Bool {
        let map: [String: String] = [
            "GBP": "GB", "GB": "GBP",
            "KCC": "KC", "KC": "KCC",
            "NEP": "NE", "NE": "NEP",
            "TBB": "TB", "TB": "TBB",
            "SFO": "SF", "SF": "SFO",
            "NOS": "NO", "NO": "NOS",
            "LVR": "LV", "LV": "LVR",
            "JAC": "JAX", "JAX": "JAC"
        ]
        if a == b { return true }
        return map[a] == b || map[b] == a
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(Int(d)) }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
