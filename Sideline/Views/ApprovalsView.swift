import SwiftUI
import SwiftData

struct ApprovalsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ActionProposal.createdAt, order: .reverse) private var proposals: [ActionProposal]

    private var pending: [ActionProposal] {
        proposals.filter { $0.status == .pending }
    }

    private var history: [ActionProposal] {
        proposals.filter { $0.status != .pending }
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

                    if !history.isEmpty {
                        Section {
                            ForEach(Array(history.prefix(40))) { proposal in
                                VStack(alignment: .leading, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(proposal.title)
                                            .font(BrandTheme.body(14, weight: .medium))
                                            .foregroundStyle(BrandTheme.ink)
                                        Text("\(proposal.status.rawValue) · \(proposal.agentName)")
                                            .font(BrandTheme.body(12))
                                            .foregroundStyle(BrandTheme.muted)
                                    }
                                    Button {
                                        appState.openFollowUpChat(for: proposal)
                                    } label: {
                                        Label("Discuss", systemImage: "bubble.left.and.bubble.right")
                                            .font(BrandTheme.body(13, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(BrandTheme.ink)
                                }
                                .padding(.vertical, BrandTheme.space(4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteHistoryItem(proposal)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("History")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.top, BrandTheme.tabContentTop, for: .scrollContent)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(BrandTheme.appName.uppercased())
                        .font(BrandTheme.display(18, weight: .bold))
                        .tracking(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !history.isEmpty {
                        Button("Clear history") {
                            appState.clearApprovalHistory()
                        }
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { appState.pendingCount = pending.count }
            .onChange(of: pending.count) { _, count in
                appState.pendingCount = count
            }
            .sheet(item: $appState.followUpProposal) { proposal in
                AgentFollowUpChatSheet(proposal: proposal)
                    .environmentObject(appState)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func deleteHistoryItem(_ proposal: ActionProposal) {
        // Drop related chat threads for this proposal.
        let proposalId = proposal.id
        let threads = (try? modelContext.fetch(
            FetchDescriptor<AgentChatThread>(predicate: #Predicate { $0.proposalId == proposalId })
        )) ?? []
        for thread in threads {
            modelContext.delete(thread)
        }
        modelContext.delete(proposal)
        try? modelContext.save()
    }
}

struct ProposalRow: View {
    @EnvironmentObject private var appState: AppState
    let proposal: ActionProposal
    @State private var applying = false

    private var lineupBlocked: LineupPayload? {
        guard proposal.kind == .lineup,
              let payload = try? JSONDecoder().decode(LineupPayload.self, from: Data(proposal.payloadJSON.utf8)),
              payload.canAutoSet == false
        else { return nil }
        return payload
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
            if let blocked = lineupBlocked {
                if let blockers = blocked.blockers, !blockers.isEmpty {
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
                if let changes = blocked.requiredChanges, !changes.isEmpty {
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
            } else if !proposal.rationale.isEmpty {
                Text(proposal.rationale)
                    .font(BrandTheme.body(13))
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
                    Text(lineupBlocked != nil ? "Dismiss" : "Reject")
                }
                .buttonStyle(DangerButtonStyle())

                if lineupBlocked == nil {
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
