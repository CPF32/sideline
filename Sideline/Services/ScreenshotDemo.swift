import Foundation
import SwiftData

/// Launch-arg helpers for App Store marketing screenshots.
/// Pass `-ScreenshotDemo` and optionally `-ScreenshotTab <team|league|props|agents|settings>`.
enum ScreenshotDemo {
    static let demoLeagueId = "99999"
    static let demoHost = "www64.myfantasyleague.com"
    /// Written only in older builds during screenshot runs — never a real Odds key.
    static let placeholderOddsAPIKey = "screenshot-demo-odds-key"

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
        case "props", "analysis": return .props
        case "agents": return .agents
        case "settings": return .settings
        // Legacy: approvals is a sheet, not a tab — land on Team.
        case "approvals": return .team
        default: return nil
        }
    }

    @MainActor
    static func applyIfNeeded(appState: AppState, context: ModelContext) async {
        if isEnabled {
            await appState.applyScreenshotDemo(context: context)
            if let tab = preferredTab {
                appState.selectedTab = tab
            }
            return
        }
        // Simulator screenshot runs persist a fake franchise — wipe it on normal launches
        // so sync never hits a non-resolvable demo host.
        appState.purgeScreenshotDemoIfNeeded(context: context)
        // Older screenshot builds wrote a placeholder into the real Odds keychain slot.
        if KeychainStore.get(.oddsAPIKey) == placeholderOddsAPIKey {
            KeychainStore.delete(.oddsAPIKey)
        }
    }
}
