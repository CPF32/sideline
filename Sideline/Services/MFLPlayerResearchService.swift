import Foundation

/// Pulls MFL playerProfile (+ ranks/trending when available) for recommendation analysis
/// and the on-roster player detail sheet.
///
/// Note: MFL does **not** expose third-party injury/news wire copy through the public API.
/// We surface bio (age/height/weight/ADP), MFL ranks/trending, and the league `injuries` feed.
enum MFLPlayerResearchService {
    static func fetchDetail(
        playerId: String,
        linked: LinkedFranchise
    ) async -> PlayerDetail {
        let nid = MFLNameResolver.normalizePlayerId(playerId)
        let map = await loadDetails(playerIds: [nid], linked: linked, maxPlayers: 1)
        return map[nid] ?? map[playerId] ?? PlayerDetail(
            playerId: nid,
            name: nil,
            age: nil,
            dob: nil,
            height: nil,
            weight: nil,
            adp: nil,
            mflRank: nil,
            topAddsPct: nil,
            injury: nil,
            newsHeadlines: []
        )
    }

    static func summarize(
        playerIds: [String],
        linked: LinkedFranchise,
        maxPlayers: Int = 8
    ) async -> String {
        let ids = Array(
            playerIds
                .map { MFLNameResolver.normalizePlayerId($0) }
                .filter { !$0.isEmpty && $0 != "0000" }
                .uniqued()
                .prefix(maxPlayers)
        )
        guard !ids.isEmpty else { return "No player ids provided for research." }

        let details = await loadDetails(playerIds: ids, linked: linked, maxPlayers: maxPlayers)
        var blocks: [String] = [
            "MFL PLAYER RESEARCH (bio / rank / injury status — MFL has no news wire):"
        ]
        for id in ids {
            let p = details[id] ?? details[MFLNameResolver.normalizePlayerId(id)]
            var lines: [String] = ["PLAYER \(id)"]
            if let name = p?.name, !name.isEmpty { lines.append("name=\(name)") }
            if let age = p?.age { lines.append("age=\(age)") }
            if let dob = p?.dob { lines.append("dob=\(dob)") }
            if let h = p?.height { lines.append("height=\(h)") }
            if let w = p?.weight { lines.append("weight=\(w)") }
            if let adp = p?.adp, !adp.isEmpty, adp.uppercased() != "N/A" {
                lines.append("adp=\(adp)")
            }
            if let rank = p?.mflRank { lines.append("mflRank=\(rank)") }
            if let addPct = p?.topAddsPct { lines.append("topAddsPct=\(addPct)") }
            if let inj = p?.injury { lines.append("injury=\(inj)") }
            if let news = p?.newsHeadlines, !news.isEmpty {
                lines.append("notes=" + news.prefix(3).joined(separator: " | "))
            }
            if lines.count == 1 {
                lines.append("(no MFL profile details returned)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Load

    private static func loadDetails(
        playerIds: [String],
        linked: LinkedFranchise,
        maxPlayers: Int
    ) async -> [String: PlayerDetail] {
        let ids = Array(
            playerIds
                .map { MFLNameResolver.normalizePlayerId($0) }
                .filter { !$0.isEmpty && $0 != "0000" }
                .uniqued()
                .prefix(maxPlayers)
        )
        guard !ids.isEmpty else { return [:] }
        let idList = ids.joined(separator: ",")

        // playerProfile is a global export (api host, no L) — league-host + L often returns empty.
        async let profilesData = try? await MFLClient.shared.exportGlobalJSON(
            season: linked.season,
            type: "playerProfile",
            extra: ["P": idList],
            cacheTTL: 600
        )
        // players DETAILS fills height/weight/birthdate when profile is thin.
        async let playersData = try? await MFLClient.shared.exportGlobalJSON(
            season: linked.season,
            type: "players",
            extra: ["DETAILS": "1", "PLAYERS": idList],
            cacheTTL: 86_400
        )
        async let ranksData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "playerRanks",
            leagueId: linked.leagueId,
            cacheTTL: 1800
        )
        async let topAddsData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "topAdds",
            leagueId: linked.leagueId,
            cacheTTL: 600
        )
        async let injuriesData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "injuries",
            leagueId: linked.leagueId,
            cacheTTL: 300
        )

        let (profilesRaw, playersRaw, ranksRaw, topAddsRaw, injuriesRaw) = await (
            profilesData, playersData, ranksData, topAddsData, injuriesData
        )

        var profiles = profilesRaw.map { parseProfiles($0) } ?? [:]
        let playerBios = playersRaw.map { parsePlayersDetails($0) } ?? [:]
        for (id, bio) in playerBios {
            var merged = profiles[id] ?? Profile()
            if merged.name == nil { merged.name = bio.name }
            if merged.age == nil { merged.age = bio.age }
            if merged.dob == nil { merged.dob = bio.dob }
            if merged.height == nil { merged.height = bio.height }
            if merged.weight == nil { merged.weight = bio.weight }
            profiles[id] = merged
        }

        let ranks = ranksRaw.map { parseRankMap($0) } ?? [:]
        let trending = topAddsRaw.map { parseTopAdds($0) } ?? [:]
        let injuries = injuriesRaw.map { parseInjuries($0) } ?? [:]

        var out: [String: PlayerDetail] = [:]
        for id in ids {
            let p = profiles[id] ?? profiles[MFLNameResolver.normalizePlayerId(id)]
            let detail = PlayerDetail(
                playerId: id,
                name: p?.name,
                age: p?.age,
                dob: p?.dob,
                height: p?.height,
                weight: p?.weight,
                adp: p?.adp,
                mflRank: ranks[id] ?? ranks[MFLNameResolver.normalizePlayerId(id)],
                topAddsPct: trending[id] ?? trending[MFLNameResolver.normalizePlayerId(id)],
                injury: injuries[id] ?? injuries[MFLNameResolver.normalizePlayerId(id)],
                newsHeadlines: p?.newsHeadlines ?? []
            )
            out[id] = detail
            out[MFLNameResolver.normalizePlayerId(id)] = detail
        }
        return out
    }

    // MARK: - Parsers

    private struct Profile {
        var name: String?
        var age: String?
        var dob: String?
        var height: String?
        var weight: String?
        var adp: String?
        var newsHeadlines: [String] = []
    }

    private static func parseProfiles(_ data: Data) -> [String: Profile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let profileRoot = (root["playerProfile"] as? [String: Any]) ?? root
        var out: [String: Profile] = [:]

        func ingest(_ any: Any?) {
            if let arr = any as? [[String: Any]] {
                for row in arr {
                    if let parsed = parseOneProfile(row) { out[parsed.0] = parsed.1 }
                }
            } else if let one = any as? [String: Any] {
                if let parsed = parseOneProfile(one) { out[parsed.0] = parsed.1 }
            }
        }

        if profileRoot["id"] != nil || profileRoot["name"] != nil {
            ingest(profileRoot)
        }
        ingest(profileRoot["playerProfile"])
        ingest(profileRoot["player"])
        ingest(root["playerProfile"])
        ingest(root["player"])
        return out
    }

    private static func parsePlayersDetails(_ data: Data) -> [String: Profile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["players"] as? [String: Any])?["player"] ?? root["player"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }
        var out: [String: Profile] = [:]
        for row in rows {
            guard let idRaw = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let id = MFLNameResolver.normalizePlayerId(idRaw)
            var p = Profile()
            p.name = row["name"] as? String
            p.height = formatHeight(row["height"])
            p.weight = stringValue(row["weight"])
            if let birth = row["birthdate"] ?? row["dob"] {
                p.dob = formatBirthdate(birth)
                p.age = ageFromBirth(birth)
            }
            p.age = p.age ?? stringValue(row["age"])
            out[id] = p
        }
        return out
    }

