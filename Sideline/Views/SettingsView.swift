import SwiftUI

enum SettingsDestination: String, Hashable, CaseIterable, Identifiable {
    case account
    case theme
    case league
    case model
    case apiKey
    case teamGoals
    case agentCriteria
    case desks
    case limits
    case activity
    case about
    case signOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .theme: return "Theme"
        case .league: return "Leagues"
        case .model: return "Model"
        case .apiKey: return "API key"
        case .teamGoals: return "Team goals"
        case .agentCriteria: return "Agent criteria"
        case .desks: return "Agent desks"
        case .limits: return "Limits & guardrails"
        case .activity: return "Activity"
        case .about: return "About the developer"
        case .signOut: return "Sign out"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person"
        case .theme: return "circle.lefthalf.filled"
        case .league: return "link"
        case .model: return "cpu"
        case .apiKey: return "key"
        case .teamGoals: return "flag"
        case .agentCriteria: return "slider.horizontal.3"
        case .desks: return "square.grid.2x2"
        case .limits: return "shield"
        case .activity: return "list.bullet"
        case .about: return "cup.and.saucer"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }

    var isDestructive: Bool { self == .signOut }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showSignOutConfirm = false

    private let rows: [SettingsDestination] = [
        .account, .theme, .league, .model, .apiKey, .teamGoals, .agentCriteria, .desks, .limits, .activity, .about
    ]

    var body: some View {
        NavigationStack {
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
                    Text(BrandTheme.appName.uppercased())
                        .font(BrandTheme.display(18, weight: .bold))
                        .tracking(1)
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
                    appState.auth.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll need to sign in again to use the app.")
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
            case .account: AccountSettingsPage()
            case .theme: ThemeSettingsPage()
            case .league: LeagueSettingsPage()
            case .model: ModelSettingsPage(llm: appState.llmSettings)
            case .apiKey: APIKeySettingsPage(llm: appState.llmSettings)
            case .teamGoals: TeamGoalsSettingsPage()
            case .agentCriteria: AgentCriteriaListPage()
            case .desks: DesksSettingsPage()
            case .limits: LimitsSettingsPage()
            case .activity: ActivitySettingsPage()
            case .about: AboutDeveloperSettingsPage()
            case .signOut: EmptyView()
            }
        }
        .environmentObject(appState)
    }
}
