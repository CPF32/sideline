import Foundation

/// League-relative roster strength + draft pick assets for waiver/trade agents.
struct LeagueIntelSnapshot: Hashable {
    var myFranchiseId: String
    var teamCount: Int
    var positions: [PositionalStrengthRow]
    var myPicks: [DraftPickAsset]
    var leaguePicksByFranchise: [String: [DraftPickAsset]]
    var franchiseNames: [String: String]
    var syncedAt: Date

    var summaryForLLM: String {
        var lines: [String] = []
        lines.append("POSITIONAL STRENGTH VS LEAGUE (\(teamCount) teams) — YTD fantasy points of top starter-slot players at each position:")
        if positions.isEmpty {
            lines.append("(unavailable)")
        } else {
            for row in positions {
                let mine = String(format: "%.1f", row.myScore)
                let avg = String(format: "%.1f", row.leagueAverage)
                let depth = "depth \(row.myDepth)"
                let top = row.topPlayers.isEmpty
                    ? ""
                    : " | mine: " + row.topPlayers.map { "\($0.name) \(String(format: "%.1f", $0.points))" }.joined(separator: ", ")
                lines.append(
                    "- \(row.position): \(row.label) · you \(mine) (rank \(row.rank)/\(teamCount)) · league avg \(avg) · \(depth)\(top)"
                )
            }
            let weak = positions.filter { $0.label == "WEAK" }.map(\.position)
            let strong = positions.filter { $0.label == "STRONG" }.map(\.position)
            if !weak.isEmpty {
                lines.append("WEAK positions (prioritize adds / receive in trades): \(weak.joined(separator: ", "))")
            }
            if !strong.isEmpty {
                lines.append("STRONG positions (candidates to drop / trade away / hold): \(strong.joined(separator: ", "))")
            }
        }

        lines.append("")
        lines.append("DRAFT PICK ASSETS (use pickId like FP_xxxx_year_round in trade payloads):")
        if myPicks.isEmpty {
            lines.append("Your picks: (none loaded — redraft leagues may have no future picks)")
        } else {
            lines.append("Your picks (\(myPicks.count)):")
            for p in myPicks.sorted() {
                lines.append("- \(p.pickId) | \(p.displayLabel)")
            }
        }
        let others = leaguePicksByFranchise
            .filter { MFLNameResolver.normalizeFranchiseId($0.key) != MFLNameResolver.normalizeFranchiseId(myFranchiseId) }
            .sorted { (franchiseNames[$0.key] ?? $0.key) < (franchiseNames[$1.key] ?? $1.key) }
        if !others.isEmpty {
            lines.append("Other teams' picks (for trade targets):")
            for (fid, picks) in others.prefix(12) {
                let name = franchiseNames[fid] ?? fid
                let sample = picks.sorted().prefix(6).map(\.displayLabel).joined(separator: "; ")
                lines.append("- \(name) (\(fid)): \(sample)\(picks.count > 6 ? "…" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct PositionalStrengthRow: Hashable {
    let position: String
    /// Sum of top-N YTD points (N = starter slots for that position).
    let myScore: Double
    let leagueAverage: Double
    let rank: Int // 1 = strongest
    let myDepth: Int
    let label: String // WEAK | AVERAGE | STRONG
    let topPlayers: [NamedPoints]
}

struct NamedPoints: Hashable {
    let name: String
    let points: Double
}

struct DraftPickAsset: Hashable, Comparable {
    let pickId: String
    let year: Int
    let round: Int
    let ownerFranchiseId: String
    let originalFranchiseId: String?

    var displayLabel: String {
        if let orig = originalFranchiseId,
           MFLNameResolver.normalizeFranchiseId(orig) != MFLNameResolver.normalizeFranchiseId(ownerFranchiseId) {
            return "\(year) R\(round) (orig \(orig))"
        }
        return "\(year) R\(round)"
    }

    static func < (lhs: DraftPickAsset, rhs: DraftPickAsset) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.round != rhs.round { return lhs.round < rhs.round }
        return lhs.pickId < rhs.pickId
    }
}

enum LeagueStrengthService {
    static func load(
        linked: LinkedFranchise,
        myFranchiseId: String,
        rules: LeagueRules?,
        franchiseNames: [String: String] = [:]
    ) async throws -> LeagueIntelSnapshot {
        let client = MFLClient.shared
        async let rostersData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "rosters",
            leagueId: linked.leagueId, cacheTTL: 120
        )
        async let playersData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "players",
            leagueId: linked.leagueId, extra: ["DETAILS": "1"], cacheTTL: 86_400
        )
        async let ytdData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "playerScores",
            leagueId: linked.leagueId, extra: ["W": "YTD"], cacheTTL: 300
        )
        async let picksData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "futureDraftPicks",
            leagueId: linked.leagueId, cacheTTL: 300
        )
        async let leagueData = try? await client.exportJSON(
            host: linked.host, season: linked.season, type: "league",
            leagueId: linked.leagueId, cacheTTL: 600
        )

