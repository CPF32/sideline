import Foundation
import SwiftData

@Model
final class LinkedFranchise {
    @Attribute(.unique) var id: String
    var leagueId: String
    var leagueName: String
    var franchiseId: String
    var franchiseName: String
    var host: String
    var season: Int
    var updatedAt: Date
    /// `mfl` or `sleeper` — defaults for lightweight migration of existing links.
    var providerRaw: String = LeagueProvider.mfl.rawValue
    /// Sleeper user_id when provider is sleeper (empty for MFL).
    var sleeperUserId: String = ""

    var provider: LeagueProvider {
        get { LeagueProvider(rawValue: providerRaw) ?? .mfl }
        set { providerRaw = newValue.rawValue }
    }

    var isSleeper: Bool {
        if provider == .sleeper { return true }
        // Fallbacks if SwiftData migration left providerRaw defaulted.
        if id.hasPrefix("sleeper|") { return true }
        if host.localizedCaseInsensitiveContains("sleeper") { return true }
        return false
    }
    var isMFL: Bool { !isSleeper }

    init(
        leagueId: String,
        leagueName: String,
        franchiseId: String,
        franchiseName: String,
        host: String,
        season: Int,
        provider: LeagueProvider = .mfl,
        sleeperUserId: String = ""
    ) {
        self.id = LinkedFranchise.makeId(
            provider: provider,
            leagueId: leagueId,
            franchiseId: franchiseId
        )
        self.leagueId = leagueId
        self.leagueName = leagueName
        self.franchiseId = franchiseId
        self.franchiseName = franchiseName
        self.host = host
        self.season = season
        self.providerRaw = provider.rawValue
        self.sleeperUserId = sleeperUserId
        self.updatedAt = .now
    }

    static func makeId(provider: LeagueProvider, leagueId: String, franchiseId: String) -> String {
        "\(provider.rawValue)|\(leagueId)|\(franchiseId)"
    }

    /// Matches new ids and legacy MFL `leagueId-franchiseId` rows.
    static func matches(
        _ link: LinkedFranchise,
        provider: LeagueProvider,
        leagueId: String,
        franchiseId: String
    ) -> Bool {
        if link.id == makeId(provider: provider, leagueId: leagueId, franchiseId: franchiseId) {
            return true
        }
        if provider == .mfl, link.id == "\(leagueId)-\(franchiseId)" {
            return true
        }
        return link.provider == provider
            && link.leagueId == leagueId
            && link.franchiseId == franchiseId
    }
}

struct MFLLeagueSummary: Identifiable, Hashable {
    var id: String { "\(leagueId)-\(franchiseId)" }
    let leagueId: String
    let name: String
    let franchiseId: String
    let franchiseName: String
    let host: String
    let url: String?
}

struct RosterPlayer: Identifiable, Hashable, Codable {
    var id: String { playerId }
    let playerId: String
    var name: String
    var position: String
    var team: String
    var status: String // starter | bench | ir | taxi | fa
    var projectedPoints: Double?
    /// Live / final fantasy points for the selected week (from liveScoring / playerScores).
    var actualPoints: Double? = nil
    var seasonPoints: Double? = nil
    var lastWeekPoints: Double? = nil
    var opponent: String?
    var injuryStatus: String?
    /// upcoming | started | final | bye | unknown
    var gameLockState: String? = nil
    var gameKickoff: Date? = nil
    /// NFL game clock seconds remaining (from MFL nflSchedule).
    var gameSecondsRemaining: Int? = nil
    /// League salary units from MFL (typically full dollars).
    var salary: Double? = nil
    var contractYear: Int? = nil

    /// Prefer live/final points once the NFL game has started; otherwise projection.
    /// Never show matchup zeros / stale actuals as "live" for upcoming / unknown / bye.
    var displayWeekPoints: (value: Double, isLive: Bool)? {
        let lock = gameLockState ?? "upcoming"
        switch lock {
        case "started":
            if let actual = actualPoints { return (actual, true) }
            if let proj = projectedPoints { return (proj, false) }
            return nil
        case "final":
            if let actual = actualPoints { return (actual, false) }
            return nil
        default:
            // upcoming | bye | unknown — projection only; omit if unavailable
            if let proj = projectedPoints { return (proj, false) }
            return nil
        }
    }

    /// Compact game-status label for roster rows (clock instead of bare STARTED).
    var gameStatusLabel: String? {
        switch gameLockState {
        case nil, "", "upcoming", "unknown":
            return nil
        case "bye":
            return "BYE"
        case "final":
            return "FINAL"
        case "started":
            if let secs = gameSecondsRemaining, secs > 0 {
                let m = secs / 60
                let s = secs % 60
                return String(format: "%d:%02d", m, s)
            }
            return "LIVE"
        default:
            return gameLockState?.uppercased()
        }
    }

