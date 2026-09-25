import AppIntents
import Foundation

/// Cycles the Matchup Live Activity to the next linked league.
/// `LiveActivityIntent` runs in the app process so we can sync + update ActivityKit.
struct CycleLiveActivityLeagueIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next league"
    static var description: IntentDescription = IntentDescription(
        "Show the next linked fantasy league on the Live Activity."
    )

    func perform() async throws -> some IntentResult {
        await LiveActivityLeagueCycler.cycle()
        return .result()
    }
}

/// Bridge so the shared intent can call app-target code without linking AppState into the extension.
enum LiveActivityLeagueCycler {
    @MainActor
    static var cycleHandler: (() async -> Void)?

    @MainActor
    static func cycle() async {
        await cycleHandler?()
    }
}
