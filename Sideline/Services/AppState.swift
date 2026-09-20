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
    @Published var leagueReview: LeagueReviewSnapshot?
    @Published var isLoadingLeague = false
    @Published var followUpProposal: ActionProposal?

    let auth = AppleAuthService()
    let llmSettings = LLMSettingsStore()

    private var modelContext: ModelContext?

    var availableWeeks: [Int] {
        Array(1...max(currentSeasonWeek, team?.week ?? selectedWeek, 1))
    }

    var isViewingHistoricWeek: Bool {
        selectedWeek < currentSeasonWeek
    }

    func attach(context: ModelContext) {
        modelContext = context
        refreshPendingCount()
        if linkedFranchise == nil {
            linkedFranchise = try? context.fetch(FetchDescriptor<LinkedFranchise>()).first
        }
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
        Task { await syncTeam(week: week) }
    }

    func syncTeam(week: Int? = nil) async {
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
                // Explicit week from the picker (current or historic)
                snapshot = try await TeamSyncService.loadTeam(linked: linked, week: week)
                selectedWeek = week
                currentSeasonWeek = max(currentSeasonWeek, week)
            } else {
                // Default / refresh — always land on live NFL week from nflSchedule
                snapshot = try await TeamSyncService.loadTeam(linked: linked, week: nil)
                selectedWeek = snapshot.week
                currentSeasonWeek = snapshot.week
            }
            team = snapshot
            // Persist real team name once league export resolves it (myleagues often returns "Franchise").
            if snapshot.franchiseName.caseInsensitiveCompare("Franchise") != .orderedSame,
               !snapshot.franchiseName.isEmpty,
               linked.franchiseName != snapshot.franchiseName {
                linked.franchiseName = snapshot.franchiseName
                linked.updatedAt = .now
                try? modelContext?.save()
            }
            let historic = selectedWeek < currentSeasonWeek ? " · historic" : ""
            statusMessage = "Week \(selectedWeek)\(historic)"
            log("Synced roster week \(selectedWeek)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncLeagueReview() async {
        guard let linked = linkedFranchise else {
            showConnect = true
            return
        }
        isLoadingLeague = true
        defer { isLoadingLeague = false }
        do {
            leagueReview = try await LeagueReviewService.load(linked: linked, week: selectedWeek)
        } catch {
            errorMessage = error.localizedDescription
        }
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
            if payload.canAutoSet == false {
                let blockers = (payload.blockers ?? []).joined(separator: "; ")
                let changes = (payload.requiredChanges ?? []).joined(separator: "; ")
                return "Lineup not submitted — roster cannot auto-set yet. Blockers: \(blockers.isEmpty ? (payload.comments ?? "see proposal") : blockers). Fix: \(changes.isEmpty ? "see proposal rationale" : changes)"
            }
            guard !payload.starterIds.isEmpty else {
                return "Lineup not submitted — no starter IDs in proposal."
            }
            let lineupResult = try await MFLClient.shared.submitLineup(
                host: linked.host,
                season: linked.season,
                leagueId: linked.leagueId,
                week: payload.week,
                starterIds: payload.starterIds,
                comments: payload.comments
            )
            var extras: [String] = []
            if let ir = payload.irIds, !ir.isEmpty {
                extras.append("IR list (\(ir.count) ids) recorded in proposal — MFL IR import pending")
            }
            if let taxi = payload.taxiIds, !taxi.isEmpty {
                extras.append("Taxi list (\(taxi.count) ids) recorded in proposal — MFL taxi import pending")
            }
            if extras.isEmpty { return lineupResult }
            return lineupResult + " · " + extras.joined(separator: " · ")
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
            extra: scoreExtra.merging(["W": "YTD"]) { _, new in new },
            cacheTTL: 180
        )
        async let lastWeekData = try? await MFLClient.shared.exportJSON(
            host: linked.host,
            season: linked.season,
            type: "playerScores",
            leagueId: linked.leagueId,
            extra: scoreExtra.merging(["W": String(lastWeek)]) { _, new in new },
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
}