    func replacing(
        status: String? = nil,
        name: String? = nil,
        position: String? = nil,
        team: String? = nil,
        projectedPoints: Double? = nil,
        actualPoints: Double? = nil,
        opponent: String? = nil,
        injuryStatus: String? = nil,
        salary: Double? = nil,
        contractYear: Int? = nil
    ) -> RosterPlayer {
        RosterPlayer(
            playerId: playerId,
            name: name ?? self.name,
            position: position ?? self.position,
            team: team ?? self.team,
            status: status ?? self.status,
            projectedPoints: projectedPoints ?? self.projectedPoints,
            actualPoints: actualPoints ?? self.actualPoints,
            seasonPoints: seasonPoints,
            lastWeekPoints: lastWeekPoints,
            opponent: opponent ?? self.opponent,
            injuryStatus: injuryStatus ?? self.injuryStatus,
            gameLockState: gameLockState,
            gameKickoff: gameKickoff,
            gameSecondsRemaining: gameSecondsRemaining,
            salary: salary ?? self.salary,
            contractYear: contractYear ?? self.contractYear
        )
    }
}

struct MatchupSnapshot: Hashable, Codable {
    var week: Int
    var myScore: Double?
    var oppScore: Double?
    var opponentName: String?
    var lineupDeadline: Date?
}

/// Franchise opponent for a future (or past) week, used on the Team tab schedule strip.
struct UpcomingMatchupPreview: Identifiable, Hashable {
    var id: Int { week }
    let week: Int
    let opponentName: String
    var isHome: Bool?
}

struct TeamSnapshot: Hashable, Codable {
    var leagueId: String
    var franchiseId: String
    var leagueName: String
    var franchiseName: String
    var week: Int
    /// Season points for (year-to-date), not the selected week's score.
    var seasonPointsFor: Double?
    var starters: [RosterPlayer]
    var bench: [RosterPlayer]
    var ir: [RosterPlayer]
    var taxi: [RosterPlayer]
    var matchup: MatchupSnapshot?
    var leagueRules: LeagueRules?
    /// Sum of rostered player salaries (when the league uses salaries).
    var totalSalary: Double? = nil
    var syncedAt: Date

    var allRostered: [RosterPlayer] { starters + bench + ir + taxi }

    var salaryCap: Double? { leagueRules?.salaryCapAmount }
}

/// Compact money labels: 4_500_000 → "$4.5M", 750_000 → "$750K".
enum SalaryFormat {
    static func compact(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let abs = Swift.abs(value)
        if abs >= 1_000_000 {
            let m = abs / 1_000_000
            let body: String
            if abs.truncatingRemainder(dividingBy: 1_000_000) == 0 {
                body = String(format: "%.0fM", m)
            } else if m >= 10 || (m * 10).rounded() == m * 10 {
                // Prefer one decimal when useful (4.5M), drop trailing .0
                let one = String(format: "%.1f", m)
                body = one.hasSuffix(".0") ? "\(Int(m))M" : "\(one)M"
            } else {
                let one = String(format: "%.1f", m)
                body = one.hasSuffix(".0") ? "\(Int(m))M" : "\(one)M"
            }
            return "\(sign)$\(body)"
        }
        if abs >= 1_000 {
            let k = abs / 1_000
            if abs.truncatingRemainder(dividingBy: 1_000) == 0 {
                return "\(sign)$\(Int(k))K"
            }
            let one = String(format: "%.1f", k)
            let body = one.hasSuffix(".0") ? "\(Int(k))K" : "\(one)K"
            return "\(sign)$\(body)"
        }
        if abs == abs.rounded() {
            return "\(sign)$\(Int(abs))"
        }
        return "\(sign)$\(String(format: "%.0f", abs))"
    }

    static func compactOptional(_ value: Double?) -> String? {
        guard let value else { return nil }
        return compact(value)
    }
}

struct LineupSlotPick: Codable, Hashable, Identifiable {
    var id: String { "\(slot)-\(playerId)" }
    /// Starter slot label from league rules (QB, RB, WR, TE, FLEX, etc.).
    var slot: String
    var playerId: String
    var name: String?
    var reason: String?
}

struct LineupPayload: Codable {
    var week: Int
    var starterIds: [String]
    var irIds: [String]?
    var taxiIds: [String]?
    var comments: String?
    /// false when the desk cannot build a legal lineup with the current roster.
    /// Missing on decode → treat as blocked for safety (do not auto-approve).
    var canAutoSet: Bool? = nil
    var blockers: [String]? = nil
    var requiredChanges: [String]? = nil
    /// Per-slot picks with reasons (preferred display for Approvals).
    var slots: [LineupSlotPick]? = nil

    /// True only when explicitly marked auto-settable.
    var isAutoSettable: Bool { canAutoSet == true }
}

enum ProposalKind: String, Codable, CaseIterable, Identifiable {
    case lineup
    case waiver
    case trade
    case draft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lineup: return "Lineup"
        case .waiver: return "Waiver / FA"
        case .trade: return "Trade"
        case .draft: return "Draft"
        }
    }
}

enum ProposalStatus: String, Codable {
    case pending
    case approved
    case rejected
    case applied
    case failed
}

@Model
final class ActionProposal {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var statusRaw: String
    var title: String
    var summary: String
    var rationale: String
    var risks: String
    var payloadJSON: String
    var agentName: String
    var createdAt: Date
    var resolvedAt: Date?
    var applyResult: String?

