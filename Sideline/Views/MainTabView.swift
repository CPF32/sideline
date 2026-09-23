import SwiftUI

enum MainTab: Hashable {
    case team
    case league
    case agents
    case settings
}

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            TeamCockpitView()
                .tabItem { Label("Team", systemImage: "person.3") }
                .tag(MainTab.team)

            LeagueReviewView()
                .tabItem { Label("League", systemImage: "sportscourt") }
                .tag(MainTab.league)

            AgentsSheet()
                .tabItem { Label("Agents", systemImage: "brain.head.profile") }
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
                .presentationDetents([.medium, .large])
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
