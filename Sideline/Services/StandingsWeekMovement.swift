import Foundation

/// Builds week-over-week standings ranks from MFL `weeklyResults` with `W=YTD`.
enum StandingsWeekMovement {
    struct Record: Hashable {
        var wins: Int = 0
        var losses: Int = 0
        var ties: Int = 0
        var pointsFor: Double = 0
        var pointsAgainst: Double = 0
    }

    /// Returns franchiseId → rank (1 = first) after games through `throughWeek` inclusive.
    static func ranks(
        fromYTD weeklyYTD: Data?,
        throughWeek: Int
    ) -> [String: Int] {
        guard throughWeek >= 1, let weeklyYTD else { return [:] }
        let records = accumulate(fromYTD: weeklyYTD, throughWeek: throughWeek)
        return rank(records)
    }

    /// Positive delta = rose N spots from end of `priorWeek` to end of `currentWeek`.
    static func deltas(
        fromYTD weeklyYTD: Data?,
        currentWeek: Int
    ) -> [String: Int] {
        guard currentWeek >= 2 else { return [:] }
        let prior = ranks(fromYTD: weeklyYTD, throughWeek: currentWeek - 1)
        let current = ranks(fromYTD: weeklyYTD, throughWeek: currentWeek)
        guard !prior.isEmpty, !current.isEmpty else { return [:] }

        var out: [String: Int] = [:]
        for (id, now) in current {
            if let before = prior[id] {
                out[id] = before - now
            }
        }
        return out
    }

    // MARK: - Accumulate

    private static func accumulate(fromYTD data: Data, throughWeek: Int) -> [String: Record] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let weekly = (root["weeklyResults"] as? [String: Any]) ?? root
        var records: [String: Record] = [:]

        for (weekNum, matchups) in weekMatchups(from: weekly) {
            guard weekNum >= 1, weekNum <= throughWeek else { continue }
            for matchup in matchups {
                let sides = arrayOfDicts(matchup["franchise"])
                guard sides.count >= 2 else { continue }
                let a = side(sides[0])
                let b = side(sides[1])
                guard let aId = a.id, let bId = b.id else { continue }

                // Only count completed (or at least scored) games toward prior-week baseline.
                guard let aScore = a.score, let bScore = b.score else { continue }

                records[aId, default: Record()].pointsFor += aScore
                records[aId, default: Record()].pointsAgainst += bScore
                records[bId, default: Record()].pointsFor += bScore
                records[bId, default: Record()].pointsAgainst += aScore

                if aScore > bScore {
                    records[aId, default: Record()].wins += 1
                    records[bId, default: Record()].losses += 1
                } else if bScore > aScore {
                    records[bId, default: Record()].wins += 1
                    records[aId, default: Record()].losses += 1
                } else {
                    records[aId, default: Record()].ties += 1
                    records[bId, default: Record()].ties += 1
                }
            }
        }
        return records
    }

    /// week number → matchup dicts
    private static func weekMatchups(from weekly: [String: Any]) -> [(Int, [[String: Any]])] {
        var out: [(Int, [[String: Any]])] = []

        // YTD often: weeklyResults.week = [ { week: "1", matchup: [...] }, ... ]
        let weekNodes = arrayOfDicts(weekly["week"])
        if !weekNodes.isEmpty {
            for node in weekNodes {
                let w = intValue(node["week"]) ?? intValue(node["id"]) ?? 0
                let matchups = arrayOfDicts(node["matchup"])
                if w > 0 { out.append((w, matchups)) }
            }
            if !out.isEmpty { return out }
        }

        // Sometimes: array of weeklyResults roots under a list
        if let arr = weekly["weeklyResults"] as? [[String: Any]] {
            for node in arr {
                let w = intValue(node["week"]) ?? 0
                let matchups = arrayOfDicts(node["matchup"])
                if w > 0 { out.append((w, matchups)) }
            }
            if !out.isEmpty { return out }
        }

        // Single-week payload: week attribute on root + matchups
        if let w = intValue(weekly["week"]), w > 0 {
            out.append((w, arrayOfDicts(weekly["matchup"])))
        }

        return out
    }

    private static func rank(_ records: [String: Record]) -> [String: Int] {
        let sorted = records.sorted { a, b in
            let ra = a.value
            let rb = b.value
            if ra.wins != rb.wins { return ra.wins > rb.wins }
            if ra.losses != rb.losses { return ra.losses < rb.losses }
            if ra.ties != rb.ties { return ra.ties > rb.ties }
            if ra.pointsFor != rb.pointsFor { return ra.pointsFor > rb.pointsFor }
            return a.key < b.key
        }
        var map: [String: Int] = [:]
        for (idx, item) in sorted.enumerated() {
            map[item.key] = idx + 1
        }
        return map
    }

    private static func side(_ row: [String: Any]) -> (id: String?, score: Double?) {
        let raw = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init)
        let id = raw.map { MFLNameResolver.normalizeFranchiseId($0) }
        let score = doubleValue(row["score"])
        return (id, score)
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
