import Foundation

/// Normalized league scoring lines for agent context (MFL / Sleeper / ESPN).
struct ScoringRules: Hashable, Codable {
    struct Line: Hashable, Codable, Identifiable {
        var id: String { "\(label)|\(positions ?? "")|\(points)" }
        /// Human label, e.g. "Receptions" or "Pass TD".
        var label: String
        var points: Double
        /// Position filter when the host scopes the rule (MFL), e.g. "QB" or "RB/WR".
        var positions: String?
        /// Extra detail (range, per-yard notes, ESPN overrides).
        var notes: String?
    }

    var lines: [Line]
    /// Rough bucket for FantasyPros / projections: std, half_ppr, ppr, or custom.
    var formatHint: String?

    var isEmpty: Bool { lines.isEmpty }

    var summaryForLLM: String {
        guard !lines.isEmpty else {
            return "League scoring rules unavailable."
        }
        var header = "LEAGUE SCORING"
        if let formatHint, !formatHint.isEmpty {
            header += " (\(formatHint))"
        }
        header += ":"

        // Prefer compact single block; cap length so prompts stay bounded.
        let sorted = lines.sorted { lhs, rhs in
            let la = abs(lhs.points)
            let ra = abs(rhs.points)
            if la != ra { return la > ra }
            return lhs.label < rhs.label
        }
        let capped = Array(sorted.prefix(48))
        let parts = capped.map { line -> String in
            var s = line.label
            if let positions = line.positions, !positions.isEmpty {
                s += "[\(positions)]"
            }
            s += "=\(Self.formatPoints(line.points))"
            if let notes = line.notes, !notes.isEmpty {
                s += " (\(notes))"
            }
            return s
        }
        var out = header + "\n" + parts.joined(separator: ", ")
        if lines.count > capped.count {
            out += "\n… +\(lines.count - capped.count) more scoring lines omitted"
        }
        return out
    }

    // MARK: - Sleeper

    static func parseSleeper(from leagueData: Data) -> ScoringRules? {
        guard let root = try? JSONSerialization.jsonObject(with: leagueData) as? [String: Any],
              let scoring = root["scoring_settings"] as? [String: Any]
        else { return nil }
        return parseSleeper(scoring: scoring)
    }

    static func parseSleeper(scoring: [String: Any]) -> ScoringRules {
        var lines: [Line] = []
        for (key, raw) in scoring {
            guard let pts = doubleValue(raw), abs(pts) > 0.000_01 else { continue }
            let label = sleeperLabel(key)
            lines.append(Line(label: label, points: pts, positions: nil, notes: nil))
        }
        lines.sort { $0.label < $1.label }
        return ScoringRules(lines: lines, formatHint: sleeperFormatHint(scoring: scoring))
    }

    /// Infer PPR / half / std from `rec` for projection key selection.
    static func sleeperProjectionKey(from scoring: [String: Any]?) -> String {
        guard let scoring else { return "pts_ppr" }
        let rec = doubleValue(scoring["rec"]) ?? 0
        if rec >= 0.9 { return "pts_ppr" }
        if rec >= 0.4 { return "pts_half_ppr" }
        return "pts_std"
    }

    static func sleeperFormatHint(scoring: [String: Any]) -> String {
        let rec = doubleValue(scoring["rec"]) ?? 0
        if rec >= 0.9 { return "PPR" }
        if rec >= 0.4 { return "half-PPR" }
        if abs(rec) < 0.01 { return "standard" }
        return "custom"
    }

    // MARK: - MFL

    /// `rules` = league TYPE=rules; `allRules` = global TYPE=allRules (abbrev → label).
    static func parseMFL(rulesData: Data, allRulesData: Data?) -> ScoringRules? {
        guard let root = try? JSONSerialization.jsonObject(with: rulesData) as? [String: Any] else {
            return nil
        }
        let rulesRoot = (root["rules"] as? [String: Any]) ?? root
        let positionRules = arrayOfAny(rulesRoot["positionRules"])
        guard !positionRules.isEmpty else { return nil }

        let labels = parseMFLAllRulesLabels(allRulesData)
        var lines: [Line] = []

        for posAny in positionRules {
            guard let posRow = posAny as? [String: Any] else { continue }
            let positions = stringValue(posRow["positions"]) ?? stringValue(posRow["position"])
            let ruleRows = arrayOfDicts(posRow["rule"])
            for rule in ruleRows {
                let event = stringValue(rule["event"])
                    ?? stringValue(rule["abbreviation"])
                    ?? ""
                guard !event.isEmpty else { continue }
                let pointsRaw = stringValue(rule["points"]) ?? ""
                guard let pts = parseMFLPoints(pointsRaw), abs(pts) > 0.000_01 else { continue }
                let range = stringValue(rule["range"])
                let label = labels[event] ?? event
                var notes: [String] = []
                if pointsRaw.contains("*") || pointsRaw.contains("/") {
                    notes.append("each \(pointsRaw)")
                }
                if let range, !range.isEmpty, range != "0-999", range != "*-*" {
                    notes.append("range \(range)")
                }
                lines.append(Line(
                    label: label,
                    points: pts,
                    positions: positions,
                    notes: notes.isEmpty ? nil : notes.joined(separator: "; ")
                ))
            }
        }

        guard !lines.isEmpty else { return nil }
        return ScoringRules(lines: lines, formatHint: mflFormatHint(lines: lines))
    }

