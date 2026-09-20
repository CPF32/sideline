import Foundation

/// Groups bench (or roster) players by starter-position order with slot counts from league rules.
enum RosterPositionGrouping {
    struct Group: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        /// e.g. "1" or "1–2"
        let starterSlotsLabel: String?
        let players: [RosterPlayer]
    }

    /// Canonical display order for discrete positions.
    static let positionOrder: [String] = [
        "QB", "RB", "WR", "TE", "PK", "DT", "DE", "LB", "CB", "S"
    ]

    static func benchGroups(players: [RosterPlayer], rules: LeagueRules?) -> [Group] {
        let slotCounts = slotCountByKey(rules: rules)
        let flexPositions = flexEligiblePositions(rules: rules)
        var buckets: [String: [RosterPlayer]] = [:]

        for player in players {
            let key = bucketKey(for: player.position)
            buckets[key, default: []].append(player)
        }

        var keysInOrder: [String] = []
        for pos in positionOrder where buckets[pos]?.isEmpty == false {
            keysInOrder.append(pos)
        }

        // Tiebreak = flex starter slots (e.g. RB/WR/TE). List flex-only positions here;
        // dedicated QB/RB/… stay in their own groups.
        let flexOnlyPlayers = players.filter { player in
            let p = normalizePos(player.position)
            return !positionOrder.contains(bucketKey(for: p))
                && (flexPositions.contains(p) || p.contains("/") || p == "FLEX" || p == "OP" || p == "OFF")
        }
        if !flexOnlyPlayers.isEmpty {
            buckets["TIEBREAK"] = flexOnlyPlayers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        let showTiebreakHeader = slotCounts["TIEBREAK"] != nil || !(buckets["TIEBREAK"]?.isEmpty ?? true)
        if showTiebreakHeader {
            // Insert after standard positions even if empty of special flex players —
            // still show the (N) so you know how many flex starts the league allows.
            if !keysInOrder.contains("TIEBREAK") {
                keysInOrder.append("TIEBREAK")
            }
        }

        let known = Set(positionOrder + ["TIEBREAK"])
        let extras = buckets.keys
            .filter { !known.contains($0) && !(buckets[$0]?.isEmpty ?? true) }
            .sorted()
        keysInOrder.append(contentsOf: extras)

        return keysInOrder.compactMap { key in
            let list = (buckets[key] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            // Skip empty groups except Tiebreak when it has a starter-slot count to show.
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
    /// Flex-eligible leftovers aren't put in Tiebreak automatically — Tiebreak is for flex *slots* labeling;
    /// players stay under their discrete position (QB/RB/…).
    private static func bucketKey(for position: String) -> String {
        let p = normalizePos(position)
        if positionOrder.contains(p) { return p }
        // Common aliases
        switch p {
        case "K", "PK": return "PK"
        case "DEF", "DF", "D/ST", "DST": return "DEF"
        case "SS", "FS": return "S"
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
                // Flex / tiebreak — "pick any from starts" across listed positions.
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
