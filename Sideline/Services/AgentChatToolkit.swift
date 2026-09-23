import Foundation

/// Live tools the follow-up chat agent can call (roster, FAs, rules, feasibility, FantasyPros).
enum AgentChatToolkit {
    struct ToolCall: Hashable {
        let id: String
        let name: String
        let argumentsJSON: String
    }

    struct TurnResult {
        let assistantText: String?
        let toolCalls: [ToolCall]
    }

    static let openAITools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "get_roster",
                "description": "Fetch the manager's current roster (starters, bench, IR, taxi) with projections, salaries/contracts when available, injuries, and game lock state. Call this before recommending drops or lineup moves.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_league_rules",
                "description": "Fetch starter slot limits by position, roster size, IR/taxi slots, and salary cap when the league uses salaries.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_lineup_feasibility",
                "description": "Analyze whether a legal lineup can be set with the current roster and list blockers / required changes.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "get_free_agents",
                "description": "Look up free agents from MFL or Sleeper. Use when recommending pickups to fill a position hole or upgrade. Returns live scores/projections — not stale chat context.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "position": [
                            "type": "string",
                            "description": "Optional position filter, e.g. QB, RB, WR, TE, PK, DT, DE, LB, CB, S"
                        ],
                        "sort": [
                            "type": "string",
                            "enum": ["ytd", "lastWeek", "proj"],
                            "description": "Rank by season YTD points, last week points, or this-week projection. Default ytd."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max players to return (1–25). Default 10."
                        ]
                    ],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "research_players",
                "description": "Fetch host + FantasyPros research for specific player IDs: profile, news, injury, ranks, projections. REQUIRED before recommending who to drop or pick up.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "player_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "1–8 player IDs to research (candidates to add and/or drop)."
                        ]
                    ],
                    "required": ["player_ids"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "fantasypros_rankings",
                "description": "FantasyPros expert consensus rankings (ECR). Use for sit/start, ROS value, and comparing players at a position. Same data FantasyPros MCP exposes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "position": [
                            "type": "string",
                            "description": "QB, RB, WR, TE, K, DST, or ALL. Default ALL."
                        ],
                        "scope": [
                            "type": "string",
                            "enum": ["weekly", "ros"],
                            "description": "weekly = this week ECR; ros = rest-of-season. Default weekly."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max rows (1–40). Default 20."
                        ]
                    ],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "fantasypros_projections",
                "description": "FantasyPros weekly fantasy-point projections by position. Use for this-week start/sit math.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "position": [
                            "type": "string",
                            "description": "QB, RB, WR, TE, K, DST, or ALL. Default ALL."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max rows (1–40). Default 20."
                        ]
                    ],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "fantasypros_news",
                "description": "FantasyPros NFL news wire. Optionally filter to one player by name.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "player_name": [
                            "type": "string",
                            "description": "Optional player name filter, e.g. \"Bijan Robinson\"."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max items (1–15). Default 8."
                        ]
                    ],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "fantasypros_research",
                "description": "Look up FantasyPros weekly ECR, ROS rank, projection, and news by player display names (works for free agents and rostered players).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "player_names": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "1–10 player names to research."
                        ]
                    ],
                    "required": ["player_names"],
                    "additionalProperties": false
                ]
            ]
        ]
    ]

    static func systemPrompt(agentName: String, proposal: ActionProposal) -> String {
        let fpHint = FantasyProsClient.hasAPIKey
            ? """
              FantasyPros tools are available (same data as FantasyPros MCP):
              - fantasypros_rankings / fantasypros_projections for position boards
              - fantasypros_news for injury/role notes
              - fantasypros_research by player name for FA + roster comparisons
              Prefer FantasyPros ranks/projections over guessing when debating sit/start or pickups.
              """
            : """
              FantasyPros is not configured — tell the user to add an API key in Settings → FantasyPros if they want expert ranks/projections in chat.
              """
        return """
        You are \(agentName) in Sideline, in a follow-up chat about a prior proposal.
        Answer clearly and confidently when tool data supports it. If data is thin, say what you're uncertain about.

        You have tools. USE THEM when the user asks about drops, pickups, lineup holes, free agents, rankings, or current roster — do not rely only on memory.
        - get_roster before suggesting who to drop or sit/start
        - get_free_agents when recommending pickups (filter by position when relevant)
        - research_players on the shortlist of candidates BEFORE your final recommendation
        - fantasypros_rankings / fantasypros_projections / fantasypros_research for expert consensus and projections
        - get_league_rules / get_lineup_feasibility when discussing whether a lineup is legal

        \(fpHint)

        For drop / pickup recommendations:
        - Call research_players and/or fantasypros_research on the players you are comparing.
        - Analyze role/news, ranks, injury, and projections — not salary alone.
        - Salary/cap is one factor among many; never make salary the whole rationale.
        - Prefer concrete player names + IDs. Plain text only (no JSON in the final reply).
        - Keep answers practical and short unless the user asks for depth.

        PROPOSAL CONTEXT:
        title: \(proposal.title)
        kind: \(proposal.kind.title)
        status: \(proposal.status.rawValue)
        summary: \(proposal.summary)
        rationale: \(proposal.rationale)
        risks: \(proposal.risks)
        payload: \(proposal.payloadJSON)
        """
    }

    @MainActor
    static func execute(
        name: String,
        argumentsJSON: String,
        appState: AppState
    ) async -> String {
        let args = parseArgs(argumentsJSON)
        switch name {
        case "get_roster":
            return await rosterText(appState: appState)
        case "get_league_rules":
            return rulesText(appState: appState)
        case "get_lineup_feasibility":
            return feasibilityText(appState: appState)
        case "get_free_agents":
            let position = (args["position"] as? String)?.uppercased()
            let sort = (args["sort"] as? String) ?? "ytd"
            let limit = min(25, max(1, (args["limit"] as? Int) ?? intValue(args["limit"]) ?? 10))
            return await freeAgentsText(appState: appState, position: position, sort: sort, limit: limit)
        case "research_players":
            return await researchPlayersText(appState: appState, args: args)
        case "fantasypros_rankings":
            return await fantasyProsRankingsText(appState: appState, args: args)
        case "fantasypros_projections":
            return await fantasyProsProjectionsText(appState: appState, args: args)
        case "fantasypros_news":
            return await fantasyProsNewsText(appState: appState, args: args)
        case "fantasypros_research":
            return await fantasyProsResearchText(appState: appState, args: args)
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - Tool bodies

    @MainActor
    private static func rosterText(appState: AppState) async -> String {
        let previous = appState.team
        if appState.linkedFranchise != nil {
            await appState.syncTeam(week: appState.selectedWeek)
        }
        guard let team = appState.team ?? previous else {
            return "No team loaded. Connect MFL and sync first."
        }
        func block(_ title: String, _ players: [RosterPlayer]) -> String {
            if players.isEmpty { return "\(title): (none)" }
            let lines = players.map { p -> String in
                let proj = p.projectedPoints.map { String(format: "%.1f", $0) } ?? "-"
                let game = p.gameLockState ?? "?"
                let opp = p.opponent ?? "-"
                let inj = p.injuryStatus.map { " injury:\($0)" } ?? ""
                let sal = p.salary.map { " salary:\(SalaryFormat.compact($0))" } ?? ""
                let cy = p.contractYear.map { " contractYear:\($0)" } ?? ""
                return "\(p.playerId)|\(p.name)|\(p.position)|\(p.team)|proj:\(proj)|game:\(game)|opp:\(opp)\(sal)\(cy)\(inj)"
            }
            return "\(title) (\(players.count)):\n" + lines.joined(separator: "\n")
        }
        var header = [
            "League: \(team.leagueName) | \(team.franchiseName) | Week \(team.week)"
        ]
        if let total = team.totalSalary {
            let cap = team.salaryCap.map { " / cap \(SalaryFormat.compact($0))" } ?? ""
            header.append("SALARY: total \(SalaryFormat.compact(total))\(cap)")
        } else if let cap = team.salaryCap {
            header.append("SALARY CAP: \(SalaryFormat.compact(cap))")
        }
        return (header + [
            block("STARTERS", team.starters),
            block("BENCH", team.bench),
            block("IR", team.ir),
            block("TAXI", team.taxi)
        ]).joined(separator: "\n\n")
    }

    @MainActor
    private static func rulesText(appState: AppState) -> String {
        guard let rules = appState.team?.leagueRules else {
            return "League rules not loaded. Sync the team first."
        }
        return rules.summaryForLLM
    }

    @MainActor
    private static func feasibilityText(appState: AppState) -> String {
        guard let team = appState.team else {
            return "No team loaded."
        }
        return LineupFeasibility.analyze(team: team).summaryForLLM
    }

    @MainActor
    private static func freeAgentsText(
        appState: AppState,
        position: String?,
        sort: String,
        limit: Int
    ) async -> String {
        do {
            var players = try await appState.fetchFreeAgents(
                sort: sort,
                limit: max(limit, 15),
                position: position
            )
            players = Array(players.prefix(limit))
            if players.isEmpty {
                return "No free agents found for sort=\(sort) position=\(position ?? "any")."
            }
            let header = "FREE AGENTS sort=\(sort) position=\(position ?? "any") count=\(players.count)"
            let lines = players.map { p -> String in
                let proj = p.projectedPoints.map { String(format: "%.1f", $0) } ?? "-"
                let ytd = p.seasonPoints.map { String(format: "%.1f", $0) } ?? "-"
                let lw = p.lastWeekPoints.map { String(format: "%.1f", $0) } ?? "-"
                let sal = p.salary.map { "salary:\(SalaryFormat.compact($0))" } ?? "salary:-"
                return "\(p.playerId)|\(p.name)|\(p.position)|\(p.team)|proj:\(proj)|ytd:\(ytd)|lastWeek:\(lw)|\(sal)"
            }
            return header + "\n" + lines.joined(separator: "\n")
        } catch {
            return "Failed to load free agents: \(error.localizedDescription)"
        }
    }

    @MainActor
    private static func researchPlayersText(appState: AppState, args: [String: Any]) async -> String {
        guard let linked = appState.linkedFranchise else {
            return "No league linked — connect MFL or Sleeper first."
        }
        var ids: [String] = []
        if let arr = args["player_ids"] as? [String] {
            ids = arr
        } else if let arr = args["player_ids"] as? [Any] {
            ids = arr.compactMap { $0 as? String ?? ($0 as? Int).map(String.init) }
        } else if let s = args["player_ids"] as? String {
            ids = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let single = args["player_id"] as? String {
            ids = [single]
        }
        ids = ids.filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            return "research_players requires player_ids (array)."
        }
        var chunks: [String] = []
        if linked.isMFL {
            chunks.append(await MFLPlayerResearchService.summarize(playerIds: ids, linked: linked))
        }
        let rosterHits = (appState.team?.allRostered ?? []).filter { ids.contains($0.playerId) }
        var nameHits: [String] = rosterHits.map(\.name)

        if !rosterHits.isEmpty {
            chunks.append(await SleeperPlayerCatalog.shared.contextLines(for: rosterHits, limit: 12))
        } else if linked.isSleeper {
            var lines: [String] = ["SLEEPER PLAYERS:"]
            for id in ids.prefix(12) {
                if let p = await SleeperPlayerCatalog.shared.player(id: id) {
                    var bits = ["\(p.fullName) \(p.position) \(p.team)"]
                    if let inj = p.injuryStatus { bits.append("injury=\(inj)") }
                    if let st = p.status { bits.append("status=\(st)") }
                    lines.append("- " + bits.joined(separator: " · "))
                    nameHits.append(p.fullName)
                }
            }
            chunks.append(lines.joined(separator: "\n"))
        }

        if FantasyProsClient.hasAPIKey {
            await FantasyProsIntelService.shared.ensureLoaded(
                season: linked.season,
                week: appState.team?.week ?? appState.selectedWeek
            )
            if !rosterHits.isEmpty {
                chunks.append(await FantasyProsIntelService.shared.contextLines(for: rosterHits, limit: 12))
            }
            let missing = ids.filter { id in !(appState.team?.allRostered ?? []).contains { $0.playerId == id } }
            if !missing.isEmpty, nameHits.count < ids.count {
                if let fas = try? await appState.fetchFreeAgents(sort: "ytd", limit: 40, position: nil) {
                    for fa in fas where missing.contains(fa.playerId) {
                        nameHits.append(fa.name)
                    }
                }
            }
            if !nameHits.isEmpty {
                chunks.append(await FantasyProsIntelService.shared.researchByNames(nameHits, limitPerPlayer: 2))
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    @MainActor
    private static func ensureFantasyProsLoaded(appState: AppState) async -> String? {
        guard FantasyProsClient.hasAPIKey else {
            return "FantasyPros not configured. Add an API key in Settings → FantasyPros."
        }
        let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
        let week = max(1, appState.team?.week ?? appState.selectedWeek)
        await FantasyProsIntelService.shared.ensureLoaded(
            season: season,
            week: week,
            hasLiveGames: DataCache.hasLiveGames(in: appState.team)
        )
        return nil
    }

    @MainActor
    private static func fantasyProsRankingsText(appState: AppState, args: [String: Any]) async -> String {
        if let err = await ensureFantasyProsLoaded(appState: appState) { return err }
        let position = (args["position"] as? String) ?? "ALL"
        let scope = (args["scope"] as? String) ?? "weekly"
        let limit = min(40, max(1, (args["limit"] as? Int) ?? intValue(args["limit"]) ?? 20))
        return await FantasyProsIntelService.shared.rankingsToolText(
            position: position, scope: scope, limit: limit
        )
    }

    @MainActor
    private static func fantasyProsProjectionsText(appState: AppState, args: [String: Any]) async -> String {
        if let err = await ensureFantasyProsLoaded(appState: appState) { return err }
        let position = (args["position"] as? String) ?? "ALL"
        let limit = min(40, max(1, (args["limit"] as? Int) ?? intValue(args["limit"]) ?? 20))
        return await FantasyProsIntelService.shared.projectionsToolText(position: position, limit: limit)
    }

    @MainActor
    private static func fantasyProsNewsText(appState: AppState, args: [String: Any]) async -> String {
        if let err = await ensureFantasyProsLoaded(appState: appState) { return err }
        let name = args["player_name"] as? String
        let limit = min(15, max(1, (args["limit"] as? Int) ?? intValue(args["limit"]) ?? 8))
        return await FantasyProsIntelService.shared.newsToolText(playerName: name, limit: limit)
    }

    @MainActor
    private static func fantasyProsResearchText(appState: AppState, args: [String: Any]) async -> String {
        if let err = await ensureFantasyProsLoaded(appState: appState) { return err }
        var names: [String] = []
        if let arr = args["player_names"] as? [String] {
            names = arr
        } else if let arr = args["player_names"] as? [Any] {
            names = arr.compactMap { $0 as? String }
        } else if let s = args["player_names"] as? String {
            names = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let single = args["player_name"] as? String {
            names = [single]
        }
        names = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return "fantasypros_research requires player_names (array)."
        }
        return await FantasyProsIntelService.shared.researchByNames(names)
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
