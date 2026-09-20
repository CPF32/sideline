import Foundation

/// Fixed shape for persisted week summaries. LLM fills narrative; app fills chart facts.
struct WeekSummaryDocument: Codable, Hashable {
    var version: Int
    var kind: String
    var week: Int
    var headline: String
    var team: TeamWeekSummaryContent?
    var league: LeagueWeekSummaryContent?

    static let currentVersion = 1

    enum CodingKeys: String, CodingKey {
        case version, kind, week, headline, team, league
    }

    init(
        version: Int,
        kind: String,
        week: Int,
        headline: String,
        team: TeamWeekSummaryContent?,
        league: LeagueWeekSummaryContent?
    ) {
        self.version = version
        self.kind = kind
        self.week = week
        self.headline = headline
        self.team = team
        self.league = league
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? WeekSummaryDocument.currentVersion
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "team"
        week = try c.decodeIfPresent(Int.self, forKey: .week) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        team = try c.decodeIfPresent(TeamWeekSummaryContent.self, forKey: .team)
        league = try c.decodeIfPresent(LeagueWeekSummaryContent.self, forKey: .league)
    }
}

struct SummaryCallout: Codable, Hashable, Identifiable {
    var id: String { "\(title)|\(detail)" }
    var title: String
    var detail: String
    /// Optional badge: START | SIT | HOLD | UP | DOWN | NEWS
    var badge: String?

    enum CodingKeys: String, CodingKey {
        case title, detail, badge
    }

    init(title: String, detail: String, badge: String? = nil) {
        self.title = title
        self.detail = detail
        self.badge = badge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
    }
}

struct SummaryChartPoint: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    var value: Double
    var secondary: Double? = nil
    var highlight: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case label, value, secondary, highlight
    }

    init(label: String, value: Double, secondary: Double? = nil, highlight: Bool? = nil) {
        self.label = label
        self.value = value
        self.secondary = secondary
        self.highlight = highlight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        if let d = try c.decodeIfPresent(Double.self, forKey: .value) {
            value = d
        } else if let i = try c.decodeIfPresent(Int.self, forKey: .value) {
            value = Double(i)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .value), let d = Double(s) {
            value = d
        } else {
            value = 0
        }
        secondary = try c.decodeIfPresent(Double.self, forKey: .secondary)
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight)
    }
}

struct TeamWeekSummaryContent: Codable, Hashable {
    var matchupBlurb: String
    var resultLabel: String?
    var myScore: Double?
    var oppScore: Double?
    var opponentName: String?
    /// Starter scoring bars (filled from MFL facts).
    var starterScores: [SummaryChartPoint]
    var sitStart: [SummaryCallout]
    var injuriesNews: [SummaryCallout]
    var scoringNotes: [SummaryCallout]
    var nextActions: [String]

    enum CodingKeys: String, CodingKey {
        case matchupBlurb, resultLabel, myScore, oppScore, opponentName
        case starterScores, sitStart, injuriesNews, scoringNotes, nextActions
    }

    init(
        matchupBlurb: String,
        resultLabel: String? = nil,
        myScore: Double? = nil,
        oppScore: Double? = nil,
        opponentName: String? = nil,
        starterScores: [SummaryChartPoint] = [],
        sitStart: [SummaryCallout] = [],
        injuriesNews: [SummaryCallout] = [],
        scoringNotes: [SummaryCallout] = [],
        nextActions: [String] = []
    ) {
        self.matchupBlurb = matchupBlurb
        self.resultLabel = resultLabel
        self.myScore = myScore
        self.oppScore = oppScore
        self.opponentName = opponentName
        self.starterScores = starterScores
        self.sitStart = sitStart
        self.injuriesNews = injuriesNews
        self.scoringNotes = scoringNotes
        self.nextActions = nextActions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchupBlurb = try c.decodeIfPresent(String.self, forKey: .matchupBlurb) ?? ""
        resultLabel = try c.decodeIfPresent(String.self, forKey: .resultLabel)
        myScore = try c.decodeIfPresent(Double.self, forKey: .myScore)
        oppScore = try c.decodeIfPresent(Double.self, forKey: .oppScore)
        opponentName = try c.decodeIfPresent(String.self, forKey: .opponentName)
        starterScores = try c.decodeIfPresent([SummaryChartPoint].self, forKey: .starterScores) ?? []
        sitStart = try c.decodeIfPresent([SummaryCallout].self, forKey: .sitStart) ?? []
        injuriesNews = try c.decodeIfPresent([SummaryCallout].self, forKey: .injuriesNews) ?? []
        scoringNotes = try c.decodeIfPresent([SummaryCallout].self, forKey: .scoringNotes) ?? []
        nextActions = try c.decodeIfPresent([String].self, forKey: .nextActions) ?? []
    }
}

struct LeagueWeekSummaryContent: Codable, Hashable {
    var recap: String
    var matchupScores: [SummaryChartPoint]
    var pfLeaders: [SummaryChartPoint]
    var movers: [SummaryCallout]
    var transactionImpacts: [SummaryCallout]
    var lookingAhead: String

    enum CodingKeys: String, CodingKey {
        case recap, matchupScores, pfLeaders, movers, transactionImpacts, lookingAhead
    }

    init(
        recap: String,
        matchupScores: [SummaryChartPoint] = [],
        pfLeaders: [SummaryChartPoint] = [],
        movers: [SummaryCallout] = [],
        transactionImpacts: [SummaryCallout] = [],
        lookingAhead: String = ""
    ) {
        self.recap = recap
        self.matchupScores = matchupScores
        self.pfLeaders = pfLeaders
        self.movers = movers
        self.transactionImpacts = transactionImpacts
        self.lookingAhead = lookingAhead
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recap = try c.decodeIfPresent(String.self, forKey: .recap) ?? ""
        matchupScores = try c.decodeIfPresent([SummaryChartPoint].self, forKey: .matchupScores) ?? []
        pfLeaders = try c.decodeIfPresent([SummaryChartPoint].self, forKey: .pfLeaders) ?? []
        movers = try c.decodeIfPresent([SummaryCallout].self, forKey: .movers) ?? []
        transactionImpacts = try c.decodeIfPresent([SummaryCallout].self, forKey: .transactionImpacts) ?? []
        lookingAhead = try c.decodeIfPresent(String.self, forKey: .lookingAhead) ?? ""
    }
}

enum WeekSummaryDocumentCodec {
    static func encode(_ document: WeekSummaryDocument) throws -> String {
        let data = try JSONEncoder().encode(document)
        guard let s = String(data: data, encoding: .utf8) else {
            throw LLMClientError.decode
        }
        return s
    }

    static func decode(from body: String) -> WeekSummaryDocument? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = trimmed.extractJSONObject() ?? trimmed
        if let data = raw.data(using: .utf8),
           let doc = try? JSONDecoder().decode(WeekSummaryDocument.self, from: data) {
            return doc
        }
        // Legacy plain-text summaries → wrap so UI still renders.
        return WeekSummaryDocument(
            version: WeekSummaryDocument.currentVersion,
            kind: "unknown",
            week: 0,
            headline: String(trimmed.prefix(120)),
            team: TeamWeekSummaryContent(matchupBlurb: trimmed),
            league: nil
        )
    }
}
