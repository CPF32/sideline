import Foundation

enum AgentDesk: String, CaseIterable, Identifiable {
    case gm
    case lineup
    case waiver
    case trade
    case draft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gm: return "Run GM review"
        case .lineup: return "Set my lineup"
        case .waiver: return "Scan waivers"
        case .trade: return "Find trades"
        case .draft: return "Advise this pick"
        }
    }

    var agentName: String {
        switch self {
        case .gm: return "GM"
        case .lineup: return "Lineup Desk"
        case .waiver: return "Waiver Desk"
        case .trade: return "Trade Desk"
        case .draft: return "Draft Desk"
        }
    }
}

struct AgentProposalDraft: Identifiable {
    let id = UUID()
    let kind: ProposalKind
    let title: String
    let summary: String
    let rationale: String
    let risks: String
    let payloadJSON: String
    let agentName: String
}

struct AgentActivityLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let at: Date = .now
}

enum AgentOrchestrator {
    static func run(
        desk: AgentDesk,
        team: TeamSnapshot,
        freeAgentsSample: [RosterPlayer],
        guardrails: GuardrailSettings,
        criteria: AgentCriteriaBundle,
        llm: LLMClient,
        leagueIntel: LeagueIntelSnapshot? = nil,
        playerResearch: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [AgentProposalDraft] {
        let report = { (msg: String) in onProgress?(msg) }
        switch desk {
        case .gm:
            report("GM review — coordinating desks")
            var all: [AgentProposalDraft] = []
            all += try await runSpecialist(.lineup, team: team, freeAgentsSample: freeAgentsSample, guardrails: guardrails, criteria: criteria, llm: llm, leagueIntel: leagueIntel, playerResearch: playerResearch, onProgress: onProgress)
            all += try await runSpecialist(.waiver, team: team, freeAgentsSample: freeAgentsSample, guardrails: guardrails, criteria: criteria, llm: llm, leagueIntel: leagueIntel, playerResearch: playerResearch, onProgress: onProgress)
            all += try await runSpecialist(.trade, team: team, freeAgentsSample: freeAgentsSample, guardrails: guardrails, criteria: criteria, llm: llm, leagueIntel: leagueIntel, playerResearch: playerResearch, onProgress: onProgress)
            report("Merging \(all.count) draft proposal(s)")
            return dedupe(all)
        default:
            return try await runSpecialist(desk, team: team, freeAgentsSample: freeAgentsSample, guardrails: guardrails, criteria: criteria, llm: llm, leagueIntel: leagueIntel, playerResearch: playerResearch, onProgress: onProgress)
        }
    }

    private static func runSpecialist(
        _ desk: AgentDesk,
        team: TeamSnapshot,
        freeAgentsSample: [RosterPlayer],
        guardrails: GuardrailSettings,
        criteria: AgentCriteriaBundle,
        llm: LLMClient,
        leagueIntel: LeagueIntelSnapshot? = nil,
        playerResearch: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [AgentProposalDraft] {
        let report = { (msg: String) in onProgress?(msg) }
        let kind: ProposalKind
        switch desk {
        case .lineup: kind = .lineup
        case .waiver: kind = .waiver
        case .trade: kind = .trade
        case .draft: kind = .draft
        case .gm: kind = .lineup
        }

        report("\(desk.agentName) — building roster context")
        let feasibility = (kind == .lineup) ? LineupFeasibility.analyze(team: team) : nil
        if let feasibility, !feasibility.canAutoSet {
            report("\(desk.agentName) — roster cannot fill a legal lineup (\(feasibility.blockers.count) blocker(s))")
        }
        let system = systemPrompt(for: desk, week: team.week)
        let context = TeamContextBuilder.build(
            team: team,
            freeAgents: freeAgentsSample,
            guardrails: guardrails,
            criteria: criteria,
            focus: kind,
            lineupFeasibility: feasibility,
            leagueIntel: leagueIntel,
            playerResearch: playerResearch
        )
        report("\(desk.agentName) — calling \(llm.provider.displayName) · \(friendlyModelName(llm.model))…")
        let raw = try await llm.completeJSON(system: system, user: context)
        report("\(desk.agentName) — parsing model response")
        var drafts = try parseProposals(raw, kind: kind, agentName: desk.agentName, week: team.week)
        if kind == .lineup, let feasibility, !feasibility.canAutoSet {
            // Drop any "can auto-set" drafts when feasibility says no — Approve must not be offered.
            drafts = drafts.filter { draft in
                (try? JSONDecoder().decode(LineupPayload.self, from: Data(draft.payloadJSON.utf8)))?.canAutoSet == false
            }
            if drafts.isEmpty {
                drafts = [LineupFeasibility.blockedProposal(team: team, report: feasibility)]
            }
        }
        // Enrich lineup drafts with resolved slot/name when model omitted slots.
        if kind == .lineup {
            drafts = drafts.map { enrichLineupSlots($0, team: team) }
        }
        report("\(desk.agentName) — checking guardrails on \(drafts.count) draft(s)")
        let allowed = drafts.filter { GuardrailEngine.allows(draft: $0, settings: guardrails, team: team) }
        if drafts.count != allowed.count {
            report("\(desk.agentName) — filtered \(drafts.count - allowed.count) by guardrails")
        }
        report("\(desk.agentName) — \(allowed.count) proposal(s) passed")
        return allowed
    }

    private static func friendlyModelName(_ id: String) -> String {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
    }

    private static func systemPrompt(for desk: AgentDesk, week: Int) -> String {
        let shared = """
        You are the \(desk.agentName) for Sideline, a fantasy football GM app.
        Return ONLY a JSON object:
        {"proposals":[{"title":string,"summary":string,"rationale":string,"risks":string,"payload":object}]}
        Use ONLY player IDs that appear in the user context. Prefer 1–3 high-quality proposals.
        Respect guardrails (never-bench / never-drop / never-trade / FAAB caps).
        Follow the user's team goals and desk criteria exactly.
        """

        switch desk {
        case .lineup:
            return shared + """

            LINEUP DESK GUIDE:
            - Your job is to produce a LEGAL starting lineup for week \(week) AND fix IR/taxi compliance when needed.
            - FIRST read LINEUP FEASIBILITY in the user context.
            - If FEASIBILITY is CANNOT AUTO-SET: do NOT invent an illegal lineup. Return exactly one proposal:
              title like "Can't auto-set lineup", summary of the main gap, rationale listing blockers, risks empty or short,
              payload:
              {"week":\(week),"starterIds":[],"canAutoSet":false,"blockers":[string…],"requiredChanges":[string…],"comments":string?}
              requiredChanges must be concrete actions (e.g. "Add a WR via waivers", "Activate X from IR", "Drop bye-week hole at RB").
            - If FEASIBILITY is OK: build a full legal lineup.
            - League starter rules list how many players you may start at each position (and flex). Match those counts.
            - If no lineup is set yet (starters empty / all on bench), build a full compliant starter set from the roster.
            - GAME TIMES (critical): Each player has gameLockState. Respect it:
              • upcoming — eligible to start or bench freely.
              • started / final — game already kicked off or finished. Do NOT newly move these players FROM bench INTO starters. If they are already starters, KEEP them in starterIds (they are locked).
              • bye — do not start.
            - When filling open starter slots mid-week (e.g. Friday after Thursday games), only choose from players with gameLockState=upcoming.
            - INJURY / AVAILABILITY (highest priority after legality + game locks):
              • Never start players marked Out / IR / Injured Reserve / PUP / Suspended when a healthier eligible option exists.
              • Strongly deprioritize Doubtful — treat as nearly Out unless every healthy alternative is much worse AND criteria say otherwise.
              • Questionable / Q: if avoidQuestionable=true (default), prefer healthy/probable backups even with a modest projection gap. Only start Q when the healthy option is clearly weaker or criteria allow risk.
              • Mention injury status in each risky slot's `reason` and in `risks` when starting anyone Q/D/O.
              • Move Out/IR-eligible players OFF the active roster onto IR when IR slots remain; activate healthy IR players when eligible.
            - PLAYER PROPS (when PLAYER PROPS block is present): use rush/rec/pass yards, receptions, and anytime TD lines as a secondary signal for sit/start — favor players with stronger volume props when projections are close; do not override clear injury or lock constraints.
            - Keep taxi usage within taxi slot limits; do not start taxi players unless the league allows and they are activated.
            - Never leave required starter slots empty when eligible upcoming players are available on the active roster.
            - When auto-setting is possible, payload MUST be:
              {"week":\(week),"starterIds":[playerId…],"irIds":[playerId…]?,"taxiIds":[playerId…]?,"canAutoSet":true,"comments":string?,"slots":[{"slot":"QB","playerId":"…","name":"…","reason":"why this player for this slot"},…]}
            - `slots` is REQUIRED when canAutoSet is true: one entry per starting slot (match league starter rules including flex). Each reason should be one short sentence (matchup, projection, injury avoidance, prop support).
            - Prefer projected points among eligible (upcoming) healthy players unless criteria say otherwise.
            """
        case .waiver:
            return shared + """

            WAIVER / FA DESK GUIDE:
            - You MUST return at least one proposal whenever free agents are listed. Do not return an empty proposals array.
            - Each proposal is a concrete add (and drop if the roster is full or over rosterSize).
            - Payload:
              {"addPlayerId":string,"dropPlayerId":string?,"bid":number?,"notes":string?}
            - addPlayerId must be a free-agent id from context. dropPlayerId must be a rostered (non-IR/taxi unless freeing a slot) id when dropping.
            - Rank adds by: (1) bye/injury/questionable holes this week, (2) WEAK positions from POSITIONAL STRENGTH VS LEAGUE, (3) research outlook (news, ADP/rank, age, trending adds, injury) for rest-of-season value, (4) player props when present as a secondary volume signal, (5) salary/cap fit when present, (6) handcuff if criteria say so.
            - Prefer fixing WEAK spots over stacking already-STRONG positions. When dropping, prefer surplus at STRONG positions and consider long-term cost using research — don't cut a cheap young keeper just to stream one week if a higher-salary fading vet is available.
            - Do NOT make salary the primary rationale. Use MFL PLAYER RESEARCH in context to justify adds/drops.
            - Keep FAAB bids at or under max FAAB % / guardrail max when provided. Respect salary cap room when listed.
            - If nothing is a clear upgrade, still propose the best available stash with a low/zero bid and explain why in rationale — never stay silent.
            """
        case .trade:
            return shared + """

            TRADE DESK GUIDE:
            - Propose realistic trades using rostered player IDs AND draft pick IDs from context.
            - Read POSITIONAL STRENGTH VS LEAGUE and DRAFT PICK ASSETS carefully.
            - Prefer deals that improve WEAK positions by giving from STRONG positions and/or picks.
            - INJURY WEIGHTING (critical):
              • Do NOT acquire Out / IR / Doubtful players as primary win-now pieces without a steep discount and a clear stash/IR plan.
              • Questionable targets: haircut value and call out the risk in `risks`; prefer healthy alternatives at the same position when comparable.
              • Selling: injured/out assets on your roster are fair to move for healthier help or picks — disclose status in rationale.
              • Never treat an injured star as full healthy value in either direction.
            - PLAYER PROPS (when present): use volume lines as a secondary signal for short-term trade timing (buy low on healthy players with strong props; fade sellers whose props imply limited usage).
            - Payload:
              {"givePlayerIds":[string],"receivePlayerIds":[string],"givePickIds":[string]?,"receivePickIds":[string]?,"partnerFranchiseId":string?,"notes":string?}
            - givePickIds / receivePickIds must be pickId values from DRAFT PICK ASSETS (FP_… form) when including picks.
            - Player-only, pick-only, or mixed deals are all valid. Include partnerFranchiseId when a logical partner is clear.
            - Contenders: trade future picks for win-now talent at WEAK spots — but only healthy/probable win-now talent. Rebuilders: trade surplus talent for picks / youth.
            """
        case .draft:
            return shared + """

            DRAFT DESK GUIDE:
            - Recommend the next pick given remaining needs and board value in context.
            - Payload:
              {"pickPlayerId":string?,"pickNumber":number?,"notes":string?}
            - Prefer IDs from the available/board list when present; otherwise describe the archetype in notes.
            """
        case .gm:
            return shared
        }
    }

    private static func parseProposals(_ raw: String, kind: ProposalKind, agentName: String, week: Int) throws -> [AgentProposalDraft] {
        let jsonString = raw.extractJSONObject() ?? raw
        guard let data = jsonString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LLMClientError.decode }

        let list: [[String: Any]]
        if let proposals = root["proposals"] as? [[String: Any]] {
            list = proposals
        } else if root["payload"] != nil || root["title"] != nil {
            // Model returned a single proposal object instead of wrapped array.
            list = [root]
        } else {
            throw LLMClientError.decode
        }

        return list.compactMap { row in
            let title = row["title"] as? String ?? kind.title
            let summary = row["summary"] as? String ?? ""
            let rationale = row["rationale"] as? String ?? ""
            let risks = row["risks"] as? String ?? ""
            var payload = row["payload"] as? [String: Any] ?? [:]
            if kind == .lineup, payload["week"] == nil {
                payload["week"] = week
            }
            // Normalize alternate key spellings from models.
            if kind == .waiver {
                if payload["addPlayerId"] == nil {
                    payload["addPlayerId"] = payload["add"] ?? payload["addId"] ?? payload["playerId"]
                }
                if payload["dropPlayerId"] == nil {
                    payload["dropPlayerId"] = payload["drop"] ?? payload["dropId"]
                }
            }
            if kind == .trade {
                if payload["givePlayerIds"] == nil {
                    payload["givePlayerIds"] = payload["give"] ?? payload["send"] ?? []
                }
                if payload["receivePlayerIds"] == nil {
                    payload["receivePlayerIds"] = payload["receive"] ?? payload["get"] ?? []
                }
                if payload["givePickIds"] == nil {
                    payload["givePickIds"] = payload["givePicks"] ?? payload["sendPicks"]
                }
                if payload["receivePickIds"] == nil {
                    payload["receivePickIds"] = payload["receivePicks"] ?? payload["getPicks"]
                }
            }
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload.isEmpty ? [:] : payload),
                  let payloadJSON = String(data: payloadData, encoding: .utf8)
            else { return nil }
            return AgentProposalDraft(
                kind: kind,
                title: title,
                summary: summary,
                rationale: rationale,
                risks: risks,
                payloadJSON: payloadJSON,
                agentName: agentName
            )
        }
    }