    private static func parseOneProfile(_ row: [String: Any]) -> (String, Profile)? {
        let player = (row["player"] as? [String: Any]) ?? row
        let idRaw = (row["id"] as? String)
            ?? (player["id"] as? String)
            ?? (row["id"] as? Int).map(String.init)
            ?? (player["id"] as? Int).map(String.init)
        guard let idRaw else { return nil }
        let id = MFLNameResolver.normalizePlayerId(idRaw)

        var profile = Profile()
        profile.name = (row["name"] as? String) ?? (player["name"] as? String)
        profile.age = stringValue(player["age"] ?? row["age"])
        profile.dob = stringValue(player["dob"] ?? row["dob"] ?? player["birthdate"] ?? row["birthdate"])
            ?? formatBirthdate(player["birthdate"] ?? row["birthdate"])
        profile.height = formatHeight(player["height"] ?? row["height"])
        profile.weight = stringValue(player["weight"] ?? row["weight"])
        profile.adp = stringValue(player["adp"] ?? row["adp"])

        // Rare: some seasons embed short notes under news/article — not a full wire.
        let newsRoot = (row["news"] as? [String: Any]) ?? (player["news"] as? [String: Any])
        let articlesAny = newsRoot?["article"]
        var headlines: [String] = []
        if let arr = articlesAny as? [[String: Any]] {
            headlines = arr.compactMap { ($0["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let one = articlesAny as? [String: Any],
                  let h = one["headline"] as? String {
            headlines = [h]
        }
        profile.newsHeadlines = headlines
        return (id, profile)
    }

    private static func parseRankMap(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["playerRanks"] as? [String: Any])?["player"]
            ?? root["player"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }
        var map: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let rank = stringValue(row["rank"] ?? row["ranking"] ?? row["averageRank"])
            guard let rank, !rank.isEmpty else { continue }
            let nid = MFLNameResolver.normalizePlayerId(id)
            map[nid] = rank
            map[id] = rank
        }
        return map
    }

    private static func parseTopAdds(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["topAdds"] as? [String: Any])?["player"]
            ?? root["player"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }
        var map: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let pct = stringValue(row["percent"] ?? row["percentage"] ?? row["addPercentage"])
            guard let pct else { continue }
            let nid = MFLNameResolver.normalizePlayerId(id)
            map[nid] = pct
            map[id] = pct
        }
        return map
    }

