import Foundation

/// Starting-slot / roster limits from MFL `TYPE=league`.
struct LeagueRules: Hashable, Codable {
    var rosterSize: Int?
    var injuredReserveSlots: Int?
    var taxiSquadSlots: Int?
    var totalStarters: Int?
    /// Position → required starter count range (min...max). Flex encoded as name e.g. "RB/WR/TE".
    var starterSlots: [StarterSlot]
    var usesSalaries: Bool = false
    var salaryCapAmount: Double?
    var rawNotes: String?

    struct StarterSlot: Hashable, Codable, Identifiable {
        var id: String { "\(name)-\(min)-\(max)" }
        var name: String
        var min: Int
        var max: Int
    }

    var summaryForLLM: String {
        var lines: [String] = []
        if let rosterSize { lines.append("rosterSize=\(rosterSize) (active roster, excludes IR/taxi unless league counts them)") }
        if let injuredReserveSlots { lines.append("IR slots=\(injuredReserveSlots)") }
        if let taxiSquadSlots { lines.append("taxi slots=\(taxiSquadSlots)") }
        if let totalStarters { lines.append("totalStartersRequired=\(totalStarters)") }
        if !starterSlots.isEmpty {
            let slotLine = starterSlots.map { slot in
                slot.min == slot.max ? "\(slot.name):\(slot.max)" : "\(slot.name):\(slot.min)-\(slot.max)"
            }.joined(separator: ", ")
            lines.append("starterSlots=[\(slotLine)]")
        }
        if usesSalaries {
            lines.append("usesSalaries=true")
            if let salaryCapAmount {
                lines.append("salaryCap=\(SalaryFormat.compact(salaryCapAmount)) (raw:\(Int(salaryCapAmount)))")
            }
        }
        if let rawNotes, !rawNotes.isEmpty { lines.append(rawNotes) }
        return lines.isEmpty ? "League starter rules unavailable — infer from current starters if present." : lines.joined(separator: "\n")
    }

    static func parse(from leagueData: Data) -> LeagueRules {
        guard let root = try? JSONSerialization.jsonObject(with: leagueData) as? [String: Any] else {
            return LeagueRules(starterSlots: [])
        }
        let league = (root["league"] as? [String: Any]) ?? root
        let rosterSize = intValue(league["rosterSize"])
        let ir = intValue(league["injuredReserve"])
        let taxi = intValue(league["taxiSquad"])
        let usesSalaries = boolish(league["usesSalaries"])
        let salaryCap = doubleValue(league["salaryCapAmount"])

        var slots: [StarterSlot] = []
        var total: Int?
        var notes: [String] = []

        if let starters = league["starters"] as? [String: Any] {
            total = intValue(starters["count"])
            if let iop = intValue(starters["iop_starters"]) {
                notes.append("offenseStarters(iop)=\(iop)")
            }
            if let idp = intValue(starters["idp_starters"]) {
                notes.append("defenseStarters(idp)=\(idp)")
            }
            let positions = arrayOfDicts(starters["position"])
            for row in positions {
                let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { continue }
                let (mn, mx) = parseLimit(row["limit"])
                slots.append(StarterSlot(name: name, min: mn, max: mx))
            }
        }

        return LeagueRules(
            rosterSize: rosterSize,
            injuredReserveSlots: ir,
            taxiSquadSlots: taxi,
            totalStarters: total,
            starterSlots: slots,
            usesSalaries: usesSalaries || salaryCap != nil,
            salaryCapAmount: salaryCap,
            rawNotes: notes.isEmpty ? nil : notes.joined(separator: "; ")
        )
    }

    private static func parseLimit(_ any: Any?) -> (Int, Int) {
        if let i = any as? Int { return (i, i) }
        if let d = any as? Double { let v = Int(d); return (v, v) }
        guard let s = any as? String else { return (0, 0) }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(trimmed) { return (i, i) }
        let parts = trimmed.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        if parts.count == 1 { return (parts[0], parts[0]) }
        return (0, 0)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    private static func boolish(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let i = any as? Int { return i != 0 }
        if let s = any as? String {
            let t = s.lowercased()
            return t == "1" || t == "yes" || t == "true" || t == "y"
        }
        return false
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        return []
    }
}