        let (rostersRaw, playersRaw, ytdRaw, picksRaw, leagueRaw) = await (
            rostersData, playersData, ytdData, picksData, leagueData
        )

        var names = franchiseNames
        if let leagueRaw {
            let parsed = MFLNameResolver.parseFranchiseNames(from: leagueRaw)
            for (k, v) in parsed { names[k] = v }
        }

        let playerMap = playersRaw.map { MFLNameResolver.parsePlayerNames(from: $0) } ?? [:]
        let scoreMap = ytdRaw.map { parseScoreMap($0) } ?? [:]
        let rosterByFranchise = rostersRaw.map { parseAllRosters($0, players: playerMap) } ?? [:]
        let slotsNeeded = starterNeedsByPosition(rules: rules)

        let teamCount = max(1, rosterByFranchise.count)
        var franchiseScores: [String: [String: Double]] = [:] // franchise → pos → score
        var franchiseDepth: [String: [String: Int]] = [:]
        var myTopPlayers: [String: [NamedPoints]] = [:]

        for (fid, players) in rosterByFranchise {
            let active = players.filter { $0.status != "ir" && $0.status != "taxi" }
            var byPos: [String: [(name: String, pts: Double)]] = [:]
            for p in active {
                let pos = normalizePos(p.position)
                guard slotsNeeded[pos] != nil
                        || RosterPositionGrouping.displayPositionOrder(rules: rules).contains(pos)
                else { continue }
                let pts = scoreMap[p.playerId] ?? scoreMap[MFLNameResolver.normalizePlayerId(p.playerId)] ?? 0
                byPos[pos, default: []].append((p.name, pts))
            }
            var scores: [String: Double] = [:]
            var depths: [String: Int] = [:]
            for (pos, list) in byPos {
                let sorted = list.sorted { $0.pts > $1.pts }
                depths[pos] = sorted.count
                let n = max(1, slotsNeeded[pos] ?? 1)
                let top = Array(sorted.prefix(n))
                scores[pos] = top.reduce(0) { $0 + $1.pts }
                if MFLNameResolver.normalizeFranchiseId(fid) == MFLNameResolver.normalizeFranchiseId(myFranchiseId) {
                    myTopPlayers[pos] = top.map { NamedPoints(name: $0.name, points: $0.pts) }
                }
            }
            franchiseScores[fid] = scores
            franchiseDepth[fid] = depths
        }

        let myKey = rosterByFranchise.keys.first {
            MFLNameResolver.normalizeFranchiseId($0) == MFLNameResolver.normalizeFranchiseId(myFranchiseId)
        } ?? myFranchiseId

        let positionsToRate = orderedPositions(
            slotsNeeded: slotsNeeded,
            myScores: franchiseScores[myKey] ?? [:],
            rules: rules
        )
        var rows: [PositionalStrengthRow] = []
        for pos in positionsToRate {
            var teamVals: [(String, Double)] = []
            for (fid, scores) in franchiseScores {
                teamVals.append((fid, scores[pos] ?? 0))
            }
            teamVals.sort { $0.1 > $1.1 }
            let myScore = franchiseScores[myKey]?[pos] ?? 0
            let avg = teamVals.isEmpty ? 0 : teamVals.map(\.1).reduce(0, +) / Double(teamVals.count)
            let rank = (teamVals.firstIndex { MFLNameResolver.normalizeFranchiseId($0.0) == MFLNameResolver.normalizeFranchiseId(myKey) } ?? teamVals.count) + 1
            let depth = franchiseDepth[myKey]?[pos] ?? 0
            let label = strengthLabel(rank: rank, teamCount: teamCount, myScore: myScore, average: avg, depth: depth, slots: slotsNeeded[pos] ?? 1)
            rows.append(PositionalStrengthRow(
                position: pos,
                myScore: myScore,
                leagueAverage: avg,
                rank: rank,
                myDepth: depth,
                label: label,
                topPlayers: myTopPlayers[pos] ?? []
            ))
        }