    static func parseMFLAllRulesLabels(_ data: Data?) -> [String: String] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        let all = (root["allRules"] as? [String: Any]) ?? root
        let rows = arrayOfDicts(all["rule"])
        var map: [String: String] = [:]
        for row in rows {
            let abbr = textNode(row["abbreviation"]) ?? stringValue(row["abbreviation"])
            guard let abbr, !abbr.isEmpty else { continue }
            let short = textNode(row["shortDescription"])
                ?? stringValue(row["shortDescription"])
                ?? textNode(row["detailedDescription"])
            if let short, !short.isEmpty {
                map[abbr] = short
            }
        }
        return map
    }

    // MARK: - ESPN

    static func parseESPN(from root: [String: Any]?) -> ScoringRules? {
        guard let root else { return nil }
        let settings = root["settings"] as? [String: Any]
        let scoringSettings = settings?["scoringSettings"] as? [String: Any]
        let items = arrayOfDicts(scoringSettings?["scoringItems"])
        guard !items.isEmpty else { return nil }

        var lines: [Line] = []
        for item in items {
            let statId = intValue(item["statId"]) ?? 0
            let pts = doubleValue(item["points"]) ?? 0
            let overrides = item["pointsOverrides"] as? [String: Any]
            let hasOverride = overrides?.values.contains { abs(doubleValue($0) ?? 0) > 0.000_01 } == true
            if abs(pts) < 0.000_01 && !hasOverride { continue }

            let meta = espnStatMeta(statId)
            let label = meta?.label ?? "stat\(statId)"
            var notes: [String] = []
            if let overrides {
                let bits = overrides.compactMap { key, val -> String? in
                    guard let p = doubleValue(val), abs(p) > 0.000_01 else { return nil }
                    return "slot\(key)=\(formatPoints(p))"
                }.sorted()
                if !bits.isEmpty {
                    notes.append("overrides: \(bits.joined(separator: ","))")
                }
            }
            lines.append(Line(
                label: label,
                points: pts,
                positions: nil,
                notes: notes.isEmpty ? nil : notes.joined(separator: "; ")
            ))
        }
        guard !lines.isEmpty else { return nil }
        return ScoringRules(lines: lines, formatHint: espnFormatHint(lines: lines))
    }

    // MARK: - Helpers

    private static func formatPoints(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 10_000 {
            return String(Int(value.rounded()))
        }
        let s = String(format: "%.4f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return s.isEmpty ? "0" : s
    }

    /// MFL points strings: "4", "0.04", "*0.1", "/10" (points per N yards).
    private static func parseMFLPoints(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.hasPrefix("*"), let v = Double(String(t.dropFirst())) { return v }
        if t.hasPrefix("/"), let denom = Double(String(t.dropFirst())), denom != 0 {
            return 1.0 / denom
        }
        if let v = Double(t) { return v }
        return nil
    }

    private static func mflFormatHint(lines: [Line]) -> String {
        let rec = lines.first {
            let l = $0.label.lowercased()
            return l.contains("reception") || $0.label == "CC" || $0.label == "Rec"
        }
        guard let pts = rec?.points else { return "custom" }
        if pts >= 0.9 { return "PPR" }
        if pts >= 0.4 { return "half-PPR" }
        if abs(pts) < 0.01 { return "standard" }
        return "custom"
    }

    private static func espnFormatHint(lines: [Line]) -> String {
        // ESPN receptions ≈ statId 53 ("Each reception") or 41.
        let rec = lines.first {
            let l = $0.label.lowercased()
            return l.contains("reception") || l == "each reception"
        }
        guard let pts = rec?.points else { return "custom" }
        if pts >= 0.9 { return "PPR" }
        if pts >= 0.4 { return "half-PPR" }
        if abs(pts) < 0.01 { return "standard" }
        return "custom"
    }

    private static func sleeperLabel(_ key: String) -> String {
        Self.sleeperLabels[key] ?? key.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    private static let sleeperLabels: [String: String] = [
        "pass_yd": "Pass YD",
        "pass_td": "Pass TD",
        "pass_int": "INT thrown",
        "pass_2pt": "Pass 2PT",
        "pass_att": "Pass att",
        "pass_cmp": "Pass CMP",
        "pass_sack": "Sacked",
        "rush_yd": "Rush YD",
        "rush_td": "Rush TD",
        "rush_2pt": "Rush 2PT",
        "rush_att": "Rush att",
        "rec": "Reception",
        "rec_yd": "Rec YD",
        "rec_td": "Rec TD",
        "rec_2pt": "Rec 2PT",
        "fum": "Fumble",
        "fum_lost": "Fumble lost",
        "fum_rec": "Fumble recovered",
        "fgm": "FG made",
        "fgm_0_19": "FG 0-19",
        "fgm_20_29": "FG 20-29",
        "fgm_30_39": "FG 30-39",
        "fgm_40_49": "FG 40-49",
        "fgm_50p": "FG 50+",
        "fgmiss": "FG miss",
        "fgmiss_0_19": "FG miss 0-19",
        "fgmiss_20_29": "FG miss 20-29",
        "fgmiss_30_39": "FG miss 30-39",
        "fgmiss_40_49": "FG miss 40-49",
        "fgmiss_50p": "FG miss 50+",
        "xpm": "XP made",
        "xpmiss": "XP miss",
        "def_td": "DEF TD",
        "pts_allow_0": "PA 0",
        "pts_allow_1_6": "PA 1-6",
        "pts_allow_7_13": "PA 7-13",
        "pts_allow_14_20": "PA 14-20",
        "pts_allow_21_27": "PA 21-27",
        "pts_allow_28_34": "PA 28-34",
        "pts_allow_35p": "PA 35+",
        "sack": "Sack",
        "int": "INT",
        "safe": "Safety",
        "blk_kick": "Blocked kick",
        "ff": "Forced fumble",
        "st_td": "ST TD",
        "st_ff": "ST FF",
        "st_fum_rec": "ST fum rec",
        "bonus_pass_yd_300": "Pass 300+ bonus",
        "bonus_pass_yd_400": "Pass 400+ bonus",
        "bonus_rush_yd_100": "Rush 100+ bonus",
        "bonus_rush_yd_200": "Rush 200+ bonus",
        "bonus_rec_yd_100": "Rec 100+ bonus",
        "bonus_rec_yd_200": "Rec 200+ bonus",
        "idp_tkl_solo": "IDP solo tackle",
        "idp_tkl_ast": "IDP assist",
        "idp_tkl": "IDP tackle",
        "idp_sack": "IDP sack",
        "idp_int": "IDP INT",
        "idp_ff": "IDP FF",
        "idp_fum_rec": "IDP fum rec",
        "idp_safe": "IDP safety",
        "idp_blk": "IDP block",
        "idp_pass_def": "IDP PD"
    ]

    private struct ESPNStatMeta {
        let abbr: String
        let label: String
    }

    private static func espnStatMeta(_ id: Int) -> ESPNStatMeta? {
        Self.espnStatMap[id]
    }

    /// Subset of ESPN SETTINGS_SCORING_FORMAT_MAP (common fantasy football stats).
    private static let espnStatMap: [Int: ESPNStatMeta] = [
        0: .init(abbr: "PA", label: "Pass attempted"),
        1: .init(abbr: "PC", label: "Pass completed"),
        2: .init(abbr: "INC", label: "Incomplete pass"),
        3: .init(abbr: "PY", label: "Passing yards"),
        4: .init(abbr: "PTD", label: "Pass TD"),
        5: .init(abbr: "PY5", label: "Every 5 pass yards"),
        6: .init(abbr: "PY10", label: "Every 10 pass yards"),
        7: .init(abbr: "PY20", label: "Every 20 pass yards"),
        8: .init(abbr: "PY25", label: "Every 25 pass yards"),
        9: .init(abbr: "PY50", label: "Every 50 pass yards"),
        10: .init(abbr: "PY100", label: "Every 100 pass yards"),
        15: .init(abbr: "PTD40", label: "40+ yard Pass TD bonus"),
        16: .init(abbr: "PTD50", label: "50+ yard Pass TD bonus"),
        17: .init(abbr: "P300", label: "300-399 pass yards"),
        18: .init(abbr: "P400", label: "400+ pass yards"),
        19: .init(abbr: "2PC", label: "Pass 2PT"),
        20: .init(abbr: "INTT", label: "INT thrown"),
        23: .init(abbr: "RA", label: "Rush attempt"),
        24: .init(abbr: "RY", label: "Rushing yards"),
        25: .init(abbr: "RTD", label: "Rush TD"),
        26: .init(abbr: "2PR", label: "Rush 2PT"),
        27: .init(abbr: "RY5", label: "Every 5 rush yards"),
        28: .init(abbr: "RY10", label: "Every 10 rush yards"),
        35: .init(abbr: "RTD40", label: "40+ yard Rush TD bonus"),
        36: .init(abbr: "RTD50", label: "50+ yard Rush TD bonus"),
        37: .init(abbr: "RY100", label: "100-199 rush yards"),
        38: .init(abbr: "RY200", label: "200+ rush yards"),
        41: .init(abbr: "RECS", label: "Receptions"),
        42: .init(abbr: "REY", label: "Receiving yards"),
        43: .init(abbr: "RETD", label: "Rec TD"),
        44: .init(abbr: "2PRE", label: "Rec 2PT"),
        45: .init(abbr: "RETD40", label: "40+ yard Rec TD bonus"),
        46: .init(abbr: "RETD50", label: "50+ yard Rec TD bonus"),
        53: .init(abbr: "REC", label: "Reception"),
        56: .init(abbr: "REY100", label: "100-199 rec yards"),
        57: .init(abbr: "REY200", label: "200+ rec yards"),
        63: .init(abbr: "FTD", label: "Fumble recovered for TD"),
        68: .init(abbr: "FUM", label: "Fumble"),
        72: .init(abbr: "FUML", label: "Fumble lost"),
        74: .init(abbr: "FG50P", label: "FG 50+"),
        77: .init(abbr: "FG40", label: "FG 40-49"),
        80: .init(abbr: "FG0", label: "FG 0-39"),
        83: .init(abbr: "FG", label: "FG made"),
        85: .init(abbr: "FGM", label: "FG missed"),
        86: .init(abbr: "PAT", label: "PAT made"),
        88: .init(abbr: "PATM", label: "PAT missed"),
        89: .init(abbr: "PA0", label: "PA 0"),
        90: .init(abbr: "PA1", label: "PA 1-6"),
        91: .init(abbr: "PA7", label: "PA 7-13"),
        92: .init(abbr: "PA14", label: "PA 14-17"),
        93: .init(abbr: "BLKKRTD", label: "Blocked return TD"),
        94: .init(abbr: "DEFRETTD", label: "Fum/INT return TD"),
        95: .init(abbr: "INT", label: "Interception"),
        96: .init(abbr: "FR", label: "Fumble recovered"),
        97: .init(abbr: "BLKK", label: "Blocked kick"),
        98: .init(abbr: "SF", label: "Safety"),
        99: .init(abbr: "SK", label: "Sack"),
        101: .init(abbr: "KRTD", label: "KR TD"),
        102: .init(abbr: "PRTD", label: "PR TD"),
        103: .init(abbr: "INTTD", label: "INT return TD"),
        104: .init(abbr: "FRTD", label: "Fumble return TD"),
        105: .init(abbr: "TRTD", label: "Return TD"),
        106: .init(abbr: "FF", label: "Forced fumble"),
        107: .init(abbr: "TKA", label: "Assisted tackle"),
        108: .init(abbr: "TKS", label: "Solo tackle"),
        109: .init(abbr: "TK", label: "Total tackles"),
        113: .init(abbr: "PD", label: "Pass defended"),
        114: .init(abbr: "KR", label: "KR yards"),
        115: .init(abbr: "PR", label: "PR yards"),
        120: .init(abbr: "PTSA", label: "Points allowed"),
        121: .init(abbr: "PA18", label: "PA 18-21"),
        122: .init(abbr: "PA22", label: "PA 22-27"),
        123: .init(abbr: "PA28", label: "PA 28-34"),
        124: .init(abbr: "PA35", label: "PA 35-45"),
        125: .init(abbr: "PA46", label: "PA 46+")
    ]

    // MARK: - JSON helpers

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(d) }
        return textNode(any)
    }

    /// MFL often wraps scalars as `{ "$t": "value" }`.
    private static func textNode(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let dict = any as? [String: Any], let t = dict["$t"] as? String { return t }
        return nil
    }

    private static func arrayOfDicts(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let one = any as? [String: Any] { return [one] }
        if let arr = any as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func arrayOfAny(_ any: Any?) -> [Any] {
        if let arr = any as? [Any] { return arr }
        if let one = any { return [one] }
        return []
    }
}
