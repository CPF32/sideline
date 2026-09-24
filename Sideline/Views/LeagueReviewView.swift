import SwiftUI

struct LeagueReviewView: View {
    @EnvironmentObject private var appState: AppState
    @State private var transactionFilter: TransactionTypeFilter = .all
    @State private var teamFilterId: String? = nil
    @State private var showWeekSummary = false

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                Group {
                    if appState.linkedFranchise == nil {
                        VStack(spacing: 12) {
                            Text("Connect MFL or Sleeper to review your league.")
                                .font(BrandTheme.body(15))
                                .foregroundStyle(BrandTheme.muted)
                            Button("Connect league") { appState.showConnect = true }
                                .buttonStyle(PrimaryButtonStyle())
                                .padding(.horizontal, BrandTheme.space(40))
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                                Divider().overlay(BrandTheme.hairline)
                                VStack(alignment: .leading, spacing: 24) {
                                    standingsSection
                                    matchupsSection
                                    transactionsSection
                                }
                                .padding(.horizontal, BrandTheme.pageGutter)
                                .padding(.top, BrandTheme.space(20))
                                .padding(.bottom, BrandTheme.space(40))
                            }
                            .sidelinePullRefreshReader()
                        }
                        .sidelinePullToRefresh {
                            await appState.syncLeagueReview()
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
            .task {
                if appState.linkedFranchise != nil, appState.leagueReview == nil {
                    await appState.syncLeagueReview()
                }
            }
            .onChange(of: appState.selectedWeek) { _, _ in
                Task { await appState.syncLeagueReview() }
            }
            .onChange(of: appState.leagueReview?.syncedAt) { _, _ in
                let options = transactionFilterOptions
                if !options.contains(transactionFilter) {
                    transactionFilter = .all
                }
                if let teamFilterId,
                   !transactionTeamOptions.contains(where: { $0.id == teamFilterId }) {
                    self.teamFilterId = nil
                }
            }
            .sheet(isPresented: $showWeekSummary) {
                WeekSummarySheet(kind: .league)
                    .environmentObject(appState)
            }
        }
    }

    private var header: some View {
        LeaguePageHeader(
            leagueName: appState.linkedFranchise?.leagueName ?? "League",
            subtitle: "Week \(appState.selectedWeek) overview",
            trailing: AnyView(headerTrailing),
            footnote: nil
        )
    }

