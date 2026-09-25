import SwiftUI

struct AnalysisView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("sideline.propsTab.visible") private var propsTabVisible = true
    @State private var insights: [OddsRosterInsight] = []
    @State private var status: String?
    @State private var isError = false
    @State private var isLoading = false
    @State private var hasKey = OddsAPIClient.hasAPIKey
    @State private var selectedPlayer: RosterPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                Group {
                    if !hasKey {
                        emptyKeyState
                    } else if isLoading && insights.isEmpty {
                        Text(appState.isViewingHistoricWeek
                              ? "Loading historic props…"
                              : "Loading player props…")
                            .font(BrandTheme.body(14))
                            .foregroundStyle(BrandTheme.muted)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                LeaguePageHeader(
                                    leagueName: appState.linkedFranchise?.leagueName ?? "Props",
                                    subtitle: propsSubtitle,
                                    trailing: headerTrailing,
                                    footnote: nil
                                )
                                Divider().overlay(BrandTheme.hairline)

                                if let status, isError {
                                    Text(status)
                                        .font(BrandTheme.body(13))
                                        .foregroundStyle(BrandTheme.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, BrandTheme.pageGutter)
                                        .padding(.top, BrandTheme.space(16))
                                }

                                rosterSection
                            }
                            .padding(.bottom, BrandTheme.space(40))
                            .sidelinePullRefreshReader()
                        }
                        .sidelinePullToRefresh {
                            await reload(force: true)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SidelineNavTitle()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.linkedFranchise != nil {
                        LeagueSwitcherMenu()
                    }
                }
            }
            .task { await reload(force: false) }
            .onChange(of: appState.team?.syncedAt) { _, _ in
                Task { await reload(force: false) }
            }
            .onChange(of: appState.selectedWeek) { _, _ in
                Task { await reload(force: true) }
            }
            .sheet(item: $selectedPlayer) { player in
                PlayerDetailSheet(player: player)
                    .environmentObject(appState)
            }
        }
    }

    private var headerTrailing: AnyView? {
        guard appState.linkedFranchise != nil else { return nil }
        return AnyView(WeekPickerControl())
    }

    private var emptyKeyState: some View {
        VStack(spacing: 16) {
            Text("Player props for your roster")
                .font(BrandTheme.body(16, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
                .multilineTextAlignment(.center)
            Text("Add an Odds API key to load pass/rush/receiving lines and anytime TDs for players on your team. Free keys are at the-odds-api.com — this is separate from your LLM / OpenAI key.")
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
                .multilineTextAlignment(.center)
            Button("Add Odds API key") {
                appState.settingsPath = [.apis, .oddsAPI]
                appState.selectedTab = .settings
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, BrandTheme.space(40))

            Button {
                propsTabVisible = false
                if appState.selectedTab == .props {
                    appState.selectedTab = .team
                }
            } label: {
                Text("Hide Props tab")
                    .font(BrandTheme.body(14, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Text("You can turn it back on in Settings → Appearance.")
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, BrandTheme.pageGutter)
    }

    private var propsSubtitle: String {
        let week = appState.selectedWeek
        let historic = appState.isViewingHistoricWeek ? " · historic" : ""
        if insights.isEmpty {
            return "Week \(week)\(historic) · no props matched"
        }
        return "Week \(week)\(historic) · \(insights.count) players"
    }

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if insights.isEmpty, !isError {
                Text(appState.isViewingHistoricWeek
                      ? "No historic props for this week. Paid Odds API plans unlock historical player markets."
                      : "Sync Team after saving a key — Sideline fetches props for games your roster plays in.")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.vertical, BrandTheme.space(20))
            }

            ForEach(insights) { row in
                playerPropBlock(row)
                Divider().overlay(BrandTheme.hairline)
            }
        }
    }

    private func playerPropBlock(_ row: OddsRosterInsight) -> some View {
        let props = Array(row.props.prefix(6))
        let matchup = row.matchupLabel ?? row.primary?.matchupLabel
        let book = row.primary?.bookmaker ?? props.first?.bookmaker

        return Button {
            selectedPlayer = row.player
        } label: {
            VStack(alignment: .leading, spacing: BrandTheme.space(12)) {
                // Header — same rhythm as Team roster rows
                HStack(alignment: .top, spacing: 12) {
                    Text(row.player.position)
                        .font(BrandTheme.body(12, weight: .semibold))
                        .foregroundStyle(BrandTheme.muted)
                        .frame(width: BrandTheme.space(36), alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.player.name)
                            .font(BrandTheme.body(15, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        HStack(spacing: 6) {
                            if !row.player.team.isEmpty {
                                Text(row.player.team)
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            if let matchup, !matchup.isEmpty {
                                Text(matchup)
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            if let injury = row.player.injuryStatus, !injury.isEmpty {
                                Text(injury)
                                    .font(BrandTheme.body(11, weight: .semibold))
                                    .foregroundStyle(BrandTheme.danger)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        if let book {
                            Text(book)
                                .font(BrandTheme.body(11, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink.opacity(0.55))
                        }
                        Text(row.player.status.capitalized)
                            .font(BrandTheme.body(11))
                            .foregroundStyle(BrandTheme.muted)
                    }
                }

                if props.isEmpty {
                    Text("No props matched")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .padding(.leading, BrandTheme.space(36) + 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(props.enumerated()), id: \.element.id) { index, prop in
                            if index > 0 {
                                Divider().overlay(BrandTheme.hairline)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(prop.marketLabel)
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                                Spacer(minLength: 8)
                                OddsPropLineLabel(prop: prop)
                            }
                            .padding(.vertical, BrandTheme.space(9))
                        }
                    }
                    .padding(.leading, BrandTheme.space(36) + 12)
                }
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.vertical, BrandTheme.space(14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows player details")
    }

    private func reload(force: Bool) async {
        hasKey = OddsAPIClient.hasAPIKey
        guard hasKey else {
            insights = []
            return
        }
        isLoading = true
        appState.isLoadingProps = true
        defer {
            isLoading = false
            appState.isLoadingProps = false
        }
        if force {
            await OddsIntelService.shared.invalidate()
        }
        if appState.linkedFranchise != nil,
           appState.team?.week != appState.selectedWeek {
            await appState.syncTeam(week: appState.selectedWeek)
        }
        let roster = (appState.team?.starters ?? []) + (appState.team?.bench ?? [])
        let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
        let week = appState.selectedWeek
        let live = !appState.isViewingHistoricWeek && DataCache.hasLiveGames(in: appState.team)
        await OddsIntelService.shared.ensureLoaded(
            players: roster,
            season: season,
            week: week,
            isHistoric: appState.isViewingHistoricWeek,
            hasLiveGames: live
        )
        insights = await OddsIntelService.shared.rosterInsights(from: roster, limit: 40)
        let err = await OddsIntelService.shared.lastWasError
        isError = err
        status = err ? await OddsIntelService.shared.lastStatus : nil
    }
}
