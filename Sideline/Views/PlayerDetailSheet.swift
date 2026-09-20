import SwiftUI

struct PlayerDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let player: RosterPlayer

    @State private var detail: PlayerDetail?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: BrandTheme.space(20)) {
                        headerBlock
                        weekPointsBlock
                        metaBlock
                        if isLoading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading MFL profile…")
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            .padding(.top, BrandTheme.space(8))
                        } else if loadFailed, detailHasNoAPIFields {
                            Text("MFL didn’t return a profile for this player.")
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                        } else {
                            profileFields
                            newsBlock
                        }
                    }
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.top, BrandTheme.space(12))
                    .padding(.bottom, BrandTheme.space(32))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("PLAYER")
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
            .task { await load() }
        }
    }

    private var detailHasNoAPIFields: Bool {
        guard let detail else { return true }
        return detail.age == nil
            && detail.height == nil
            && detail.weight == nil
            && detail.adp == nil
            && detail.mflRank == nil
            && detail.topAddsPct == nil
            && (detail.injury == nil || detail.injury?.isEmpty == true)
            && detail.newsHeadlines.isEmpty
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(player.name)
                .font(BrandTheme.display(28, weight: .bold))
                .foregroundStyle(BrandTheme.ink)
            HStack(spacing: 8) {
                Text(player.position)
                    .font(BrandTheme.body(14, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
                if !player.team.isEmpty {
                    Text(player.team)
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                }
                if let opp = player.opponent, !opp.isEmpty {
                    Text(opp)
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                }
                if let lock = player.gameLockState, !lock.isEmpty {
                    Text(lock.uppercased())
                        .font(BrandTheme.body(11, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink.opacity(0.65))
                }
            }
            if let injury = player.injuryStatus ?? detail?.injury, !injury.isEmpty {
                Text(injury)
                    .font(BrandTheme.body(13, weight: .semibold))
                    .foregroundStyle(BrandTheme.danger)
            }
        }
    }

    private var weekPointsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS WEEK")
                .font(BrandTheme.display(12, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)

            HStack(spacing: BrandTheme.space(24)) {
                if let proj = player.projectedPoints {
                    pointStat(label: "Projected", value: proj, live: false)
                }
                if let actual = player.actualPoints {
                    let live = (player.gameLockState == "started" || player.gameLockState == "final")
                    pointStat(label: live ? "Live" : "Scored", value: actual, live: true)
                } else if player.gameLockState == "upcoming" || player.gameLockState == nil {
                    Text("Live score after kickoff")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                }
                Spacer(minLength: 0)
            }

            if let ytd = player.seasonPoints {
                Text("Season \(String(format: "%.1f", ytd)) pts")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
    }

    private func pointStat(label: String, value: Double, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(live ? BrandTheme.accent : BrandTheme.muted.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(BrandTheme.body(12, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
            }
            Text(String(format: "%.1f", value))
                .font(BrandTheme.mono(22, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let salary = player.salary {
                metaRow("Salary", SalaryFormat.compact(salary))
            }
            if let year = player.contractYear {
                metaRow("Contract", String(year))
            }
            metaRow("Roster", player.status.capitalized)
        }
    }

    @ViewBuilder
    private var profileFields: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 8) {
                Text("PROFILE")
                    .font(BrandTheme.display(12, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                if let age = detail.age { metaRow("Age", age) }
                if let h = detail.height { metaRow("Height", h) }
                if let w = detail.weight { metaRow("Weight", "\(w) lb") }
                if let adp = detail.adp, adp.uppercased() != "N/A" { metaRow("ADP", adp) }
                if let rank = detail.mflRank { metaRow("MFL rank", rank) }
                if let adds = detail.topAddsPct { metaRow("Top adds", "\(adds)%") }
                if let inj = detail.injury, player.injuryStatus == nil || player.injuryStatus?.isEmpty == true {
                    metaRow("Injury", inj)
                }
            }
        }
    }

    @ViewBuilder
    private var newsBlock: some View {
        if let headlines = detail?.newsHeadlines, !headlines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEWS")
                    .font(BrandTheme.display(12, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                ForEach(Array(headlines.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(BrandTheme.body(14, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        guard let linked = appState.linkedFranchise else {
            isLoading = false
            loadFailed = true
            return
        }
        isLoading = true
        loadFailed = false
        let fetched = await MFLPlayerResearchService.fetchDetail(
            playerId: player.playerId,
            linked: linked
        )
        detail = fetched
        loadFailed = fetched.age == nil
            && fetched.height == nil
            && fetched.weight == nil
            && fetched.adp == nil
            && fetched.mflRank == nil
            && fetched.topAddsPct == nil
            && (fetched.injury == nil || fetched.injury?.isEmpty == true)
            && fetched.newsHeadlines.isEmpty
        isLoading = false
    }
}