    var kind: ProposalKind {
        get { ProposalKind(rawValue: kindRaw) ?? .lineup }
        set { kindRaw = newValue.rawValue }
    }

    var status: ProposalStatus {
        get { ProposalStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        kind: ProposalKind,
        title: String,
        summary: String,
        rationale: String,
        risks: String,
        payloadJSON: String,
        agentName: String
    ) {
        self.id = UUID().uuidString
        self.kindRaw = kind.rawValue
        self.statusRaw = ProposalStatus.pending.rawValue
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.risks = risks
        self.payloadJSON = payloadJSON
        self.agentName = agentName
        self.createdAt = .now
    }
}

/// Follow-up discussion thread tied to a proposal (approval or notice).
@Model
final class AgentChatThread {
    @Attribute(.unique) var id: String
    var proposalId: String
    var title: String
    var agentName: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \AgentChatMessage.thread)
    var messages: [AgentChatMessage]

    init(proposalId: String, title: String, agentName: String) {
        self.id = UUID().uuidString
        self.proposalId = proposalId
        self.title = title
        self.agentName = agentName
        self.createdAt = .now
        self.updatedAt = .now
        self.messages = []
    }
}

@Model
final class AgentChatMessage {
    @Attribute(.unique) var id: String
    var roleRaw: String // user | assistant | system
    var content: String
    var createdAt: Date
    var thread: AgentChatThread?

    var role: String {
        get { roleRaw }
        set { roleRaw = newValue }
    }

    init(role: String, content: String, thread: AgentChatThread? = nil) {
        self.id = UUID().uuidString
        self.roleRaw = role
        self.content = content
        self.createdAt = .now
        self.thread = thread
    }
}

@Model
final class ActivityEvent {
    @Attribute(.unique) var id: String
    var message: String
    var detail: String
    var createdAt: Date

    init(message: String, detail: String = "") {
        self.id = UUID().uuidString
        self.message = message
        self.detail = detail
        self.createdAt = .now
    }
}

enum WeekSummaryKind: String, Codable, CaseIterable, Identifiable {
    case team
    case league

    var id: String { rawValue }

    var title: String {
        switch self {
        case .team: return "Team summary"
        case .league: return "League summary"
        }
    }
}

/// One immutable AI summary per league/season/week/kind (team summaries also keyed by franchise).
@Model
final class PersistedWeekSummary {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var leagueId: String
    var franchiseId: String
    var season: Int
    var week: Int
    var body: String
    var modelLabel: String
    var createdAt: Date

    var kind: WeekSummaryKind {
        get { WeekSummaryKind(rawValue: kindRaw) ?? .team }
        set { kindRaw = newValue.rawValue }
    }

    init(
        kind: WeekSummaryKind,
        leagueId: String,
        franchiseId: String,
        season: Int,
        week: Int,
        body: String,
        modelLabel: String
    ) {
        self.id = Self.makeId(
            kind: kind,
            leagueId: leagueId,
            franchiseId: franchiseId,
            season: season,
            week: week
        )
        self.kindRaw = kind.rawValue
        self.leagueId = leagueId
        self.franchiseId = franchiseId
        self.season = season
        self.week = week
        self.body = body
        self.modelLabel = modelLabel
        self.createdAt = .now
    }

    static func makeId(
        kind: WeekSummaryKind,
        leagueId: String,
        franchiseId: String,
        season: Int,
        week: Int
    ) -> String {
        let franchiseKey = kind == .league ? "league" : franchiseId
        return "\(kind.rawValue)|\(leagueId)|\(franchiseKey)|\(season)|\(week)"
    }
}

/// In-memory view of a stored summary (avoids publishing SwiftData models).
struct CachedWeekSummary: Hashable {
    let id: String
    let kind: WeekSummaryKind
    let week: Int
    let body: String
    let modelLabel: String
    let createdAt: Date

    var document: WeekSummaryDocument? {
        WeekSummaryDocumentCodec.decode(from: body)
    }
}

struct GuardrailSettings: Codable, Equatable {
    var neverBenchPlayerIds: [String] = []
    var neverDropPlayerIds: [String] = []
    var neverTradePlayerIds: [String] = []
    var maxFAABBid: Double?
    var stopHoursBeforeKickoff: Double = 1
    var lineupDeskEnabled: Bool = true
    var waiverDeskEnabled: Bool = true
    var tradeDeskEnabled: Bool = true
    var draftDeskEnabled: Bool = true

    static let storageKey = "sideline.guardrails"
}

struct WaiverPayload: Codable {
    var addPlayerId: String?
    var dropPlayerId: String?
    var bid: Double?
    var notes: String?
}

struct TradePayload: Codable {
    var givePlayerIds: [String]
    var receivePlayerIds: [String]
    /// MFL-style pick ids, e.g. FP_0003_2027_2
    var givePickIds: [String]? = nil
    var receivePickIds: [String]? = nil
    var partnerFranchiseId: String?
    var notes: String?
}

struct DraftPayload: Codable {
    var pickPlayerId: String?
    var pickNumber: Int?
    var notes: String?
}
