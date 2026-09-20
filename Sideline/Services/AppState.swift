import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var team: TeamSnapshot?
    @Published var linkedFranchise: LinkedFranchise?
    @Published var isSyncing = false
    @Published var isRunningAgent = false
    @Published var agentRunTitle: String?
    @Published var agentActivityLines: [AgentActivityLine] = []
    @Published var agentActivityStatus: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var pendingCount: Int = 0
    @Published var guardrails: GuardrailSettings = GuardrailEngine.load()
    @Published var agentCriteria: AgentCriteriaBundle = AgentCriteriaStore.load()
    @Published var showApprovals = false
    @Published var showSettings = false
    @Published var showConnect = false
    @Published var showAgents = false
    @Published var selectedTab: MainTab = .team
    @Published var selectedWeek: Int = 1
    @Published var currentSeasonWeek: Int = 1
    /// Last regular-season (or playoff) week available in this league for browsing/lineups.
    @Published var seasonEndWeek: Int = 18
    /// Next few franchise matchups after the live NFL week (from full schedule).
    @Published var upcomingMatchups: [UpcomingMatchupPreview] = []
    @Published var leagueReview: LeagueReviewSnapshot?
    @Published var isLoadingLeague = false
    @Published var followUpProposal: ActionProposal?
    @Published var teamWeekSummary: CachedWeekSummary?
    @Published var leagueWeekSummary: CachedWeekSummary?
    @Published var isGeneratingTeamSummary = false
    @Published var isGeneratingLeagueSummary = false

    let auth = AppleAuthService()
    let llmSettings = LLMSettingsStore()

    private var modelContext: ModelContext?

    var availableWeeks: [Int] {
        let end = max(seasonEndWeek, currentSeasonWeek, team?.week ?? selectedWeek, 1)
        return Array(1...min(end, 22))
    }

    var isViewingHistoricWeek: Bool {
        selectedWeek < currentSeasonWeek
    }

    var isViewingFutureWeek: Bool {
        selectedWeek > currentSeasonWeek
    }

    var weekKindLabel: String? {
        if isViewingHistoricWeek { return "Historic week" }
        if isViewingFutureWeek { return "Upcoming week — set lineup early" }
        return nil
    }

    func attach(context: ModelContext) {
        modelContext = context
        refreshPendingCount()
        if linkedFranchise == nil {
            linkedFranchise = try? context.fetch(FetchDescriptor<LinkedFranchise>()).first
        }
        refreshCachedSummaries()
    }

    /// Removes leftover ScreenshotDemo franchise/proposals so normal sync uses a real MFL link.
    func purgeScreenshotDemoIfNeeded(context: ModelContext) {
        modelContext = context
        let demoId = ScreenshotDemo.demoLeagueId
        let links = (try? context.fetch(FetchDescriptor<LinkedFranchise>())) ?? []
        var purgedLink = false
        for link in links where link.leagueId == demoId {
            context.delete(link)
            purgedLink = true
        }
        if purgedLink {
            let proposals = (try? context.fetch(FetchDescriptor<ActionProposal>())) ?? []
            for proposal in proposals {
                let proposalId = proposal.id
                let threads = (try? context.fetch(
                    FetchDescriptor<AgentChatThread>(predicate: #Predicate { $0.proposalId == proposalId })
                )) ?? []
                for thread in threads { context.delete(thread) }
                context.delete(proposal)
            }
            try? context.save()
            if linkedFranchise?.leagueId == demoId {
                linkedFranchise = nil
                team = nil
                leagueReview = nil
                teamWeekSummary = nil
                leagueWeekSummary = nil
                pendingCount = 0
                agentActivityLines = []
                agentActivityStatus = nil
                agentRunTitle = nil
            }
        }
        if linkedFranchise == nil {
            linkedFranchise = try? context.fetch(FetchDescriptor<LinkedFranchise>()).first
        }
        refreshPendingCount()
    }

    func saveGuardrails() {
        GuardrailEngine.save(guardrails)
    }

    func saveAgentCriteria() {
        AgentCriteriaStore.save(agentCriteria)
    }

    func refreshPendingCount() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ActionProposal>(
            predicate: #Predicate { $0.statusRaw == "pending" }
        )
        pendingCount = (try? context.fetch(descriptor).count) ?? 0
    }

    func selectWeek(_ week: Int) {
        selectedWeek = week
        refreshCachedSummaries()
        Task { await syncTeam(week: week) }
    }

    func syncTeam(week: Int? = nil) async {
        guard !ScreenshotDemo.isEnabled else { return }
        guard let linked = linkedFranchise else {
            showConnect = true
            return
        }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let snapshot: TeamSnapshot
            if let week {
                // Explicit week from the picker (historic, live, or upcoming)
                snapshot = try await TeamSyncService.loadTeam(linked: linked, week: week)
                selectedWeek = week
                // Never advance "live" week just because the user browsed ahead.
            } else {
                // Default / refresh — always land on live NFL week from nflSchedule
                snapshot = try await TeamSyncService.loadTeam(linked: linked, week: nil)
                selectedWeek = snapshot.week
                currentSeasonWeek = snapshot.week
            }
            team = snapshot
            if let end = snapshot.leagueRules?.endWeek, end >= currentSeasonWeek {
                seasonEndWeek = end
            } else {
                seasonEndWeek = max(seasonEndWeek, 18, currentSeasonWeek)
            }
            // Persist real team name once league export resolves it (myleagues often returns "Franchise").
            if snapshot.franchiseName.caseInsensitiveCompare("Franchise") != .orderedSame,
               !snapshot.franchiseName.isEmpty,
               linked.franchiseName != snapshot.franchiseName {
                linked.franchiseName = snapshot.franchiseName
                linked.updatedAt = .now
                try? modelContext?.save()
            }
            await refreshUpcomingMatchups(linked: linked)
            let weekNote: String
            if selectedWeek < currentSeasonWeek {
                weekNote = " · historic"
            } else if selectedWeek > currentSeasonWeek {
                weekNote = " · upcoming"
            } else {
                weekNote = ""
            }
            statusMessage = "Week \(selectedWeek)\(weekNote)"
            log("Synced roster week \(selectedWeek)")
            refreshCachedSummaries()
        } catch {
            // Keep last good roster so chat/tools aren't emptied by a flaky refresh.
            if team != nil {
                statusMessage = "Refresh incomplete — showing last sync"
                let msg = error.localizedDescription
                if msg.localizedCaseInsensitiveContains("429") || msg.localizedCaseInsensitiveContains("rate") {
                    // Soft: don't pop a blocking alert for rate limits when we still have data.
                    log("Sync soft-failed", detail: msg)
                } else {
                    errorMessage = msg
                }
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshUpcomingMatchups(linked: LinkedFranchise) async {
        do {
            let rows = try await TeamSyncService.upcomingMatchups(
                linked: linked,
                franchiseId: linked.franchiseId,
                afterWeek: currentSeasonWeek,
                throughWeek: seasonEndWeek
            )
            upcomingMatchups = rows
        } catch {
            // Soft — keep prior list if schedule fetch fails.
        }
    }

    func syncLeagueReview() async {
        guard !ScreenshotDemo.isEnabled else { return }
        guard let linked = linkedFranchise else {
            showConnect = true
            return
        }
        isLoadingLeague = true
        defer { isLoadingLeague = false }
        do {
            leagueReview = try await LeagueReviewService.load(linked: linked, week: selectedWeek)
            refreshCachedSummaries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCachedSummaries() {
        teamWeekSummary = loadCachedSummary(kind: .team)
        leagueWeekSummary = loadCachedSummary(kind: .league)
    }

    func generateWeekSummary(kind: WeekSummaryKind) async {
        guard let linked = linkedFranchise else {
            showConnect = true
            return
        }
        guard isViewingHistoricWeek else {
            errorMessage = "Summaries are only available for past weeks."
            return
        }
        // Already saved for this week — never regenerate.
        if loadCachedSummary(kind: kind) != nil {
            refreshCachedSummaries()
            return
        }
        guard let apiKey = llmSettings.resolvedAPIKey() else {
            errorMessage = LLMClientError.missingAPIKey.localizedDescription
            selectedTab = .settings
            return
        }

        switch kind {
        case .team:
            isGeneratingTeamSummary = true
            if team == nil || team?.week != selectedWeek {
                await syncTeam(week: selectedWeek)
            }
            guard team != nil else {
                errorMessage = "Sync your team first."
                isGeneratingTeamSummary = false
                return
            }
        case .league:
            isGeneratingLeagueSummary = true
            if leagueReview == nil || leagueReview?.week != selectedWeek {
                await syncLeagueReview()
            }
            guard leagueReview != nil else {
                errorMessage = "Sync league data first."
                isGeneratingLeagueSummary = false
                return
            }
        }
        defer {
            isGeneratingTeamSummary = false
            isGeneratingLeagueSummary = false
        }

        do {
            let llm = LLMClient(provider: llmSettings.provider, model: llmSettings.model, apiKey: apiKey)
            let document = try await WeekSummaryService.generate(
                kind: kind,
                linked: linked,
                week: selectedWeek,
                team: team,
                league: leagueReview,
                llm: llm,
                modelLabel: llmSettings.selectedModelLabel
            )
            let body = try WeekSummaryDocumentCodec.encode(document)
            persistSummary(
                kind: kind,
                linked: linked,
                week: selectedWeek,
                body: body,
                modelLabel: llmSettings.selectedModelLabel
            )
            refreshCachedSummaries()
            if loadCachedSummary(kind: kind) == nil {
                // Persist failed (no context) — still surface in-memory so the sheet isn't empty.
                let cached = CachedWeekSummary(
                    id: PersistedWeekSummary.makeId(
                        kind: kind,
                        leagueId: linked.leagueId,
                        franchiseId: linked.franchiseId,
                        season: linked.season,
                        week: selectedWeek
                    ),
                    kind: kind,
                    week: selectedWeek,
                    body: body,
                    modelLabel: llmSettings.selectedModelLabel,
                    createdAt: .now
                )
                switch kind {
                case .team: teamWeekSummary = cached
                case .league: leagueWeekSummary = cached
                }
            }
            log("Saved \(kind.title) for week \(selectedWeek)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCachedSummary(kind: WeekSummaryKind) -> CachedWeekSummary? {
        guard let linked = linkedFranchise, let context = modelContext else { return nil }
        let id = PersistedWeekSummary.makeId(
            kind: kind,
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            season: linked.season,
            week: selectedWeek
        )
        var descriptor = FetchDescriptor<PersistedWeekSummary>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return nil }
        return CachedWeekSummary(
            id: row.id,
            kind: row.kind,
            week: row.week,
            body: row.body,
            modelLabel: row.modelLabel,
            createdAt: row.createdAt
        )
    }

    private func persistSummary(
        kind: WeekSummaryKind,
        linked: LinkedFranchise,
        week: Int,
        body: String,
        modelLabel: String
    ) {
        guard let context = modelContext else { return }
        let id = PersistedWeekSummary.makeId(
            kind: kind,
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            season: linked.season,
            week: week
        )
        // Race-safe: if another write landed, keep the first.
        var descriptor = FetchDescriptor<PersistedWeekSummary>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            _ = existing
            return
        }
        let row = PersistedWeekSummary(
            kind: kind,
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            season: linked.season,
            week: week,
            body: body,
            modelLabel: modelLabel
        )
        context.insert(row)
        try? context.save()
    }

    func connectMFL(username: String, password: String) async throws -> [MFLLeagueSummary] {
        try await MFLClient.shared.login(username: username, password: password)
        return try await MFLClient.shared.myLeagues()
    }

    func selectLeague(_ league: MFLLeagueSummary) {
        guard let context = modelContext else { return }
        // Replace existing links for simplicity (single franchise MVP)
        if let existing = try? context.fetch(FetchDescriptor<LinkedFranchise>()) {
            for item in existing { context.delete(item) }
        }
        let linked = LinkedFranchise(
            leagueId: league.leagueId,
            leagueName: league.name,
            franchiseId: league.franchiseId,
            franchiseName: league.franchiseName,
            host: league.host,
            season: Calendar.current.mflSeason
        )
        context.insert(linked)
        try? context.save()
        linkedFranchise = linked
        showConnect = false
        log("Linked \(league.name)")
        Task { await syncTeam() }
    }

    func applyManualLineup(starterIds: [String]) async {
        guard let linked = linkedFranchise, let team else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await MFLClient.shared.submitLineup(
                host: linked.host,
                season: linked.season,
                leagueId: linked.leagueId,
                franchiseId: linked.franchiseId,
                week: team.week,
                starterIds: starterIds,
                comments: "Set via Sideline"
            )
            log("Applied lineup", detail: result)
            statusMessage = "Lineup applied"
            await syncTeam(week: selectedWeek)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runAgent(_ desk: AgentDesk) async {
        guard let team else {
            errorMessage = "Sync your team first."
            return
        }
        guard let apiKey = llmSettings.resolvedAPIKey() else {
            errorMessage = LLMClientError.missingAPIKey.localizedDescription
            selectedTab = .settings
            return
        }
        isRunningAgent = true
        agentRunTitle = desk.title
        agentActivityLines = []
        errorMessage = nil
        defer {
            isRunningAgent = false
            agentRunTitle = nil
            // Keep last run log visible briefly; clear status after.
            agentActivityStatus = nil
        }
        do {
            pushAgentActivity("Starting \(desk.agentName)")
            pushAgentActivity("Using \(llmSettings.selectedModelLabel)")

            pushAgentActivity("Loading top free agents (YTD + last week)…")
            let freeAgents = try await loadFreeAgentSample()
            let ytdCount = freeAgents.filter { $0.seasonPoints != nil }.count
            let lwCount = freeAgents.filter { $0.lastWeekPoints != nil }.count
            pushAgentActivity("Loaded \(freeAgents.count) FAs (\(min(ytdCount, 10)) YTD / \(min(lwCount, 10)) last week)")

            var leagueIntel: LeagueIntelSnapshot?
            let needsLeagueIntel = desk == .waiver || desk == .trade || desk == .gm || desk == .draft
            if needsLeagueIntel, let linked = linkedFranchise {
                pushAgentActivity("Analyzing positional strength vs league + draft picks…")
                leagueIntel = try? await LeagueStrengthService.load(
                    linked: linked,
                    myFranchiseId: team.franchiseId,
                    rules: team.leagueRules
                )
                if let intel = leagueIntel {
                    let weak = intel.positions.filter { $0.label == "WEAK" }.map(\.position)
                    let strong = intel.positions.filter { $0.label == "STRONG" }.map(\.position)
                    pushAgentActivity(
                        "Strength: weak [\(weak.isEmpty ? "—" : weak.joined(separator: ","))] · strong [\(strong.isEmpty ? "—" : strong.joined(separator: ","))] · picks \(intel.myPicks.count)"
                    )
                } else {
                    pushAgentActivity("League strength snapshot unavailable — continuing without it")
                }
            }

            var playerResearch: String?
            let needsResearch = desk == .waiver || desk == .trade || desk == .gm
            if needsResearch, let linked = linkedFranchise {
                pushAgentActivity("Researching players on MFL (profiles, news, ranks)…")
                var researchIds: [String] = []
                // Top FA candidates by YTD then last week.
                let faYTD = freeAgents
                    .sorted { ($0.seasonPoints ?? -1) > ($1.seasonPoints ?? -1) }
                    .prefix(6)
                    .map(\.playerId)
                let faLW = freeAgents
                    .sorted { ($0.lastWeekPoints ?? -1) > ($1.lastWeekPoints ?? -1) }
                    .prefix(4)
                    .map(\.playerId)
                researchIds.append(contentsOf: faYTD)
                researchIds.append(contentsOf: faLW)
                // Likely drop candidates: lowest-projected bench.
                let dropCandidates = team.bench
                    .sorted { ($0.projectedPoints ?? 999) < ($1.projectedPoints ?? 999) }
                    .prefix(4)
                    .map(\.playerId)
                researchIds.append(contentsOf: dropCandidates)
                playerResearch = await MFLPlayerResearchService.summarize(
                    playerIds: researchIds,
                    linked: linked,
                    maxPlayers: 10
                )
                pushAgentActivity("Loaded MFL research for \(min(10, Set(researchIds).count)) players")
            }

            let llm = LLMClient(provider: llmSettings.provider, model: llmSettings.model, apiKey: apiKey)
            let drafts = try await AgentOrchestrator.run(
                desk: desk,
                team: team,
                freeAgentsSample: freeAgents,
                guardrails: guardrails,
                criteria: agentCriteria,
                llm: llm,
                leagueIntel: leagueIntel,
                playerResearch: playerResearch
            ) { [weak self] message in
                Task { @MainActor in
                    self?.pushAgentActivity(message)
                }
            }

            pushAgentActivity("Saving \(drafts.count) proposal(s)…")
            guard let context = modelContext else { return }
            for draft in drafts {
                let proposal = ActionProposal(
                    kind: draft.kind,
                    title: draft.title,
                    summary: draft.summary,
                    rationale: draft.rationale,
                    risks: draft.risks,
                    payloadJSON: draft.payloadJSON,
                    agentName: draft.agentName
                )
                context.insert(proposal)
            }
            try? context.save()
            refreshPendingCount()
            log("\(desk.agentName) produced \(drafts.count) proposal(s)")
            pushAgentActivity(drafts.isEmpty ? "Done — no proposals" : "Done — \(drafts.count) ready for approval")
            if !drafts.isEmpty {
                selectedTab = .approvals
            }
            statusMessage = drafts.isEmpty ? "No proposals" : "\(drafts.count) proposal(s) ready"
        } catch {
            pushAgentActivity("Failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func pushAgentActivity(_ message: String) {
        agentActivityStatus = message
        agentActivityLines.append(AgentActivityLine(text: message))
        if agentActivityLines.count > 40 {
            agentActivityLines.removeFirst(agentActivityLines.count - 40)
        }
    }

    func approve(_ proposal: ActionProposal) async {
        guard let linked = linkedFranchise else { return }
        do {
            let result = try await applyProposal(proposal, linked: linked)
            proposal.status = .applied
            proposal.resolvedAt = .now
            proposal.applyResult = result
            try? modelContext?.save()
            refreshPendingCount()
            log("Approved \(proposal.title)", detail: result)
            await syncTeam(week: selectedWeek)
        } catch {
            proposal.status = .failed
            proposal.applyResult = error.localizedDescription
            try? modelContext?.save()
            errorMessage = error.localizedDescription
        }
    }

    func reject(_ proposal: ActionProposal) {
        proposal.status = .rejected
        proposal.resolvedAt = .now
        try? modelContext?.save()
        refreshPendingCount()
        log("Rejected \(proposal.title)")
    }

    func openFollowUpChat(for proposal: ActionProposal) {
        followUpProposal = proposal
    }

    func clearApprovalHistory() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ActionProposal>(
            predicate: #Predicate { $0.statusRaw != "pending" }
        )
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        if let threads = try? context.fetch(FetchDescriptor<AgentChatThread>()) {
            for thread in threads where ids.contains(thread.proposalId) {
                context.delete(thread)
            }
        }
        for item in items {
            context.delete(item)
        }
        try? context.save()
        log("Cleared \(items.count) approval history item(s)")
    }

    private func applyProposal(_ proposal: ActionProposal, linked: LinkedFranchise) async throws -> String {
        let data = Data(proposal.payloadJSON.utf8)
        switch proposal.kind {
        case .lineup:
            let payload = try JSONDecoder().decode(LineupPayload.self, from: data)
            guard payload.isAutoSettable else {
                let blockers = (payload.blockers ?? []).joined(separator: "; ")
                let changes = (payload.requiredChanges ?? []).joined(separator: "; ")
                throw MFLError.lineupBlocked(
                    "Lineup not submitted — fix roster first. \(blockers.isEmpty ? (payload.comments ?? "See proposal blockers") : blockers). \(changes.isEmpty ? "" : "Fix: \(changes)")"
                )
            }
            guard !payload.starterIds.isEmpty else {
                throw MFLError.decode("Lineup proposal has no starter IDs.")
            }
            try await MFLClient.shared.submitLineup(
                host: linked.host,
                season: linked.season,
                leagueId: linked.leagueId,
                franchiseId: linked.franchiseId,
                week: payload.week,
                starterIds: payload.starterIds,
                comments: payload.comments
            )
            var extras: [String] = []
            if let ir = payload.irIds, !ir.isEmpty {
                extras.append("IR list (\(ir.count) ids) recorded in proposal — MFL IR import not wired yet; set IR in MFL if needed")
            }
            if let taxi = payload.taxiIds, !taxi.isEmpty {
                extras.append("Taxi list (\(taxi.count) ids) recorded in proposal — MFL taxi import not wired yet")
            }
            if extras.isEmpty { return "Lineup submitted to MFL." }
            return "Lineup submitted to MFL. " + extras.joined(separator: " · ")
        case .waiver, .trade, .draft:
            // Import types vary by league; stage as approved local action with clear next step.
            // Lineup write path is fully wired; other ops log intent until league-specific import confirmed.
            return "Recorded approval for \(proposal.kind.title). MFL import mapping pending for this league type — payload kept: \(proposal.payloadJSON)"
        }
    }

    /// Live free-agent lookup for agents / follow-up chat tools.
    func fetchFreeAgents(sort: String = "ytd", limit: Int = 10, position: String? = nil) async throws -> [RosterPlayer] {
        guard let linked = linkedFranchise else { return [] }
        let week = team?.week ?? selectedWeek
        let lastWeek = max(1, week - 1)
        let count = String(min(40, max(limit, 10)))

        var scoreExtra: [String: String] = [
            "STATUS": "freeagent",
            "COUNT": count
        ]
        if let position, !position.isEmpty {
            scoreExtra["POSITION"] = position.uppercased()
        }
        let ytdExtra = scoreExtra.merging(["W": "YTD"]) { _, new in new }
        let lastWeekExtra = scoreExtra.merging(["W": String(lastWeek)]) { _, new in new }

        async let playersData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "players",
            leagueId: linked.leagueId,
            extra: ["DETAILS": "1"],
            cacheTTL: 86_400
        )
        async let ytdData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "playerScores",
            leagueId: linked.leagueId,
            extra: ytdExtra,
            cacheTTL: 180
        )
        async let lastWeekData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "playerScores",
            leagueId: linked.leagueId,
            extra: lastWeekExtra,
            cacheTTL: 180
        )
        async let projectionsData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "projectedScores",
            leagueId: linked.leagueId,
            extra: ["W": String(week)],
            cacheTTL: 300
        )
        async let salaryMapTask = TeamSyncService.fetchSalaryMap(linked: linked)

        let (playersRaw, ytdRaw, lwRaw, projectionsRaw, salaryMap) = await (
            playersData, ytdData, lastWeekData, projectionsData, salaryMapTask
        )
        let playerMap = playersRaw.map { MFLNameResolver.parsePlayerNames(from: $0) } ?? [:]
        let projMap = projectionsRaw.map { Self.parseProjectionMap($0) } ?? [:]
        let ytdScores = ytdRaw.map { Self.parsePlayerScoreRows($0) } ?? []
        let lwScores = lwRaw.map { Self.parsePlayerScoreRows($0) } ?? []

        var byId: [String: RosterPlayer] = [:]

        func upsert(id rawId: String, score: Double?, asSeason: Bool?, asLastWeek: Bool?) {
            let id = MFLNameResolver.normalizePlayerId(rawId)
            let meta = playerMap[id] ?? playerMap[rawId]
            let sal = salaryMap[id] ?? salaryMap[rawId]
            var player = byId[id] ?? RosterPlayer(
                playerId: id,
                name: meta?.name ?? id,
                position: meta?.pos ?? "",
                team: meta?.team ?? "",
                status: "fa",
                projectedPoints: projMap[id] ?? projMap[rawId],
                seasonPoints: nil,
                lastWeekPoints: nil,
                opponent: nil,
                injuryStatus: nil,
                salary: sal?.salary,
                contractYear: sal?.contractYear
            )
            if let score, asSeason == true { player.seasonPoints = score }
            if let score, asLastWeek == true { player.lastWeekPoints = score }
            if player.projectedPoints == nil {
                player.projectedPoints = projMap[id] ?? projMap[rawId]
            }
            if player.salary == nil { player.salary = sal?.salary }
            if player.contractYear == nil { player.contractYear = sal?.contractYear }
            byId[id] = player
        }

        for row in ytdScores {
            upsert(id: row.id, score: row.score, asSeason: true, asLastWeek: nil)
        }
        for row in lwScores {
            upsert(id: row.id, score: row.score, asSeason: nil, asLastWeek: true)
        }
        // Also include projection-only FAs if we have IDs from either list.
        for (id, proj) in projMap {
            if byId[id] != nil { continue }
            // Only add if they're clearly free agents we already saw — skip full proj dump.
            _ = proj
        }

        var list = Array(byId.values)
        if let position, !position.isEmpty {
            let want = position.uppercased()
            list = list.filter { $0.position.uppercased() == want }
        }
        switch sort {
        case "lastWeek":
            list.sort { ($0.lastWeekPoints ?? -1) > ($1.lastWeekPoints ?? -1) }
        case "proj":
            list.sort { ($0.projectedPoints ?? -1) > ($1.projectedPoints ?? -1) }
        default:
            list.sort { ($0.seasonPoints ?? -1) > ($1.seasonPoints ?? -1) }
        }
        return Array(list.prefix(limit))
    }

    private func loadFreeAgentSample() async throws -> [RosterPlayer] {
        // Agent desks: top 10 YTD + top 10 last week (merged).
        let ytd = try await fetchFreeAgents(sort: "ytd", limit: 10)
        let lw = try await fetchFreeAgents(sort: "lastWeek", limit: 10)
        var byId: [String: RosterPlayer] = [:]
        for p in ytd { byId[p.playerId] = p }
        for p in lw {
            if var existing = byId[p.playerId] {
                existing.lastWeekPoints = p.lastWeekPoints ?? existing.lastWeekPoints
                existing.projectedPoints = existing.projectedPoints ?? p.projectedPoints
                byId[p.playerId] = existing
            } else {
                byId[p.playerId] = p
            }
        }
        var ordered: [RosterPlayer] = []
        var seen = Set<String>()
        for p in ytd where seen.insert(p.playerId).inserted { ordered.append(byId[p.playerId] ?? p) }
        for p in lw where seen.insert(p.playerId).inserted { ordered.append(byId[p.playerId] ?? p) }
        return ordered
    }

    private static func parsePlayerScoreRows(_ data: Data) -> [(id: String, score: Double)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let any = (root["playerScores"] as? [String: Any])?["playerScore"]
            ?? (root["projectedScores"] as? [String: Any])?["playerScore"]
            ?? root["playerScore"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] { list = arr }
        else if let one = any as? [String: Any] { list = [one] }
        else { return [] }

        var rows: [(String, Double)] = []
        for row in list {
            let rawId = (row["id"] as? String)
                ?? (row["id"] as? Int).map(String.init)
                ?? (row["player_id"] as? String)
            guard let rawId else { continue }
            let score: Double?
            if let s = row["score"] as? String { score = Double(s) }
            else if let d = row["score"] as? Double { score = d }
            else if let i = row["score"] as? Int { score = Double(i) }
            else { score = nil }
            guard let score else { continue }
            rows.append((rawId, score))
        }
        // If API ignored COUNT, sort and take top ourselves.
        return rows.sorted { $0.1 > $1.1 }
    }

    private static func parseProjectionMap(_ data: Data) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let any = (root["projectedScores"] as? [String: Any])?["playerScore"]
            ?? (root["playerScores"] as? [String: Any])?["playerScore"]
            ?? root["playerScore"]
        let list: [[String: Any]]
        if let arr = any as? [[String: Any]] { list = arr }
        else if let one = any as? [String: Any] { list = [one] }
        else { return [:] }
        var map: [String: Double] = [:]
        for row in list {
            guard let id = row["id"] as? String ?? row["player_id"] as? String else { continue }
            if let s = row["score"] as? String, let v = Double(s) { map[id] = v }
            else if let v = row["score"] as? Double { map[id] = v }
        }
        return map
    }

    private func log(_ message: String, detail: String = "") {
        guard let context = modelContext else { return }
        context.insert(ActivityEvent(message: message, detail: detail))
        try? context.save()
    }

    /// Deterministic in-memory + SwiftData seed for App Store screenshot captures.
    func applyScreenshotDemo(context: ModelContext) {
        auth.applyScreenshotDemo()
        modelContext = context

        // Wipe prior demo rows so relaunches stay clean.
        if let existingLinks = try? context.fetch(FetchDescriptor<LinkedFranchise>()) {
            for item in existingLinks { context.delete(item) }
        }
        if let existingProposals = try? context.fetch(FetchDescriptor<ActionProposal>()) {
            for item in existingProposals { context.delete(item) }
        }

        let linked = LinkedFranchise(
            leagueId: ScreenshotDemo.demoLeagueId,
            leagueName: "Sideline Classic",
            franchiseId: "0001",
            franchiseName: "Farish FC",
            host: ScreenshotDemo.demoHost,
            season: 2025
        )
        context.insert(linked)
        linkedFranchise = linked

        let rules = LeagueRules(
            rosterSize: 20,
            injuredReserveSlots: 2,
            taxiSquadSlots: 3,
            totalStarters: 9,
            starterSlots: [
                .init(name: "QB", min: 1, max: 1),
                .init(name: "RB", min: 2, max: 2),
                .init(name: "WR", min: 3, max: 3),
                .init(name: "TE", min: 1, max: 1),
                .init(name: "FLEX", min: 1, max: 1),
                .init(name: "PK", min: 1, max: 1)
            ],
            usesSalaries: true,
            salaryCapAmount: 200_000_000,
            rawNotes: nil
        )

        func player(
            id: String,
            name: String,
            pos: String,
            team: String,
            status: String,
            proj: Double,
            opp: String,
            salary: Double,
            injury: String? = nil
        ) -> RosterPlayer {
            RosterPlayer(
                playerId: id,
                name: name,
                position: pos,
                team: team,
                status: status,
                projectedPoints: proj,
                seasonPoints: proj * 8,
                lastWeekPoints: proj - 1.2,
                opponent: opp,
                injuryStatus: injury,
                gameLockState: "upcoming",
                gameKickoff: nil,
                salary: salary,
                contractYear: 2026
            )
        }

        let starters = [
            player(id: "1", name: "Jalen Hurts", pos: "QB", team: "PHI", status: "starter", proj: 22.4, opp: "@TB", salary: 28_000_000),
            player(id: "2", name: "Saquon Barkley", pos: "RB", team: "PHI", status: "starter", proj: 18.7, opp: "@TB", salary: 22_000_000),
            player(id: "3", name: "Breece Hall", pos: "RB", team: "NYJ", status: "starter", proj: 15.1, opp: "vs DEN", salary: 14_000_000),
            player(id: "4", name: "CeeDee Lamb", pos: "WR", team: "DAL", status: "starter", proj: 16.8, opp: "@NYG", salary: 24_000_000),
            player(id: "5", name: "Amon-Ra St. Brown", pos: "WR", team: "DET", status: "starter", proj: 15.9, opp: "vs SEA", salary: 18_000_000),
            player(id: "6", name: "Malik Nabers", pos: "WR", team: "NYG", status: "starter", proj: 14.2, opp: "vs DAL", salary: 9_000_000),
            player(id: "7", name: "Travis Kelce", pos: "TE", team: "KC", status: "starter", proj: 12.4, opp: "@LAC", salary: 12_000_000),
            player(id: "8", name: "James Cook", pos: "RB", team: "BUF", status: "starter", proj: 13.6, opp: "vs MIA", salary: 7_500_000),
            player(id: "9", name: "Jake Elliott", pos: "PK", team: "PHI", status: "starter", proj: 8.2, opp: "@TB", salary: 3_200_000)
        ]
        let bench = [
            player(id: "10", name: "Jayden Daniels", pos: "QB", team: "WAS", status: "bench", proj: 19.1, opp: "@ARI", salary: 11_000_000),
            player(id: "11", name: "DK Metcalf", pos: "WR", team: "SEA", status: "bench", proj: 11.4, opp: "@DET", salary: 10_000_000),
            player(id: "12", name: "Isiah Pacheco", pos: "RB", team: "KC", status: "bench", proj: 10.8, opp: "@LAC", salary: 6_000_000, injury: "Q")
        ]
        let ir = [
            player(id: "13", name: "Cooper Kupp", pos: "WR", team: "LAR", status: "ir", proj: 0, opp: "BYE", salary: 8_000_000, injury: "IR")
        ]
        let taxi = [
            player(id: "14", name: "Rome Odunze", pos: "WR", team: "CHI", status: "taxi", proj: 9.1, opp: "vs IND", salary: 2_800_000)
        ]
        let rostered = starters + bench + ir + taxi
        let totalSalary = rostered.compactMap(\.salary).reduce(0, +)

        team = TeamSnapshot(
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            leagueName: linked.leagueName,
            franchiseName: linked.franchiseName,
            week: 6,
            seasonPointsFor: 742.3,
            starters: starters,
            bench: bench,
            ir: ir,
            taxi: taxi,
            matchup: MatchupSnapshot(
                week: 6,
                myScore: 88.4,
                oppScore: 81.2,
                opponentName: "Gridiron Guild",
                lineupDeadline: nil
            ),
            leagueRules: rules,
            totalSalary: totalSalary,
            syncedAt: .now
        )
        selectedWeek = 6
        currentSeasonWeek = 6
        statusMessage = "Week 6"

        leagueReview = LeagueReviewSnapshot(
            week: 6,
            standings: [
                LeagueStandingRow(franchiseId: "0001", name: "Farish FC", wins: 4, losses: 1, ties: 0, pointsFor: 742.3, pointsAgainst: 680.1, rank: 1, rankDelta: 1),
                LeagueStandingRow(franchiseId: "0002", name: "Gridiron Guild", wins: 4, losses: 1, ties: 0, pointsFor: 731.0, pointsAgainst: 701.4, rank: 2, rankDelta: -1),
                LeagueStandingRow(franchiseId: "0003", name: "Blitz Bureau", wins: 3, losses: 2, ties: 0, pointsFor: 698.5, pointsAgainst: 690.2, rank: 3, rankDelta: 0),
                LeagueStandingRow(franchiseId: "0004", name: "Red Zone Inc", wins: 3, losses: 2, ties: 0, pointsFor: 684.2, pointsAgainst: 705.8, rank: 4, rankDelta: 2),
                LeagueStandingRow(franchiseId: "0005", name: "Snap Count", wins: 2, losses: 3, ties: 0, pointsFor: 655.9, pointsAgainst: 712.0, rank: 5, rankDelta: -1),
                LeagueStandingRow(franchiseId: "0006", name: "Play Action", wins: 1, losses: 4, ties: 0, pointsFor: 612.4, pointsAgainst: 748.6, rank: 6, rankDelta: 0)
            ],
            transactions: [
                LeagueTransactionRow(id: "t1", timestamp: .now.addingTimeInterval(-3600), franchiseId: "0003", franchiseName: "Blitz Bureau", summary: "Added Jaylen Warren, Dropped Zamir White", type: "freeagent"),
                LeagueTransactionRow(id: "t2", timestamp: .now.addingTimeInterval(-7200), franchiseId: "0002", franchiseName: "Gridiron Guild", summary: "Waiver: Isaiah Likely for $12", type: "waiver"),
                LeagueTransactionRow(id: "t3", timestamp: .now.addingTimeInterval(-86400), franchiseId: "0001", franchiseName: "Farish FC", summary: "Trade: sent Pick 2026 2nd for Tee Higgins", type: "trade")
            ],
            matchups: [
                LeagueMatchupRow(id: "m1", homeName: "Farish FC", awayName: "Gridiron Guild", homeScore: 88.4, awayScore: 81.2),
                LeagueMatchupRow(id: "m2", homeName: "Blitz Bureau", awayName: "Red Zone Inc", homeScore: 74.1, awayScore: 79.6),
                LeagueMatchupRow(id: "m3", homeName: "Snap Count", awayName: "Play Action", homeScore: 62.0, awayScore: 58.4)
            ],
            syncedAt: .now
        )

        let lineup = ActionProposal(
            kind: .lineup,
            title: "Start Cook over Pacheco",
            summary: "Flip James Cook into FLEX. Pacheco is questionable and projects 3.0 pts lower.",
            rationale: "Cook has a friendly matchup and higher median projection this week.",
            risks: "If Pacheco is active and sees goal-line work, you leave a few points on the table.",
            payloadJSON: #"{"canAutoSet":true}"#,
            agentName: "Lineup Desk"
        )
        let waiver = ActionProposal(
            kind: .waiver,
            title: "Add Jauan Jennings, drop DK Metcalf",
            summary: "Jennings is available and ranks as a top add at WR for your league shape.",
            rationale: "Metcalf’s volume is thin; Jennings has clearer target share this week.",
            risks: "Metcalf still has boom weeks — only move if you need a safer floor.",
            payloadJSON: #"{"canAutoSet":true}"#,
            agentName: "Waiver Desk"
        )
        context.insert(lineup)
        context.insert(waiver)
        try? context.save()

        pendingCount = 2
        agentRunTitle = "Set my lineup"
        agentActivityStatus = "Proposed 1 lineup change · waiting on approval"
        agentActivityLines = [
            AgentActivityLine(text: "Using GPT-4.1 mini"),
            AgentActivityLine(text: "Loaded roster + injury notes"),
            AgentActivityLine(text: "Compared FLEX options vs league strength"),
            AgentActivityLine(text: "Queued proposal for approval")
        ]
        isRunningAgent = false
        showConnect = false
        errorMessage = nil
    }
}
