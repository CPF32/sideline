import Foundation
import ActivityKit

/// Shared Live Activity attributes for in-progress fantasy matchups.
struct MatchupLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var myScore: Double
        var oppScore: Double
        var opponentName: String
        var week: Int
        var statusLine: String
        /// My live starters — cycled one at a time. Kept for older pushes; prefer `myPlayerLines`.
        var playerLines: [String]
        /// Unix seconds — number in APNs JSON for Codable interop with the push backend.
        var lastUpdated: Double
        /// Unix seconds of the next backend sync (legacy; UI now cycles NFL games instead).
        var nextSyncAt: Double? = nil
        /// Mutable so the Lock Screen can cycle leagues without restarting the activity.
        var leagueName: String = ""
        var myTeamName: String = ""
        var providerLabel: String = ""
        var leagueLinkId: String = ""
        /// When > 1, the Live Activity shows a cycle control.
        var leagueCount: Int = 1
        /// Live starters on my roster (`Name  12.3`).
        var myPlayerLines: [String] = []
        /// Live starters on the opponent (`Name  12.3`).
        var oppPlayerLines: [String] = []
        /// Active NFL games (`KC @ LAC  12:34`).
        var nflGameLines: [String] = []
    }

    /// Static shell — prefer ContentState fields for anything that can change mid-activity.
    var leagueName: String
    var myTeamName: String
    var providerLabel: String
}

enum MatchupLiveSyncSchedule {
    /// Matches the backend poll cadence (wrangler.toml / scores.ts).
    static let intervalSeconds: TimeInterval = 5 * 60
    /// How long each cycled player / NFL game stays on screen.
    static let cycleSeconds: TimeInterval = 1.5

    /// Target time for the next refresh: always ~5 minutes after `date`.
    static func nextSyncAt(after date: Date = Date()) -> Double {
        date.timeIntervalSince1970 + intervalSeconds
    }
}

extension MatchupLiveAttributes.ContentState {
    /// Prefer dedicated my lines; fall back to legacy `playerLines`.
    var resolvedMyPlayerLines: [String] {
        myPlayerLines.isEmpty ? playerLines : myPlayerLines
    }
}
