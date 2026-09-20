import SwiftUI

struct TeamCockpitView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedPlayer: RosterPlayer?
    @State private var showWeekSummary = false

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Divider().overlay(BrandTheme.hairline)
                        matchupStrip
                        if !appState.upcomingMatchups.isEmpty {
                            Divider().overlay(BrandTheme.hairline)
                            upcomingMatchupsSection
                        }
                        Divider().overlay(BrandTheme.hairline)
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
                        if appState.linkedFranchise == nil {
                            emptyConnect
                        }
                    }
                    .padding(.bottom, BrandTheme.space(24))
                }
                .refreshable { await appState.syncTeam() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(BrandTheme.appName.uppercased())
                        .font(BrandTheme.display(18, weight: .bold))
                        .tracking(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.linkedFranchise == nil {
                        Button("Connect MFL") {
                            appState.showConnect = true
                        }
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    }
                }
            }
            .task {
                if appState.linkedFranchise != nil, appState.team == nil {
                    await appState.syncTeam()
                }
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

    private var header: some View {
        LeaguePageHeader(
            leagueName: appState.linkedFranchise?.leagueName ?? "No league linked",
            subtitle: teamSubtitle,
            trailing: headerTrailing,
            footnote: nil
        ) {
            if showsSalaryStrip {
                salaryHeaderLine
                    .padding(.top, 4)
            }
        }
    }

    private var headerTrailing: AnyView? {
        if appState.linkedFranchise == nil { return nil }
        return AnyView(
            VStack(alignment: .trailing, spacing: 4) {
                if appState.isViewingHistoricWeek {
                    WeekSummaryLink(isGenerating: appState.isGeneratingTeamSummary) {
                        showWeekSummary = true
                    }
                }
                HStack(spacing: 10) {
                    if appState.isSyncing {
                        ProgressView()
                    }
                    WeekPickerControl()
                }
            }
        )
    }

    private var teamSubtitle: String {
        let name = resolvedTeamName
        if let pf = appState.team?.seasonPointsFor {
            return "\(name)  ·  \(String(format: "%.1f", pf)) PF"
        }
        return name
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
        return appState.linkedFranchise == nil ? "Connect MFL to begin" : "My team"
    }

    private var showsSalaryStrip: Bool {
        guard let team = appState.team else { return false }
        return team.totalSalary != nil || team.salaryCap != nil || (team.leagueRules?.usesSalaries == true)
    }

    private var salaryHeaderLine: some View {
        let total = appState.team?.totalSalary
        let cap = appState.team?.salaryCap
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Salary")
                .font(BrandTheme.body(13, weight: .medium))
                .foregroundStyle(BrandTheme.muted)
            Text(total.map(SalaryFormat.compact) ?? "—")
                .font(BrandTheme.mono(13, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
            if let cap {
                Text("/ \(SalaryFormat.compact(cap))")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
            }
            if let total, let cap, cap > 0 {
                let remaining = cap - total
                Text("·")
                    .foregroundStyle(BrandTheme.muted)
                Text(remaining >= 0 ? "\(SalaryFormat.compact(remaining)) left" : "\(SalaryFormat.compact(abs(remaining))) over")
                    .font(BrandTheme.body(13, weight: .semibold))
                    .foregroundStyle(remaining >= 0 ? BrandTheme.standingsUp : BrandTheme.danger)
            }
            Spacer(minLength: 0)
        }
    }

    private var matchupStrip: some View {
        let matchup = appState.team?.matchup
        let future = appState.isViewingFutureWeek
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(future ? "Upcoming matchup" : "Matchup")
                    .font(BrandTheme.body(12, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
                Text(matchup?.opponentName.map { "vs \($0)" } ?? "—")
                    .font(BrandTheme.body(16, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }
            Spacer()
            if future {
                Text("Week \(appState.selectedWeek)")
                    .font(BrandTheme.mono(16, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
            } else {
                if let mine = matchup?.myScore {
                    Text(String(format: "%.1f", mine))
                        .font(BrandTheme.mono(20, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
                Text("–")
                    .foregroundStyle(BrandTheme.muted)
                if let opp = matchup?.oppScore {
                    Text(String(format: "%.1f", opp))
                        .font(BrandTheme.mono(20, weight: .semibold))
                        .foregroundStyle(BrandTheme.muted)
                } else {
                    Text("—")
                        .font(BrandTheme.mono(20))
                        .foregroundStyle(BrandTheme.muted)
                }
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(16))
    }

    private var upcomingMatchupsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UPCOMING")
                .font(BrandTheme.display(13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(16))
                .padding(.bottom, BrandTheme.space(8))

            ForEach(Array(appState.upcomingMatchups.prefix(4).enumerated()), id: \.element.id) { index, row in
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
                if index < min(appState.upcomingMatchups.count, 4) - 1 {
                    Rectangle()
                        .fill(BrandTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, BrandTheme.pageGutter)
                }
            }
        }
        .padding(.bottom, BrandTheme.space(12))
    }

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
                ForEach(groups.filter { $0.key != "TIEBREAK" && !$0.players.isEmpty }) { group in
                    Text(group.title)
                        .font(BrandTheme.display(12, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .tracking(0.5)
                        .padding(.horizontal, BrandTheme.pageGutter)
                        .padding(.top, BrandTheme.space(10))
                        .padding(.bottom, BrandTheme.space(4))

                    ForEach(Array(group.players.enumerated()), id: \.element.id) { index, player in
                        PlayerRow(player: player) { selectedPlayer = player }
                        if index < group.players.count - 1 {
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, BrandTheme.pageGutter)
                        }
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
                ForEach(groups) { group in
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(BrandTheme.display(12, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                            .tracking(0.5)
                        if let slots = group.starterSlotsLabel {
                            Text("(\(slots))")
                                .font(BrandTheme.body(12, weight: .medium))
                                .foregroundStyle(BrandTheme.muted)
                        }
                    }
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.top, BrandTheme.space(10))
                    .padding(.bottom, BrandTheme.space(4))

                    ForEach(Array(group.players.enumerated()), id: \.element.id) { index, player in
                        PlayerRow(player: player) { selectedPlayer = player }
                        if index < group.players.count - 1 {
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, BrandTheme.pageGutter)
                        }
                    }
                    if group.players.isEmpty, group.key == "TIEBREAK" {
                        Text("Any eligible starter from flex positions")
                            .font(BrandTheme.body(12))
                            .foregroundStyle(BrandTheme.muted)
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.bottom, BrandTheme.space(6))
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
                ForEach(displayGroups) { group in
                    Text(group.title)
                        .font(BrandTheme.display(12, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .tracking(0.5)
                        .padding(.horizontal, BrandTheme.pageGutter)
                        .padding(.top, BrandTheme.space(10))
                        .padding(.bottom, BrandTheme.space(4))

                    ForEach(Array(group.players.enumerated()), id: \.element.id) { index, player in
                        PlayerRow(player: player) { selectedPlayer = player }
                        if index < group.players.count - 1 {
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, BrandTheme.pageGutter)
                        }
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
        }
    }

    private var emptyConnect: some View {
        Text("Link your MFL franchise to load the cockpit. Use Connect MFL up top.")
            .font(BrandTheme.body(15))
            .foregroundStyle(BrandTheme.muted)
            .multilineTextAlignment(.leading)
            .padding(BrandTheme.space(24))
    }
}

struct PlayerRow: View {
    let player: RosterPlayer
    var onSelect: (() -> Void)? = nil

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(spacing: 12) {
                Text(player.position)
                    .font(BrandTheme.body(12, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .frame(width: BrandTheme.space(36), alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(BrandTheme.body(15, weight: .medium))
                        .foregroundStyle(BrandTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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
                        if let lock = player.gameLockState, lock != "upcoming", !lock.isEmpty {
                            Text(lock.uppercased())
                                .font(BrandTheme.body(10, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink.opacity(0.65))
                        }
                        if let injury = player.injuryStatus, !injury.isEmpty {
                            Text(injury)
                                .font(BrandTheme.body(11, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink.opacity(0.7))
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let salary = player.salary {
                        Text(SalaryFormat.compact(salary))
                            .font(BrandTheme.mono(12, weight: .medium))
                            .foregroundStyle(BrandTheme.muted)
                    }
                    if let points = player.displayWeekPoints {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f", points.value))
                                .font(BrandTheme.mono(14, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                            Circle()
                                .fill(points.isLive ? BrandTheme.accent : BrandTheme.muted.opacity(0.55))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
            .padding(.horizontal, BrandTheme.pageGutter)
            .padding(.vertical, BrandTheme.space(12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows player details")
    }
}
