import SwiftUI

enum SettingsDestination: String, Hashable, CaseIterable, Identifiable {
    case theme
    case league
    case model
    case apis
    case apiKey
    case fantasyPros
    case oddsAPI
    case teamGoals
    case agentCriteria
    case activity
    case about
    case account
    case signOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theme: return "Appearance"
        case .league: return "Leagues"
        case .model: return "Model"
        case .apis: return "APIs"
        case .apiKey: return "Model API key"
        case .fantasyPros: return "FantasyPros"
        case .oddsAPI: return "Odds API"
        case .teamGoals: return "Team goals"
        case .agentCriteria: return "Agent criteria"
        case .activity: return "Activity"
        case .about: return "About the developer"
        case .account: return "Account"
        case .signOut: return "Sign out"
        }
    }

    var systemImage: String {
        switch self {
        case .theme: return "paintpalette"
        case .league: return "link"
        case .model: return "cpu"
        case .apis: return "key.horizontal"
        case .apiKey: return "key"
        case .fantasyPros: return "chart.line.uptrend.xyaxis"
        case .oddsAPI: return "chart.bar.doc.horizontal"
        case .teamGoals: return "flag"
        case .agentCriteria: return "slider.horizontal.3"
        case .activity: return "list.bullet"
        case .about: return "person"
        case .account: return "person.crop.circle"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }

    var isDestructive: Bool { self == .signOut }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showSignOutConfirm = false

    private let rows: [SettingsDestination] = [
        .league, .model, .apis, .teamGoals, .agentCriteria, .activity, .account, .theme, .about
    ]

    var body: some View {
        NavigationStack(path: $appState.settingsPath) {
            ZStack {
                SidelineBackground()
                GeometryReader { geo in
                    let rowCount = CGFloat(rows.count + 1) // + sign out
                    let rowHeight = min(52, max(40, (geo.size.height - 24) / rowCount))

                    VStack(spacing: 0) {
                        ForEach(rows) { dest in
                            NavigationLink(value: dest) {
                                settingsRow(dest, height: rowHeight)
                            }
                            .buttonStyle(.plain)
                            Rectangle()
                                .fill(BrandTheme.hairline)
                                .frame(height: 1)
                                .padding(.leading, BrandTheme.space(52))
                        }

                        Button {
                            showSignOutConfirm = true
                        } label: {
                            settingsRow(.signOut, height: rowHeight)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, BrandTheme.tabContentTop)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SidelineNavTitle()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { dest in
                SettingsDetailRouter(destination: dest)
                    .environmentObject(appState)
            }
            .confirmationDialog(
                "Sign out of Sideline?",
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task {
                        // Clear user-scoped FantasyPros / Odds caches while Apple user id is still known.
                        await FantasyProsClient.shared.clearCache()
                        await OddsAPIClient.shared.clearCache()
                        await FantasyProsIntelService.shared.reset()
                        await OddsIntelService.shared.reset()
                        await MainActor.run { appState.auth.signOut() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll need to sign in again to use the app.")
            }
        }
        .onChange(of: appState.selectedTab) { _, tab in
            if tab != .settings {
                appState.settingsPath = []
            }
        }
    }

    private func settingsRow(_ dest: SettingsDestination, height: CGFloat) -> some View {
        HStack(spacing: 14) {
            Image(systemName: dest.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(dest.isDestructive ? BrandTheme.danger : BrandTheme.ink)
                .frame(width: BrandTheme.space(28))
            Text(dest.title)
                .font(BrandTheme.body(16, weight: .semibold))
                .foregroundStyle(dest.isDestructive ? BrandTheme.danger : BrandTheme.ink)
            Spacer(minLength: 0)
            if !dest.isDestructive {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .frame(height: height)
        .contentShape(Rectangle())
    }
}

struct SettingsDetailRouter: View {
    @EnvironmentObject private var appState: AppState
    let destination: SettingsDestination

    var body: some View {
        Group {
            switch destination {
            case .theme: ThemeSettingsPage()
            case .league: LeagueSettingsPage()
            case .model: ModelSettingsPage(llm: appState.llmSettings)
            case .apis: APIsSettingsPage()
            case .apiKey: APIKeySettingsPage(llm: appState.llmSettings)
            case .fantasyPros: FantasyProsSettingsPage()
            case .oddsAPI: OddsAPISettingsPage()
            case .teamGoals: TeamGoalsSettingsPage()
            case .agentCriteria: AgentCriteriaListPage()
            case .activity: ActivitySettingsPage()
            case .about: AboutDeveloperSettingsPage()
            case .account: AccountSettingsPage()
            case .signOut: EmptyView()
            }
        }
        .environmentObject(appState)
    }
}
