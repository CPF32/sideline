import Foundation

/// Builds one-shot structured team/league week summaries (JSON → fixed UI).
enum WeekSummaryService {
    static func generate(
        kind: WeekSummaryKind,
        linked: LinkedFranchise,
        week: Int,
        team: TeamSnapshot?,
        league: LeagueReviewSnapshot?,
        llm: LLMClient,
        modelLabel: String
    ) async throws -> WeekSummaryDocument {
        _ = modelLabel
        let system: String
        let user: String
        switch kind {
        case .team:
            system = teamSystemPrompt(week: week)
            user = await teamUserContext(linked: linked, week: week, team: team)
        case .league:
            system = leagueSystemPrompt(week: week)
            user = leagueUserContext(linked: linked, week: week, league: league)
        }

        let raw = try await llm.completeJSON(system: system, user: user)
        let jsonString = raw.extractJSONObject() ?? raw
        guard let data = jsonString.data(using: .utf8) else { throw LLMClientError.decode }

        var document: WeekSummaryDocument
        do {
            document = try JSONDecoder().decode(WeekSummaryDocument.self, from: data)
        } catch {
            // Tolerate partial LLM shapes by decoding narrative-only then enriching.
            document = try decodeLoose(kind: kind, week: week, data: data)
        }

        document.version = WeekSummaryDocument.currentVersion
        document.kind = kind.rawValue
        document.week = week
        enrich(&document, kind: kind, team: team, league: league, linked: linked)
        if document.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.headline = defaultHeadline(kind: kind, week: week, team: team, league: league, linked: linked)
        }
        return document
    }

    // MARK: - Enrich with factual chart data

    private static func enrich(
        _ document: inout WeekSummaryDocument,
        kind: WeekSummaryKind,
        team: TeamSnapshot?,
        league: LeagueReviewSnapshot?,
        linked: LinkedFranchise
    ) {
        switch kind {
        case .team:
            var content = document.team ?? TeamWeekSummaryContent(
                matchupBlurb: "",
                resultLabel: nil,
                myScore: nil,
                oppScore: nil,
                opponentName: nil,
                starterScores: [],
                sitStart: [],
                injuriesNews: [],
                scoringNotes: [],
                nextActions: []
            )
            if let team {
                let my = team.matchup?.myScore
                let opp = team.matchup?.oppScore
                content.myScore = my
                content.oppScore = opp
                content.opponentName = team.matchup?.opponentName
                if content.resultLabel == nil || content.resultLabel?.isEmpty == true {
                    content.resultLabel = resultLabel(my: my, opp: opp)
                }
                content.starterScores = team.starters.prefix(10).map { p in
                    let value = p.actualPoints ?? p.displayWeekPoints?.value ?? p.projectedPoints ?? 0
                    return SummaryChartPoint(
                        label: shortName(p.name),
                        value: value,
                        secondary: p.projectedPoints,
                        highlight: (p.actualPoints ?? 0) >= 15
                    )
                }
            }
            document.team = content
        case .league:
            var content = document.league ?? LeagueWeekSummaryContent(
                recap: "",
                matchupScores: [],
                pfLeaders: [],
                movers: [],
                transactionImpacts: [],
                lookingAhead: ""
            )
            if let league {
                content.matchupScores = league.matchups.prefix(8).compactMap { m -> SummaryChartPoint? in
                    let home = m.homeScore
                    let away = m.awayScore
                    // Prefer showing the higher-scoring side as primary label for a clean bar.
                    let homeName = shortFranchise(m.homeName)
                    let awayName = shortFranchise(m.awayName)
                    let label = "\(homeName)/\(awayName)"
                    let mine = m.homeName.localizedCaseInsensitiveContains(linked.franchiseName)
                        || m.awayName.localizedCaseInsensitiveContains(linked.franchiseName)
                    return SummaryChartPoint(
                        label: label,
                        value: home ?? 0,
                        secondary: away,
                        highlight: mine
                    )
                }
                content.pfLeaders = league.standings.prefix(8).map { row in
                    SummaryChartPoint(
                        label: shortFranchise(row.name),
                        value: row.pointsFor,
                        secondary: Double(row.rank ?? 0),
                        highlight: MFLNameResolver.normalizeFranchiseId(row.franchiseId)
                            == MFLNameResolver.normalizeFranchiseId(linked.franchiseId)
                    )
                }
            }
            document.league = content
        }
    }

    private static func resultLabel(my: Double?, opp: Double?) -> String? {
        guard let my, let opp else { return nil }
        let diff = my - opp
        if abs(diff) < 0.05 { return "Tie" }
        return diff > 0
            ? String(format: "Won by %.1f", diff)
            : String(format: "Lost by %.1f", abs(diff))
    }

    private static func defaultHeadline(
        kind: WeekSummaryKind,
        week: Int,
        team: TeamSnapshot?,
        league: LeagueReviewSnapshot?,
        linked: LinkedFranchise
    ) -> String {
        switch kind {
        case .team:
            if let opp = team?.matchup?.opponentName {
                return "Week \(week) vs \(opp)"
            }
            return "Week \(week) team recap"
        case .league:
            return "\(linked.leagueName) · Week \(week)"
        }
    }

    // MARK: - Prompts

    private static func teamSystemPrompt(week: Int) -> String {
        """
        You are Sideline's week-summary analyst for MyFantasyLeague.
        Return ONLY a JSON object matching this exact shape (no markdown, no prose outside JSON):
        {
          "version": 1,
          "kind": "team",
          "week": \(week),
          "headline": "short punchy headline ≤ 8 words",
          "team": {
            "matchupBlurb": "1–2 sentences on the matchup result and what decided it",
            "resultLabel": "Won by X / Lost by X / Tie or empty string",
            "sitStart": [{"title":"Player Name","detail":"one-line reason","badge":"START|SIT|HOLD"}],
            "injuriesNews": [{"title":"Player or topic","detail":"one-line note","badge":"NEWS"}],
            "scoringNotes": [{"title":"Player or theme","detail":"one-line scoring takeaway","badge":null}],
            "nextActions": ["short action", "short action"]
          },
          "league": null
        }
        Rules:
        - sitStart: 3–6 borderline or notable lineup calls only (not every starter).
        - injuriesNews: only real issues from context (0–4).
        - scoringNotes: 2–5 bullets on who popped / disappeared.
        - nextActions: 2–4 concrete follow-ups.
        - Do NOT invent scores or chart arrays — the app fills those from MFL.
        - Use player names from the context only.
        """
    }

    private static func leagueSystemPrompt(week: Int) -> String {
        """
        You are Sideline's league-recap analyst for MyFantasyLeague.
        Return ONLY a JSON object matching this exact shape (no markdown, no prose outside JSON):
        {
          "version": 1,
          "kind": "league",
          "week": \(week),
          "headline": "short punchy headline ≤ 8 words",
          "team": null,
          "league": {
            "recap": "2–3 sentence week storyline",
            "movers": [{"title":"Franchise","detail":"why they moved","badge":"UP|DOWN"}],
            "transactionImpacts": [{"title":"Franchise or deal","detail":"impact in one line","badge":null}],
            "lookingAhead": "one short closer sentence"
          }
        }
        Rules:
        - movers: 2–5 franchises with meaningful rank/PF shifts.
        - transactionImpacts: 2–5 highest-impact adds/drops/trades/waivers from context (skip noise).
        - Do NOT invent chart arrays — the app fills matchupScores and pfLeaders from MFL.
        - Use franchise names from the context only.
        """
    }

    // MARK: - Context

    private static func teamUserContext(
        linked: LinkedFranchise,
        week: Int,
        team: TeamSnapshot?
    ) async -> String {
        guard let team else {
            return "League \(linked.leagueName). Franchise \(linked.franchiseName). Week \(week). No roster snapshot loaded."
        }

        var lines: [String] = [
            "LEAGUE: \(team.leagueName)",
            "FRANCHISE: \(team.franchiseName)",
            "WEEK: \(week)",
            "SEASON PF: \(team.seasonPointsFor.map { String(format: "%.1f", $0) } ?? "n/a")"
        ]
        if let m = team.matchup {
            lines.append(
                "MATCHUP: vs \(m.opponentName ?? "TBD") · mine \(fmt(m.myScore)) · opp \(fmt(m.oppScore))"
            )
        }

        lines.append("STARTERS:")
        for p in team.starters {
            lines.append(playerLine(p))
        }
        lines.append("BENCH:")
        for p in team.bench.prefix(16) {
            lines.append(playerLine(p))
        }
        if !team.ir.isEmpty {
            lines.append("IR: " + team.ir.map(\.name).joined(separator: ", "))
        }

        let newsIds = (team.starters + team.bench)
            .filter { ($0.injuryStatus?.isEmpty == false) || ($0.gameLockState == "upcoming") }
            .prefix(8)
            .map(\.playerId)
        if !newsIds.isEmpty, linked.isMFL {
            let research = await MFLPlayerResearchService.summarize(
                playerIds: Array(newsIds),
                linked: linked,
                maxPlayers: 8
            )
            lines.append(research)
        }

        let sleeperIntel = await SleeperPlayerCatalog.shared.contextLines(
            for: team.starters + team.bench,
            limit: 16
        )
        lines.append(sleeperIntel)

        if FantasyProsClient.hasAPIKey {
            await FantasyProsIntelService.shared.ensureLoaded(season: linked.season, week: week)
            let fp = await FantasyProsIntelService.shared.contextLines(
                for: team.starters + team.bench,
                limit: 20
            )
            lines.append(fp)
        }

        return lines.joined(separator: "\n")
    }

    private static func leagueUserContext(
        linked: LinkedFranchise,
        week: Int,
        league: LeagueReviewSnapshot?
    ) -> String {
        guard let league else {
            return "League \(linked.leagueName). Week \(week). No league review snapshot loaded."
        }
        var lines: [String] = [
            "LEAGUE: \(linked.leagueName)",
            "MY FRANCHISE: \(linked.franchiseName) (\(linked.franchiseId))",
            "WEEK: \(week)"
        ]

        lines.append("STANDINGS:")
        for row in league.standings.prefix(16) {
            let delta: String
            if let d = row.rankDelta, d != 0 {
                delta = d > 0 ? " ↑\(d)" : " ↓\(abs(d))"
            } else {
                delta = ""
            }
            lines.append(
                "#\(row.rank ?? 0)\(delta) \(row.name) \(row.wins)-\(row.losses)-\(row.ties) PF \(String(format: "%.1f", row.pointsFor))"
            )
        }

        lines.append("MATCHUPS:")
        for m in league.matchups {
            lines.append(
                "\(m.homeName) \(fmt(m.homeScore)) vs \(m.awayName) \(fmt(m.awayScore))"
            )
        }

        lines.append("TRANSACTIONS (week \(week)):")
        if league.transactions.isEmpty {
            lines.append("(none)")
        } else {
            for tx in league.transactions.prefix(25) {
                lines.append("[\(tx.type)] \(tx.franchiseName): \(tx.summary)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Loose decode

    private struct LooseTeam: Codable {
        var headline: String?
        var matchupBlurb: String?
        var resultLabel: String?
        var sitStart: [SummaryCallout]?
        var injuriesNews: [SummaryCallout]?
        var scoringNotes: [SummaryCallout]?
        var nextActions: [String]?
        var team: TeamWeekSummaryContent?
    }

    private struct LooseLeague: Codable {
        var headline: String?
        var recap: String?
        var movers: [SummaryCallout]?
        var transactionImpacts: [SummaryCallout]?
        var lookingAhead: String?
        var league: LeagueWeekSummaryContent?
    }

    private static func decodeLoose(
        kind: WeekSummaryKind,
        week: Int,
        data: Data
    ) throws -> WeekSummaryDocument {
        switch kind {
        case .team:
            let loose = try JSONDecoder().decode(LooseTeam.self, from: data)
            let team = loose.team ?? TeamWeekSummaryContent(
                matchupBlurb: loose.matchupBlurb ?? "",
                resultLabel: loose.resultLabel,
                myScore: nil,
                oppScore: nil,
                opponentName: nil,
                starterScores: [],
                sitStart: loose.sitStart ?? [],
                injuriesNews: loose.injuriesNews ?? [],
                scoringNotes: loose.scoringNotes ?? [],
                nextActions: loose.nextActions ?? []
            )
            return WeekSummaryDocument(
                version: 1,
                kind: kind.rawValue,
                week: week,
                headline: loose.headline ?? "",
                team: team,
                league: nil
            )
        case .league:
            let loose = try JSONDecoder().decode(LooseLeague.self, from: data)
            let league = loose.league ?? LeagueWeekSummaryContent(
                recap: loose.recap ?? "",
                matchupScores: [],
                pfLeaders: [],
                movers: loose.movers ?? [],
                transactionImpacts: loose.transactionImpacts ?? [],
                lookingAhead: loose.lookingAhead ?? ""
            )
            return WeekSummaryDocument(
                version: 1,
                kind: kind.rawValue,
                week: week,
                headline: loose.headline ?? "",
                team: nil,
                league: league
            )
        }
    }

    private static func playerLine(_ p: RosterPlayer) -> String {
        let pts: String
        if let d = p.displayWeekPoints {
            pts = String(format: "%.1f %@", d.value, d.kind.label)
        } else {
            pts = "n/a"
        }
        let lock = p.gameLockState ?? "?"
        let inj = p.injuryStatus.map { " inj:\($0)" } ?? ""
        let opp = p.opponent ?? ""
        return "- \(p.name) \(p.position) \(p.team) \(opp) |\(lock)| \(pts)\(inj)"
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private static func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let last = parts.last else { return name }
        if parts.count == 1 { return String(last) }
        let first = parts[0].prefix(1)
        return "\(first). \(last)"
    }

    private static func shortFranchise(_ name: String) -> String {
        if name.count <= 14 { return name }
        return String(name.prefix(12)) + "…"
    }
}
