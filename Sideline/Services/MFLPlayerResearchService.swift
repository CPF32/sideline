import Foundation

/// Pulls MFL playerProfile (+ ranks/trending when available) for recommendation analysis.
enum MFLPlayerResearchService {
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

        async let profilesData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "playerProfile",
            leagueId: linked.leagueId,
            extra: ["P": ids.joined(separator: ",")],
            cacheTTL: 600
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

        let (profilesRaw, ranksRaw, topAddsRaw, injuriesRaw) = await (
            profilesData, ranksData, topAddsData, injuriesData
        )

        let profiles = profilesRaw.map { parseProfiles($0) } ?? [:]
        let ranks = ranksRaw.map { parseRankMap($0) } ?? [:]
        let trending = topAddsRaw.map { parseTopAdds($0) } ?? [:]
        let injuries = injuriesRaw.map { parseInjuries($0) } ?? [:]

        var blocks: [String] = [
            "MFL PLAYER RESEARCH (use this to analyze options — do not just recite salary):"
        ]
        for id in ids {
            let p = profiles[id] ?? profiles[MFLNameResolver.normalizePlayerId(id)]
            var lines: [String] = ["PLAYER \(id)"]
            if let name = p?.name, !name.isEmpty { lines.append("name=\(name)") }
            if let age = p?.age { lines.append("age=\(age)") }
            if let dob = p?.dob { lines.append("dob=\(dob)") }
            if let h = p?.height { lines.append("height=\(h)") }
            if let w = p?.weight { lines.append("weight=\(w)") }
            if let adp = p?.adp, !adp.isEmpty, adp.uppercased() != "N/A" {
                lines.append("adp=\(adp)")
            }
            if let rank = ranks[id] ?? ranks[MFLNameResolver.normalizePlayerId(id)] {
                lines.append("mflRank=\(rank)")
            }
            if let addPct = trending[id] ?? trending[MFLNameResolver.normalizePlayerId(id)] {
                lines.append("topAddsPct=\(addPct)")
            }
            if let inj = injuries[id] ?? injuries[MFLNameResolver.normalizePlayerId(id)] {
                lines.append("injury=\(inj)")
            }
            if let news = p?.newsHeadlines, !news.isEmpty {
                lines.append("news=" + news.prefix(3).joined(separator: " | "))
            }
            if lines.count == 1 {
                lines.append("(no MFL profile details returned)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
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

        // Single profile object
        if profileRoot["id"] != nil || profileRoot["player"] != nil {
            if let parsed = parseOneProfile(profileRoot) {
                out[parsed.0] = parsed.1
            }
        }

        // Multiple: playerProfile.playerProfile or array under player
        let candidates: [Any] = [
            profileRoot["playerProfile"] as Any,
            profileRoot["player"] as Any,
            root["playerProfile"] as Any
        ].compactMap { $0 }

        for any in candidates {
            if let arr = any as? [[String: Any]] {
                for row in arr {
                    if let parsed = parseOneProfile(row) { out[parsed.0] = parsed.1 }
                }
            } else if let one = any as? [String: Any] {
                if let parsed = parseOneProfile(one) { out[parsed.0] = parsed.1 }
            }
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
        profile.dob = stringValue(player["dob"] ?? row["dob"])
        profile.height = stringValue(player["height"] ?? row["height"])
        profile.weight = stringValue(player["weight"] ?? row["weight"])
        profile.adp = stringValue(player["adp"] ?? row["adp"])

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
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
