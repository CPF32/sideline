import SwiftUI
import SwiftData

@main
struct SidelineApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("sideline.appearance.darkMode") private var isDarkMode = false

    init() {
        // Fresh installs default to light — ignore system dark until the user toggles Theme.
        UserDefaults.standard.register(defaults: [
            "sideline.appearance.darkMode": false
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(ScreenshotDemo.isEnabled ? .light : (isDarkMode ? .dark : .light))
                .phoneLayoutRoot()
                .modelContainer(for: [
                    LinkedFranchise.self,
                    ActionProposal.self,
                    AgentChatThread.self,
                    AgentChatMessage.self,
                    ActivityEvent.self,
                    PersistedWeekSummary.self
                ])
        }
    }
}
