import SwiftUI
import SwiftData

@main
struct SidelineApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(ScreenshotDemo.isEnabled ? .light : (appState.isDarkMode ? .dark : .light))
                .phoneLayoutRoot()
                .modelContainer(for: [
                    LinkedFranchise.self,
                    ActionProposal.self,
                    AgentChatThread.self,
                    AgentChatMessage.self,
                    ActivityEvent.self,
                    PersistedWeekSummary.self,
                    UserPreferences.self
                ])
        }
    }
}
