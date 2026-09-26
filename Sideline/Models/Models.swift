import Foundation
import SwiftData
import SwiftUI

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
    /// `mfl`, `sleeper`, or `espn` — defaults for lightweight migration of existing links.
    var providerRaw: String = LeagueProvider.mfl.rawValue
    /// Sleeper user_id when provider is sleeper (empty for MFL / ESPN).
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

    var isESPN: Bool {
        if provider == .espn { return true }
        if id.hasPrefix("espn|") { return true }
        if host.localizedCaseInsensitiveContains("espn") { return true }
        return false
    }

    var isMFL: Bool {
        if provider == .mfl {
            // Don't treat mis-tagged rows as MFL when id/host clearly say otherwise.
            if isSleeper || isESPN { return false }
            return true
        }
        // Legacy rows before providerRaw existed: defaulted to mfl and used leagueId-franchiseId ids.
        if isSleeper || isESPN { return false }
        if id.contains("|") { return false }
        return !host.localizedCaseInsensitiveContains("sleeper")
            && !host.localizedCaseInsensitiveContains("espn")
    }

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

enum WeekPointsKind: Equatable {
    case projected
    case live
    case final

    var label: String {
        switch self {
        case .projected: return "proj"
        case .live: return "live"
        case .final: return "final"
        }
    }

    var dotColor: Color {
        switch self {
        case .projected: return BrandTheme.muted.opacity(0.55)
        case .live: return BrandTheme.accent
        case .final: return BrandTheme.finalPoints
        }
    }
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
    /// Host lineup slot when known (ESPN `lineupSlotId` → QB, WR, RB/WR/TE, …).
    /// Used so matchup rows follow the actual slot, not a re-bucket by player position.
    var lineupSlot: String? = nil

    /// IR / Q / D / OUT (or IR roster slot) with no host projection → still show 0.
    var treatsMissingProjectionAsZero: Bool {
        if status == "ir" { return true }
        return InjuryStatusWeight.shortDisplayTag(injuryStatus) != nil
    }

    /// Prefer live/final points once the NFL game has started; otherwise projection.
    /// Never show matchup zeros / stale actuals as "live" for upcoming / unknown / bye.
    var displayWeekPoints: (value: Double, kind: WeekPointsKind)? {
        let lock = gameLockState ?? "upcoming"
        switch lock {
        case "started":
            if let actual = actualPoints { return (actual, .live) }
            if let proj = projectedPoints { return (proj, .projected) }
            if treatsMissingProjectionAsZero { return (0, .projected) }
            return nil
        case "final":
            if let actual = actualPoints { return (actual, .final) }
            return nil
        case "bye":
            // Host projections can lag the schedule — bye week is always 0.
            return (0, .projected)
        default:
            // upcoming | unknown — projection only; omit if unavailable
            if let proj = projectedPoints { return (proj, .projected) }
            if treatsMissingProjectionAsZero { return (0, .projected) }
            return nil
        }
    }

    /// Compact game-status label for roster rows / profile header.
    /// Live → clock; upcoming → kickoff schedule; final / bye as-is.
    var gameStatusLabel: String? {
        switch gameLockState {
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
        case "upcoming", nil, "":
            guard let kickoff = gameKickoff else { return nil }
            return Self.formatKickoffSchedule(kickoff)
        case "unknown":
            guard let kickoff = gameKickoff else { return nil }
            return Self.formatKickoffSchedule(kickoff)
        default:
            if let kickoff = gameKickoff { return Self.formatKickoffSchedule(kickoff) }
            return gameLockState?.uppercased()
        }
    }

    /// Compact schedule chip: `Sun 1:00p`, `Mon 8:15p` (weekday abbr always).
    static func formatKickoffSchedule(_ date: Date) -> String {
        let time: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mma"
            return f
        }()
        let raw = time.string(from: date)
            .replacingOccurrences(of: "AM", with: "a")
            .replacingOccurrences(of: "PM", with: "p")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEE"
        return "\(day.string(from: date)) \(raw)"
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
            contractYear: contractYear ?? self.contractYear,
            lineupSlot: lineupSlot
        )
    }
}

struct MatchupSnapshot: Hashable, Codable {
    var week: Int
    var myScore: Double?
    var oppScore: Double?
    var opponentName: String?
    /// Host franchise / roster id for the opponent (MFL franchise, Sleeper roster_id, ESPN teamId).
    var opponentFranchiseId: String? = nil
    var lineupDeadline: Date?
    /// Opponent starters in active NFL games — `Name  12.3` for Live Activity cycling.
    var oppLivePlayerLines: [String] = []
    /// Host-supplied win probability for "mine" (0...1), when the league API provides one.
    /// None of MFL / Sleeper / ESPN return this today, so it's always computed locally —
    /// this field exists so a future provider (or host update) can be preferred over that.
    var myWinProbability: Double? = nil
}

