import Foundation

/// Groups bench (or roster) players by starter-position order from league rules.
enum RosterPositionGrouping {
    struct Group: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        /// e.g. "1" or "1–2"
        let starterSlotsLabel: String?
        let players: [RosterPlayer]
    }

    /// Fallback only when league starter slots are missing (e.g. some Sleeper leagues).
    static let positionOrder: [String] = [
        "QB", "RB", "WR", "TE", "PK", "DT", "DE", "LB", "CB", "S"
    ]

    /// Discrete position keys in the order defined by league starter slots.
    /// Flex (`RB/WR/TE`) is skipped here — callers insert `TIEBREAK` / `FLEX` from slot order.
    static func displayPositionOrder(rules: LeagueRules?) -> [String] {
        guard let rules, !rules.starterSlots.isEmpty else {
            return positionOrder
        }
        var order: [String] = []
        var seen = Set<String>()
        for slot in rules.starterSlots {
            let name = normalizePos(slot.name)
            guard !name.contains("/") else { continue }
            let key = bucketKey(for: name)
            if seen.insert(key).inserted {
                order.append(key)
            }
        }
        return order.isEmpty ? positionOrder : order
    }

    static func benchGroups(players: [RosterPlayer], rules: LeagueRules?) -> [Group] {
        let slotCounts = slotCountByKey(rules: rules)
        let flexPositions = flexEligiblePositions(rules: rules)
        var buckets: [String: [RosterPlayer]] = [:]

        for player in players {
            let key = bucketKey(for: player.position)
            buckets[key, default: []].append(player)
        }

        var keysInOrder: [String] = []
        var added = Set<String>()

        if let rules, !rules.starterSlots.isEmpty {
            // Preserve host slot order (incl. where flex / tiebreak sits).
            for slot in rules.starterSlots {
                let name = normalizePos(slot.name)
                if name.contains("/") {
                    if added.insert("TIEBREAK").inserted {
                        keysInOrder.append("TIEBREAK")
                    }
                } else {
                    let key = bucketKey(for: name)
                    if added.insert(key).inserted {
                        keysInOrder.append(key)
                    }
                }
            }
        } else {
            for pos in positionOrder where buckets[pos]?.isEmpty == false {
                keysInOrder.append(pos)
                added.insert(pos)
            }
        }

        // Tiebreak bucket for flex-labeled players (rare) when not already present.
        let flexOnlyPlayers = players.filter { player in
            let p = normalizePos(player.position)
            let key = bucketKey(for: p)
            return !added.contains(key)
                && (flexPositions.contains(p) || p.contains("/") || p == "FLEX" || p == "OP" || p == "OFF")
        }
        if !flexOnlyPlayers.isEmpty {
            buckets["TIEBREAK"] = flexOnlyPlayers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if added.insert("TIEBREAK").inserted {
                keysInOrder.append("TIEBREAK")
            }
        }

        let showTiebreakHeader = slotCounts["TIEBREAK"] != nil || !(buckets["TIEBREAK"]?.isEmpty ?? true)
        if showTiebreakHeader, added.insert("TIEBREAK").inserted {
            keysInOrder.append("TIEBREAK")
        }

        let extras = buckets.keys
            .filter { !added.contains($0) && !(buckets[$0]?.isEmpty ?? true) }
            .sorted()
        keysInOrder.append(contentsOf: extras)

        return keysInOrder.compactMap { key in
            let list = (buckets[key] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if list.isEmpty && key != "TIEBREAK" { return nil }
            if list.isEmpty && key == "TIEBREAK" && slotCounts["TIEBREAK"] == nil { return nil }

            let title = key == "TIEBREAK" ? "Tiebreak" : key
            return Group(
                key: key,
                title: title,
                starterSlotsLabel: slotLabel(slotCounts[key]),
                players: list
            )
        }
    }

    /// Flat starter list in league-rules position order (Team roster slide).
    static func startersInDisplayOrder(_ players: [RosterPlayer], rules: LeagueRules? = nil) -> [RosterPlayer] {
        benchGroups(players: players, rules: rules)
            .filter { $0.key != "TIEBREAK" && !$0.players.isEmpty }
            .flatMap(\.players)
    }

    /// Matchup rows keyed by league starter slots (max per position), in host slot order.
    struct MatchupSlotPair: Identifiable {
        let id: Int
        let slotLabel: String
        let mine: RosterPlayer?
        let opponent: RosterPlayer?
    }

    static func matchupSlotPairs(
        mine: [RosterPlayer],
        opponent: [RosterPlayer],
        rules: LeagueRules?
    ) -> [MatchupSlotPair] {
        let template = matchupSlotTemplate(rules: rules, mine: mine, opponent: opponent)
        let order = displayPositionOrder(rules: rules)
        var mineQueues = positionQueues(mine, rules: rules)
        var oppQueues = positionQueues(opponent, rules: rules)
        let flexEligible = flexEligiblePositions(rules: rules)

        var pairs: [MatchupSlotPair] = []
        var index = 0

        for slot in template {
            let minePlayer: RosterPlayer?
            let oppPlayer: RosterPlayer?
            if slot == "FLEX" {
                minePlayer = dequeueFlex(from: &mineQueues, eligible: flexEligible, order: order)
                oppPlayer = dequeueFlex(from: &oppQueues, eligible: flexEligible, order: order)
            } else {
                minePlayer = dequeue(from: &mineQueues, position: slot)
                oppPlayer = dequeue(from: &oppQueues, position: slot)
            }
            if minePlayer == nil, oppPlayer == nil { continue }
            pairs.append(
                MatchupSlotPair(
                    id: index,
                    slotLabel: slot,
                    mine: minePlayer,
                    opponent: oppPlayer
                )
            )
            index += 1
        }

        let leftoversMine = flattenQueues(mineQueues, order: order)
        let leftoversOpp = flattenQueues(oppQueues, order: order)
        if !leftoversMine.isEmpty || !leftoversOpp.isEmpty {
            let extra = zipStartersFallback(mine: leftoversMine, opp: leftoversOpp)
            for pair in extra {
                let label = bucketKey(for: pair.mine?.position ?? pair.opp?.position ?? "")
                pairs.append(
                    MatchupSlotPair(
                        id: index,
                        slotLabel: label == "OTHER" ? "—" : label,
                        mine: pair.mine,
                        opponent: pair.opp
                    )
                )
                index += 1
            }
        }
        return pairs
    }

    /// Slot rows from league rules in host order: each discrete slot × max, flex × max where it appears.
    static func matchupSlotTemplate(
        rules: LeagueRules?,
        mine: [RosterPlayer],
        opponent: [RosterPlayer]
    ) -> [String] {
        if let rules, !rules.starterSlots.isEmpty {
            var template: [String] = []
            for slot in rules.starterSlots {
                guard slot.max > 0 else { continue }
                let name = normalizePos(slot.name)
                if name.contains("/") {
                    for _ in 0..<slot.max { template.append("FLEX") }
                } else {
                    let key = bucketKey(for: name)
                    for _ in 0..<slot.max { template.append(key) }
                }
            }
            if !template.isEmpty { return template }
        }

        // No usable rules — size each position to max(mine, opp) count, fallback order.
        let order = displayPositionOrder(rules: rules)
        let mineCounts = Dictionary(grouping: mine, by: { bucketKey(for: $0.position) }).mapValues(\.count)
        let oppCounts = Dictionary(grouping: opponent, by: { bucketKey(for: $0.position) }).mapValues(\.count)
        var byPos: [String: Int] = [:]
        for key in Set(mineCounts.keys).union(oppCounts.keys) {
            byPos[key] = max(mineCounts[key] ?? 0, oppCounts[key] ?? 0)
        }
        var template: [String] = []
        for pos in order {
            guard let n = byPos.removeValue(forKey: pos), n > 0 else { continue }
            for _ in 0..<n { template.append(pos) }
        }
        for key in byPos.keys.sorted() {
            guard let n = byPos[key], n > 0 else { continue }
            for _ in 0..<n { template.append(key) }
        }
        return template
    }

    private static func positionQueues(
        _ players: [RosterPlayer],
        rules: LeagueRules?
    ) -> [String: [RosterPlayer]] {
        var queues: [String: [RosterPlayer]] = [:]
        for player in startersInDisplayOrder(players, rules: rules) {
            let key = bucketKey(for: player.position)
            queues[key, default: []].append(player)
        }
        return queues
    }

    private static func dequeue(from queues: inout [String: [RosterPlayer]], position: String) -> RosterPlayer? {
        let key = bucketKey(for: position)
        guard var list = queues[key], !list.isEmpty else { return nil }
        let player = list.removeFirst()
        queues[key] = list
        return player
    }

    private static func dequeueFlex(
        from queues: inout [String: [RosterPlayer]],
        eligible: Set<String>,
        order: [String]
    ) -> RosterPlayer? {
        let flexOrder: [String]
        if eligible.isEmpty {
            flexOrder = order.filter { ["RB", "WR", "TE"].contains($0) }
        } else {
            flexOrder = order.filter { eligible.contains($0) }
                + eligible.subtracting(Set(order)).sorted()
        }
        for pos in flexOrder {
            if let player = dequeue(from: &queues, position: pos) {
                return player
            }
        }
        return nil
    }

    private static func flattenQueues(
        _ queues: [String: [RosterPlayer]],
        order: [String]
    ) -> [RosterPlayer] {
        var out: [RosterPlayer] = []
        var seen = Set<String>()
        for pos in order {
            out.append(contentsOf: queues[pos] ?? [])
            seen.insert(pos)
        }
        for key in queues.keys.sorted() where !seen.contains(key) {
            out.append(contentsOf: queues[key] ?? [])
        }
        return out
    }

    private static func zipStartersFallback(
        mine: [RosterPlayer],
        opp: [RosterPlayer]
    ) -> [(mine: RosterPlayer?, opp: RosterPlayer?)] {
        let count = max(mine.count, opp.count)
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            (i < mine.count ? mine[i] : nil, i < opp.count ? opp[i] : nil)
        }
    }

    private static func flexEligiblePositions(rules: LeagueRules?) -> Set<String> {
        guard let rules else { return [] }
        var set = Set<String>()
        for slot in rules.starterSlots where slot.name.contains("/") {
            for part in slot.name.split(separator: "/") {
                set.insert(normalizePos(String(part)))
            }
        }
        return set
    }

    /// Map a player position into a display bucket.
    private static func bucketKey(for position: String) -> String {
        let p = normalizePos(position)
        // Common aliases
        switch p {
        case "K", "PK": return "PK"
        case "DEF", "DF", "D/ST", "DST": return "DEF"
        case "SS", "FS": return "S"
        case "HB", "FB": return "RB"
        default: return p.isEmpty ? "OTHER" : p
        }
    }

    private static func normalizePos(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Aggregate starter slot counts: discrete positions + flex → Tiebreak.
    private static func slotCountByKey(rules: LeagueRules?) -> [String: (min: Int, max: Int)] {
        guard let rules else { return [:] }
        var map: [String: (Int, Int)] = [:]
        var flexMin = 0
        var flexMax = 0
        var hasFlex = false

        for slot in rules.starterSlots {
            let name = normalizePos(slot.name)
            if name.contains("/") {
                hasFlex = true
                flexMin += slot.min
                flexMax += slot.max
            } else {
                let key = bucketKey(for: name)
                let existing = map[key] ?? (0, 0)
                map[key] = (existing.0 + slot.min, existing.1 + slot.max)
            }
        }
        if hasFlex {
            map["TIEBREAK"] = (flexMin, flexMax)
        }
        return map
    }

    private static func slotLabel(_ range: (min: Int, max: Int)?) -> String? {
        guard let range else { return nil }
        if range.min == range.max { return "\(range.max)" }
        return "\(range.min)–\(range.max)"
    }
}