    private static func parseInjuries(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["injuries"] as? [String: Any])?["injury"]
            ?? root["injury"]
        let rows: [[String: Any]]
        if let arr = any as? [[String: Any]] { rows = arr }
        else if let one = any as? [String: Any] { rows = [one] }
        else { return [:] }
        var map: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String ?? (row["id"] as? Int).map(String.init) else { continue }
            let status = stringValue(row["status"] ?? row["injury_status"]) ?? ""
            let details = stringValue(row["details"] ?? row["detail"] ?? row["news"]) ?? ""
            let combined = [status, details].filter { !$0.isEmpty }.joined(separator: " — ")
            guard !combined.isEmpty else { continue }
            let nid = MFLNameResolver.normalizePlayerId(id)
            map[nid] = combined
            map[id] = combined
        }
        return map
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(format: "%g", d) }
        return nil
    }

    /// MFL height is often total inches.
    private static func formatHeight(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty {
            if s.contains("'") || s.lowercased().contains("ft") { return s }
            if let inches = Int(s) { return "\(inches / 12)'\(inches % 12)\"" }
            return s
        }
        if let inches = any as? Int {
            return "\(inches / 12)'\(inches % 12)\""
        }
        if let d = any as? Double {
            let inches = Int(d)
            return "\(inches / 12)'\(inches % 12)\""
        }
        return nil
    }

    private static func formatBirthdate(_ any: Any?) -> String? {
        guard let date = dateFromEpoch(any) else { return stringValue(any) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func ageFromBirth(_ any: Any?) -> String? {
        guard let date = dateFromEpoch(any) else { return nil }
        let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        return years.map(String.init)
    }

    private static func dateFromEpoch(_ any: Any?) -> Date? {
        if let s = any as? String, let t = TimeInterval(s) {
            return Date(timeIntervalSince1970: t)
        }
        if let i = any as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = any as? Double { return Date(timeIntervalSince1970: d) }
        return nil
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
