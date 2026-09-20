import SwiftUI
import Charts

/// “Summary” control shown above the week picker for historic weeks only.
struct WeekSummaryLink: View {
    let isGenerating: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text("Summary")
                    .font(BrandTheme.body(13, weight: .bold))
                    .underline(true, color: BrandTheme.ink.opacity(0.35))
            }
            .foregroundStyle(BrandTheme.ink)
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }
}

/// Structured generate-once week summary popup.
struct WeekSummarySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let kind: WeekSummaryKind

    @State private var attemptFinished = false

    private var summary: CachedWeekSummary? {
        kind == .team ? appState.teamWeekSummary : appState.leagueWeekSummary
    }

    private var isGenerating: Bool {
        kind == .team ? appState.isGeneratingTeamSummary : appState.isGeneratingLeagueSummary
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    Group {
                        if let document = summary?.document {
                            summaryContent(document)
                        } else if isGenerating || !attemptFinished {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Writing summary…")
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, BrandTheme.space(24))
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(appState.errorMessage ?? "Couldn’t load this summary.")
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Try again") {
                                    attemptFinished = false
                                    Task { await loadSummary() }
                                }
                                .font(BrandTheme.body(14, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, BrandTheme.space(24))
                        }
                    }
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.top, BrandTheme.space(8))
                    .padding(.bottom, BrandTheme.space(40))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("WEEK \(appState.selectedWeek)")
                        .font(BrandTheme.display(14, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(BrandTheme.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(BrandTheme.body(15, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
            }
            .task {
                await loadSummary()
            }
        }
    }

    private func loadSummary() async {
        if summary?.document != nil {
            attemptFinished = true
            return
        }
        await appState.generateWeekSummary(kind: kind)
        attemptFinished = true
    }

    @ViewBuilder
    private func summaryContent(_ document: WeekSummaryDocument) -> some View {
        VStack(alignment: .leading, spacing: BrandTheme.space(22)) {
            Text(document.headline.isEmpty ? "Week \(appState.selectedWeek)" : document.headline)
                .font(BrandTheme.display(26, weight: .bold))
                .foregroundStyle(BrandTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if kind == .team, let team = document.team {
                teamSections(team)
            } else if kind == .league, let league = document.league {
                leagueSections(league)
            } else if kind == .team, let blurb = document.team?.matchupBlurb, !blurb.isEmpty {
                Text(blurb)
                    .font(BrandTheme.body(15))
                    .foregroundStyle(BrandTheme.ink)
            } else if kind == .league, let recap = document.league?.recap, !recap.isEmpty {
                Text(recap)
                    .font(BrandTheme.body(15))
                    .foregroundStyle(BrandTheme.ink)
            }

            if let summary {
                Text(savedFooter(summary))
                    .font(BrandTheme.body(11))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.top, BrandTheme.space(4))
            }
        }
    }

    // MARK: - Team

    @ViewBuilder
    private func teamSections(_ team: TeamWeekSummaryContent) -> some View {
        matchupScoreblock(team)

        if !team.matchupBlurb.isEmpty {
            Text(team.matchupBlurb)
                .font(BrandTheme.body(15))
                .foregroundStyle(BrandTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !team.starterScores.isEmpty {
            sectionHeader("STARTER SCORING")
            starterChart(team.starterScores)
        }

        if !team.sitStart.isEmpty {
            sectionHeader("SIT / START")
            calloutList(team.sitStart)
        }

        if !team.injuriesNews.isEmpty {
            sectionHeader("INJURIES & NEWS")
            calloutList(team.injuriesNews)
        }

        if !team.scoringNotes.isEmpty {
            sectionHeader("SCORING NOTES")
            calloutList(team.scoringNotes)
        }

        if !team.nextActions.isEmpty {
            sectionHeader("NEXT")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(team.nextActions.enumerated()), id: \.offset) { _, action in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(BrandTheme.ink)
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                        Text(action)
                            .font(BrandTheme.body(14))
                            .foregroundStyle(BrandTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func matchupScoreblock(_ team: TeamWeekSummaryContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = team.resultLabel, !result.isEmpty {
                Text(result.uppercased())
                    .font(BrandTheme.display(12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(BrandTheme.muted)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You")
                        .font(BrandTheme.body(12))
                        .foregroundStyle(BrandTheme.muted)
                    Text(team.myScore.map { String(format: "%.1f", $0) } ?? "—")
                        .font(BrandTheme.mono(28, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
                Spacer()
                Text("–")
                    .font(BrandTheme.display(22, weight: .bold))
                    .foregroundStyle(BrandTheme.muted)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(team.opponentName ?? "Opp")
                        .font(BrandTheme.body(12))
                        .foregroundStyle(BrandTheme.muted)
                        .lineLimit(1)
                    Text(team.oppScore.map { String(format: "%.1f", $0) } ?? "—")
                        .font(BrandTheme.mono(28, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
            }

            if let my = team.myScore, let opp = team.oppScore {
                Chart {
                    BarMark(
                        x: .value("Side", "You"),
                        y: .value("Pts", my)
                    )
                    .foregroundStyle(BrandTheme.ink)
                    BarMark(
                        x: .value("Side", "Opp"),
                        y: .value("Pts", opp)
                    )
                    .foregroundStyle(BrandTheme.muted.opacity(0.45))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                }
                .frame(height: 88)
            }
        }
    }

    private func starterChart(_ points: [SummaryChartPoint]) -> some View {
        Chart(points) { point in
            BarMark(
                x: .value("Pts", point.value),
                y: .value("Player", point.label)
            )
            .foregroundStyle((point.highlight == true) ? BrandTheme.ink : BrandTheme.ink.opacity(0.45))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4))
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let s = value.as(String.self) {
                        Text(s)
                            .font(BrandTheme.body(11))
                            .foregroundStyle(BrandTheme.muted)
                    }
                }
            }
        }
        .frame(height: CGFloat(max(140, points.count * 28)))
    }

    // MARK: - League

    @ViewBuilder
    private func leagueSections(_ league: LeagueWeekSummaryContent) -> some View {
        if !league.recap.isEmpty {
            Text(league.recap)
                .font(BrandTheme.body(15))
                .foregroundStyle(BrandTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !league.pfLeaders.isEmpty {
            sectionHeader("POINTS FOR")
            pfLeadersChart(league.pfLeaders)
        }

        if !league.matchupScores.isEmpty {
            sectionHeader("SCOREBOARD")
            scoreboardList(league.matchupScores)
        }

        if !league.movers.isEmpty {
            sectionHeader("STANDINGS MOVES")
            calloutList(league.movers)
        }

        if !league.transactionImpacts.isEmpty {
            sectionHeader("TRANSACTIONS")
            calloutList(league.transactionImpacts)
        }

        if !league.lookingAhead.isEmpty {
            sectionHeader("LOOKING AHEAD")
            Text(league.lookingAhead)
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scoreboardList(_ points: [SummaryChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                let parts = point.label.split(separator: "/", maxSplits: 1).map(String.init)
                let home = parts.first ?? point.label
                let away = parts.count > 1 ? parts[1] : "Opp"
                VStack(spacing: 6) {
                    scoreboardSide(
                        name: home,
                        score: point.value,
                        leading: (point.secondary.map { point.value > $0 } ?? false) || point.highlight == true
                    )
                    scoreboardSide(
                        name: away,
                        score: point.secondary,
                        leading: point.secondary.map { $0 > point.value } ?? false
                    )
                }
                .padding(.vertical, BrandTheme.space(10))
                if index < points.count - 1 {
                    Rectangle()
                        .fill(BrandTheme.hairline)
                        .frame(height: 1)
                }
            }
        }
    }

    private func scoreboardSide(name: String, score: Double?, leading: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(BrandTheme.body(14, weight: leading ? .bold : .medium))
                .foregroundStyle(BrandTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(score.map { String(format: "%.1f", $0) } ?? "—")
                .font(BrandTheme.mono(14, weight: leading ? .bold : .regular))
                .foregroundStyle(BrandTheme.ink)
        }
    }

    private func pfLeadersChart(_ points: [SummaryChartPoint]) -> some View {
        Chart(points) { point in
            BarMark(
                x: .value("PF", point.value),
                y: .value("Team", point.label)
            )
            .foregroundStyle((point.highlight == true) ? BrandTheme.ink : BrandTheme.ink.opacity(0.45))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4))
        }
        .frame(height: CGFloat(max(140, points.count * 26)))
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTheme.display(12, weight: .semibold))
            .tracking(1)
            .foregroundStyle(BrandTheme.muted)
            .padding(.top, BrandTheme.space(4))
    }

    private func calloutList(_ items: [SummaryCallout]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge.uppercased())
                            .font(BrandTheme.display(10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(badgeColor(badge))
                            .frame(width: 44, alignment: .leading)
                            .padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(BrandTheme.body(14, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                        Text(item.detail)
                            .font(BrandTheme.body(13))
                            .foregroundStyle(BrandTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, BrandTheme.space(10))
                if index < items.count - 1 {
                    Rectangle()
                        .fill(BrandTheme.hairline)
                        .frame(height: 1)
                }
            }
        }
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge.uppercased() {
        case "START", "UP": return BrandTheme.standingsUp
        case "SIT", "DOWN": return BrandTheme.standingsDown
        default: return BrandTheme.muted
        }
    }

    private func savedFooter(_ summary: CachedWeekSummary) -> String {
        let date = summary.createdAt.formatted(date: .abbreviated, time: .shortened)
        let model = summary.modelLabel.isEmpty ? "saved" : summary.modelLabel
        return "Saved \(date) · \(model)"
    }
}