/// Franchise opponent for a future (or past) week, used on the Team tab schedule strip.
struct UpcomingMatchupPreview: Identifiable, Hashable, Codable {
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
    /// Opponent week lineup for the Matchup swipe panes.
    var opponentStarters: [RosterPlayer] = []
    var opponentBench: [RosterPlayer] = []
    var matchup: MatchupSnapshot?
    var leagueRules: LeagueRules?
    /// Point values from the host (MFL rules / Sleeper scoring_settings / ESPN scoringItems).
    var scoringRules: ScoringRules? = nil
    /// Sum of rostered player salaries (when the league uses salaries).
    var totalSalary: Double? = nil
    var syncedAt: Date

    var allRostered: [RosterPlayer] { starters + bench + ir + taxi }

    var salaryCap: Double? { leagueRules?.salaryCapAmount }

    /// Projected starter totals (sum of available projections).
    var myProjectedStarterTotal: Double? {
        Self.projectedTotal(starters)
    }

    var oppProjectedStarterTotal: Double? {
        Self.projectedTotal(opponentStarters)
    }

    /// Actual fantasy points from starters whose NFL games have started or finished.
    /// Returns `nil` when nobody on this side has kicked off yet.
    static func scoredSoFar(starters: [RosterPlayer]) -> Double? {
        let played = starters.filter {
            let lock = $0.gameLockState ?? "upcoming"
            return lock == "started" || lock == "final"
        }
        guard !played.isEmpty else { return nil }
        return played.reduce(0) { $0 + ($1.actualPoints ?? 0) }
    }

    /// True when any starter on either side has an in-progress or finished NFL game.
    var hasStartedOrFinalGames: Bool {
        (starters + opponentStarters).contains {
            let lock = $0.gameLockState ?? "upcoming"
            return lock == "started" || lock == "final"
        }
    }

    /// Locally modeled win probability plus each side's projected final score (see
    /// `WinProbabilityCalculator`) — `nil` when there isn't a lineup on either side yet.
    var winProbabilityResult: WinProbabilityCalculator.Result? {
        WinProbabilityCalculator.evaluate(mine: starters, opponent: opponentStarters)
    }

    /// Probability (0...1) that "mine" finishes with the higher score. Prefers a host-supplied
    /// figure when present; otherwise the locally modeled result above.
    var winProbability: Double? {
        matchup?.myWinProbability ?? winProbabilityResult?.myProbability
    }

    /// Replace host matchup totals with points-from-players-who-have-played once the slate is live.
    /// Avoids showing full-week projections (or stale host aggregates) as the live score.
    func applyingScoredSoFarToMatchup() -> TeamSnapshot {
        guard hasStartedOrFinalGames, var m = matchup else { return self }
        m.myScore = Self.scoredSoFar(starters: starters) ?? 0
        m.oppScore = Self.scoredSoFar(starters: opponentStarters) ?? 0
        var copy = self
        copy.matchup = m
        return copy
    }

    private static func projectedTotal(_ players: [RosterPlayer]) -> Double? {
        let values = players.compactMap(\.projectedPoints)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

/// Swipe panes on the Team tab (left = my team, right = matchup).
enum MatchupRosterPane: Int, CaseIterable, Identifiable {
    case mine = 0
    case matchup = 1

    var id: Int { rawValue }
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

/// Single-row SwiftData document for user settings (model, guardrails, theme, etc.).
/// API keys stay in Keychain — never written here.
@Model
final class UserPreferences {
    static let singletonId = "device"

    @Attribute(.unique) var id: String
    var llmProviderRaw: String
    var llmModel: String
    /// JSON object `{ "openai": "gpt-4o", "openrouter": "…", … }`
    var llmModelsByProviderJSON: Data
    var guardrailsJSON: Data
    var agentCriteriaJSON: Data
    var isDarkMode: Bool
    var liveActivityEnabled: Bool
    var fantasyProsScoringRaw: String
    var activeLeagueLinkId: String?
    var updatedAt: Date

    init(
        llmProviderRaw: String = "openai",
        llmModel: String = "gpt-4o-mini",
        llmModelsByProviderJSON: Data = Data("{}".utf8),
        guardrailsJSON: Data = (try? JSONEncoder().encode(GuardrailSettings())) ?? Data(),
        agentCriteriaJSON: Data = (try? JSONEncoder().encode(AgentCriteriaBundle())) ?? Data(),
        isDarkMode: Bool = false,
        liveActivityEnabled: Bool = false,
        fantasyProsScoringRaw: String = "HALF",
        activeLeagueLinkId: String? = nil
    ) {
        self.id = Self.singletonId
        self.llmProviderRaw = llmProviderRaw
        self.llmModel = llmModel
        self.llmModelsByProviderJSON = llmModelsByProviderJSON
        self.guardrailsJSON = guardrailsJSON
        self.agentCriteriaJSON = agentCriteriaJSON
        self.isDarkMode = isDarkMode
        self.liveActivityEnabled = liveActivityEnabled
        self.fantasyProsScoringRaw = fantasyProsScoringRaw
        self.activeLeagueLinkId = activeLeagueLinkId
        self.updatedAt = .now
    }
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
