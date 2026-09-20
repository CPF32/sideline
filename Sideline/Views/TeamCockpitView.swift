import SwiftUI

struct TeamCockpitView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Divider().overlay(BrandTheme.hairline)
                        matchupStrip
                        Divider().overlay(BrandTheme.hairline)
                        rosterSection(title: "Starters", players: appState.team?.starters ?? [])
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
        }
    }

    private var header: some View {
        LeaguePageHeader(
            leagueName: appState.linkedFranchise?.leagueName ?? "No league linked",
            subtitle: teamSubtitle,
            trailing: headerTrailing,
            footnote: appState.isViewingHistoricWeek ? "Historic week" : nil
        ) {
            if showsSalaryStrip {
                salaryHeaderLine
                    .padding(.top, 4)
            }
        }
    }

    private var headerTrailing: AnyView? {
        if appState.linkedFranchise == nil { return nil }
        if appState.isSyncing {
            return AnyView(
                HStack(spacing: 10) {
                    ProgressView()
                    weekMenu
                }
            )
        }
        return AnyView(weekMenu)
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

    private var weekMenu: some View {
        Menu {
            ForEach(appState.availableWeeks.reversed(), id: \.self) { week in
                Button {
                    appState.selectWeek(week)
                } label: {
                    HStack {
                        Text("Week \(week)")
                        if week == appState.selectedWeek {
                            Image(systemName: "checkmark")
                        }
                        if week < appState.currentSeasonWeek {
                            Text("Historic")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("WEEK \(appState.selectedWeek)")
                    .font(BrandTheme.display(14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(BrandTheme.ink)
        }
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Matchup")
                    .font(BrandTheme.body(12, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
                Text(appState.team?.matchup?.opponentName.map { "vs \($0)" } ?? "—")
                    .font(BrandTheme.body(16, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }
            Spacer()
            if let mine = appState.team?.matchup?.myScore {
                Text(String(format: "%.1f", mine))
                    .font(BrandTheme.mono(20, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }
            Text("–")
                .foregroundStyle(BrandTheme.muted)
            if let opp = appState.team?.matchup?.oppScore {
                Text(String(format: "%.1f", opp))
                    .font(BrandTheme.mono(20, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
            } else {
                Text("—")
                    .font(BrandTheme.mono(20))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(16))
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
                    PlayerRow(player: player, isStarter: false)
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
                        PlayerRow(player: player, isStarter: false)
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
                        PlayerRow(player: player, isStarter: false)
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
                    PlayerRow(player: player, isStarter: title == "Starters")
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
    var isStarter: Bool

    var body: some View {
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
                if let proj = player.projectedPoints {
                    Text(String(format: "%.1f", proj))
                        .font(BrandTheme.mono(14, weight: .medium))
                        .foregroundStyle(BrandTheme.ink)
                }
            }
            if isStarter {
                Circle()
                    .fill(BrandTheme.accent)
                    .frame(width: BrandTheme.space(8), height: BrandTheme.space(8))
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(12))
        .contentShape(Rectangle())
    }
}
