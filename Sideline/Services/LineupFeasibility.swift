import Foundation

/// Deterministic check: can we fill a legal lineup with the current roster under game locks?
enum LineupFeasibility {
    struct Report: Hashable {
        var canAutoSet: Bool
        var blockers: [String]
        var requiredChanges: [String]
        var summaryForLLM: String

        static let ok = Report(canAutoSet: true, blockers: [], requiredChanges: [], summaryForLLM: "LINEUP FEASIBILITY: OK — a legal lineup is possible with the current roster.")
    }

    static func analyze(team: TeamSnapshot) -> Report {
        let rules = team.leagueRules
        let slots = rules?.starterSlots ?? []
        guard !slots.isEmpty || (rules?.totalStarters ?? 0) > 0 else {
            // No rules — assume LLM can still try from current starters pattern.
            return .ok
        }

        let lockedStarterIds = Set(
            team.starters.filter {
                let s = $0.gameLockState ?? ""
                return s == "started" || s == "final"
            }.map(\.playerId)
        )

        // Eligible pool: active roster players who can still be newly started, plus locked current starters.
        let active = team.starters + team.bench
        var eligible: [RosterPlayer] = []
        for p in active {
            let state = p.gameLockState ?? "unknown"
            if lockedStarterIds.contains(p.playerId) {
                eligible.append(p)
                continue
            }
            if state == "bye" { continue }
            if state == "started" || state == "final" { continue }
            // upcoming or unknown — treat as fillable
            eligible.append(p)
        }

        // Healthy IR that could be activated (not out).
        let activatableIR = team.ir.filter { player in
            let inj = (player.injuryStatus ?? "").lowercased()
            let out = inj.contains("out") || inj.contains("ir") || inj == "o" || inj.contains("injured reserve")
            return !out
        }

        var blockers: [String] = []
        var changes: [String] = []

        // Per discrete slot shortage (ignore flex first, then flex).
        let discrete = slots.filter { !LeagueRules.isFlexSlotName($0.name) }
        let flex = slots.filter { LeagueRules.isFlexSlotName($0.name) }

        var remaining = eligible
        // Reserve locked starters into their position buckets first.
        for lockedId in lockedStarterIds {
            guard let p = remaining.first(where: { $0.playerId == lockedId }) else { continue }
            // Keep them in remaining for counting against their pos / flex.
            _ = p
        }

        func take(matching allowed: Set<String>, count: Int) -> Int {
            var taken = 0
            var kept: [RosterPlayer] = []
            for p in remaining {
                if taken < count, allowed.contains(p.position.uppercased()) {
                    taken += 1
                } else {
                    kept.append(p)
                }
            }
            remaining = kept
            return taken
        }

        for slot in discrete {
            let need = slot.min
            let pos = slot.name.uppercased()
            // Prefer locking in already-started players at this pos.
            let lockedAtPos = remaining.filter {
                lockedStarterIds.contains($0.playerId) && $0.position.uppercased() == pos
            }.count
            let have = take(matching: [pos], count: need)
            if have < need {
                let short = need - have
                blockers.append("Need \(need) \(slot.name) starter(s); only \(have) eligible on active roster (\(short) short).")
                changes.append("Add \(short) startable \(slot.name) (waiver/FA or activate from IR/taxi), or wait until bye/lock clears.")
                if !activatableIR.filter({ $0.position.uppercased() == pos }).isEmpty {
                    changes.append("Consider activating \(slot.name) from IR: " + activatableIR.filter { $0.position.uppercased() == pos }.map(\.name).joined(separator: ", "))
                }
                let taxiAtPos = team.taxi.filter { $0.position.uppercased() == pos }
                if !taxiAtPos.isEmpty {
                    changes.append("Taxi has \(slot.name) who could be activated: " + taxiAtPos.map(\.name).joined(separator: ", "))
                }
            }
            _ = lockedAtPos
        }

        for slot in flex {
            let need = slot.min
            let allowed = LeagueRules.flexEligiblePositions(fromSlotName: slot.name)
            let have = take(matching: allowed, count: need)
            if have < need {
                let short = need - have
                blockers.append("Need \(need) flex (\(slot.name)) starter(s); only \(have) eligible left (\(short) short).")
                changes.append("Add \(short) startable \(slot.name) player(s) via waiver/FA, or free someone from IR/taxi.")
            }
        }

        if let total = rules?.totalStarters, total > 0 {
            let filled = (rules?.starterSlots ?? []).reduce(0) { $0 + $1.min }
            // Recount eligible vs total if we only have totalStarters without detailed slots.
            if slots.isEmpty {
                let openSlots = max(0, total - lockedStarterIds.count)
                let freeEligible = eligible.filter { !lockedStarterIds.contains($0.playerId) }.count
                if freeEligible < openSlots {
                    let short = openSlots - freeEligible
                    blockers.append("Need \(total) total starters; only \(eligible.count) eligible including locked (\(short) open slot(s) unfillable).")
                    changes.append("Add \(short) players who have not played yet this week (or activate from IR/taxi).")
                }
            } else if filled > 0 {
                // already covered by slot checks
                _ = filled
            }
        }

        // Bye holes on current starters that need replacing and no eligible replacement.
        let byeStarters = team.starters.filter { ($0.gameLockState ?? "") == "bye" }
        for p in byeStarters {
            let pos = p.position.uppercased()
            let replacements = (team.bench).filter {
                $0.position.uppercased() == pos
                    && ($0.gameLockState ?? "upcoming") == "upcoming"
            }
            if replacements.isEmpty {
                blockers.append("\(p.name) (\(p.position)) is on bye and no upcoming \(p.position) is on the bench.")
                changes.append("Pick up a \(p.position) for \(p.name)'s bye, or move a flex-eligible player into that slot if rules allow.")
            }
        }

        // IR compliance — overfilled IR or injured actives when IR room remains.
        if let irSlots = rules?.injuredReserveSlots, irSlots > 0 {
            if team.ir.count > irSlots {
                blockers.append("IR has \(team.ir.count) players but only \(irSlots) IR slot(s).")
                changes.append("Move \(team.ir.count - irSlots) player(s) off IR onto the active roster or drop them.")
            }
            let room = max(0, irSlots - team.ir.count)
            if room > 0 {
                let injuredActive = (team.starters + team.bench).filter { player in
                    let inj = (player.injuryStatus ?? "").lowercased()
                    return inj.contains("out") || inj.contains("ir") || inj == "o"
                        || inj.contains("injured reserve") || inj.contains("sus")
                }
                if !injuredActive.isEmpty {
                    blockers.append("IR has \(room) open slot(s) but injured/out players remain on the active roster: " + injuredActive.map(\.name).joined(separator: ", ") + ".")
                    changes.append("Move to IR: " + injuredActive.prefix(room).map(\.name).joined(separator: ", ") + ".")
                }
            }
        }

        let uniqueBlockers = uniquePreserve(blockers)
        let uniqueChanges = uniquePreserve(changes)
        let can = uniqueBlockers.isEmpty

        var lines: [String] = [
            "LINEUP FEASIBILITY: \(can ? "OK" : "CANNOT AUTO-SET")"
        ]
        if !uniqueBlockers.isEmpty {
            lines.append("Blockers:")
            uniqueBlockers.forEach { lines.append("- \($0)") }
        }
        if !uniqueChanges.isEmpty {
            lines.append("Required changes before auto lineup:")
            uniqueChanges.forEach { lines.append("- \($0)") }
        }
        lines.append("Eligible active players for new starts: \(eligible.filter { !lockedStarterIds.contains($0.playerId) }.count); locked starters already played: \(lockedStarterIds.count).")

        return Report(
            canAutoSet: can,
            blockers: uniqueBlockers,
            requiredChanges: uniqueChanges,
            summaryForLLM: lines.joined(separator: "\n")
        )
    }

    private static func uniquePreserve(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Local fallback proposal when the model fails to emit a blockers proposal.
    static func blockedProposal(team: TeamSnapshot, report: Report) -> AgentProposalDraft {
        let payload = LineupPayload(
            week: team.week,
            starterIds: team.starters.map(\.playerId), // keep current / locked as-is
            irIds: nil,
            taxiIds: nil,
            comments: report.requiredChanges.joined(separator: " "),
            canAutoSet: false,
            blockers: report.blockers,
            requiredChanges: report.requiredChanges
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return AgentProposalDraft(
            kind: .lineup,
            title: "Can't auto-set lineup",
            summary: report.blockers.prefix(2).joined(separator: " "),
            rationale: report.summaryForLLM,
            risks: "Approve does nothing useful until roster gaps are fixed — use this as a checklist.",
            payloadJSON: json,
            agentName: AgentDesk.lineup.agentName
        )
    }
}
