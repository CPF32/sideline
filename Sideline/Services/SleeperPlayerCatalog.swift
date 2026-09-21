import Foundation

/// Caches Sleeper's NFL player dump and matches MFL (or free-text) players by name/team/pos.
actor SleeperPlayerCatalog {
    static let shared = SleeperPlayerCatalog()

    private var byId: [String: SleeperPlayerRecord] = [:]
    private var bySearchKey: [String: SleeperPlayerRecord] = [:]
    private var loadedAt: Date?
    private let maxAge: TimeInterval = 86_400

    func ensureLoaded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge, !byId.isEmpty { return }
        guard let data = try? await SleeperClient.shared.allPlayers() else { return }
        ingest(data)
    }

    func player(id: String) async -> SleeperPlayerRecord? {
        await ensureLoaded()
        return byId[id]
    }

    func match(name: String, team: String, position: String) async -> SleeperPlayerRecord? {
        await ensureLoaded()
        let (first, last) = splitName(name)
        let pos = position.uppercased()
        let teamKey = NFLScheduleService.normalizeTeam(team)
        let key = "\(last.lowercased())|\(first.lowercased())|\(pos)|\(teamKey)"
        if let hit = bySearchKey[key] { return hit }

        // Relaxed: last + pos + team
        let relaxed = byId.values.first {
            $0.lastName.compare(last, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && $0.position.uppercased() == pos
                && (teamKey.isEmpty || NFLScheduleService.normalizeTeam($0.team) == teamKey
                    || teamAliasesMatch(teamKey, NFLScheduleService.normalizeTeam($0.team)))
        }
        if let relaxed { return relaxed }

        // Last resort: last + first
        return byId.values.first {
            $0.lastName.compare(last, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && $0.firstName.compare(first, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    func enrichDetail(_ base: PlayerDetail, name: String, team: String, position: String) async -> PlayerDetail {
        guard let s = await match(name: name, team: team, position: position) else { return base }
        var d = base
        if d.name == nil || d.name?.isEmpty == true { d.name = s.fullName }
        if d.age == nil, let age = s.age { d.age = String(age) }
        if d.height == nil { d.height = formatHeight(s.height) }
        if d.weight == nil { d.weight = s.weight }
        if d.injury == nil || d.injury?.isEmpty == true {
            d.injury = s.injuryStatus
        }
        d.college = s.college ?? d.college
        d.number = s.number ?? d.number
        d.status = s.status ?? d.status
        if let y = s.yearsExp { d.yearsExp = String(y) }
        if let order = s.depthChartOrder {
            d.depthChart = "\(s.position) #\(order)"
        }
        d.sleeperPlayerId = s.playerId
        return d
    }

    /// Compact lines for agent / summary prompts.
    func contextLines(for players: [RosterPlayer], limit: Int = 20) async -> String {
        await ensureLoaded()
        var lines: [String] = ["SLEEPER PLAYER INTEL (injury / depth / bio):"]
        var count = 0
        for p in players {
            guard count < limit else { break }
            guard let s = await match(name: p.name, team: p.team, position: p.position) else { continue }
            var bits: [String] = ["\(s.fullName) \(s.position) \(s.team)"]
            if let inj = s.injuryStatus, !inj.isEmpty { bits.append("injury=\(inj)") }
            if let st = s.status, !st.isEmpty { bits.append("status=\(st)") }
            if let order = s.depthChartOrder { bits.append("depth=\(order)") }
            if let age = s.age { bits.append("age=\(age)") }
            if let college = s.college { bits.append("college=\(college)") }
            lines.append("- " + bits.joined(separator: " · "))
            count += 1
        }
        if count == 0 {
            lines.append("(no sleeper matches)")
        }
        return lines.joined(separator: "\n")
    }

    private func ingest(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var byId: [String: SleeperPlayerRecord] = [:]
        var byKey: [String: SleeperPlayerRecord] = [:]
        for (id, value) in root {
            guard let row = value as? [String: Any] else { continue }
            let first = (row["first_name"] as? String) ?? ""
            let last = (row["last_name"] as? String) ?? ""
            let pos = (row["position"] as? String) ?? ""
            let team = (row["team"] as? String) ?? ""
            guard !last.isEmpty || !first.isEmpty else { continue }
            let record = SleeperPlayerRecord(
                playerId: id,
                firstName: first,
                lastName: last,
                fullName: [first, last].filter { !$0.isEmpty }.joined(separator: " "),
                position: pos,
                team: team,
                number: intOrString(row["number"]),
                height: row["height"] as? String,
                weight: row["weight"] as? String,
                age: row["age"] as? Int,
                college: row["college"] as? String,
                status: row["status"] as? String,
                injuryStatus: row["injury_status"] as? String,
                yearsExp: row["years_exp"] as? Int,
                depthChartPosition: row["depth_chart_position"] as? Int,
                depthChartOrder: row["depth_chart_order"] as? Int
            )
            byId[id] = record
            byKey[record.searchKey] = record
        }
        self.byId = byId
        self.bySearchKey = byKey
        self.loadedAt = .now
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

    private func formatHeight(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("'") { return raw }
        if let inches = Int(raw) {
            return "\(inches / 12)'\(inches % 12)\""
        }
        return raw
    }

    private func intOrString(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        return nil
    }
}