    @ViewBuilder
    private var headerTrailing: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if appState.isViewingHistoricWeek {
                WeekSummaryLink(isGenerating: appState.isGeneratingLeagueSummary) {
                    showWeekSummary = true
                }
            }
            HStack(spacing: 10) {
                WeekPickerControl()
            }
        }
    }

    private var standingsSection: some View {
        section("Standings") {
            let rows = appState.leagueReview?.standings ?? []
            let myId = MFLNameResolver.normalizeFranchiseId(
                appState.linkedFranchise?.franchiseId ?? ""
            )
            if rows.isEmpty {
                empty("No standings yet — sync after connecting.")
            } else {
                ForEach(rows) { row in
                    let isMine = MFLNameResolver.normalizeFranchiseId(row.franchiseId) == myId
                    HStack(spacing: 8) {
                        Text("\(row.rank ?? 0)")
                            .font(BrandTheme.mono(13, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                            .frame(width: BrandTheme.space(22), alignment: .leading)

                        rankMovementBadge(row.rankDelta)
                            .frame(width: BrandTheme.space(36), alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(BrandTheme.body(14, weight: isMine ? .bold : .semibold))
                                .foregroundStyle(BrandTheme.ink)
                            Text("\(row.wins)-\(row.losses)-\(row.ties)")
                                .font(BrandTheme.body(12))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f", row.pointsFor))
                                .font(BrandTheme.mono(13, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                            Text("PF")
                                .font(BrandTheme.body(10))
                                .foregroundStyle(BrandTheme.muted)
                        }
                    }
                    .padding(.horizontal, BrandTheme.space(10))
                    .padding(.vertical, BrandTheme.space(10))
                    .background(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .fill(isMine ? BrandTheme.accentWash : Color.clear)
                    )
                    .overlay(alignment: .bottom) {
                        if !isMine {
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.horizontal, BrandTheme.space(10))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rankMovementBadge(_ delta: Int?) -> some View {
        if let delta, delta != 0 {
            HStack(spacing: 2) {
                Image(systemName: delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("\(abs(delta))")
                    .font(BrandTheme.mono(11, weight: .semibold))
            }
            .foregroundStyle(delta > 0 ? BrandTheme.standingsUp : BrandTheme.standingsDown)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var matchupsSection: some View {
        section("Week \(appState.selectedWeek) matchups") {
            let rows = appState.leagueReview?.matchups ?? []
            if rows.isEmpty {
                empty("No matchups for this week.")
            } else {
                ForEach(rows) { row in
                    let homeLeads = isLeading(row.homeScore, vs: row.awayScore)
                    let awayLeads = isLeading(row.awayScore, vs: row.homeScore)
                    VStack(spacing: 6) {
                        matchupSide(name: row.homeName, score: row.homeScore, leading: homeLeads)
                        matchupSide(name: row.awayName, score: row.awayScore, leading: awayLeads)
                    }
                    .padding(.vertical, BrandTheme.space(10))
                    Divider().overlay(BrandTheme.hairline)
                }
            }
        }
    }

    private func isLeading(_ score: Double?, vs other: Double?) -> Bool {
        guard let score, let other else { return false }
        return score > other
    }

    private func matchupSide(name: String, score: Double?, leading: Bool) -> some View {
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

    private var transactionsSection: some View {
        let allRows = appState.leagueReview?.transactions ?? []
        let filtered = filteredTransactions(allRows)
        return VStack(alignment: .leading, spacing: 10) {
            Text("TRANSACTIONS")
                .font(BrandTheme.display(12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)

            if !allRows.isEmpty {
                transactionFilterBar
                teamFilterBar
            }

            if allRows.isEmpty {
                empty("No recent transactions.")
            } else if filtered.isEmpty {
                empty("No transactions for this filter.")
            } else {
                ForEach(filtered.prefix(40)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(TransactionTypeFilter.displayTitle(for: row.type))
                                .font(BrandTheme.display(10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(BrandTheme.muted)
                            Spacer()
                            if let ts = row.timestamp {
                                Text(ts.formatted(date: .abbreviated, time: .omitted))
                                    .font(BrandTheme.body(11))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                        }
                        Text(row.franchiseName)
                            .font(BrandTheme.body(13, weight: .semibold))
                            .foregroundStyle(BrandTheme.ink)
                        Text(row.summary)
                            .font(BrandTheme.body(13))
                            .foregroundStyle(BrandTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, BrandTheme.space(8))
                    Divider().overlay(BrandTheme.hairline)
                }
            }
        }
    }

    private var transactionFilterBar: some View {
        filterScroll(options: transactionFilterOptions.map { ($0.id, $0.title) }) { id in
            if let match = transactionFilterOptions.first(where: { $0.id == id }) {
                transactionFilter = match
            }
        } isSelected: { id in
            transactionFilter.id == id
        }
    }

    private var teamFilterBar: some View {
        let options: [(id: String, title: String)] =
            [("all", "All teams")] + transactionTeamOptions.map { ($0.id, $0.name) }
        return filterScroll(options: options) { id in
            teamFilterId = (id == "all") ? nil : id
        } isSelected: { id in
            if id == "all" { return teamFilterId == nil }
            return teamFilterId == id
        }
    }

    private func filterScroll(
        options: [(id: String, title: String)],
        onSelect: @escaping (String) -> Void,
        isSelected: @escaping (String) -> Bool
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(options, id: \.id) { option in
                    let selected = isSelected(option.id)
                    Button {
                        onSelect(option.id)
                    } label: {
                        VStack(spacing: 6) {
                            Text(option.title)
                                .font(BrandTheme.body(13, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? BrandTheme.ink : BrandTheme.muted)
                                .lineLimit(1)
                            Rectangle()
                                .fill(selected ? BrandTheme.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, BrandTheme.space(12))
                        .padding(.top, BrandTheme.space(4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var transactionFilterOptions: [TransactionTypeFilter] {
        let types = Set((appState.leagueReview?.transactions ?? []).map { TransactionTypeFilter.bucket(for: $0.type) })
        let known: [TransactionTypeFilter] = [.freeAgent, .waiver, .trade, .ir, .taxi, .other]
        return [.all] + known.filter { types.contains($0) }
    }

    private var transactionTeamOptions: [(id: String, name: String)] {
        let rows = appState.leagueReview?.transactions ?? []
        var seen: [String: String] = [:]
        for row in rows where !row.franchiseId.isEmpty {
            if seen[row.franchiseId] == nil {
                seen[row.franchiseId] = row.franchiseName
            }
        }
        return seen
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func filteredTransactions(_ rows: [LeagueTransactionRow]) -> [LeagueTransactionRow] {
        rows.filter { row in
            let typeOK = transactionFilter == .all
                || TransactionTypeFilter.bucket(for: row.type) == transactionFilter
            let teamOK = teamFilterId == nil || row.franchiseId == teamFilterId
            return typeOK && teamOK
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(BrandTheme.display(12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(BrandTheme.body(14))
            .foregroundStyle(BrandTheme.muted)
            .padding(.vertical, BrandTheme.space(8))
    }
}

private enum TransactionTypeFilter: String, Identifiable, Hashable {
    case all
    case freeAgent
    case waiver
    case trade
    case ir
    case taxi
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .freeAgent: return "FA"
        case .waiver: return "Waiver"
        case .trade: return "Trade"
        case .ir: return "IR"
        case .taxi: return "Taxi"
        case .other: return "Other"
        }
    }

    static func bucket(for raw: String) -> TransactionTypeFilter {
        let t = raw.uppercased()
        if t.contains("FREE_AGENT") || t == "FA" { return .freeAgent }
        if t.contains("WAIVER") { return .waiver }
        if t.contains("TRADE") { return .trade }
        if t == "IR" || t.contains("INJURED") { return .ir }
        if t.contains("TAXI") { return .taxi }
        return .other
    }

    static func displayTitle(for raw: String) -> String {
        switch bucket(for: raw) {
        case .all: return raw.uppercased()
        case .freeAgent: return "FREE AGENT"
        case .waiver: return "WAIVER"
        case .trade: return "TRADE"
        case .ir: return "IR"
        case .taxi: return "TAXI"
        case .other: return raw.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }
}
