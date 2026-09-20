import Foundation

enum MFLNameResolver {
    /// MFL franchise ids are 4-digit strings ("0001"). Schedule/standings sometimes omit zeros.
    static func normalizeFranchiseId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(trimmed), n >= 0, n < 10_000 {
            return String(format: "%04d", n)
        }
        return trimmed
    }

    static func franchiseName(id: String?, names: [String: String], fallback: String? = nil) -> String {
        guard let id else { return fallback ?? "Unknown" }
        let key = normalizeFranchiseId(id)
        return names[key] ?? names[id] ?? fallback ?? id
    }

    static func parseFranchiseNames(from leagueData: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: leagueData) as? [String: Any] else { return [:] }
        let league = (root["league"] as? [String: Any]) ?? root
        let franchisesAny = (league["franchises"] as? [String: Any])?["franchise"]
            ?? league["franchise"]
        let list: [[String: Any]]
        if let arr = franchisesAny as? [[String: Any]] { list = arr }
        else if let one = franchisesAny as? [String: Any] { list = [one] }
        else { return [:] }

        var map: [String: String] = [:]
        for f in list {
            let rawId = (f["id"] as? String) ?? (f["id"] as? Int).map(String.init)
            guard let rawId else { continue }
            let id = normalizeFranchiseId(rawId)
            let name = (f["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner = (f["owner_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let abbrev = (f["abbrev"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = [name, owner, abbrev].compactMap { $0 }.first { !$0.isEmpty } ?? id
            map[id] = resolved
            map[rawId] = resolved
        }
        return map
    }

    static func parsePlayerNames(from playersData: Data) -> [String: (name: String, pos: String, team: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: playersData) as? [String: Any] else { return [:] }
        let playersAny = (root["players"] as? [String: Any])?["player"] ?? root["player"]
        let list: [[String: Any]]
        if let arr = playersAny as? [[String: Any]] { list = arr }
        else if let one = playersAny as? [String: Any] { list = [one] }
        else { return [:] }

        var map: [String: (String, String, String)] = [:]
        for p in list {
            let rawId = (p["id"] as? String) ?? (p["id"] as? Int).map(String.init)
            guard let rawId else { continue }
            let id = normalizePlayerId(rawId)
            var name = (p["name"] as? String) ?? id
            // MFL often uses "Last,First"
            if name.contains(",") {
                let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    name = "\(parts[1]) \(parts[0])"
                }
            }
            let pos = (p["position"] as? String) ?? ""
            let team = (p["team"] as? String) ?? ""
            map[id] = (name, pos, team)
            map[rawId] = (name, pos, team)
        }
        return map
    }

    static func normalizePlayerId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(trimmed), n < 1000 {
            return String(format: "%04d", n)
        }
        return trimmed
    }

    /// Resolve MFL add/drop strings like "12345,67890|10" into display names.
    static func resolvePlayerList(_ raw: String, players: [String: (name: String, pos: String, team: String)]) -> String {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",| ").union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return raw }
        let parts = cleaned
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|,").union(.whitespaces)) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return raw }
        return parts.map { token in
            let idPart = String(token.split(separator: "|").first ?? Substring(token))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !idPart.isEmpty else { return token }
            let id = normalizePlayerId(idPart)
            if let meta = players[id] ?? players[idPart] {
                let team = meta.team.isEmpty ? "" : " \(meta.team)"
                let pos = meta.pos.isEmpty ? "" : " \(meta.pos)"
                return "\(meta.name)\(pos)\(team)"
            }
            return idPart
        }.joined(separator: ", ")
    }
}
