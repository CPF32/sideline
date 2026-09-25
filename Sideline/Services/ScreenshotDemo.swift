import Foundation
import SwiftData

/// Launch-arg helpers for App Store marketing screenshots.
/// Pass `-ScreenshotDemo` and optionally
/// `-ScreenshotTab <lineup|matchup|league|desk|settings>`
/// (legacy: `team`, `props`, `agents` still accepted).
enum ScreenshotDemo {
    static let demoLeagueId = "99999"
    static let demoHost = "www64.myfantasyleague.com"
    /// Written only in older builds during screenshot runs — never a real Odds key.
    static let placeholderOddsAPIKey = "screenshot-demo-odds-key"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ScreenshotDemo")
    }

    /// Tab + optional Lineup/Matchup swipe pane for the first tab.
    static var preferredDestination: (tab: MainTab, pane: MatchupRosterPane?)? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-ScreenshotTab"),
              args.indices.contains(index + 1) else { return nil }
        switch args[index + 1].lowercased() {
        case "lineup", "team":
            return (.team, .mine)
        case "matchup":
            return (.team, .matchup)
        case "league":
            return (.league, nil)
        case "desk", "agents":
            return (.agents, nil)
        case "settings":
            return (.settings, nil)
        // Legacy: props tab removed — land on Matchup (props live on player profiles).
        case "props", "analysis":
            return (.team, .matchup)
        // Legacy: approvals is a sheet, not a tab.
        case "approvals":
            return (.team, .mine)
        default:
            return nil
        }
    }

    @MainActor
    static func applyIfNeeded(appState: AppState, context: ModelContext) async {
        if isEnabled {
            await appState.applyScreenshotDemo(context: context)
            if let dest = preferredDestination {
                appState.selectedTab = dest.tab
                if let pane = dest.pane {
                    appState.teamRosterPane = pane
                }
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
