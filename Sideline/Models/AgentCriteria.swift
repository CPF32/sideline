import Foundation

/// Per-agent goals and decision criteria the user customizes for their team.
struct AgentCriteriaBundle: Codable, Equatable {
    var lineup: LineupCriteria = .init()
    var waiver: WaiverCriteria = .init()
    var trade: TradeCriteria = .init()
    var draft: DraftCriteria = .init()
    var teamGoals: String = ""

    static let storageKey = "sideline.agentCriteria"
}

struct LineupCriteria: Codable, Equatable {
    var enabled: Bool = true
    var goal: String = "Set a legal starting lineup for this week that maximizes projected points among players whose games have not started yet. Never newly start players who already played earlier in the week; keep locked starters who already played. Also fix IR/taxi compliance when needed."
    var riskTolerance: RiskTolerance = .balanced
    var preferCeiling: Bool = false
    var avoidQuestionable: Bool = true
    var stackPreference: String = "" // e.g. "QB+WR same NFL team when viable"
    var notes: String = ""
}

struct WaiverCriteria: Codable, Equatable {
    var enabled: Bool = true
    var goal: String = "Always return 1–3 concrete add/drop (or FAAB bid) proposals using free-agent IDs from context. Prioritize bye/injury holes, then WEAK positions vs the league, then upside. Prefer adds that fix roster-setup gaps over BPA at already-STRONG positions. If the roster is full, pair every add with a drop (prefer dropping depth at STRONG positions)."
    var riskTolerance: RiskTolerance = .balanced
    var maxFAABPercent: Double = 25
    var prioritizeNeedOverBestAvailable: Bool = true
    var stashHandcuffs: Bool = false
    var notes: String = ""
}

struct TradeCriteria: Codable, Equatable {
    var enabled: Bool = true
    var goal: String = "Propose realistic trades (players and/or draft picks) that improve championship odds. Fix WEAK positions by trading from STRONG ones or using picks. Use only rostered player IDs and pickIds from context; name a partner franchise when possible."
    var riskTolerance: RiskTolerance = .balanced
    var contendMode: ContendMode = .contend
    var preferSidewaysOverPanic: Bool = true
    var targetPositions: String = "" // e.g. "RB depth, WR1"
    var notes: String = ""
}

struct DraftCriteria: Codable, Equatable {
    var enabled: Bool = true
    var goal: String = "Recommend the best next pick given remaining needs and board value. Prefer elite RB/WR early unless an elite QB falls; late rounds favor upside and handcuffs."
    var riskTolerance: RiskTolerance = .balanced
    var earlyRoundBias: String = "Elite RB/WR unless elite QB falls"
    var lateRoundBias: String = "Upside flyers and handcuffs"
    var notes: String = ""
}

enum RiskTolerance: String, Codable, CaseIterable, Identifiable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        }
    }
}

enum ContendMode: String, Codable, CaseIterable, Identifiable {
    case contend
    case rebuild
    case winNow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contend: return "Contend"
        case .rebuild: return "Rebuild"
        case .winNow: return "Win now"
        }
    }
}

enum AgentCriteriaStore {
    static func load() -> AgentCriteriaBundle {
        guard let data = UserDefaults.standard.data(forKey: AgentCriteriaBundle.storageKey),
              var value = try? JSONDecoder().decode(AgentCriteriaBundle.self, from: data)
        else { return AgentCriteriaBundle() }
        value.lineup.enabled = true
        value.waiver.enabled = true
        value.trade.enabled = true
        value.draft.enabled = true
        return value
    }

    static func save(_ bundle: AgentCriteriaBundle) {
        if let data = try? JSONEncoder().encode(bundle) {
            UserDefaults.standard.set(data, forKey: AgentCriteriaBundle.storageKey)
        }
    }
}

// MARK: - League review models

struct LeagueStandingRow: Identifiable, Hashable {
    var id: String { franchiseId }
    let franchiseId: String
    let name: String
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let rank: Int?
    /// Spots moved since last sync: positive = rose, negative = fell, nil = unknown.
    var rankDelta: Int? = nil
}

struct LeagueTransactionRow: Identifiable, Hashable {
    let id: String
    let timestamp: Date?
    let franchiseId: String
    let franchiseName: String
    let summary: String
    let type: String
}

struct LeagueMatchupRow: Identifiable, Hashable {
    let id: String
    let homeName: String
    let awayName: String
    let homeScore: Double?
    let awayScore: Double?
}

struct LeagueReviewSnapshot: Hashable {
    var week: Int
    var standings: [LeagueStandingRow]
    var transactions: [LeagueTransactionRow]
    var matchups: [LeagueMatchupRow]
    var syncedAt: Date
}
