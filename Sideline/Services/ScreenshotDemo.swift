import Foundation
import SwiftData

/// Launch-arg helpers for App Store marketing screenshots.
/// Pass `-ScreenshotDemo` and optionally `-ScreenshotTab <team|league|agents|approvals|settings>`.
enum ScreenshotDemo {
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
        case "approvals": return .approvals
        case "settings": return .settings
        default: return nil
        }
    }

    @MainActor
    static func applyIfNeeded(appState: AppState, context: ModelContext) {
        guard isEnabled else { return }
        appState.applyScreenshotDemo(context: context)
        if let tab = preferredTab {
            appState.selectedTab = tab
        }
    }
}
