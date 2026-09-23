import Foundation
import SwiftData

/// Launch-arg helpers for App Store marketing screenshots.
/// Pass `-ScreenshotDemo` and optionally `-ScreenshotTab <team|league|agents|settings>`.
enum ScreenshotDemo {
    static let demoLeagueId = "99999"
    static let demoHost = "www64.myfantasyleague.com"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo")
    }

    static var preferredTab: MainTab? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-ScreenshotTab"),
              args.indices.contains(index + 1) else { return nil }
        switch args[index + 1].lowercased() {
        case "team": return .team
        case "league": return .league
        case "agents": return .agents
        case "approvals": return .team
        case "settings": return .settings
        default: return nil
        }
    }

    @MainActor
    static func applyIfNeeded(appState: AppState, context: ModelContext) {
        if isEnabled {
            appState.applyScreenshotDemo(context: context)
            if let tab = preferredTab {
                appState.selectedTab = tab
            }
            return
        }
        // Simulator screenshot runs persist a fake franchise — wipe it on normal launches
        // so sync never hits a non-resolvable demo host.
        appState.purgeScreenshotDemoIfNeeded(context: context)
    }
}