    private static func dedupe(_ drafts: [AgentProposalDraft]) -> [AgentProposalDraft] {
        var seen = Set<String>()
        var out: [AgentProposalDraft] = []
        for d in drafts {
            let key = "\(d.kind.rawValue)|\(d.payloadJSON)"
            if seen.insert(key).inserted { out.append(d) }
        }
        return out
    }

    /// Fill missing `slots` from starterIds + roster so Approvals can show who/why per position.
    private static func enrichLineupSlots(_ draft: AgentProposalDraft, team: TeamSnapshot) -> AgentProposalDraft {
        guard var payload = try? JSONDecoder().decode(LineupPayload.self, from: Data(draft.payloadJSON.utf8)) else {
            return draft
        }
        guard payload.isAutoSettable, !payload.starterIds.isEmpty else { return draft }
        if let existing = payload.slots, !existing.isEmpty { return draft }

        let byId = Dictionary(uniqueKeysWithValues: team.allRostered.map { ($0.playerId, $0) })
        var remaining = payload.starterIds
        var picks: [LineupSlotPick] = []

        func take(allowed: Set<String>, slot: String) {
            guard let idx = remaining.firstIndex(where: { id in
                let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
                return allowed.contains((p?.position ?? "").uppercased())
            }) else { return }
            let id = remaining.remove(at: idx)
            let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
            let proj = p?.projectedPoints.map { String(format: "%.1f proj", $0) } ?? "roster pick"
            let opp = p?.opponent.map { " vs \($0)" } ?? ""
            picks.append(LineupSlotPick(
                slot: slot,
                playerId: id,
                name: p?.name,
                reason: "\(proj)\(opp)"
            ))
        }

        let slots = team.leagueRules?.starterSlots ?? []
        for slot in slots where !slot.name.contains("/") {
            for _ in 0..<max(slot.min, 1) {
                take(allowed: [slot.name.uppercased()], slot: slot.name.uppercased())
            }
        }
        for slot in slots where slot.name.contains("/") {
            let allowed = Set(slot.name.split(separator: "/").map { String($0).uppercased() })
            for _ in 0..<max(slot.min, 1) {
                take(allowed: allowed, slot: slot.name.uppercased())
            }
        }
        for id in remaining {
            let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
            picks.append(LineupSlotPick(
                slot: (p?.position.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "START",
                playerId: id,
                name: p?.name,
                reason: draft.summary
            ))
        }
        payload.slots = picks
        payload.canAutoSet = true
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return draft }
        return AgentProposalDraft(
            kind: draft.kind,
            title: draft.title,
            summary: draft.summary,
            rationale: draft.rationale,
            risks: draft.risks,
            payloadJSON: json,
            agentName: draft.agentName
        )
    }
}

