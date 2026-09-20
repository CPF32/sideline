import SwiftUI
import SwiftData

struct AgentFollowUpChatSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let proposal: ActionProposal
    @State private var thread: AgentChatThread?
    @State private var draft = ""
    @State private var isSending = false
    @State private var statusText: String?
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var sortedMessages: [AgentChatMessage] {
        (thread?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                VStack(spacing: 0) {
                    contextBanner
                    Divider().overlay(BrandTheme.hairline)
                    messagesScroll
                    Divider().overlay(BrandTheme.hairline)
                    composer
                }
            }
            .navigationTitle(proposal.agentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(BrandTheme.ink)
                }
            }
            .onAppear { ensureThread() }
        }
    }

    private var contextBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(proposal.title)
                .font(BrandTheme.body(14, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
            Text("\(proposal.status.rawValue) · \(proposal.kind.title)")
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted)
            if !proposal.summary.isEmpty {
                Text(proposal.summary)
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrandTheme.pageGutterCompact)
        .padding(.vertical, BrandTheme.space(12))
        .background(BrandTheme.accentWash)
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if sortedMessages.isEmpty {
                        Text("Ask about drops, pickups, or this proposal — I can look up your live roster and free agents.")
                            .font(BrandTheme.body(14))
                            .foregroundStyle(BrandTheme.muted)
                            .padding(.top, BrandTheme.space(24))
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(sortedMessages) { message in
                        chatBubble(message)
                            .id(message.id)
                    }
                    if isSending {
                        HStack {
                            ProgressView()
                            Text(statusText ?? "Thinking…")
                                .font(BrandTheme.body(13))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        .padding(.horizontal, BrandTheme.space(4))
                        .id("sending")
                    }
                    if let errorText {
                        Text(errorText)
                            .font(BrandTheme.body(13))
                            .foregroundStyle(BrandTheme.danger)
                    }
                }
                .padding(BrandTheme.pageGutterCompact)
            }
            .onChange(of: sortedMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isSending) { _, sending in
                if sending { scrollToBottom(proxy) }
            }
        }
    }

    private func chatBubble(_ message: AgentChatMessage) -> some View {
        let isUser = message.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
                .font(BrandTheme.body(15))
                .foregroundStyle(isUser ? BrandTheme.onAccent : BrandTheme.ink)
                .padding(.horizontal, BrandTheme.space(12))
                .padding(.vertical, BrandTheme.space(10))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isUser ? BrandTheme.accent : BrandTheme.surfaceStrong)
                )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about this proposal…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(BrandTheme.body(15))
                .padding(BrandTheme.space(12))
                .background(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .fill(BrandTheme.surfaceStrong)
                )
                .focused($focused)
                .disabled(isSending)

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? BrandTheme.ink : BrandTheme.muted.opacity(0.5))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, BrandTheme.pageGutterCompact)
        .padding(.vertical, BrandTheme.space(12))
        .background(BrandTheme.background.opacity(0.95))
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                if isSending {
                    proxy.scrollTo("sending", anchor: .bottom)
                } else if let last = sortedMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func ensureThread() {
        if thread != nil { return }
        let proposalId = proposal.id
        var descriptor = FetchDescriptor<AgentChatThread>(
            predicate: #Predicate { $0.proposalId == proposalId }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            thread = existing
            return
        }
        let created = AgentChatThread(
            proposalId: proposal.id,
            title: proposal.title,
            agentName: proposal.agentName
        )
        modelContext.insert(created)
        // Seed with a short assistant intro so the thread isn't blank.
        let intro = AgentChatMessage(
            role: "assistant",
            content: introText(),
            thread: created
        )
        modelContext.insert(intro)
        try? modelContext.save()
        thread = created
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ensureThread()
        guard let thread else { return }
        guard let apiKey = appState.llmSettings.resolvedAPIKey() else {
            errorText = LLMClientError.missingAPIKey.localizedDescription
            return
        }

        draft = ""
        errorText = nil
        statusText = "Thinking…"
        isSending = true
        defer {
            isSending = false
            statusText = nil
        }

        let userMsg = AgentChatMessage(role: "user", content: text, thread: thread)
        modelContext.insert(userMsg)
        thread.updatedAt = .now
        try? modelContext.save()

        do {
            let llm = LLMClient(
                provider: appState.llmSettings.provider,
                model: appState.llmSettings.model,
                apiKey: apiKey
            )
            let system = AgentChatToolkit.systemPrompt(
                agentName: proposal.agentName,
                proposal: proposal
            )
            let history = sortedMessages
                .filter { $0.role == "user" || $0.role == "assistant" }
                .suffix(20)
                .map { ($0.role, $0.content) }

            let usesNativeTools = appState.llmSettings.provider == .openAI
                || appState.llmSettings.provider == .openRouter

            let reply: String
            if usesNativeTools {
                reply = try await llm.runToolLoop(
                    system: system,
                    history: Array(history),
                    tools: AgentChatToolkit.openAITools,
                    executeTool: { name, args in
                        await AgentChatToolkit.execute(
                            name: name,
                            argumentsJSON: args,
                            appState: appState
                        )
                    },
                    onProgress: { msg in
                        Task { @MainActor in
                            statusText = msg
                        }
                    }
                )
            } else {
                // Anthropic/Google: inject a fresh roster + FA snapshot once, then plain chat.
                statusText = "Loading roster & free agents…"
                let roster = await AgentChatToolkit.execute(
                    name: "get_roster", argumentsJSON: "{}", appState: appState
                )
                let fas = await AgentChatToolkit.execute(
                    name: "get_free_agents",
                    argumentsJSON: #"{"sort":"ytd","limit":15}"#,
                    appState: appState
                )
                let rules = await AgentChatToolkit.execute(
                    name: "get_league_rules", argumentsJSON: "{}", appState: appState
                )
                let enrichedSystem = system
                    + "\n\nLIVE TOOL SNAPSHOT (refreshed this turn):\n"
                    + rules + "\n\n" + roster + "\n\n" + fas
                    + "\n\nUse this live data. If you need a different position, say which FA filter to run next."
                statusText = "Thinking…"
                reply = try await llm.completeChat(system: enrichedSystem, messages: Array(history))
            }

            let assistantMsg = AgentChatMessage(role: "assistant", content: reply, thread: thread)
            modelContext.insert(assistantMsg)
            thread.updatedAt = .now
            try? modelContext.save()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func introText() -> String {
        if proposal.title.localizedCaseInsensitiveContains("can't auto-set")
            || proposal.title.localizedCaseInsensitiveContains("cannot auto") {
            return "I couldn’t auto-set that lineup. Ask who to drop, what FA to pick up, or how to patch holes — I’ll look up your live roster and free agents."
        }
        switch proposal.status {
        case .applied, .approved:
            return "This \(proposal.kind.title.lowercased()) was approved. Ask about alternatives, drops, or pickups — I can pull live roster/FA data."
        case .rejected:
            return "This proposal was rejected. I can rethink it with a fresh look at your roster and free agents."
        default:
            return "Ask about this proposal, who to drop, or which free agents to add. I can look up live roster and FA data — not just this chat’s starting context."
        }
    }
}
