import SwiftUI

enum MainTab: Hashable {
    case team
    case league
    case agents
    case settings
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    private var teamTabTitle: String {
        switch appState.teamRosterPane {
        case .matchup: return "Match"
        case .mine: return "Team"
        }
    }

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            TeamCockpitView()
                .tabItem {
                    Label(teamTabTitle, systemImage: "list.bullet.rectangle")
                }
                .tag(MainTab.team)

            LeagueReviewView()
                .tabItem { Label("League", systemImage: "sportscourt") }
                .tag(MainTab.league)

            AgentsSheet()
                .tabItem { Label("Desk", systemImage: "briefcase.fill") }
                .tag(MainTab.agents)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .tint(BrandTheme.ink)
        .toolbarBackground(BrandTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(BrandTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $appState.showConnect) {
            ConnectLeagueHubView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showApprovals) {
            ApprovalsSheet()
                .environmentObject(appState)
                // Prefer large so the Team page TabView isn't compressed mid-detent
                // (that left Matchup blank with the snackbar floating mid-screen).
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}
