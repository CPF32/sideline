import SwiftUI

struct AgentsSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AgentDesk.allCases.enumerated()), id: \.element.id) { index, desk in
                        let isThisRunning = appState.isRunningAgent && appState.agentRunTitle == desk.title
                        Button {
                            Task { await appState.runAgent(desk) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(desk.title)
                                        .font(BrandTheme.body(16, weight: .semibold))
                                        .foregroundStyle(BrandTheme.ink)
                                    Text(desk.agentName)
                                        .font(BrandTheme.body(12))
                                        .foregroundStyle(BrandTheme.muted)
                                }
                                Spacer()
                                if isThisRunning {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(BrandTheme.muted)
                                }
                            }
                            .padding(.horizontal, BrandTheme.pageGutter)
                            .padding(.vertical, BrandTheme.space(16))
                            .padding(.top, index == 0 ? BrandTheme.tabContentTop : 0)
                            .opacity(isThisRunning ? 0.55 : 1)
                        }
                        .disabled(appState.isRunningAgent)
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.pageGutter)
                    }
                    Spacer(minLength: 0)
                }

                if appState.isRunningAgent || !appState.agentActivityLines.isEmpty {
                    VStack {
                        Spacer()
                        agentLivePanel
                            .padding(.horizontal, BrandTheme.pageGutterCompact)
                            .padding(.bottom, BrandTheme.space(16))
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.isRunningAgent)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SidelineNavTitle()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var agentLivePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if appState.isRunningAgent {
                    ProgressView()
                        .tint(BrandTheme.onAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.isRunningAgent ? (appState.agentRunTitle ?? "Running agent") : "Last run")
                        .font(BrandTheme.body(14, weight: .semibold))
                        .foregroundStyle(BrandTheme.onAccent)
                    if let status = appState.agentActivityStatus ?? appState.agentActivityLines.last?.text {
                        Text(status)
                            .font(BrandTheme.body(12))
                            .foregroundStyle(BrandTheme.onAccent.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if !appState.isRunningAgent, !appState.agentActivityLines.isEmpty {
                    Button("Clear") {
                        appState.agentActivityLines = []
                    }
                    .font(BrandTheme.body(12, weight: .semibold))
                    .foregroundStyle(BrandTheme.onAccent)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.agentActivityLines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.at.formatted(date: .omitted, time: .standard))
                                    .font(BrandTheme.mono(10))
                                    .foregroundStyle(BrandTheme.onAccent.opacity(0.55))
                                    .frame(width: BrandTheme.space(64), alignment: .leading)
                                Text(line.text)
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.onAccent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.id)
                        }
                    }
                }
                .frame(maxHeight: BrandTheme.space(140))
                .onChange(of: appState.agentActivityLines.count) { _, _ in
                    if let last = appState.agentActivityLines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(BrandTheme.pageGutterTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
        .allowsHitTesting(!appState.isRunningAgent)
    }
}
