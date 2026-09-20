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
}

struct SummaryCallout: Codable, Hashable, Identifiable {
    var id: String { "\(title)|\(detail)" }
    var title: String
    var detail: String
    /// Optional badge: START | SIT | HOLD | UP | DOWN | NEWS
    var badge: String?
}

struct SummaryChartPoint: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    var value: Double
    var secondary: Double? = nil
    var highlight: Bool? = nil
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
}

struct LeagueWeekSummaryContent: Codable, Hashable {
    var recap: String
    var matchupScores: [SummaryChartPoint]
    var pfLeaders: [SummaryChartPoint]
    var movers: [SummaryCallout]
    var transactionImpacts: [SummaryCallout]
    var lookingAhead: String
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
        let raw = trimmed.extractJSONObject() ?? trimmed
        if let data = raw.data(using: .utf8),
           let doc = try? JSONDecoder().decode(WeekSummaryDocument.self, from: data),
           doc.version >= 1 {
            return doc
        }
        // Legacy plain-text summaries → wrap so UI still renders.
        guard !trimmed.isEmpty else { return nil }
        return WeekSummaryDocument(
            version: WeekSummaryDocument.currentVersion,
            kind: "unknown",
            week: 0,
            headline: String(trimmed.prefix(120)),
            team: TeamWeekSummaryContent(
                matchupBlurb: trimmed,
                resultLabel: nil,
                myScore: nil,
                oppScore: nil,
                opponentName: nil,
                starterScores: [],
                sitStart: [],
                injuriesNews: [],
                scoringNotes: [],
                nextActions: []
            ),
            league: nil
        )
    }
}
