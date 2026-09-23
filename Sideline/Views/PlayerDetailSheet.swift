import SwiftUI

struct PlayerDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let player: RosterPlayer

    @State private var detail: PlayerDetail?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var expandedNewsIDs: Set<String> = []

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
                                Text("Loading profile…")
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            .padding(.top, BrandTheme.space(8))
                        } else if loadFailed, detailHasNoAPIFields {
                            Text(emptyMessage)
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
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

    private var emptyMessage: String {
        if FantasyProsClient.hasAPIKey {
            return "No profile fields matched for this player. Sideline pulls Sleeper bio and MFL ranks when available."
        }
        return "No bio came back for this player. Add a FantasyPros API key in Settings for rankings, projections, and notes."
    }

    private var detailHasNoAPIFields: Bool {
        guard let detail else { return true }
        return Self.isEmptyProfile(detail)
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
                if let status = player.gameStatusLabel {
                    Text(status)
                        .font(BrandTheme.mono(11, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink.opacity(0.65))
                } else if player.gameLockState == "upcoming" {
                    Text("UPCOMING")
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
            sectionHeader("THIS WEEK", source: nil)

            HStack(spacing: BrandTheme.space(24)) {
                if let proj = player.projectedPoints {
                    pointStat(label: "Projected", value: proj, live: false)
                }
                let lock = player.gameLockState ?? "upcoming"
                if lock == "started" || lock == "final", let actual = player.actualPoints {
                    pointStat(label: lock == "started" ? "Live" : "Final", value: actual, live: lock == "started")
                } else if player.projectedPoints == nil {
                    Text("No projection available")
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
            let hasBio = detail.age != nil || detail.height != nil || detail.weight != nil
                || detail.number != nil || detail.college != nil || detail.yearsExp != nil
                || detail.depthChart != nil || detail.status != nil
            let hasMFL = detail.adp != nil || detail.mflRank != nil || detail.topAddsPct != nil
            let hasFP = detail.fpRankECR != nil || detail.fpRosRank != nil
                || detail.fpProjection != nil || detail.fpTier != nil

            VStack(alignment: .leading, spacing: BrandTheme.space(18)) {
                if hasBio {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("BIO", source: nil)
                        if let age = detail.age { metaRow("Age", age) }
                        if let h = detail.height { metaRow("Height", h) }
                        if let w = detail.weight { metaRow("Weight", "\(w) lb") }
                        if let number = detail.number { metaRow("Number", "#\(number)") }
                        if let college = detail.college { metaRow("College", college) }
                        if let years = detail.yearsExp { metaRow("Exp", "\(years) yr") }
                        if let depth = detail.depthChart { metaRow("Depth", depth) }
                        if let status = detail.status { metaRow("Status", status) }
                        if let inj = detail.injury, player.injuryStatus == nil || player.injuryStatus?.isEmpty == true {
                            metaRow("Injury", inj)
                        }
                    }
                }

                if hasMFL {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("MFL", source: nil)
                        if let adp = detail.adp, adp.uppercased() != "N/A" {
                            metaRow("ADP", adp)
                        }
                        if let rank = detail.mflRank { metaRow("Rank", rank) }
                        if let adds = detail.topAddsPct { metaRow("Top adds", "\(adds)%") }
                    }
                }

                if hasFP {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("RANKINGS", source: "FantasyPros")
                        if let ecr = detail.fpRankECR {
                            let pos = detail.fpPosRank.map { " (\($0))" } ?? ""
                            metaRow("Weekly ECR", "#\(ecr)\(pos)")
                        }
                        if let tier = detail.fpTier { metaRow("Tier", tier) }
                        if let ros = detail.fpRosRank {
                            let pos = detail.fpRosPosRank.map { " (\($0))" } ?? ""
                            metaRow("ROS", "#\(ros)\(pos)")
                        }
                        if let proj = detail.fpProjection {
                            metaRow("Proj", proj)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var newsBlock: some View {
        let items = resolvedNewsItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("NOTES", source: items.first?.source)
                ForEach(items.prefix(5)) { item in
                    newsRow(item)
                }
                Text(newsFooterCopy(for: items))
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func newsFooterCopy(for items: [PlayerNewsItem]) -> String {
        let sources = Set(items.map(\.source))
        if sources.contains("FantasyPros") {
            return "Tap a FantasyPros note to open the story. MFL notes expand in-app (MFL rarely ships article links)."
        }
        if sources.contains("MFL") {
            return "Tap a note to expand the full text. MFL doesn’t usually include outbound article links."
        }
        return "Tap a note to expand or open the linked story."
    }

    private var resolvedNewsItems: [PlayerNewsItem] {
        guard let detail else { return [] }
        if !detail.newsItems.isEmpty { return detail.newsItems }
        return detail.newsHeadlines.enumerated().map { idx, line in
            let parts = line.split(separator: "—", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let body = parts.count > 1 ? parts[1] : ""
            return PlayerNewsItem(
                id: "legacy-\(idx)",
                title: parts.first ?? line,
                body: body,
                linkURL: Self.firstURL(in: body) ?? Self.firstURL(in: line),
                source: "Notes"
            )
        }
    }

    private func newsRow(_ item: PlayerNewsItem) -> some View {
        let expanded = expandedNewsIDs.contains(item.id)
        let hasBody = !item.body.isEmpty
        return Button {
            if let url = item.linkURL {
                openURL(url)
            } else if hasBody {
                if expanded {
                    expandedNewsIDs.remove(item.id)
                } else {
                    expandedNewsIDs.insert(item.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title)
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.linkURL != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    } else if hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    }
                }
                if hasBody, expanded || item.linkURL != nil {
                    Text(item.body)
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(item.linkURL != nil && !expanded ? 3 : nil)
                } else if hasBody, !expanded, item.body != item.title {
                    Text(item.body)
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.linkURL == nil && !hasBody)
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range),
              let url = match.url else { return nil }
        return url
    }

    private func sectionHeader(_ title: String, source: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(BrandTheme.display(12, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
            Spacer(minLength: 8)
            if let source, !source.isEmpty {
                Text(source)
                    .font(BrandTheme.body(11, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink.opacity(0.55))
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
        isLoading = true
        loadFailed = false

        await SleeperPlayerCatalog.shared.ensureLoaded()

        // Shared profile pipeline for Sleeper + MFL: Sleeper bio → optional MFL ranks → FantasyPros.
        var fetched = PlayerDetail(
            playerId: player.playerId,
            name: player.name,
            age: nil,
            dob: nil,
            height: nil,
            weight: nil,
            adp: nil,
            mflRank: nil,
            topAddsPct: nil,
            injury: player.injuryStatus,
            newsHeadlines: []
        )

        if let record = await SleeperPlayerCatalog.shared.player(id: player.playerId) {
            fetched = await SleeperPlayerCatalog.shared.detail(from: record)
            if fetched.injury == nil || fetched.injury?.isEmpty == true {
                fetched.injury = player.injuryStatus
            }
        } else {
            fetched = await SleeperPlayerCatalog.shared.enrichDetail(
                fetched,
                name: player.name,
                team: player.team,
                position: player.position
            )
        }

        if let linked = appState.linkedFranchise, linked.isMFL {
            let mfl = await MFLPlayerResearchService.fetchDetail(
                playerId: player.playerId,
                linked: linked
            )
            if fetched.adp == nil { fetched.adp = mfl.adp }
            if fetched.mflRank == nil { fetched.mflRank = mfl.mflRank }
            if fetched.topAddsPct == nil { fetched.topAddsPct = mfl.topAddsPct }
            if (fetched.injury == nil || fetched.injury?.isEmpty == true), let inj = mfl.injury {
                fetched.injury = inj
            }
            if fetched.newsItems.isEmpty, !mfl.newsItems.isEmpty {
                fetched.newsItems = mfl.newsItems
                fetched.newsHeadlines = mfl.newsHeadlines
            } else if fetched.newsHeadlines.isEmpty {
                fetched.newsHeadlines = mfl.newsHeadlines
            }
        } else if let linked = appState.linkedFranchise, linked.isSleeper {
            // Same aggregate identity: Sleeper id → MFL id via DynastyProcess, then MFL research
            // if the user also has any MFL league linked (cookies).
            await PlayerIDCrosswalk.shared.ensureLoaded()
            if let bridge = await PlayerIDCrosswalk.shared.record(sleeperId: player.playerId),
               let mflId = bridge.mflId,
               let mflLink = appState.linkedLeagues.first(where: { $0.isMFL }) {
                let mfl = await MFLPlayerResearchService.fetchDetail(playerId: mflId, linked: mflLink)
                if fetched.adp == nil { fetched.adp = mfl.adp }
                if fetched.mflRank == nil { fetched.mflRank = mfl.mflRank }
                if fetched.topAddsPct == nil { fetched.topAddsPct = mfl.topAddsPct }
                if (fetched.injury == nil || fetched.injury?.isEmpty == true), let inj = mfl.injury {
                    fetched.injury = inj
                }
                if fetched.newsItems.isEmpty, !mfl.newsItems.isEmpty {
                    fetched.newsItems = mfl.newsItems
                    fetched.newsHeadlines = mfl.newsHeadlines
                }
            }
        }

        if fetched.newsItems.isEmpty, !fetched.newsHeadlines.isEmpty {
            fetched.newsItems = fetched.newsHeadlines.enumerated().map { idx, line in
                let parts = line.split(separator: "—", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let title = parts.first ?? line
                let body = parts.count > 1 ? parts[1] : line
                return PlayerNewsItem(
                    id: "mfl-\(idx)",
                    title: title,
                    body: body,
                    linkURL: Self.firstURL(in: body) ?? Self.firstURL(in: line),
                    source: "MFL"
                )
            }
        }

        if FantasyProsClient.hasAPIKey {
            let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
            let week = max(1, appState.team?.week ?? appState.selectedWeek)
            await FantasyProsIntelService.shared.ensureLoaded(
                season: season,
                week: week,
                hasLiveGames: player.gameLockState == "started"
            )
            // Prefer Sleeper catalog name/team/pos so FantasyPros matching works for Sleeper ids.
            var forMatch = player
            await PlayerIDCrosswalk.shared.ensureLoaded()
            if let bridge = await PlayerIDCrosswalk.shared.record(sleeperId: player.playerId) {
                if !bridge.name.isEmpty { forMatch.name = bridge.name }
                if !bridge.team.isEmpty { forMatch.team = bridge.team }
                if !bridge.position.isEmpty { forMatch.position = bridge.position }
            }
            var record = await SleeperPlayerCatalog.shared.player(id: player.playerId)
            if record == nil {
                record = await SleeperPlayerCatalog.shared.match(
                    name: forMatch.name, team: forMatch.team, position: forMatch.position
                )
            }
            if let record {
                forMatch.name = record.fullName
                if !record.team.isEmpty { forMatch.team = record.team }
                if !record.position.isEmpty { forMatch.position = record.position }
            } else if let detailName = fetched.name, !detailName.isEmpty {
                forMatch.name = detailName
            }
            fetched = await FantasyProsIntelService.shared.enrichDetail(fetched, player: forMatch)
        }

        let empty = Self.isEmptyProfile(fetched)
        detail = fetched
        loadFailed = empty
        isLoading = false
    }

    private static func isEmptyProfile(_ detail: PlayerDetail) -> Bool {
        detail.age == nil
            && detail.height == nil
            && detail.weight == nil
            && detail.adp == nil
            && detail.mflRank == nil
            && detail.topAddsPct == nil
            && (detail.injury == nil || detail.injury?.isEmpty == true)
            && detail.newsHeadlines.isEmpty
            && detail.newsItems.isEmpty
            && detail.college == nil
            && detail.number == nil
            && detail.status == nil
            && detail.yearsExp == nil
            && detail.depthChart == nil
            && detail.fpRankECR == nil
            && detail.fpProjection == nil
            && detail.fpRosRank == nil
    }
}