        let picksByFranchise = picksRaw.map { parseFutureDraftPicks($0) } ?? [:]
        let myPicks = picksByFranchise.first {
            MFLNameResolver.normalizeFranchiseId($0.key) == MFLNameResolver.normalizeFranchiseId(myFranchiseId)
        }?.value ?? []

        return LeagueIntelSnapshot(
            myFranchiseId: myFranchiseId,
            teamCount: teamCount,
            positions: rows,
            myPicks: myPicks,
            leaguePicksByFranchise: picksByFranchise,
            franchiseNames: names,
            syncedAt: .now
        )
    }

    // MARK: - Helpers

    private static func strengthLabel(
        rank: Int,
        teamCount: Int,
        myScore: Double,
        average: Double,
        depth: Int,
        slots: Int
    ) -> String {
        if depth < slots { return "WEAK" }
        let topThird = max(1, Int(ceil(Double(teamCount) / 3.0)))
        let bottomThirdStart = teamCount - topThird + 1
        if rank <= topThird || (average > 0 && myScore >= average * 1.15) { return "STRONG" }
        if rank >= bottomThirdStart || (average > 0 && myScore <= average * 0.85) { return "WEAK" }
        return "AVERAGE"
    }

    private static func starterNeedsByPosition(rules: LeagueRules?) -> [String: Int] {
        var needs: [String: Int] = [:]
        guard let slots = rules?.starterSlots, !slots.isEmpty else {
            // Sensible IDP/offense defaults when rules missing.
            return ["QB": 1, "RB": 2, "WR": 2, "TE": 1, "PK": 1]
        }
        for slot in slots {
            let name = slot.name.uppercased()
            if name.contains("/") { continue } // flex — counted via discrete positions
            let pos = normalizePos(name)
            needs[pos, default: 0] += max(slot.min, slot.max)
        }
        if needs.isEmpty {
            return ["QB": 1, "RB": 2, "WR": 2, "TE": 1]
        }
        return needs
    }

    private static func orderedPositions(
        slotsNeeded: [String: Int],
        myScores: [String: Double],
        rules: LeagueRules?
    ) -> [String] {
        var keys = Set(slotsNeeded.keys).union(myScores.keys)
        var ordered: [String] = []
        for p in RosterPositionGrouping.displayPositionOrder(rules: rules) where keys.contains(p) {
            ordered.append(p)
            keys.remove(p)
        }
        ordered.append(contentsOf: keys.sorted())
        return ordered
    }

    private static func normalizePos(_ raw: String) -> String {
        let p = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch p {
        case "K", "PK": return "PK"
        case "DEF", "DF", "DST", "D/ST": return "Def"
        case "HB", "FB": return "RB"
        default: return p
        }
    }

    private static func parseScoreMap(_ data: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["playerScores"] as? [String: Any])?["playerScore"]
            ?? root["playerScore"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }
        var map: [String: Double] = [:]
        for row in rows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let score: Double?
            if let s = row["score"] as? Double { score = s }
            else if let s = row["score"] as? String { score = Double(s) }
            else if let s = row["score"] as? Int { score = Double(s) }
            else { score = nil }
            guard let score else { continue }
            let nid = MFLNameResolver.normalizePlayerId(id)
            map[nid] = score
            map[id] = score
        }
        return map
    }

    private static func parseAllRosters(
        _ data: Data,
        players: [String: (name: String, pos: String, team: String)]
    ) -> [String: [RosterPlayer]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let franchisesAny = (root["rosters"] as? [String: Any])?["franchise"] ?? root["franchise"]
        let franchises: [[String: Any]]
        if let arr = franchisesAny as? [[String: Any]] { franchises = arr }
        else if let one = franchisesAny as? [String: Any] { franchises = [one] }
        else { return [:] }

        var out: [String: [RosterPlayer]] = [:]
        for franchise in franchises {
            guard let fid = franchise["id"] as? String ?? (franchise["id"] as? Int).map(String.init) else { continue }
            var list: [RosterPlayer] = []
            let playerAny = franchise["player"]
            if let arr = playerAny as? [[String: Any]] {
                for row in arr {
                    guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
                    let statusCode = (row["status"] as? String)?.uppercased() ?? ""
                    let meta = players[id] ?? players[MFLNameResolver.normalizePlayerId(id)]
                    list.append(RosterPlayer(
                        playerId: MFLNameResolver.normalizePlayerId(id),
                        name: meta?.name ?? id,
                        position: meta?.pos ?? (row["position"] as? String ?? ""),
                        team: meta?.team ?? "",
                        status: statusFromCode(statusCode)
                    ))
                }
            } else if let csv = playerAny as? String {
                for token in csv.split(separator: ",") {
                    let parts = token.split(separator: "_")
                    guard let idPart = parts.first else { continue }
                    let id = MFLNameResolver.normalizePlayerId(String(idPart))
                    let statusCode = parts.count > 1 ? String(parts[1]).uppercased() : ""
                    let meta = players[id]
                    list.append(RosterPlayer(
                        playerId: id,
                        name: meta?.name ?? id,
                        position: meta?.pos ?? "",
                        team: meta?.team ?? "",
                        status: statusFromCode(statusCode)
                    ))
                }
            }
            out[fid] = list
        }
        return out
    }

    private static func statusFromCode(_ code: String) -> String {
        switch code {
        case "S", "STARTER": return "starter"
        case "IR", "INJURED_RESERVE": return "ir"
        case "TAXI", "TAXI_SQUAD": return "taxi"
        default: return "bench"
        }
    }

    private static func parseFutureDraftPicks(_ data: Data) -> [String: [DraftPickAsset]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let franchisesAny = (root["futureDraftPicks"] as? [String: Any])?["franchise"]
            ?? root["franchise"]
        let franchises: [[String: Any]]
        if let arr = franchisesAny as? [[String: Any]] { franchises = arr }
        else if let one = franchisesAny as? [String: Any] { franchises = [one] }
        else { return [:] }

        var out: [String: [DraftPickAsset]] = [:]
        for franchise in franchises {
            guard let fid = franchise["id"] as? String ?? (franchise["id"] as? Int).map(String.init) else { continue }
            let pickAny = franchise["futureDraftPick"]
            let pickRows: [[String: Any]]
            if let arr = pickAny as? [[String: Any]] { pickRows = arr }
            else if let one = pickAny as? [String: Any] { pickRows = [one] }
            else { continue }

            var picks: [DraftPickAsset] = []
            for row in pickRows {
                let year: Int
                if let y = row["year"] as? Int { year = y }
                else if let y = row["year"] as? String, let v = Int(y) { year = v }
                else { continue }
                let round: Int
                if let r = row["round"] as? Int { round = r }
                else if let r = row["round"] as? String, let v = Int(r) { round = v }
                else { continue }
                let original = row["originalPickFor"] as? String
                    ?? (row["originalPickFor"] as? Int).map(String.init)
                let origPad = paddedFranchise(original ?? fid)
                let pickId = "FP_\(origPad)_\(year)_\(round)"
                picks.append(DraftPickAsset(
                    pickId: pickId,
                    year: year,
                    round: round,
                    ownerFranchiseId: fid,
                    originalFranchiseId: original
                ))
            }
            if !picks.isEmpty {
                out[fid] = picks
            }
        }
        return out
    }

    private static func paddedFranchise(_ id: String) -> String {
        let digits = id.filter(\.isNumber)
        guard !digits.isEmpty else { return id }
        if digits.count >= 4 { return digits }
        return String(repeating: "0", count: 4 - digits.count) + digits
    }
}
