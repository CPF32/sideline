import SwiftUI
import SwiftData

/// Pending agent proposals sheet (opened from the Team snackbar).
struct ApprovalsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ActionProposal.createdAt, order: .reverse) private var proposals: [ActionProposal]

    private var pending: [ActionProposal] {
        proposals.filter { $0.status == .pending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                List {
                    Section {
                        if pending.isEmpty {
                            Text("No pending proposals. Run an agent from the Agents tab.")
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                        } else {
                            ForEach(pending) { proposal in
                                ProposalRow(proposal: proposal)
                            }
                        }
                    } header: {
                        Text("Needs your approval")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("APPROVALS")
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
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { appState.pendingCount = pending.count }
            .onChange(of: pending.count) { _, count in
                appState.pendingCount = count
                // Rejecting the last proposal left an empty mid-sheet "Needs your approval"
                // section; close so Team can restore layout.
                if count == 0 {
                    dismiss()
                }
            }
            .sheet(item: $appState.followUpProposal) { proposal in
                AgentFollowUpChatSheet(proposal: proposal)
                    .environmentObject(appState)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct ProposalRow: View {
    @EnvironmentObject private var appState: AppState
    let proposal: ActionProposal
    @State private var applying = false

    private var lineupPayload: LineupPayload? {
        guard proposal.kind == .lineup else { return nil }
        return try? JSONDecoder().decode(LineupPayload.self, from: Data(proposal.payloadJSON.utf8))
    }

    /// Blocked when canAutoSet is false OR missing (safe default).
    private var lineupBlocked: Bool {
        guard let payload = lineupPayload else { return false }
        return !payload.isAutoSettable
    }

    private var slotLines: [(slot: String, name: String, reason: String)] {
        guard let payload = lineupPayload, payload.isAutoSettable else { return [] }
        let roster = appState.team?.allRostered ?? []
        let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.playerId, $0) })

        if let slots = payload.slots, !slots.isEmpty {
            return slots.map { pick in
                let player = byId[pick.playerId] ?? byId[MFLNameResolver.normalizePlayerId(pick.playerId)]
                let name = pick.name ?? player?.name ?? pick.playerId
                return (pick.slot, name, pick.reason ?? "")
            }
        }

        var lines: [(String, String, String)] = []
        let slots = appState.team?.leagueRules?.starterSlots ?? []
        var remaining = payload.starterIds
        func take(for allowed: Set<String>, label: String) {
            guard let idx = remaining.firstIndex(where: { id in
                let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
                return allowed.contains((p?.position ?? "").uppercased())
            }) else { return }
            let id = remaining.remove(at: idx)
            let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
            lines.append((label, p?.name ?? id, ""))
        }
        for slot in slots where !LeagueRules.isFlexSlotName(slot.name) {
            for _ in 0..<max(slot.min, 1) {
                take(for: [slot.name.uppercased()], label: slot.name.uppercased())
            }
        }
        for slot in slots where LeagueRules.isFlexSlotName(slot.name) {
            let allowed = LeagueRules.flexEligiblePositions(fromSlotName: slot.name)
            for _ in 0..<max(slot.min, 1) {
                take(for: allowed, label: LeagueRules.displaySlotLabel(slot.name))
            }
        }
        for id in remaining {
            let p = byId[id] ?? byId[MFLNameResolver.normalizePlayerId(id)]
            lines.append((p?.position.uppercased() ?? "START", p?.name ?? id, ""))
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(proposal.kind.title.uppercased())
                    .font(BrandTheme.display(11, weight: .semibold))
                    .foregroundStyle(BrandTheme.muted)
                    .tracking(1)
                Spacer()
                Text(proposal.agentName)
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
            }
            Text(proposal.title)
                .font(BrandTheme.body(16, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
            if !proposal.summary.isEmpty {
                Text(proposal.summary)
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.ink)
            }

            if lineupBlocked, let payload = lineupPayload {
                if let blockers = payload.blockers, !blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHY IT CAN’T AUTO-SET")
                            .font(BrandTheme.display(10, weight: .semibold))
                            .foregroundStyle(BrandTheme.danger)
                            .tracking(0.8)
                        ForEach(blockers, id: \.self) { line in
                            Text("• \(line)")
                                .font(BrandTheme.body(13))
                                .foregroundStyle(BrandTheme.ink)
                        }
                    }
                }
                if let changes = payload.requiredChanges, !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHAT TO FIX")
                            .font(BrandTheme.display(10, weight: .semibold))
                            .foregroundStyle(BrandTheme.muted)
                            .tracking(0.8)
                        ForEach(changes, id: \.self) { line in
                            Text("• \(line)")
                                .font(BrandTheme.body(13))
                                .foregroundStyle(BrandTheme.ink)
                        }
                    }
                }
            } else if !slotLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROPOSED STARTERS")
                        .font(BrandTheme.display(10, weight: .semibold))
                        .foregroundStyle(BrandTheme.muted)
                        .tracking(0.8)
                    ForEach(Array(slotLines.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.slot)
                                    .font(BrandTheme.body(12, weight: .semibold))
                                    .foregroundStyle(BrandTheme.positionColor(for: row.slot))
                                    .frame(width: 56, alignment: .leading)
                                Text(row.name)
                                    .font(BrandTheme.body(14, weight: .medium))
                                    .foregroundStyle(BrandTheme.ink)
                            }
                            if !row.reason.isEmpty {
                                Text(row.reason)
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.muted)
                                    .padding(.leading, 64)
                            }
                        }
                    }
                }
            } else if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
            }

            if !lineupBlocked, !proposal.rationale.isEmpty, !slotLines.isEmpty {
                Text(proposal.rationale)
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
            }

            if !proposal.risks.isEmpty {
                Text("Risks: \(proposal.risks)")
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.danger.opacity(0.9))
            }
            HStack(spacing: 10) {
                Button {
                    appState.reject(proposal)
                } label: {
                    Text(lineupBlocked ? "Dismiss" : "Reject")
                }
                .buttonStyle(DangerButtonStyle())

                if !lineupBlocked {
                    Button {
                        Task {
                            applying = true
                            await appState.approve(proposal)
                            applying = false
                        }
                    } label: {
                        Text(applying ? "Applying…" : "Approve")
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: !applying))
                    .disabled(applying)
                }
            }

            Button {
                appState.openFollowUpChat(for: proposal)
            } label: {
                Label("Discuss with agent", systemImage: "bubble.left.and.bubble.right")
                    .font(BrandTheme.body(14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BrandTheme.space(12))
                    .background(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandTheme.ink)
        }
        .padding(.vertical, BrandTheme.space(6))
    }
}
