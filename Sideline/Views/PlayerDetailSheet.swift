import SwiftUI
import SafariServices

/// Keeps the last opened player profile in memory so reopen is instant (services already
/// cache upstream, but the sheet used to reset `isLoading` and blank the UI every time).
private actor PlayerDetailSheetCache {
    static let shared = PlayerDetailSheetCache()

    struct Entry {
        var detail: PlayerDetail
        var props: [OddsPlayerProp]
    }

    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry? { entries[key] }

    func store(key: String, detail: PlayerDetail, props: [OddsPlayerProp]) {
        entries[key] = Entry(detail: detail, props: props)
    }
}

struct PlayerDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let player: RosterPlayer

    @State private var detail: PlayerDetail?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var expandedNewsIDs: Set<String> = []
    @State private var browserItem: InAppNewsBrowserItem?
    @State private var oddsProps: [OddsPlayerProp] = []

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerBlock
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.top, BrandTheme.space(12))
                            .padding(.bottom, BrandTheme.space(16))

                        hairline

                        snapshotStrip
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.vertical, BrandTheme.space(16))

                        if showsMarketSection {
                            hairline
                            marketSection
                        }
                        if hasRankingsSection {
                            hairline
                            rankingsSection
                        }
                        if !notesBySource.isEmpty {
                            hairline
                            newsSection
                        }

                        if isLoading, !hasRenderableBody {
                            hairline
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading profile…")
                                    .font(BrandTheme.body(14))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.vertical, BrandTheme.space(20))
                        } else if loadFailed, detailHasNoAPIFields, !isLoading, !showsMarketSection {
                            hairline
                            Text(emptyMessage)
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, BrandTheme.pageGutter)
                                .padding(.vertical, BrandTheme.space(20))
                        }
                    }
                    .padding(.bottom, BrandTheme.space(40))
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
            .sheet(item: $browserItem) { item in
                InAppSafariSheet(url: item.url)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// True when bio, props, rankings, or notes already have something to show.
    private var hasRenderableBody: Bool {
        if !oddsProps.isEmpty { return true }
        if hasRankingsSectionContent { return true }
        if !notesBySource.isEmpty { return true }
        if OddsAPIClient.hasAPIKey { return true }
        if FantasyProsClient.hasAPIKey { return true }
        if let detail, !Self.isEmptyProfile(detail) { return true }
        // Bio strip filled from catalog counts — avoid blank "Loading profile…" flash.
        if detail?.age != nil || detail?.height != nil || detail?.weight != nil || detail?.yearsExp != nil {
            return true
        }
        return false
    }

    private var hairline: some View {
        Divider().overlay(BrandTheme.hairline)
    }

    private var emptyMessage: String {
        if FantasyProsClient.hasAPIKey {
            return "No profile fields matched for this player. Sideline pulls Sleeper bio, MFL ranks/news when available, and FantasyPros."
        }
        return "No bio came back for this player. Sideline uses Sleeper + MFL public profiles (and news when MFL provides it). Add a FantasyPros API key in Settings for richer notes."
    }

    private var detailHasNoAPIFields: Bool {
        guard let detail else { return true }
        return Self.isEmptyProfile(detail)
    }

    // MARK: - Header (kept)

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(player.name)
                    .font(BrandTheme.display(28, weight: .bold))
                    .foregroundStyle(BrandTheme.ink)
                if let tag = InjuryStatusWeight.shortDisplayTag(player.injuryStatus ?? detail?.injury) {
                    Text(tag)
                        .font(BrandTheme.body(14, weight: .bold))
                        .foregroundStyle(BrandTheme.danger)
                        .accessibilityLabel("Injury status \(tag)")
                }
            }
            HStack(spacing: 8) {
                Text(player.position)
                    .font(BrandTheme.body(14, weight: .semibold))
                    .foregroundStyle(BrandTheme.positionColor(for: player.position))
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Snapshot strip (week + franchise + bio)

    private var snapshotStrip: some View {
        VStack(alignment: .leading, spacing: BrandTheme.space(10)) {
            HStack(alignment: .top, spacing: BrandTheme.space(14)) {
                weekMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
                franchiseMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
                bioMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let ytd = player.seasonPoints {
                Text("Season \(String(format: "%.1f", ytd)) pts")
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
    }

    private var weekMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(BrandTheme.display(12, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
            VStack(alignment: .leading, spacing: BrandTheme.space(10)) {
                if let proj = player.projectedPoints {
                    stripStat(label: "Proj", value: String(format: "%.1f", proj), kind: .projected)
                } else if player.treatsMissingProjectionAsZero {
                    stripStat(label: "Proj", value: "0.0", kind: .projected)
                }
                let lock = player.gameLockState ?? "upcoming"
                if lock == "started" || lock == "final", let actual = player.actualPoints {
                    stripStat(
                        label: lock == "started" ? "Live" : "Final",
                        value: String(format: "%.1f", actual),
                        kind: lock == "started" ? .live : .final
                    )
                } else if player.projectedPoints == nil, !player.treatsMissingProjectionAsZero {
                    Text("No projection")
                        .font(BrandTheme.body(12))
                        .foregroundStyle(BrandTheme.muted)
                }
            }
        }
    }

    private var franchiseMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FRANCHISE")
                .font(BrandTheme.display(12, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
            VStack(alignment: .leading, spacing: 5) {
                if let salary = player.salary {
                    stripKV("Salary", SalaryFormat.compact(salary))
                } else if appState.team?.leagueRules?.usesSalaries == true {
                    stripKV("Salary", "—")
                }
                if let year = player.contractYear {
                    stripKV("Contract", String(year))
                }
                stripKV("Roster", player.status.capitalized)
            }
        }
    }

    private var bioMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BIO")
                .font(BrandTheme.display(12, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
                .tracking(1)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(bioDisplayRows, id: \.label) { row in
                    if let value = row.value {
                        stripKV(row.label, value)
                    } else if isLoading {
                        stripKVSkeleton(row.label)
                    } else {
                        stripKV(row.label, "—")
                    }
                }
            }
        }
    }

    /// Fixed Age / Size / Exp slots so Franchise never shifts when bio arrives.
    private var bioDisplayRows: [(label: String, value: String?)] {
        [
            ("Age", detail?.age),
            ("Size", detail.flatMap(sizeLabel(from:))),
            ("Exp", detail?.yearsExp.map { "\($0) yr" })
        ]
    }

    private func stripStat(label: String, value: String, kind: WeekPointsKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(kind.dotColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(BrandTheme.body(12, weight: .medium))
                    .foregroundStyle(BrandTheme.muted)
            }
            Text(value)
                .font(BrandTheme.mono(22, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
        }
    }

    private func stripKV(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted)
            Text(value)
                .font(BrandTheme.mono(12, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    private func stripKVSkeleton(_ label: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(BrandTheme.muted.opacity(0.22))
                .frame(width: 44, height: 11)
                .redacted(reason: .placeholder)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("\(label) loading")
    }

    // MARK: - Props

    private var showsMarketSection: Bool {
        if player.gameLockState == "bye" { return false }
        if !oddsProps.isEmpty { return true }
        // Reserve props slot while fetching when a key is on device (no flash / no jump).
        return OddsAPIClient.hasAPIKey
    }

    @ViewBuilder
    private var marketSection: some View {
        profileSection(title: "PROPS", source: oddsProps.first?.bookmaker ?? (OddsAPIClient.hasAPIKey ? "Odds API" : nil)) {
            if isLoading && oddsProps.isEmpty {
                propsSkeletonRows
            } else if oddsProps.isEmpty {
                Text("No player props matched for \(player.name) yet.")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(oddsProps.prefix(6).enumerated()), id: \.element.id) { index, prop in
                        if index > 0 { hairline }
                        propRow(prop)
                    }
                }
            }
        }
    }

    private var propsSkeletonRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                if index > 0 { hairline }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Rush yards")
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                    Spacer(minLength: 8)
                    Text("O 62.5 (-110)")
                        .font(BrandTheme.mono(13, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                }
                .padding(.vertical, BrandTheme.space(9))
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading props")
    }

    // MARK: - Bio (compact, beside franchise)

    private func sizeLabel(from detail: PlayerDetail) -> String? {
        let height = detail.height?.trimmingCharacters(in: .whitespacesAndNewlines)
        let weight = detail.weight.map { "\($0)" }
        switch (height?.isEmpty == false ? height : nil, weight) {
        case let (h?, w?):
            return "\(h) / \(w) lb"
        case let (h?, nil):
            return h
        case let (nil, w?):
            return "\(w) lb"
        default:
            return nil
        }
    }

    // MARK: - Rankings

    private var hasRankingsSection: Bool {
        if hasRankingsSectionContent { return true }
        // Reserve rankings slot while FantasyPros is loading when a key is present.
        return FantasyProsClient.hasAPIKey && isLoading
    }

    private var hasRankingsSectionContent: Bool {
        guard let detail else { return false }
        return detail.fpRankECR != nil || detail.fpRosRank != nil
            || detail.fpProjection != nil || detail.fpTier != nil
    }

    @ViewBuilder
    private var rankingsSection: some View {
        profileSection(title: "RANKINGS", source: "FantasyPros") {
            if hasRankingsSectionContent, let detail {
                let rows = rankingRows(from: detail)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { hairline }
                        detailRow(row.0, row.1, mono: true)
                    }
                }
            } else if isLoading {
                VStack(spacing: 0) {
                    ForEach(["Weekly ECR", "Tier", "ROS"], id: \.self) { label in
                        HStack {
                            Text(label)
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                            Spacer()
                            Text("#12")
                                .font(BrandTheme.mono(14, weight: .semibold))
                                .foregroundStyle(BrandTheme.ink)
                                .redacted(reason: .placeholder)
                        }
                        .padding(.vertical, BrandTheme.space(9))
                        if label != "ROS" { hairline }
                    }
                }
                .accessibilityLabel("Loading rankings")
            }
        }
    }

    private func rankingRows(from detail: PlayerDetail) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let ecr = detail.fpRankECR {
            let pos = detail.fpPosRank.map { " (\($0))" } ?? ""
            rows.append(("Weekly ECR", "#\(ecr)\(pos)"))
        }
        if let tier = detail.fpTier { rows.append(("Tier", tier)) }
        if let ros = detail.fpRosRank {
            let pos = detail.fpRosPosRank.map { " (\($0))" } ?? ""
            rows.append(("ROS", "#\(ros)\(pos)"))
        }
        if let proj = detail.fpProjection { rows.append(("Proj", proj)) }
        return rows
    }

    // MARK: - Notes

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notesBySource.enumerated()), id: \.element.source) { groupIndex, group in
                if groupIndex > 0 { hairline }
                profileSection(title: "NOTES", source: group.source) {
                    VStack(spacing: 0) {
                        ForEach(Array(group.items.prefix(5).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { hairline }
                            if item.source == "FantasyPros" {
                                fantasyProsNewsRow(item)
                            } else {
                                hostNoteRow(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct NotesGroup {
        let source: String
        let items: [PlayerNewsItem]
    }

    private var notesBySource: [NotesGroup] {
        let items = resolvedNewsItems
        guard !items.isEmpty else { return [] }
        var order: [String] = []
        var buckets: [String: [PlayerNewsItem]] = [:]
        for item in items {
            let key = noteSourceLabel(item.source)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key, default: []].append(item)
        }
        order.sort { a, b in
            if a == "FantasyPros" { return true }
            if b == "FantasyPros" { return false }
            if a == "MFL" { return true }
            if b == "MFL" { return false }
            return a < b
        }
        return order.compactMap { key in
            guard let list = buckets[key], !list.isEmpty else { return nil }
            return NotesGroup(source: key, items: list)
        }
    }

    private func noteSourceLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Notes" { return "MFL" }
        return trimmed
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
                source: "MFL"
            )
        }
    }

    private func hostNoteRow(_ item: PlayerNewsItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(BrandTheme.body(14, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !item.body.isEmpty, item.body != item.title {
                Text(item.body)
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, BrandTheme.space(10))
    }

    private func fantasyProsNewsRow(_ item: PlayerNewsItem) -> some View {
        let expanded = expandedNewsIDs.contains(item.id)
        let hasBody = !item.body.isEmpty
        let hasLink = item.linkURL != nil
        return Button {
            if let url = item.linkURL {
                browserItem = InAppNewsBrowserItem(url: url)
            } else if hasBody {
                toggleExpanded(item.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title)
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasLink {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    } else if hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                    }
                }
                if hasBody {
                    Text(item.body)
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(hasLink && !expanded ? 3 : (expanded || hasLink ? nil : 2))
                }
            }
            .padding(.vertical, BrandTheme.space(10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasLink && !hasBody)
    }

    // MARK: - Shared chrome

    private func profileSection<Content: View>(
        title: String,
        source: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BrandTheme.space(10)) {
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
            content()
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.vertical, BrandTheme.space(16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func propRow(_ prop: OddsPlayerProp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(prop.marketLabel)
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
            Spacer(minLength: 8)
            OddsPropLineLabel(prop: prop)
        }
        .padding(.vertical, BrandTheme.space(10))
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? BrandTheme.mono(13, weight: .medium) : BrandTheme.body(14, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, BrandTheme.space(10))
    }

    private func toggleExpanded(_ id: String) {
        if expandedNewsIDs.contains(id) {
            expandedNewsIDs.remove(id)
        } else {
            expandedNewsIDs.insert(id)
        }
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

    private func mergeHostNotes(into fetched: inout PlayerDetail, from mfl: PlayerDetail) {
        guard !mfl.newsItems.isEmpty || !mfl.newsHeadlines.isEmpty else { return }
        if !mfl.newsItems.isEmpty {
            var byId = Dictionary(uniqueKeysWithValues: fetched.newsItems.map { ($0.id, $0) })
            for item in mfl.newsItems {
                byId[item.id] = item
            }
            fetched.newsItems = Array(byId.values)
            fetched.newsHeadlines = fetched.newsItems.map { item in
                item.body.isEmpty || item.body == item.title
                    ? item.title
                    : "\(item.title) — \(item.body)"
            }
        } else if fetched.newsHeadlines.isEmpty {
            fetched.newsHeadlines = mfl.newsHeadlines
        }
    }

    private func load() async {
        let week = max(1, appState.team?.week ?? appState.selectedWeek)
        let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
        let cacheKey = "\(player.playerId)|\(season)|w\(week)"

        // Instant reopen: paint last successful sheet state, then refresh quietly.
        if let cached = await PlayerDetailSheetCache.shared.entry(for: cacheKey) {
            detail = cached.detail
            oddsProps = cached.props
            loadFailed = Self.isEmptyProfile(cached.detail)
            isLoading = false
        } else {
            isLoading = true
            loadFailed = false
        }

        await SleeperPlayerCatalog.shared.ensureLoaded()

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

        // Show bio as soon as Sleeper catalog fills it (don't wait on MFL / FP / Odds).
        detail = fetched
        if !Self.isEmptyProfile(fetched) || fetched.age != nil || fetched.height != nil {
            isLoading = false
        }

        // Hydrate props from OddsIntel memory immediately when already warm.
        if OddsAPIClient.hasAPIKey, player.gameLockState != "bye" {
            let warm = await OddsIntelService.shared.props(for: player)
            if !warm.isEmpty {
                oddsProps = warm
                isLoading = false
            }
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
            mergeHostNotes(into: &fetched, from: mfl)
            detail = fetched
        } else if let linked = appState.linkedFranchise, linked.isSleeper {
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
                mergeHostNotes(into: &fetched, from: mfl)
                detail = fetched
            }
        } else if let linked = appState.linkedFranchise, linked.isESPN {
            await PlayerIDCrosswalk.shared.ensureLoaded()
            if let bridge = await PlayerIDCrosswalk.shared.record(espnId: player.playerId),
               let mflId = bridge.mflId,
               let mflLink = appState.linkedLeagues.first(where: { $0.isMFL }) {
                let mfl = await MFLPlayerResearchService.fetchDetail(playerId: mflId, linked: mflLink)
                if fetched.adp == nil { fetched.adp = mfl.adp }
                if fetched.mflRank == nil { fetched.mflRank = mfl.mflRank }
                if fetched.topAddsPct == nil { fetched.topAddsPct = mfl.topAddsPct }
                if (fetched.injury == nil || fetched.injury?.isEmpty == true), let inj = mfl.injury {
                    fetched.injury = inj
                }
                mergeHostNotes(into: &fetched, from: mfl)
                detail = fetched
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
            detail = fetched
        }

        if FantasyProsClient.hasAPIKey {
            await FantasyProsIntelService.shared.ensureLoaded(
                season: season,
                week: week,
                hasLiveGames: player.gameLockState == "started"
            )
            var forMatch = player
            await PlayerIDCrosswalk.shared.ensureLoaded()
            if let bridge = await PlayerIDCrosswalk.shared.record(sleeperId: player.playerId) {
                if !bridge.name.isEmpty {
                    forMatch.name = FantasyProsIntelService.displayNameForMatching(bridge.name)
                }
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
                let cleaned = FantasyProsIntelService.displayNameForMatching(record.fullName)
                if forMatch.name == player.name || forMatch.name.isEmpty, !cleaned.isEmpty {
                    forMatch.name = cleaned
                }
                if !record.team.isEmpty { forMatch.team = record.team }
                if !record.position.isEmpty { forMatch.position = record.position }
            } else if let detailName = fetched.name, !detailName.isEmpty {
                forMatch.name = FantasyProsIntelService.displayNameForMatching(detailName)
            } else {
                forMatch.name = FantasyProsIntelService.displayNameForMatching(forMatch.name)
            }
            fetched = await FantasyProsIntelService.shared.enrichDetail(fetched, player: forMatch)
            detail = fetched
        }

        if OddsAPIClient.hasAPIKey, player.gameLockState != "bye" {
            let live = !appState.isViewingHistoricWeek && player.gameLockState == "started"
            let rosterSeed = (appState.team?.starters ?? []) + (appState.team?.bench ?? [])
            let seed = rosterSeed.isEmpty ? [player] : rosterSeed
            await OddsIntelService.shared.ensureLoaded(
                players: seed,
                season: season,
                week: week,
                isHistoric: appState.isViewingHistoricWeek,
                hasLiveGames: live
            )
            oddsProps = await OddsIntelService.shared.props(for: player)
        } else if player.gameLockState == "bye" {
            oddsProps = []
        }

        let empty = Self.isEmptyProfile(fetched)
        detail = fetched
        loadFailed = empty
        isLoading = false

        await PlayerDetailSheetCache.shared.store(key: cacheKey, detail: fetched, props: oddsProps)
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

private struct InAppNewsBrowserItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct InAppSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