enum TeamContextBuilder {
    static func build(
        team: TeamSnapshot,
        freeAgents: [RosterPlayer],
        guardrails: GuardrailSettings,
        criteria: AgentCriteriaBundle,
        focus: ProposalKind,
        lineupFeasibility: LineupFeasibility.Report? = nil,
        leagueIntel: LeagueIntelSnapshot? = nil,
        playerResearch: String? = nil
    ) -> String {
        func line(_ p: RosterPlayer) -> String {
            let proj = p.projectedPoints.map { String(format: "%.1f", $0) } ?? "-"
            let ytd = p.seasonPoints.map { String(format: "%.1f", $0) } ?? "-"
            let lw = p.lastWeekPoints.map { String(format: "%.1f", $0) } ?? "-"
            let injury = (p.injuryStatus?.isEmpty == false) ? "|injury:\(p.injuryStatus!)" : ""
            let opp = p.opponent.map { "|opp:\($0)" } ?? ""
            let lock = p.gameLockState.map { "|game:\($0)" } ?? ""
            let kick = p.gameKickoff.map { "|kick:\(ISO8601DateFormatter().string(from: $0))" } ?? ""
            let sal = p.salary.map { "|salary:\(SalaryFormat.compact($0))" } ?? ""
            let cy = p.contractYear.map { "|contractYear:\($0)" } ?? ""
            return "\(p.playerId)|\(p.name)|\(p.position)|\(p.team)|proj:\(proj)|ytd:\(ytd)|lastWeek:\(lw)|status:\(p.status)\(opp)\(lock)\(kick)\(sal)\(cy)\(injury)"
        }

        var parts: [String] = []
        parts.append("League: \(team.leagueName) | Franchise: \(team.franchiseName) | Week: \(team.week)")
        if let pf = team.seasonPointsFor {
            parts.append("Season PF: \(String(format: "%.1f", pf))")
        }
        if let m = team.matchup {
            parts.append("Matchup: vs \(m.opponentName ?? "?") | scores \(fmt(m.myScore))–\(fmt(m.oppScore))")
        }
        parts.append("Focus: \(focus.rawValue)")

        if !criteria.teamGoals.isEmpty {
            parts.append("Team goals:\n\(criteria.teamGoals)")
        }

        let rules = team.leagueRules
        parts.append("LEAGUE ROSTER RULES:\n\(rules?.summaryForLLM ?? "Unavailable")")
        parts.append(complianceBlock(team: team, rules: rules))

        if focus == .waiver || focus == .trade || focus == .draft {
            if let leagueIntel {
                parts.append(leagueIntel.summaryForLLM)
            } else {
                parts.append("POSITIONAL STRENGTH VS LEAGUE: (not loaded — use roster depth and starter slots as a proxy)")
            }
        }
        if let playerResearch, !playerResearch.isEmpty,
           focus == .waiver || focus == .trade || focus == .draft || focus == .lineup {
            parts.append(playerResearch)
        }

        switch focus {
        case .lineup:
            parts.append("""
            Lineup criteria:
            goal=\(criteria.lineup.goal)
            risk=\(criteria.lineup.riskTolerance.rawValue)
            preferCeiling=\(criteria.lineup.preferCeiling)
            avoidQuestionable=\(criteria.lineup.avoidQuestionable)
            stack=\(criteria.lineup.stackPreference)
            notes=\(criteria.lineup.notes)
            """)
            parts.append("""
            LINEUP TASK:
            1) Read LINEUP FEASIBILITY below. If CANNOT AUTO-SET, return a blockers proposal (canAutoSet:false) — do not force an illegal lineup.
            2) Otherwise fill every required starter slot per LEAGUE ROSTER RULES (position limits + totalStarters).
            3) If starters are empty, the week lineup is NOT set — choose a full legal set of starterIds from upcoming-game players only (plus already-locked current starters if any).
            4) GAME LOCKS: keep current starters whose game is started/final; never promote bench players whose game is started/final/bye into starters.
            5) INJURIES FIRST: sit Out/Doubtful; sit Questionable when avoidQuestionable=true and a healthy option exists; move Out→IR when slots remain; activate healthy IR.
            6) Use PLAYER PROPS (if present) as a tie-breaker on close sit/start calls among healthy players.
            7) Return starterIds for the week plus desired irIds/taxiIds when changing those lists.
            """)
            parts.append(gameLockSummary(team: team))
            if let lineupFeasibility {
                parts.append(lineupFeasibility.summaryForLLM)
            } else {
                parts.append(LineupFeasibility.analyze(team: team).summaryForLLM)
            }
        case .waiver:
            parts.append("""
            Waiver criteria:
            goal=\(criteria.waiver.goal)
            risk=\(criteria.waiver.riskTolerance.rawValue)
            maxFAAB%=\(criteria.waiver.maxFAABPercent)
            needOverBPA=\(criteria.waiver.prioritizeNeedOverBestAvailable)
            handcuffs=\(criteria.waiver.stashHandcuffs)
            notes=\(criteria.waiver.notes)
            """)
            let activeCount = team.starters.count + team.bench.count
            let rosterCap = rules?.rosterSize.map(String.init) ?? "?"
            parts.append("""
            WAIVER TASK:
            Active roster count=\(activeCount) / rosterSize=\(rosterCap).
            Use POSITIONAL STRENGTH VS LEAGUE + LEAGUE ROSTER RULES to target WEAK spots and roster-setup holes.
            Use MFL PLAYER RESEARCH to analyze rest-of-season outlook (news, ADP/rank, age, injuries, trending adds) — do not justify picks with salary alone.
            You MUST propose 1–3 add/drop actions using free-agent IDs below.
            If active roster is at/above rosterSize, every add needs a dropPlayerId (prefer drops from STRONG positions).
            """)
        case .trade:
            parts.append("""
            Trade criteria:
            goal=\(criteria.trade.goal)
            risk=\(criteria.trade.riskTolerance.rawValue)
            mode=\(criteria.trade.contendMode.rawValue)
            targets=\(criteria.trade.targetPositions)
            notes=\(criteria.trade.notes)
            """)
            parts.append("""
            TRADE TASK:
            Propose 1–3 realistic trades that improve WEAK positions (or contend/rebuild goals) using players and/or draft picks from context.
            Heavily discount Out / IR / Doubtful / Questionable players on either side — call status out in rationale and risks.
            Use PLAYER PROPS when present as a secondary short-term signal only.
            Include givePickIds/receivePickIds when picks improve the deal. Name partnerFranchiseId when possible.
            """)
        case .draft:
            parts.append("""
            Draft criteria:
            goal=\(criteria.draft.goal)
            risk=\(criteria.draft.riskTolerance.rawValue)
            early=\(criteria.draft.earlyRoundBias)
            late=\(criteria.draft.lateRoundBias)
            notes=\(criteria.draft.notes)
            """)
        }

        parts.append("STARTERS (\(team.starters.count)):\n" + (team.starters.isEmpty ? "(none — lineup not set for this week)" : team.starters.map(line).joined(separator: "\n")))
        parts.append("BENCH (\(team.bench.count)):\n" + (team.bench.isEmpty ? "(none)" : team.bench.map(line).joined(separator: "\n")))
        parts.append("IR (\(team.ir.count)):\n" + (team.ir.isEmpty ? "(none)" : team.ir.map(line).joined(separator: "\n")))
        parts.append("TAXI (\(team.taxi.count)):\n" + (team.taxi.isEmpty ? "(none)" : team.taxi.map(line).joined(separator: "\n")))

        parts.append(positionDepthBlock(team: team))

        if focus == .waiver || focus == .trade || focus == .draft {
            if freeAgents.isEmpty {
                parts.append("FREE AGENTS: (none loaded — still propose best-effort guidance with empty add only if unavoidable)")
            } else {
                let bySeason = freeAgents
                    .filter { $0.seasonPoints != nil }
                    .sorted { ($0.seasonPoints ?? -1) > ($1.seasonPoints ?? -1) }
                    .prefix(10)
                let byLastWeek = freeAgents
                    .filter { $0.lastWeekPoints != nil }
                    .sorted { ($0.lastWeekPoints ?? -1) > ($1.lastWeekPoints ?? -1) }
                    .prefix(10)
                var faParts: [String] = ["FREE AGENTS — use only these IDs for adds (max 10 YTD + 10 last week):"]
                if bySeason.isEmpty {
                    faParts.append("Top 10 by season points (YTD): (none)")
                } else {
                    faParts.append("Top 10 by season points (YTD):\n" + bySeason.map(line).joined(separator: "\n"))
                }
                if byLastWeek.isEmpty {
                    faParts.append("Top 10 by points last week: (none)")
                } else {
                    faParts.append("Top 10 by points last week:\n" + byLastWeek.map(line).joined(separator: "\n"))
                }
                parts.append(faParts.joined(separator: "\n\n"))
            }
        }

        parts.append("Guardrails JSON: \(String(data: (try? JSONEncoder().encode(guardrails)) ?? Data(), encoding: .utf8) ?? "{}")")
        return parts.joined(separator: "\n\n")
    }

