import SwiftUI

struct TeamCockpitView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedPlayer: RosterPlayer?
    @State private var showWeekSummary = false
    /// Hide snackbar until the user leaves Team and comes back.
    @State private var approvalsSnackDismissed = false

    /// Bumped when Approvals dismisses so the page TabView rebuilds — sheet detents
    /// otherwise leave Matchup blank with bottom chrome floating mid-screen.
    @State private var rosterPagerEpoch = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(BrandTheme.hairline)

                TabView(selection: Binding(
                    get: { appState.teamRosterPane },
                    set: { appState.teamRosterPane = $0 }
                )) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            myTeamBody
                            if appState.linkedFranchise == nil {
                                emptyConnect
                            }
                        }
                        .padding(.bottom, BrandTheme.space(56))
                    }
                    .sidelinePullToRefresh {
                        await appState.syncTeam(revalidatePublic: true)
                    }
                    .tag(MatchupRosterPane.mine)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            matchupBody
                            if appState.linkedFranchise == nil {
                                emptyConnect
                            }
                        }
                        .padding(.bottom, BrandTheme.space(56))
                    }
                    .sidelinePullToRefresh {
                        await appState.syncTeam(revalidatePublic: true)
                    }
                    .tag(MatchupRosterPane.matchup)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(rosterPagerEpoch)
            }
            .background { SidelineBackground().ignoresSafeArea() }
            .overlay(alignment: .bottom) {
                VStack(spacing: BrandTheme.space(8)) {
                    if showApprovalsSnackbar {
                        approvalsSnackbar
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    pageDots
                }
                .padding(.bottom, BrandTheme.space(10))
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showApprovalsSnackbar)
            }
            .onChange(of: appState.showApprovals) { wasShowing, isShowing in
                // Sheet medium/large detents shrink the page pager; rebuild after it closes.
                if wasShowing && !isShowing {
                    rosterPagerEpoch &+= 1
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SidelineNavTitle()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.linkedFranchise == nil {
                        Button("Connect") {
                            appState.showConnect = true
                        }
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    } else {
                        LeagueSwitcherMenu()
                    }
                }
            }
            .task {
                if appState.linkedFranchise != nil, appState.team == nil {
                    await appState.syncTeam()
                }
            }
            .onAppear {
                approvalsSnackDismissed = false
            }
            .sheet(item: $selectedPlayer) { player in
                PlayerDetailSheet(player: player)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showWeekSummary) {
                WeekSummarySheet(kind: .team)
                    .environmentObject(appState)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: BrandTheme.space(10)) {
            ForEach(MatchupRosterPane.allCases) { pane in
                let active = appState.teamRosterPane == pane
                Circle()
                    .fill(active ? BrandTheme.accent : BrandTheme.ink.opacity(0.28))
                    .frame(
                        width: active ? BrandTheme.space(9) : BrandTheme.space(6),
                        height: active ? BrandTheme.space(9) : BrandTheme.space(6)
                    )
                    .animation(.spring(response: 0.28, dampingFraction: 0.78), value: appState.teamRosterPane)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            appState.teamRosterPane = pane
                        }
                    }
                    .accessibilityLabel(paneAccessibilityLabel(pane))
                    .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BrandTheme.space(8))
    }

    private func paneAccessibilityLabel(_ pane: MatchupRosterPane) -> String {
        switch pane {
        case .matchup: return "Match"
        case .mine: return "Team"
        }
    }

    // MARK: - Pane bodies

    @ViewBuilder
    private var myTeamBody: some View {
        if showRosterSkeleton {
            rosterLoadingSkeleton
        } else {
            if showsUpcomingSection {
                upcomingMatchupsSection
                Divider().overlay(BrandTheme.hairline)
            }
            startersSection
            Divider().overlay(BrandTheme.hairline)
            benchSection
            if shouldShowIR {
                Divider().overlay(BrandTheme.hairline)
                rosterSection(title: "IR", players: appState.team?.ir ?? [])
            }
            if shouldShowTaxi {
                Divider().overlay(BrandTheme.hairline)
                taxiSection
            }
        }
    }

    private var showRosterSkeleton: Bool {
        appState.linkedFranchise != nil
            && appState.team == nil
            && appState.isSyncing
    }

    private var rosterLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsUpcomingSection {
                upcomingMatchupsSection
                Divider().overlay(BrandTheme.hairline)
            }
            skeletonRosterBlock(title: "STARTERS", rows: 9)
            Divider().overlay(BrandTheme.hairline)
            skeletonRosterBlock(title: "BENCH", rows: 6)
        }
    }

    private func skeletonRosterBlock(title: String, rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(BrandTheme.display(13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(16))
                .padding(.bottom, BrandTheme.space(8))
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 12) {
                    Text("WR")
                        .font(BrandTheme.body(12, weight: .semibold))
                        .foregroundStyle(BrandTheme.muted)
                        .frame(width: BrandTheme.space(36), alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Player Name Here")
                            .font(BrandTheme.body(15, weight: .medium))
                            .foregroundStyle(BrandTheme.ink)
                        Text("TEAM  vs OPP")
                            .font(BrandTheme.body(12))
                            .foregroundStyle(BrandTheme.muted)
                    }
                    Spacer()
                    Text("12.3")
                        .font(BrandTheme.mono(14, weight: .medium))
                        .foregroundStyle(BrandTheme.ink)
                }
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.vertical, BrandTheme.space(12))
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading roster")
    }

    private var showsUpcomingSection: Bool {
        appState.linkedFranchise != nil
            && (appState.isLoadingUpcomingMatchups || !appState.upcomingMatchups.isEmpty)
    }

    @ViewBuilder
    private var matchupBody: some View {
        if showRosterSkeleton {
            matchupLoadingSkeleton
        } else {
            matchupScoreHero
            Divider().overlay(BrandTheme.hairline)
            matchupStartersSection
        }
    }

    private var matchupLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: BrandTheme.space(12)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Team Name")
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    Text("100.0")
                        .font(BrandTheme.mono(28, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("vs")
                    .font(BrandTheme.body(13, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Opponent Name")
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    Text("100.0")
                        .font(BrandTheme.mono(28, weight: .semibold))
                        .foregroundStyle(BrandTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.vertical, BrandTheme.space(16))
            .redacted(reason: .placeholder)

            Divider().overlay(BrandTheme.hairline)
            skeletonRosterBlock(title: "STARTERS", rows: 9)
        }
        .accessibilityLabel("Loading matchup")
    }

    // MARK: - Snackbar

    private var showApprovalsSnackbar: Bool {
        appState.pendingCount > 0 && !approvalsSnackDismissed
    }

    private var approvalsSnackbar: some View {
        HStack(spacing: 12) {
            Button {
                appState.showApprovals = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.pendingCount == 1
                              ? "1 proposal needs approval"
                              : "\(appState.pendingCount) proposals need approval")
                            .font(BrandTheme.body(14, weight: .semibold))
                        Text("Tap to review")
                            .font(BrandTheme.body(12))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation {
                    approvalsSnackDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, BrandTheme.space(14))
        .padding(.vertical, BrandTheme.space(12))
        .background(
            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                .fill(Color.black)
        )
    }

    // MARK: - Header

    private var header: some View {
        LeaguePageHeader(
            leagueName: appState.linkedFranchise?.leagueName ?? "No league linked",
            subtitle: resolvedTeamName,
            subtitleDetail: seasonPointsDetail,
            trailing: headerTrailing,
            footnote: nil
        ) {
            if showsSalaryStrip {
                salaryHeaderLine
            }
        }
    }

    /// True while the salary strip should reserve space (loaded salary league, or initial MFL sync).
    private var showsSalaryStrip: Bool {
        if let team = appState.team {
            return team.totalSalary != nil
                || team.salaryCap != nil
                || (team.leagueRules?.usesSalaries == true)
        }
        // MFL salary leagues — reserve header height during first sync so content does not jump.
        return appState.isSyncing && (appState.linkedFranchise?.isMFL == true)
    }

    private var salaryValuesPending: Bool {
        guard showsSalaryStrip else { return false }
        if appState.team == nil { return true }
        // Keep skeleton only while a sync is in flight and totals have not landed yet.
        if appState.isSyncing && appState.team?.totalSalary == nil {
            return true
        }
        return false
    }

    private var headerTrailing: AnyView? {
        if appState.linkedFranchise == nil { return nil }
        return AnyView(
            WeekHeaderControls(
                showSummary: appState.isViewingHistoricWeek,
                isGeneratingSummary: appState.isGeneratingTeamSummary,
                onSummary: { showWeekSummary = true }
            )
        )
    }

    /// Season PF sits in a fixed slot so the week picker does not jump when sync finishes.
    private var seasonPointsDetail: AnyView? {
        guard appState.linkedFranchise != nil else { return nil }
        if let pf = appState.team?.seasonPointsFor {
            return AnyView(
                Text("·  \(String(format: "%.1f", pf)) PF")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .lineLimit(1)
            )
        }
        if appState.isSyncing || appState.team == nil {
            return AnyView(
                Text("·  000.0 PF")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .redacted(reason: .placeholder)
                    .accessibilityLabel("Season points loading")
            )
        }
        return nil
    }

    /// Prefer league-resolved team name over the myleagues placeholder "Franchise".
    private var resolvedTeamName: String {
        let candidates: [String?] = [
            appState.team?.franchiseName,
            appState.linkedFranchise.flatMap { linked in
                appState.leagueReview?.standings.first {
                    MFLNameResolver.normalizeFranchiseId($0.franchiseId)
                        == MFLNameResolver.normalizeFranchiseId(linked.franchiseId)
                }?.name
            },
            appState.linkedFranchise?.franchiseName
        ]
        for raw in candidates {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.caseInsensitiveCompare("Franchise") == .orderedSame { continue }
            return trimmed
        }
        return appState.linkedFranchise == nil ? "Connect a league to begin" : "My team"
    }

    private var opponentDisplayName: String {
        appState.team?.matchup?.opponentName ?? "Opponent"
    }

    private var salaryHeaderLine: some View {
        let total = appState.team?.totalSalary
        let cap = appState.team?.salaryCap
        let usesSalaries = appState.team?.leagueRules?.usesSalaries == true
            || total != nil
            || cap != nil
            || (appState.team == nil && appState.linkedFranchise?.isMFL == true)
        let pending = salaryValuesPending

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Salary")
                .font(BrandTheme.body(13, weight: .medium))
                .foregroundStyle(BrandTheme.muted)

            if let total {
                Text(SalaryFormat.compact(total))
                    .font(BrandTheme.mono(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            } else if pending {
                Text("$12.5M")
                    .font(BrandTheme.mono(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
                    .redacted(reason: .placeholder)
                    .accessibilityLabel("Salary loading")
            } else {
                Text("—")
                    .font(BrandTheme.mono(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }

            if let cap {
                Text("/ \(SalaryFormat.compact(cap))")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
            } else if usesSalaries, pending {
                Text("/ $200M")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
                    .redacted(reason: .placeholder)
            }

            if let total, let cap, cap > 0 {
                let remaining = cap - total
                Text("·")
                    .foregroundStyle(BrandTheme.muted)
                Text(remaining >= 0 ? "\(SalaryFormat.compact(remaining)) left" : "\(SalaryFormat.compact(abs(remaining))) over")
                    .font(BrandTheme.body(13, weight: .semibold))
                    .foregroundStyle(remaining >= 0 ? BrandTheme.standingsUp : BrandTheme.danger)
            } else if usesSalaries, pending || (cap != nil && total == nil) {
                Text("·")
                    .foregroundStyle(BrandTheme.muted)
                Text("$12.5M left")
                    .font(BrandTheme.body(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .redacted(reason: .placeholder)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: pending ? .ignore : .contain)
        .accessibilityLabel(pending ? "Salary loading" : "Salary")
    }

    // MARK: - Matchup score

    private var matchupScoreKind: WeekPointsKind {
        Self.scoreKind(for: appState.team)
    }

    private var displayedMyScore: Double? {
        Self.displayedScore(mine: true, team: appState.team, kind: matchupScoreKind)
    }

    private var displayedOppScore: Double? {
        Self.displayedScore(mine: false, team: appState.team, kind: matchupScoreKind)
    }

    private var matchupWinProbabilityResult: WinProbabilityCalculator.Result? {
        guard !appState.isViewingFutureWeek else { return nil }
        return appState.team?.winProbabilityResult
    }

    private var matchupScoreHero: some View {
        let future = appState.isViewingFutureWeek
        return VStack(spacing: BrandTheme.space(6)) {
            if let result = matchupWinProbabilityResult {
                WinProbabilityGaugeView(myProbability: result.myProbability)
            }

            HStack(alignment: .center, spacing: BrandTheme.space(12)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resolvedTeamName)
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if future {
                        Text("Week \(appState.selectedWeek)")
                            .font(BrandTheme.mono(22, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    } else {
                        Text(displayedMyScore.map { String(format: "%.1f", $0) } ?? "—")
                            .font(BrandTheme.mono(28, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 2) {
                    Text("vs")
                        .font(BrandTheme.body(13, weight: .medium))
                        .foregroundStyle(BrandTheme.muted)
                    if !future, let result = matchupWinProbabilityResult {
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", result.myProjectedFinal))
                            Text("–")
                            Text(String(format: "%.1f", result.oppProjectedFinal))
                        }
                        .font(BrandTheme.mono(10, weight: .medium))
                        .foregroundStyle(BrandTheme.muted)
                    }
                }

                VStack(alignment: .trailing, spacing: 4) {
                    Text(opponentDisplayName)
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)
                    if future {
                        Text("—")
                            .font(BrandTheme.mono(22, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    } else {
                        Text(displayedOppScore.map { String(format: "%.1f", $0) } ?? "—")
                            .font(BrandTheme.mono(28, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(16))
    }

    static func scoreKind(for team: TeamSnapshot?) -> WeekPointsKind {
        guard let team else { return .projected }
        // Include opponent locks — Thursday-only games on one side should still flip to live.
        let locks = (team.starters + team.opponentStarters).map { $0.gameLockState ?? "upcoming" }
        guard !locks.isEmpty else {
            if team.matchup?.myScore != nil || team.matchup?.oppScore != nil {
                return .live
            }
            return .projected
        }
        let active = locks.filter { $0 != "bye" }
        if !active.isEmpty, active.allSatisfy({ $0 == "final" }) {
            return .final
        }
        if locks.contains("started") || locks.contains("final") {
            return .live
        }
        return .projected
    }

    static func displayedScore(mine: Bool, team: TeamSnapshot?, kind: WeekPointsKind) -> Double? {
        guard let team else { return nil }
        switch kind {
        case .projected:
            return mine ? team.myProjectedStarterTotal : team.oppProjectedStarterTotal
        case .live, .final:
            // Points from players who have played so far — never mix in projections for
            // upcoming starters (that produced bogus ~130 totals mid-slate).
            let players = mine ? team.starters : team.opponentStarters
            if let soFar = TeamSnapshot.scoredSoFar(starters: players) {
                return soFar
            }
            if mine, let score = team.matchup?.myScore { return score }
            if !mine, let score = team.matchup?.oppScore { return score }
            // Slate is live/final but this side hasn't kicked off — show 0, not projections.
            return 0
        }
    }

    // MARK: - Upcoming

    private var upcomingMatchupsSection: some View {
        let rows = Array(appState.upcomingMatchups.prefix(4))
        let showSkeleton = appState.isLoadingUpcomingMatchups && rows.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Text("UPCOMING")
                .font(BrandTheme.display(13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(16))
                .padding(.bottom, BrandTheme.space(8))

            if showSkeleton {
                ForEach(0..<4, id: \.self) { index in
                    upcomingSkeletonRow
                    if index < 3 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        appState.selectWeek(row.week)
                    } label: {
                        HStack {
                            Text("Week \(row.week)")
                                .font(BrandTheme.body(14, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink)
                                .frame(width: 72, alignment: .leading)
                            Text(row.isHome == true ? "vs" : (row.isHome == false ? "@" : "vs"))
                                .font(BrandTheme.body(13))
                                .foregroundStyle(BrandTheme.muted)
                            Text(row.opponentName)
                                .font(BrandTheme.body(15, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if row.week == appState.selectedWeek {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BrandTheme.muted)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                        }
                        .padding(.horizontal, BrandTheme.pageGutter)
                        .padding(.vertical, BrandTheme.space(12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            }
        }
        .padding(.bottom, BrandTheme.space(12))
    }

    private var upcomingSkeletonRow: some View {
        HStack {
            Text("Week 12")
                .font(BrandTheme.body(14, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
                .frame(width: 72, alignment: .leading)
            Text("vs")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
            Text("Opponent Name Here")
                .font(BrandTheme.body(15, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandTheme.muted)
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(12))
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading upcoming matchups")
    }

    // MARK: - My roster sections

    private var shouldShowIR: Bool {
        !(appState.team?.ir.isEmpty ?? true)
    }

    private var shouldShowTaxi: Bool {
        let hasPlayers = !(appState.team?.taxi.isEmpty ?? true)
        let hasSlots = (appState.team?.leagueRules?.taxiSquadSlots ?? 0) > 0
        return hasPlayers || hasSlots
    }

    private var taxiSection: some View {
        let taxiPlayers = appState.team?.taxi ?? []
        let slots = appState.team?.leagueRules?.taxiSquadSlots
        let groups = RosterPositionGrouping.benchGroups(
            players: taxiPlayers,
            rules: appState.team?.leagueRules
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("TAXI")
                    .font(BrandTheme.display(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                if let slots {
                    Text("(\(slots))")
                        .font(BrandTheme.body(12, weight: .medium))
                        .foregroundStyle(BrandTheme.muted)
                }
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.top, BrandTheme.space(16))
            .padding(.bottom, BrandTheme.space(8))

            if taxiPlayers.isEmpty {
                Text("No taxi players")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.bottom, BrandTheme.space(12))
            } else if groups.isEmpty {
                ForEach(taxiPlayers.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }) { player in
                    PlayerRow(player: player) { selectedPlayer = player }
                }
            } else {
                let taxiGroups = groups.filter { $0.key != "TIEBREAK" && !$0.players.isEmpty }
                ForEach(Array(taxiGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    ForEach(group.players) { player in
                        PlayerRow(player: player) { selectedPlayer = player }
                    }
                    if groupIndex < taxiGroups.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            }
        }
    }

    private var benchSection: some View {
        // Never mix taxi into bench even if a status was mis-tagged upstream.
        let taxiIds = Set(appState.team?.taxi.map(\.playerId) ?? [])
        let benchOnly = (appState.team?.bench ?? []).filter {
            $0.status != "taxi" && !taxiIds.contains($0.playerId)
        }
        let groups = RosterPositionGrouping.benchGroups(
            players: benchOnly,
            rules: appState.team?.leagueRules
        )
        return VStack(alignment: .leading, spacing: 0) {
            Text("BENCH")
                .font(BrandTheme.display(13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(16))
                .padding(.bottom, BrandTheme.space(8))

            if groups.isEmpty {
                Text("No players")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.bottom, BrandTheme.space(12))
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                    ForEach(group.players) { player in
                        PlayerRow(player: player) { selectedPlayer = player }
                    }
                    if group.players.isEmpty, group.key == "TIEBREAK" {
                        Text("Any eligible starter from flex positions")
                            .font(BrandTheme.body(12))
                            .foregroundStyle(BrandTheme.muted)
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.bottom, BrandTheme.space(6))
                    }
                    if groupIndex < groups.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            }
        }
    }

    private var startersSection: some View {
        let starters = appState.team?.starters ?? []
        let groups = RosterPositionGrouping.benchGroups(
            players: starters,
            rules: appState.team?.leagueRules
        )
        // Starters: show discrete positions only (alphabetical within each), skip empty Tiebreak.
        let displayGroups = groups.filter { $0.key != "TIEBREAK" && !$0.players.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("STARTERS")
                    .font(BrandTheme.display(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                Spacer(minLength: 8)
                pointsLegend
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.top, BrandTheme.space(16))
            .padding(.bottom, BrandTheme.space(8))

            if starters.isEmpty {
                Text("No players")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.bottom, BrandTheme.space(12))
            } else if displayGroups.isEmpty {
                ForEach(starters.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }) { player in
                    PlayerRow(player: player) { selectedPlayer = player }
                }
            } else {
                ForEach(Array(displayGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    ForEach(group.players) { player in
                        PlayerRow(player: player) { selectedPlayer = player }
                    }
                    if groupIndex < displayGroups.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            }
        }
    }

    private func rosterSection(title: String, players: [RosterPlayer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(BrandTheme.display(13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(16))
                .padding(.bottom, BrandTheme.space(8))

            if players.isEmpty {
                Text("No players")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.bottom, BrandTheme.space(12))
            } else {
                ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                    PlayerRow(player: player) { selectedPlayer = player }
                    if index < players.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                }
            }
        }
    }

    // MARK: - Matchup starters

    private var matchupStartersSection: some View {
        let rules = appState.team?.leagueRules
        let mine = appState.team?.starters ?? []
        let opp = appState.team?.opponentStarters ?? []
        let pairs = RosterPositionGrouping.matchupSlotPairs(mine: mine, opponent: opp, rules: rules)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("STARTERS")
                    .font(BrandTheme.display(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                Spacer(minLength: 8)
                pointsLegend
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.top, BrandTheme.space(16))
            .padding(.bottom, BrandTheme.space(8))

            if pairs.isEmpty {
                Text(appState.linkedFranchise == nil ? "Connect a league to load the matchup." : "No starter matchup yet")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.bottom, BrandTheme.space(12))
            } else {
                ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                    MatchupStarterRow(
                        slotLabel: pair.slotLabel,
                        mine: pair.mine,
                        opponent: pair.opponent,
                        onSelectMine: { if let p = pair.mine { selectedPlayer = p } },
                        onSelectOpp: { if let p = pair.opponent { selectedPlayer = p } }
                    )
                    if index < pairs.count - 1,
                       pair.slotLabel.caseInsensitiveCompare(pairs[index + 1].slotLabel) != .orderedSame {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.horizontal, BrandTheme.pageGutter)
                    }
                }
            }
        }
        .padding(.bottom, BrandTheme.space(12))
    }

    private var pointsLegend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle()
                    .fill(BrandTheme.muted.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text("proj")
                    .font(BrandTheme.body(11, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(BrandTheme.accent)
                    .frame(width: 6, height: 6)
                Text("live")
                    .font(BrandTheme.body(11, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(BrandTheme.finalPoints)
                    .frame(width: 6, height: 6)
                Text("final")
                    .font(BrandTheme.body(11, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
    }

    private var emptyConnect: some View {
        Text("Link an MFL or Sleeper league to load the cockpit. Use Connect up top.")
            .font(BrandTheme.body(15))
            .foregroundStyle(BrandTheme.muted)
            .multilineTextAlignment(.leading)
            .padding(BrandTheme.space(24))
    }
}

// MARK: - Matchup starter row

private struct MatchupStarterRow: View {
    @EnvironmentObject private var appState: AppState
    let slotLabel: String
    let mine: RosterPlayer?
    let opponent: RosterPlayer?
    var onSelectMine: (() -> Void)?
    var onSelectOpp: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: BrandTheme.space(6)) {
            // Left: name outside, score inside — Name  ● 22.4
            Button {
                onSelectMine?()
            } label: {
                HStack(alignment: .center, spacing: BrandTheme.space(6)) {
                    nameBlock(player: mine, alignment: .leading)
                    scoreChip(player: mine, dotBeforeScore: true)
                }
            }
            .buttonStyle(.plain)
            .disabled(mine == nil)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(slotLabel.uppercased())
                .font(BrandTheme.body(11, weight: .semibold))
                .foregroundStyle(BrandTheme.positionColor(for: slotLabel))
                .frame(width: BrandTheme.space(36))

            // Right: score inside, name outside — 21.8 ●  Name
            Button {
                onSelectOpp?()
            } label: {
                HStack(alignment: .center, spacing: BrandTheme.space(6)) {
                    scoreChip(player: opponent, dotBeforeScore: false)
                    nameBlock(player: opponent, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)
            .disabled(opponent == nil)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(10))
    }

    /// Fixed score column so ● lines up across rows (9.8 vs 12.1).
    private static let scoreColumnWidth: CGFloat = 36

    @ViewBuilder
    private func scoreChip(player: RosterPlayer?, dotBeforeScore: Bool) -> some View {
        Group {
            if let points = player?.displayWeekPoints {
                HStack(spacing: 4) {
                    if dotBeforeScore {
                        Circle()
                            .fill(points.kind.dotColor)
                            .frame(width: 6, height: 6)
                        Text(String(format: "%.1f", points.value))
                            .font(BrandTheme.mono(12, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                            .frame(width: Self.scoreColumnWidth, alignment: .trailing)
                    } else {
                        Text(String(format: "%.1f", points.value))
                            .font(BrandTheme.mono(12, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                            .frame(width: Self.scoreColumnWidth, alignment: .leading)
                        Circle()
                            .fill(points.kind.dotColor)
                            .frame(width: 6, height: 6)
                    }
                }
            } else {
                Text("—")
                    .font(BrandTheme.mono(12))
                    .foregroundStyle(BrandTheme.muted)
                    .frame(width: Self.scoreColumnWidth + 6 + 4, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func nameBlock(player: RosterPlayer?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(player?.name ?? "—")
                    .font(BrandTheme.body(13, weight: .medium))
                    .foregroundStyle(player == nil ? BrandTheme.muted : BrandTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let tag = InjuryStatusWeight.shortDisplayTag(player?.injuryStatus) {
                    Text(tag)
                        .font(BrandTheme.body(11, weight: .bold))
                        .foregroundStyle(BrandTheme.danger)
                        .accessibilityLabel("Injury status \(tag)")
                }
                if let player {
                    PropsAvailabilityMarkCompact(
                        hasProps: appState.playerIdsWithProps.contains(player.playerId),
                        isLoading: appState.isLoadingProps
                    )
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            if let meta = secondaryMeta(player) {
                Text(meta)
                    .font(BrandTheme.body(11))
                    .foregroundStyle(BrandTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .contentShape(Rectangle())
    }

    private func secondaryMeta(_ player: RosterPlayer?) -> String? {
        guard let player else { return nil }
        var bits: [String] = []
        if !player.team.isEmpty { bits.append(player.team) }
        if let status = player.gameStatusLabel { bits.append(status) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

struct PlayerRow: View {
    @EnvironmentObject private var appState: AppState
    let player: RosterPlayer
    var onSelect: (() -> Void)? = nil

    private var hasProps: Bool {
        appState.playerIdsWithProps.contains(player.playerId)
    }

    private var showsSalarySkeleton: Bool {
        guard player.salary == nil else { return false }
        guard appState.isSyncing else { return false }
        return appState.team?.leagueRules?.usesSalaries == true
            || appState.team?.totalSalary != nil
            || appState.team?.salaryCap != nil
    }

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(spacing: 12) {
                Text(player.position)
                    .font(BrandTheme.body(12, weight: .semibold))
                    .foregroundStyle(BrandTheme.positionColor(for: player.position))
                    .frame(width: BrandTheme.space(36), alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(player.name)
                            .font(BrandTheme.body(15, weight: .medium))
                            .foregroundStyle(BrandTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if let tag = InjuryStatusWeight.shortDisplayTag(player.injuryStatus) {
                            Text(tag)
                                .font(BrandTheme.body(12, weight: .bold))
                                .foregroundStyle(BrandTheme.danger)
                                .accessibilityLabel("Injury status \(tag)")
                        }
                        PropsAvailabilityMark(
                            hasProps: hasProps,
                            isLoading: appState.isLoadingProps
                        )
                    }
                    HStack(spacing: 6) {
                        if !player.team.isEmpty {
                            Text(player.team)
                                .font(BrandTheme.body(12))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        if let opp = player.opponent, !opp.isEmpty {
                            Text(opp)
                                .font(BrandTheme.body(12))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        if let status = player.gameStatusLabel {
                            Text(status)
                                .font(BrandTheme.mono(11, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink.opacity(0.65))
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let salary = player.salary {
                        Text(SalaryFormat.compact(salary))
                            .font(BrandTheme.mono(12, weight: .medium))
                            .foregroundStyle(BrandTheme.muted)
                    } else if showsSalarySkeleton {
                        Text("$12.5M")
                            .font(BrandTheme.mono(12, weight: .medium))
                            .foregroundStyle(BrandTheme.muted)
                            .redacted(reason: .placeholder)
                            .accessibilityLabel("Salary loading")
                    }
                    if let points = player.displayWeekPoints {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f", points.value))
                                .font(BrandTheme.mono(14, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                            Circle()
                                .fill(points.kind.dotColor)
                                .frame(width: 7, height: 7)
                        }
                    } else if appState.isSyncing {
                        HStack(spacing: 6) {
                            Text("12.3")
                                .font(BrandTheme.mono(14, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                                .redacted(reason: .placeholder)
                            Circle()
                                .fill(BrandTheme.muted.opacity(0.35))
                                .frame(width: 7, height: 7)
                        }
                        .accessibilityLabel("Points loading")
                    }
                }
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.vertical, BrandTheme.space(8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows player details")
    }
}
