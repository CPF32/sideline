import Foundation

/// Caches Sleeper's NFL player dump and matches MFL (or free-text) players by name/team/pos.
actor SleeperPlayerCatalog {
    static let shared = SleeperPlayerCatalog()

    private var byId: [String: SleeperPlayerRecord] = [:]
    private var bySearchKey: [String: SleeperPlayerRecord] = [:]
    private var loadedAt: Date?
    private let maxAge: TimeInterval = 86_400

    /// Surfaced on player sheet when the NFL dump fails or is empty.
    private(set) var lastStatus: String?

    var playerCount: Int { byId.count }

    private var diskURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sideline-sleeper-players-nfl.json")
    }

    func ensureLoaded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge, !byId.isEmpty {
            lastStatus = "\(byId.count) players cached"
            return
        }

        // Prefer on-disk cache (avoids re-downloading ~10MB on every cold start).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: diskURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: diskURL),
           !data.isEmpty {
            ingest(data)
            if !byId.isEmpty {
                lastStatus = "\(byId.count) players (disk)"
                return
            }
        }

        do {
            let data = try await SleeperClient.shared.allPlayers()
            ingest(data)
            if !byId.isEmpty {
                try? data.write(to: diskURL, options: .atomic)
                lastStatus = "\(byId.count) players loaded"
            } else {
                lastStatus = "Sleeper player dump parsed empty"
            }
        } catch {
            lastStatus = "Sleeper dump failed: \(error.localizedDescription)"
            // Soft fail — keep prior in-memory cache if any.
        }
    }

    func player(id: String) async -> SleeperPlayerRecord? {
        await ensureLoaded()
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = byId[trimmed] { return hit }
        // Some feeds stringify ints with trailing artifacts.
        if let intId = Int(trimmed), let hit = byId[String(intId)] { return hit }
        return nil
    }

    func match(name: String, team: String, position: String) async -> SleeperPlayerRecord? {
        await ensureLoaded()
        let (first, last) = splitName(name)
        let pos = normalizePos(position)
        let teamKey = NFLScheduleService.normalizeTeam(team)
        let key = "\(last.lowercased())|\(first.lowercased())|\(pos)|\(teamKey)"
        if let hit = bySearchKey[key] { return hit }
        // Also try raw Sleeper DEF key if we normalized to DST.
        if pos == "DST" {
            let defKey = "\(last.lowercased())|\(first.lowercased())|DEF|\(teamKey)"
            if let hit = bySearchKey[defKey] { return hit }
        }

        // Relaxed: last + pos + team
        let relaxed = byId.values.first {
            $0.lastName.compare(last, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && positionsMatch($0.position, pos)
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

    private func normalizePos(_ position: String) -> String {
        let p = position.uppercased()
        if p == "DEF" || p == "D/ST" || p == "D" || p == "DST" { return "DST" }
        return p
    }

    private func positionsMatch(_ a: String, _ b: String) -> Bool {
        normalizePos(a) == normalizePos(b)
    }

    /// Build a PlayerDetail from a Sleeper record (formatted for the sheet).
    func detail(from record: SleeperPlayerRecord) -> PlayerDetail {
        PlayerDetail(
            playerId: record.playerId,
            name: record.fullName,
            age: record.age.map(String.init),
            dob: nil,
            height: formatHeight(record.height),
            weight: nonempty(record.weight),
            adp: nil,
            mflRank: nil,
            topAddsPct: nil,
            injury: nonempty(record.injuryStatus),
            newsHeadlines: [],
            college: nonempty(record.college),
            number: nonempty(record.number),
            status: nonempty(record.status),
            yearsExp: record.yearsExp.map(String.init),
            depthChart: record.depthChartOrder.map { "\(record.position) #\($0)" },
            sleeperPlayerId: record.playerId
        )
    }

    func enrichDetail(_ base: PlayerDetail, name: String, team: String, position: String) async -> PlayerDetail {
        // Prefer exact Sleeper id when the sheet already has one.
        if let sid = base.sleeperPlayerId, let s = await player(id: sid) {
            return merge(base, with: s)
        }
        guard let s = await match(name: name, team: team, position: position) else { return base }
        return merge(base, with: s)
    }

    /// Compact lines for agent / summary prompts.
    func contextLines(for players: [RosterPlayer], limit: Int = 20) async -> String {
        await ensureLoaded()
        var lines: [String] = ["SLEEPER PLAYER INTEL (injury / depth / bio):"]
        var count = 0
        for p in players {
            guard count < limit else { break }
            let s: SleeperPlayerRecord?
            if let byId = await player(id: p.playerId) {
                s = byId
            } else {
                s = await match(name: p.name, team: p.team, position: p.position)
            }
            guard let s else { continue }
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

    private func merge(_ base: PlayerDetail, with s: SleeperPlayerRecord) -> PlayerDetail {
        var d = base
        if d.name == nil || d.name?.isEmpty == true { d.name = s.fullName }
        if d.age == nil, let age = s.age { d.age = String(age) }
        if d.height == nil { d.height = formatHeight(s.height) }
        if d.weight == nil { d.weight = nonempty(s.weight) }
        if d.injury == nil || d.injury?.isEmpty == true {
            d.injury = nonempty(s.injuryStatus)
        }
        if d.college == nil { d.college = nonempty(s.college) }
        if d.number == nil { d.number = nonempty(s.number) }
        if d.status == nil { d.status = nonempty(s.status) }
        if d.yearsExp == nil, let y = s.yearsExp { d.yearsExp = String(y) }
        if d.depthChart == nil, let order = s.depthChartOrder {
            d.depthChart = "\(s.position) #\(order)"
        }
        d.sleeperPlayerId = s.playerId
        return d
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
                number: stringValue(row["number"]),
                height: stringValue(row["height"]),
                weight: stringValue(row["weight"]),
                age: intValue(row["age"]),
                college: stringValue(row["college"]),
                status: stringValue(row["status"]),
                injuryStatus: stringValue(row["injury_status"]),
                yearsExp: intValue(row["years_exp"]),
                depthChartPosition: intValue(row["depth_chart_position"]),
                depthChartOrder: intValue(row["depth_chart_order"])
            )
            byId[id] = record
            byKey[record.searchKey] = record
        }
        guard !byId.isEmpty else { return }
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
        guard let raw = nonempty(raw) else { return nil }
        if raw.contains("'") || raw.contains("\"") { return raw }
        if let inches = Int(raw) {
            return "\(inches / 12)'\(inches % 12)\""
        }
        return raw
    }

    private func nonempty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
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
}