    private static func gameLockSummary(team: TeamSnapshot) -> String {
        let active = team.starters + team.bench
        func list(_ states: Set<String>) -> String {
            let matches = active.filter { states.contains($0.gameLockState ?? "") }
            if matches.isEmpty { return "(none)" }
            return matches.map { "\($0.playerId) \($0.name) (\($0.opponent ?? "?"))" }.joined(separator: "; ")
        }
        return """
        GAME LOCK SUMMARY (as of sync):
        - Already played / in progress (do not newly start from bench): \(list(["started", "final"]))
        - Bye (do not start): \(list(["bye"]))
        - Still upcoming (eligible to start): \(list(["upcoming"]))
        """
    }

    private static func complianceBlock(team: TeamSnapshot, rules: LeagueRules?) -> String {
        var lines: [String] = ["COMPLIANCE SNAPSHOT:"]
        let active = team.starters.count + team.bench.count
        if let size = rules?.rosterSize {
            lines.append("- activeRoster=\(active)/\(size) \(active > size ? "OVER LIMIT" : (active == size ? "FULL" : "HAS ROOM"))")
        } else {
            lines.append("- activeRoster=\(active)")
        }
        if let irSlots = rules?.injuredReserveSlots {
            lines.append("- IR=\(team.ir.count)/\(irSlots) \(team.ir.count > irSlots ? "OVER" : "OK")")
        } else {
            lines.append("- IR=\(team.ir.count)")
        }
        if let taxiSlots = rules?.taxiSquadSlots {
            lines.append("- taxi=\(team.taxi.count)/\(taxiSlots) \(team.taxi.count > taxiSlots ? "OVER" : "OK")")
        } else {
            lines.append("- taxi=\(team.taxi.count)")
        }
        if let total = rules?.totalStarters {
            lines.append("- startersSet=\(team.starters.count)/\(total) \(team.starters.isEmpty ? "NOT SET" : (team.starters.count == total ? "FILLED" : "CHECK COUNTS"))")
        } else {
            lines.append("- startersSet=\(team.starters.count)")
        }
            if let slots = rules?.starterSlots, !slots.isEmpty {
                let starterPositions = team.starters.map { $0.position.uppercased() }
                for slot in slots {
                    let name = slot.name.uppercased()
                    let have: Int
                    if name.contains("/") {
                        let allowed = Set(name.split(separator: "/").map(String.init))
                        // Flex: count starters whose pos is allowed (advisory — model must still assign legally).
                        have = starterPositions.filter { allowed.contains($0) }.count
                    } else {
                        have = starterPositions.filter { $0 == name }.count
                    }
                    let range = slot.min == slot.max ? "\(slot.max)" : "\(slot.min)-\(slot.max)"
                    let flag: String
                    if have < slot.min { flag = "UNDER" }
                    else if !name.contains("/"), have > slot.max { flag = "OVER" }
                    else { flag = "OK" }
                    lines.append("- slot \(slot.name): have \(have) / need \(range) → \(flag)")
                }
            }
        let injuredActive = (team.starters + team.bench).filter {
            InjuryStatusWeight.isUnavailable($0.injuryStatus)
        }
        let questionableActive = (team.starters + team.bench).filter {
            InjuryStatusWeight.isQuestionableOrDoubtful($0.injuryStatus)
                && !InjuryStatusWeight.isUnavailable($0.injuryStatus)
        }
        if !injuredActive.isEmpty {
            lines.append("- OUT/IR on active roster (do not start; prefer IR): " + injuredActive.map { "\($0.playerId) \($0.name) (\($0.injuryStatus ?? "?"))" }.joined(separator: "; "))
        }
        if !questionableActive.isEmpty {
            lines.append("- QUESTIONABLE/DOUBTFUL on active roster (deprioritize for lineup; haircut trade value): " + questionableActive.map { "\($0.playerId) \($0.name) (\($0.injuryStatus ?? "?"))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private static func positionDepthBlock(team: TeamSnapshot) -> String {
        let active = team.starters + team.bench
        let grouped = Dictionary(grouping: active, by: \.position)
        let summary = grouped.keys.sorted().map { pos in
            let n = grouped[pos]?.count ?? 0
            return "\(pos):\(n)"
        }.joined(separator: ", ")
        return "Active depth by position: \(summary.isEmpty ? "none" : summary)"
    }

    private static func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }
}

/// Shared injury string parsing for agent prompts / compliance.
enum InjuryStatusWeight {
    static func normalized(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Out / IR / PUP / suspended — should not start; move to IR when possible.
    static func isUnavailable(_ raw: String?) -> Bool {
        let s = normalized(raw)
        guard !s.isEmpty else { return false }
        if s == "o" || s == "out" { return true }
        if s.contains("out") || s.contains("injured reserve") { return true }
        if s == "ir" || s.hasPrefix("ir ") || s.contains(" ir") { return true }
        if s.contains("pup") || s.contains("suspended") || s.contains("covid") { return true }
        return false
    }

    /// Questionable or Doubtful — deprioritize for lineup; haircut for trades.
    static func isQuestionableOrDoubtful(_ raw: String?) -> Bool {
        let s = normalized(raw)
        guard !s.isEmpty else { return false }
        if s == "q" || s == "d" || s == "doubtful" || s == "questionable" { return true }
        if s.contains("doubt") || s.contains("question") { return true }
        return false
    }
}

enum GuardrailEngine {
    static func load() -> GuardrailSettings {
        guard let data = UserDefaults.standard.data(forKey: GuardrailSettings.storageKey),
              var settings = try? JSONDecoder().decode(GuardrailSettings.self, from: data)
        else { return GuardrailSettings() }
        // Desks are always available — ignore any previously saved toggles.
        settings.lineupDeskEnabled = true
        settings.waiverDeskEnabled = true
        settings.tradeDeskEnabled = true
        settings.draftDeskEnabled = true
        return settings
    }

    static func save(_ settings: GuardrailSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: GuardrailSettings.storageKey)
        }
    }

    static func allows(draft: AgentProposalDraft, settings: GuardrailSettings, team: TeamSnapshot) -> Bool {
        switch draft.kind {
        case .lineup:
            guard let payload = try? JSONDecoder().decode(LineupPayload.self, from: Data(draft.payloadJSON.utf8)) else { return false }
            // Advisory: cannot auto-set — allow empty starters when explicitly flagged.
            if payload.canAutoSet == false {
                let hasExplain = !(payload.blockers ?? []).isEmpty
                    || !(payload.requiredChanges ?? []).isEmpty
                    || !(payload.comments ?? "").isEmpty
                    || !draft.rationale.isEmpty
                return hasExplain
            }
            guard !payload.starterIds.isEmpty else { return false }
            let locked = Set(settings.neverBenchPlayerIds)
            let starterSet = Set(payload.starterIds)
            let rosterIds = Set(team.allRostered.map(\.playerId))
            for id in locked where rosterIds.contains(id) {
                if !starterSet.contains(id) { return false }
            }

            // Game locks: keep players already started whose NFL game kicked off; never promote locked/bye bench players.
            let previousStarters = Set(team.starters.map(\.playerId))
            let byId = Dictionary(uniqueKeysWithValues: team.allRostered.map { ($0.playerId, $0) })
            for id in previousStarters {
                let state = byId[id]?.gameLockState ?? ""
                if (state == "started" || state == "final"), !starterSet.contains(id) {
                    return false
                }
            }
            for id in payload.starterIds where !previousStarters.contains(id) {
                let state = byId[id]?.gameLockState ?? ""
                if state == "started" || state == "final" || state == "bye" {
                    return false
                }
            }
            return true
        case .waiver:
            guard let payload = try? JSONDecoder().decode(WaiverPayload.self, from: Data(draft.payloadJSON.utf8)) else { return false }
            // Require a concrete add — empty waiver proposals are not useful.
            guard let add = payload.addPlayerId, !add.isEmpty else { return false }
            if let drop = payload.dropPlayerId, settings.neverDropPlayerIds.contains(drop) { return false }
            if let bid = payload.bid, let max = settings.maxFAABBid, bid > max { return false }
            return true
        case .trade:
            guard let payload = try? JSONDecoder().decode(TradePayload.self, from: Data(draft.payloadJSON.utf8)) else { return false }
            if payload.givePlayerIds.contains(where: { settings.neverTradePlayerIds.contains($0) }) { return false }
            let hasPlayers = !payload.givePlayerIds.isEmpty || !payload.receivePlayerIds.isEmpty
            let hasPicks = !(payload.givePickIds ?? []).isEmpty || !(payload.receivePickIds ?? []).isEmpty
            return hasPlayers || hasPicks
        case .draft:
            return true
        }
    }
}

extension String {
    func extractJSONObject() -> String? {
        guard let start = firstIndex(of: "{"), let end = lastIndex(of: "}") else { return nil }
        return String(self[start...end])
    }
}
